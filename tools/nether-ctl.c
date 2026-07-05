/* nether-ctl: a reference client for the Nether control protocol.
 *
 * The control socket (docs/control-protocol.md) is the platform's integration
 * contract. This is the canonical example of speaking it: the proto-version
 * handshake, sending a command, and reassembling the framed reply. It is also a
 * handy operator tool (cleaner than raw `nc -U`, which can't parse the framing or
 * surface the guest exit code) and a live smoke for the contract.
 *
 *   nether-ctl <socket-path>              # handshake, print __info__
 *   nether-ctl <socket-path> <command...> # handshake, run command, print reply
 *
 * On connect it sends __info__, reads the report, and reads proto_version (it speaks
 * both 1 and 2, adapting the read loop; any other version warns and continues). Then it
 * sends the command line and reads the reply. In v2 every command/ack reply is framed
 * with `0x1e<exit>\n` (reports, shell commands, AND the acks __shutdown__/__snapshot__/
 * __put__/__get__): we read to the 0x1e, print the body before it, and exit with the code
 * (a guest 0..255, or a v2 control-plane error <0 which we map to CLI status 1). In v1 the
 * acks and any ERR/OK were BARE lines with no 0x1e; the bare-status settle guard still
 * handles them (harmless under v2, where the 0x1e always arrives). The self-delimiting logs
 * (__events__/__cmdlog__/__netlog__), render snapshots, and binary replies (__frame__)
 * carry no frame, so we drain until the socket goes idle.
 * Build (host): cc -O2 tools/nether-ctl.c -o nether-ctl
 */
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <limits.h>

#define RS 0x1e           /* the reply frame separator: body ends at 0x1e, then <exit>\n */
#define HANG_MS 60000     /* framed reply: give up only after this long with NO progress */
#define IDLE_MS 2000      /* unframed reply: a gap this long after data means it's done */
#define SETTLE_MS 500     /* a leading ERR/OK line with no 0x1e this long is a bare reply */
#define BUFCAP (1 << 20)  /* 1 MiB reply ceiling (a full screen/frame fits) */

/* The GUARD against the unframed-reply hang: an `ERR <reason>\n` (and the `OK ...\n`
 * from __shutdown__/__put__/__get__) is a bare single line with NO 0x1e frame, and can
 * come back for a command a client expected to be framed (e.g. a stray __verb__, or
 * "ERR read-only observer" / "ERR too many control clients"). A reader blocking until
 * 0x1e would hang. So in the framed path, once the buffer is a complete ERR/OK line with
 * no 0x1e, we only wait SETTLE_MS more (a real command's 0x1e<exit> trailer follows its
 * output immediately) before treating it as a terminal unframed reply and failing fast. */
static int bare_status_line(const char *buf, size_t len) {
    if (memchr(buf, RS, len)) return 0;             /* a 0x1e means it is (becoming) framed */
    if (memchr(buf, '\n', len) == NULL) return 0;   /* not a complete line yet */
    return (len >= 4 && memcmp(buf, "ERR ", 4) == 0) || (len >= 3 && memcmp(buf, "OK ", 3) == 0);
}

/* Does this command's reply end with the 0x1e<exit>\n frame? Depends on the negotiated
 * proto_version. In BOTH versions: shell commands and the report queries
 * (__info__/__stats__/__help__) are framed; the logs (__events__/__cmdlog__/__netlog__) and
 * render/framebuffer snapshots are self-delimiting/binary (not framed). The difference is the
 * acks: in v1 __shutdown__/__snapshot__/__put__/__get__ replied with a BARE OK/ERR line (read
 * unframed), but in v2 they are FRAMED like everything else (0x1e<exit>\n), so a client reads
 * them with the one framed loop and gets the exit code. We must know which, because a framed
 * reply has to be read until its 0x1e (a slow command can pause arbitrarily before it), while
 * an unframed reply has no in-band terminator. */
static int is_framed(const char *cmd, int proto) {
    if (strncmp(cmd, "__", 2) != 0) return 1; /* a shell command -> agent frame */
    if (strncmp(cmd, "__info__", 8) == 0 ||
        strncmp(cmd, "__stats__", 9) == 0 ||
        strncmp(cmd, "__help__", 8) == 0) return 1;
    /* v2: the acks are framed too (v1 sent them bare). */
    if (proto >= 2 &&
        (strncmp(cmd, "__shutdown__", 12) == 0 || strncmp(cmd, "__snapshot__", 12) == 0 ||
         strncmp(cmd, "__put__", 7) == 0 || strncmp(cmd, "__get__", 7) == 0)) return 1;
    return 0; /* logs / render / binary: self-delimiting */
}

static int connect_unix(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) + 1 > sizeof(addr.sun_path)) { close(fd); return -1; }
    strcpy(addr.sun_path, path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    return fd;
}

static int write_full(int fd, const char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, buf + off, n - off);
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return 0;
}

/* Read one reply into `buf`. For a `framed` reply, block until the 0x1e<exit>\n frame
 * arrives (a slow command may pause arbitrarily before it; only a HANG_MS gap with no
 * data at all is treated as a dead guest). For an unframed reply (logs/binary/ERR),
 * there is no in-band terminator, so return once the stream goes idle after data, or on
 * EOF. Returns the body byte count (for framed, excludes the frame); *exit_code is the
 * framed exit (a guest 0..255, or a v2 control-plane error <0), or INT_MIN if the reply
 * carried no frame/exit. (Do NOT use -1 as "no exit": v2 control errors ARE -1.) */
static ssize_t read_reply(int fd, char *buf, size_t cap, int *exit_code, int framed) {
    *exit_code = INT_MIN;
    size_t len = 0;
    for (;;) {
        /* framed normally blocks (HANG_MS) until the 0x1e frame; but once the buffer is
         * a bare ERR/OK line, settle quickly so a stray unframed reply fails fast. */
        int timeout = !framed ? IDLE_MS : (bare_status_line(buf, len) ? SETTLE_MS : HANG_MS);
        struct pollfd p = { .fd = fd, .events = POLLIN };
        int r = poll(&p, 1, timeout);
        if (r <= 0) break;  /* timeout: dead guest (framed) / idle done (unframed) / ERR settled */
        ssize_t n = read(fd, buf + len, cap - len);
        if (n <= 0) break;  /* EOF / error */
        len += (size_t)n;
        if (framed) {
            /* body ends at 0x1e, then "<exit>\n" (wait for the newline after it). */
            char *rs = memchr(buf, RS, len);
            if (rs && memchr(rs, '\n', len - (size_t)(rs - buf))) {
                *exit_code = atoi(rs + 1);
                return rs - buf;
            }
        }
        if (len == cap) break;  /* full: stop (truncated, but safe) */
    }
    /* No 0x1e frame arrived. A bare `ERR ...` line is a failure -> non-zero exit so a
     * framed caller does not mistake it for success. */
    if (len >= 4 && memcmp(buf, "ERR ", 4) == 0) *exit_code = 1;
    return (ssize_t)len;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <control-socket> [command...]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    int fd = connect_unix(path);
    if (fd < 0) { fprintf(stderr, "nether-ctl: cannot connect to %s\n", path); return 1; }

    static char buf[BUFCAP];

    /* Handshake: __info__ then verify proto_version. */
    if (write_full(fd, "__info__\n", 9) < 0) { fprintf(stderr, "nether-ctl: write failed\n"); return 1; }
    int ec;
    ssize_t n = read_reply(fd, buf, sizeof(buf), &ec, 1); /* __info__ is framed */
    if (n <= 0) { fprintf(stderr, "nether-ctl: no __info__ reply\n"); return 1; }
    buf[n < (ssize_t)sizeof(buf) ? n : (ssize_t)sizeof(buf) - 1] = '\0';
    int proto = 1;
    char *pv = strstr(buf, "proto_version=");
    if (!pv) {
        fprintf(stderr, "nether-ctl: warning: no proto_version in __info__ (old nether?)\n");
    } else {
        proto = atoi(pv + strlen("proto_version="));
        if (proto != 1 && proto != 2)
            fprintf(stderr, "nether-ctl: warning: proto_version=%d, expected 1 or 2 (breaking change)\n", proto);
    }

    /* No command: the handshake's __info__ report IS the output. */
    if (argc == 2) { (void)write_full(1, buf, (size_t)n); return 0; }

    /* Join argv[2..] into one space-separated command line. */
    static char cmd[8192];
    size_t clen = 0;
    for (int i = 2; i < argc && clen < sizeof(cmd) - 2; i++) {
        if (i > 2) cmd[clen++] = ' ';
        size_t al = strlen(argv[i]);
        if (clen + al >= sizeof(cmd) - 2) break;
        memcpy(cmd + clen, argv[i], al);
        clen += al;
    }
    cmd[clen++] = '\n';
    if (write_full(fd, cmd, clen) < 0) { fprintf(stderr, "nether-ctl: write failed\n"); return 1; }

    n = read_reply(fd, buf, sizeof(buf), &ec, is_framed(argv[2], proto));
    if (n < 0) { fprintf(stderr, "nether-ctl: read failed\n"); return 1; }
    (void)write_full(1, buf, (size_t)n);
    /* Exit status: a framed reply carries an exit (a guest 0..255, or a v2 control-plane
     * error <0); an unframed reply carries none. Map a control error to a non-zero CLI
     * status (an OS exit is a byte, so a negative can't pass through) and mask a guest exit
     * to its byte. */
    if (ec == INT_MIN) return 0;   /* no framed exit (unframed reply / bare OK ack) */
    if (ec < 0) return 1;          /* v2 control-plane error */
    return ec & 0xff;              /* guest / report exit code */
}
