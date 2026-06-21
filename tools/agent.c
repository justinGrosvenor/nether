/* Nether guest agent: the in-sandbox command executor an agent platform drives.
 *
 * Connects to the host (CID 2) on the agent control port and then serves a stream
 * of newline-terminated requests over vsock. Three request kinds:
 *
 *   <shell command>\n
 *       run it through /bin/sh, stream stdout+stderr, then a trailer 0x1e<code>\n.
 *   __PUT__ <path> <len>\n<len raw bytes>
 *       write the bytes to <path> (the file payload follows the header line raw,
 *       so it may contain newlines/NULs/0x1e); reply "OK\n" or "ERR\n".
 *   __GET__ <path>\n
 *       reply "OK <len>\n" followed by <len> raw bytes, or "ERR\n".
 *
 * This is the keystone that turns the sandbox into an agent runtime - the host runs
 * code inside an isolated guest and moves task payloads/artifacts in and out over
 * the control channel, with no network, ssh, or shared filesystem. It exits quietly
 * if the host is not there (so it is harmless to auto-start from /init).
 *
 * Build static for the guest with Zig's bundled clang:
 *   zig cc -target aarch64-linux-musl -static -O2 tools/agent.c -o agent
 */
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_HOST 2
#define AGENT_PORT 5000

struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[4];
};

static void write_full(int s, const char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(s, buf + off, n - off);
        if (w <= 0) return;
        off += (size_t)w;
    }
}

/* Run one command and frame the reply: stream stdout+stderr, then a trailer
 * 0x1e<exit-code>\n so the host can tell where the output ends and whether the
 * command succeeded. (0x1e = ASCII record separator, won't appear in text.) */
static void run(int s, const char *cmd) {
    char shell[4160];
    snprintf(shell, sizeof shell, "%s 2>&1", cmd);
    FILE *p = popen(shell, "r");
    int code = 127;
    if (p) {
        char buf[4096];
        size_t r;
        while ((r = fread(buf, 1, sizeof buf, p)) > 0) write_full(s, buf, r);
        int st = pclose(p);
        code = WIFEXITED(st) ? WEXITSTATUS(st) : 128;
    }
    char tr[24];
    int m = snprintf(tr, sizeof tr, "\x1e%d\n", code);
    write_full(s, tr, (size_t)m);
}

/* __GET__ <path>: reply "OK <len>\n" + the file bytes, or "ERR\n". */
static void do_get(int s, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { write_full(s, "ERR\n", 4); return; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); write_full(s, "ERR\n", 4); return; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); write_full(s, "ERR\n", 4); return; }
    fseek(f, 0, SEEK_SET);
    char hdr[32];
    int m = snprintf(hdr, sizeof hdr, "OK %ld\n", sz);
    write_full(s, hdr, (size_t)m);
    char b[4096];
    size_t r;
    while ((r = fread(b, 1, sizeof b, f)) > 0) write_full(s, b, r);
    fclose(f);
}

int main(void) {
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) return 1;
    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_port = AGENT_PORT;
    a.svm_cid = VMADDR_CID_HOST;
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) return 0; // no host -> exit quietly

    /* A small state machine over the byte stream: LINE accumulates a request line;
     * a __PUT__ header switches to RAW to consume exactly <len> payload bytes (which
     * may contain newlines/binary) into the file, then back to LINE. */
    enum { LINE, RAW };
    int state = LINE;
    FILE *putf = NULL;
    long put_remaining = 0;
    int put_err = 0;

    char buf[8192];
    size_t len = 0;
    for (;;) {
        ssize_t n = read(s, buf + len, sizeof buf - len);
        if (n <= 0) break;
        len += (size_t)n;
        size_t pos = 0;
        while (pos < len) {
            if (state == RAW) {
                size_t avail = len - pos;
                size_t take = avail < (size_t)put_remaining ? avail : (size_t)put_remaining;
                if (putf && take && fwrite(buf + pos, 1, take, putf) != take) put_err = 1;
                pos += take;
                put_remaining -= (long)take;
                if (put_remaining == 0) {
                    int code = put_err;
                    if (putf) { if (fclose(putf)) code = 1; putf = NULL; }
                    else code = 1;
                    write_full(s, code ? "ERR\n" : "OK\n", code ? 4 : 3);
                    state = LINE;
                }
                continue;
            }
            char *nl = memchr(buf + pos, '\n', len - pos);
            if (!nl) break; // partial line: keep it, read more
            *nl = 0;
            char *line = buf + pos;
            pos += (size_t)(nl - line) + 1;
            if (!line[0]) {
                continue;
            } else if (strncmp(line, "__PUT__ ", 8) == 0) {
                char *sp = strrchr(line + 8, ' ');
                if (!sp) { write_full(s, "ERR\n", 4); continue; }
                *sp = 0;
                putf = fopen(line + 8, "wb");
                put_err = 0;
                put_remaining = atol(sp + 1);
                state = RAW;
                if (put_remaining <= 0) { // zero-length (or bad) -> finish now
                    int code = (putf && fclose(putf) == 0) ? 0 : 1;
                    putf = NULL;
                    write_full(s, code ? "ERR\n" : "OK\n", code ? 4 : 3);
                    state = LINE;
                }
            } else if (strncmp(line, "__GET__ ", 8) == 0) {
                do_get(s, line + 8);
            } else {
                run(s, line);
            }
        }
        if (pos > 0) { memmove(buf, buf + pos, len - pos); len -= pos; }
        if (len == sizeof buf) len = 0; // overlong line guard (LINE state only)
    }
    if (putf) fclose(putf);
    close(s);
    return 0;
}
