/* Nether guest agent: the in-sandbox command executor an agent platform drives.
 *
 * Connects to the host (CID 2) on the agent control port and then serves a stream
 * of newline-terminated commands: for each, it runs the command through /bin/sh
 * and streams stdout+stderr back over the same vsock connection. This is the
 * keystone that turns the sandbox into an agent runtime - the host executes code
 * inside an isolated guest and collects results over the control channel, with no
 * network, ssh, or shared filesystem. It exits quietly if the host is not there
 * (so it is harmless to auto-start from /init on every boot).
 *
 * Build static for the guest with Zig's bundled clang:
 *   zig cc -target aarch64-linux-musl -static -O2 tools/agent.c -o agent
 */
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

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
        while ((r = fread(buf, 1, sizeof buf, p)) > 0) {
            size_t off = 0;
            while (off < r) {
                ssize_t w = write(s, buf + off, r - off);
                if (w <= 0) { off = r; break; }
                off += (size_t)w;
            }
        }
        int st = pclose(p);
        code = WIFEXITED(st) ? WEXITSTATUS(st) : 128;
    }
    char tr[24];
    int m = snprintf(tr, sizeof tr, "\x1e%d\n", code);
    write(s, tr, (size_t)m);
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

    /* Serve a stream of newline-terminated commands until the host closes. */
    char buf[8192];
    size_t len = 0;
    for (;;) {
        long n = read(s, buf + len, sizeof buf - len - 1);
        if (n <= 0) break;
        len += (size_t)n;
        size_t start = 0;
        for (size_t i = 0; i < len; i++) {
            if (buf[i] == '\n') {
                buf[i] = 0;
                if (buf[start]) run(s, buf + start);
                start = i + 1;
            }
        }
        if (start > 0) {
            memmove(buf, buf + start, len - start);
            len -= start;
        }
        if (len >= sizeof buf - 1) len = 0; // overlong line: reset
    }
    close(s);
    return 0;
}
