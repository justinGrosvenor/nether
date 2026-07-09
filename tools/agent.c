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
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pwd.h>
#include <grp.h>

/* Guest is always Linux (aarch64-linux-musl); musl defines SOCK_CLOEXEC, but guard it so
 * a host-SDK lint pass (macOS, no such flag) still parses this file. */
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 02000000
#endif

/* Optional in-guest privilege drop (defense-in-depth; the VM is the primary boundary).
 * The host sets `nether.run_as=<user>` on the kernel cmdline when run_as= is in
 * nether.conf; we resolve it once and run every command under that uid/gid instead of
 * root, so a guest-kernel escape starts unprivileged. Default: run as root (g_drop=0). */
static uid_t g_uid = 0;
static gid_t g_gid = 0;
static int g_drop = 0;

static void init_runas(void) {
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) return;
    char line[4096];
    char *got = fgets(line, sizeof line, f);
    fclose(f);
    if (!got) return;
    char *p = strstr(line, "nether.run_as=");
    if (!p) return;
    p += strlen("nether.run_as=");
    char user[64];
    int i = 0;
    while (p[i] && p[i] != ' ' && p[i] != '\n' && i < (int)sizeof user - 1) { user[i] = p[i]; i++; }
    user[i] = 0;
    if (!user[0]) return;
    struct passwd *pw = getpwnam(user);
    if (pw && pw->pw_uid != 0) {
        g_uid = pw->pw_uid;
        g_gid = pw->pw_gid;
        g_drop = 1;
        /* Give dropped commands the user's environment so `~`, $HOME-based tools, and
         * shells behave (else HOME stays the agent's "/" and writes there are denied). */
        setenv("HOME", (pw->pw_dir && pw->pw_dir[0]) ? pw->pw_dir : "/home", 1);
        setenv("USER", user, 1);
        setenv("LOGNAME", user, 1);
    }
}

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

/* Frame delimiters for a command reply (must match src/agent/control.zig):
 *   OUT_DELIM 0x1e  ends the output and begins the exit trailer.
 *   OUT_ESC   0x1f  escape lead inside the output body.
 * Untrusted command stdout can contain ANY byte, including 0x1e - so we must NOT
 * assume "0x1e won't appear in text" (it can, and a hostile workload could forge a
 * trailer). write_escaped stuffs the two control bytes out of the body: 0x1e/0x1f ->
 * 0x1f then (byte ^ 0x40) (a printable ^ / _). After this a raw 0x1e appears on the
 * wire ONLY as the real trailer, so the boundary is unforgeable by body content. The
 * host un-escapes for display; see docs/control-protocol.md "Output framing". */
#define OUT_DELIM 0x1e
#define OUT_ESC 0x1f
#define OUT_ESC_XOR 0x40

static void write_escaped(int s, const char *buf, size_t n) {
    char out[8192]; /* 2x a 4096 read at worst (every byte escaped) */
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char b = (unsigned char)buf[i];
        if (b == OUT_DELIM || b == OUT_ESC) {
            if (j + 2 > sizeof out) { write_full(s, out, j); j = 0; }
            out[j++] = OUT_ESC;
            out[j++] = (char)(b ^ OUT_ESC_XOR);
        } else {
            if (j + 1 > sizeof out) { write_full(s, out, j); j = 0; }
            out[j++] = (char)b;
        }
    }
    if (j) write_full(s, out, j);
}

/* Run one command and frame the reply: stream stdout+stderr (delimiter-escaped so the
 * body can never forge a frame boundary), then a raw trailer 0x1e<exit-code>\n so the
 * host can tell where the output ends and whether the command succeeded. */
static void run(int s, const char *cmd) {
    /* fork + pipe + exec `sh -c <cmd>` (the cmd is a direct argv, so no quoting hazard),
     * merging stderr into stdout and, when configured, dropping to the run_as uid/gid
     * before exec. (Replaces popen so the privilege drop is robust and stays in-process.) */
    int fds[2];
    int code = 127;
    if (pipe(fds) == 0) {
        pid_t pid = fork();
        if (pid == 0) {
            close(fds[0]);
            dup2(fds[1], 1);
            dup2(fds[1], 2); // stderr -> stdout (the old "2>&1")
            close(fds[1]);
            if (g_drop) {
                /* groups, then gid, then uid - once the uid drops, gid is fixed. */
                setgroups(1, &g_gid);
                if (setgid(g_gid) != 0) _exit(126);
                if (setuid(g_uid) != 0) _exit(126);
            }
            execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
            _exit(127);
        } else if (pid > 0) {
            close(fds[1]);
            char buf[4096];
            ssize_t r;
            while ((r = read(fds[0], buf, sizeof buf)) > 0) write_escaped(s, buf, (size_t)r);
            close(fds[0]);
            int st;
            waitpid(pid, &st, 0);
            code = WIFEXITED(st) ? WEXITSTATUS(st) : 128;
        } else {
            close(fds[0]);
            close(fds[1]);
        }
    }
    char tr[24];
    int m = snprintf(tr, sizeof tr, "\x1e%d\n", code);
    write_full(s, tr, (size_t)m);
}

/* Kernel entropy ioctls (<linux/random.h>). Defined by hand (guarded) so a host-SDK
 * lint pass on macOS - which has no linux/random.h - still parses this file; both
 * macOS and musl sys/ioctl.h provide _IO/_IOW. Layout matches struct rand_pool_info:
 * { int entropy_count; int buf_size; __u32 buf[]; } with buf_size in BYTES. */
#ifndef RNDADDENTROPY
#define RNDADDENTROPY _IOW('R', 0x03, int[2])
#endif
#ifndef RNDRESEEDCRNG
#define RNDRESEEDCRNG _IO('R', 0x07)
#endif

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* __reseed__ <hex>: HOST-ONLY internal command, never passed to the shell. Nether
 * queues it on the surviving agent conn at fork restore, before the guest resumes:
 * sibling forks of one base restore IDENTICAL crng state, so this feeds up to 64
 * bytes of fresh host entropy via RNDADDENTROPY with entropy_count = bits (the
 * agent is root; the kernel CREDITS the entropy) and then forces an immediate crng
 * reseed with RNDRESEEDCRNG so the very next getrandom()/urandom read draws from
 * the new state (credited input-pool entropy alone waits for the next scheduled
 * reseed - measured, not assumed).
 *
 * SILENT by contract: NO output and NO 0x1e trailer, on success OR failure. The
 * host fires this before any control client attaches; a stray frame would desync
 * the client's request/response framing (it never sent a command). Malformed hex,
 * missing device, failed ioctl: silently ignored (fail-open - the fork is then
 * merely no better than an unreseeded one). The agent has no log file; stderr goes
 * to the console, so diagnostics are deliberately omitted too. */
static void do_reseed(const char *hex) {
    struct { int entropy_count; int buf_size; unsigned char buf[64]; } rpi;
    int n = 0;
    while (n < (int)sizeof rpi.buf) {
        int hi = hexval((unsigned char)hex[2 * n]);
        int lo = hi < 0 ? -1 : hexval((unsigned char)hex[2 * n + 1]);
        if (lo < 0) break; /* end of hex (or malformed/odd tail: stop there) */
        rpi.buf[n++] = (unsigned char)((hi << 4) | lo);
    }
    if (n == 0) return;
    int fd = open("/dev/urandom", O_RDWR); /* same pool as /dev/random */
    if (fd < 0) return;
    rpi.entropy_count = n * 8;
    rpi.buf_size = n;
    if (ioctl(fd, RNDADDENTROPY, &rpi) == 0) ioctl(fd, RNDRESEEDCRNG);
    close(fd);
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
    init_runas(); // pick up nether.run_as=<user> from the kernel cmdline, if set
    // SOCK_CLOEXEC: the host control fd must NOT survive into an exec'd guest command.
    // Without it every `sh -c cmd` inherits this fd and could write framing bytes into
    // the control stream (forge exit codes / desync metering) or read queued payloads -
    // defeating the run_as containment. run() closes the pipe fds in the child but not
    // this one; CLOEXEC closes it on exec automatically (the agent parent never execs).
    int s = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
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
            } else if (strncmp(line, "__reseed__ ", 11) == 0) {
                do_reseed(line + 11); /* host-internal; silent - no output, no trailer */
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
