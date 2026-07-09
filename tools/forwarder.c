/* nether in-guest data-plane forwarder (Phase 2 of docs/park-concurrency-plan.md, 3b).
 *
 * INBOUND (data plane): the host dials this forwarder's vsock port (FWD_VSOCK_PORT); for
 * each accepted vsock connection the forwarder opens a TCP connection to the tenant's
 * ordinary localhost server (127.0.0.1:<app_port>, from `nether.app_port` on the kernel
 * cmdline) and splices bytes both ways. So a tenant runs a completely ordinary loopback
 * TCP server - zero vsock awareness - and swerver reaches it as a concurrent upstream.
 *
 * OUTBOUND (egress plane, park-while-awaiting): reverse mode. When the host sets
 * `nether.egress_port=<n>`, the forwarder ALSO listens on 127.0.0.1:<n>; each accepted
 * loopback conn (the tenant's ordinary outbound request) is bridged to a guest->host
 * vsock conn on EGRESS_VSOCK_PORT, which the host splices to the platform's upstream
 * proxy. Because the vsock conn is pure in-memory state it survives a snapshot - so a
 * guest blocked awaiting a slow upstream reply can be parked (snapshot + kill) and a
 * restored fork completes the SAME blocking recv() when the reply arrives.
 *
 * One poll() reactor handles many concurrent connections: the listen socket(s) plus, per
 * live connection, the vsock fd and the tcp fd. Static aarch64 musl, no libc dep on the
 * rootfs.
 *
 * v1 note: read-then-blocking-write per event (a stalled peer could briefly hold the loop);
 * the plan's Phase 3 refines this to non-blocking writes with per-conn out buffers. */
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_ANY 0xFFFFFFFFu
#define VMADDR_CID_HOST 2u
#define FWD_VSOCK_PORT 5001    /* the agent owns 5000; the data plane uses 5001 */
#define EGRESS_VSOCK_PORT 5002 /* guest->host egress plane; must match control.zig */
#define MAX_CONN 64            /* mirrors the host vsock engine's MAX_CONNS */

struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[4];
};

/* One live bridge: a vsock fd (to the host) spliced to a tcp fd (to the tenant server). */
struct pair {
    int vf;
    int tf;
};

static int g_app_port = 0;
static int g_egress_port = 0;

static void read_ports(void) {
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) return;
    char line[4096];
    char *got = fgets(line, sizeof line, f);
    fclose(f);
    if (!got) return;
    char *p = strstr(line, "nether.app_port=");
    if (p) g_app_port = atoi(p + strlen("nether.app_port="));
    p = strstr(line, "nether.egress_port=");
    if (p) g_egress_port = atoi(p + strlen("nether.egress_port="));
}

/* Connect to the tenant's loopback server. Returns the fd, or -1 (server not up yet). */
static int dial_app(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)g_app_port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); /* 127.0.0.1 */
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Egress plane: dial the HOST's vsock listener (the bridge splices it to the platform's
 * upstream proxy). Returns the fd, or -1. */
static int dial_host_egress(void) {
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_port = EGRESS_VSOCK_PORT;
    a.svm_cid = VMADDR_CID_HOST;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Listen on 127.0.0.1:<port> (the egress plane's in-guest front door). -1 on failure. */
static int listen_loopback(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, MAX_CONN) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Read from `from`, write it all to `to`. Returns bytes spliced (>0), 0 on read EOF, or
 * -1 on a read/write error. The caller closes the pair when this is <= 0. */
static long splice_once(int from, int to) {
    char buf[16384];
    ssize_t r = read(from, buf, sizeof buf);
    if (r <= 0) return r; /* 0 = EOF, <0 = read error (e.g. ECONNRESET) */
    size_t off = 0;
    while (off < (size_t)r) {
        ssize_t w = write(to, buf + off, (size_t)r - off);
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return (long)r;
}

int main(void) {
    read_ports();
    if (g_app_port <= 0 && g_egress_port <= 0) return 0; /* not configured: nothing to do */

    /* Inbound data plane: vsock listener the host bridge dials. Only with app_port. */
    int ls = -1;
    if (g_app_port > 0) {
        ls = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (ls < 0) return 1;
        struct sockaddr_vm la;
        memset(&la, 0, sizeof la);
        la.svm_family = AF_VSOCK;
        la.svm_port = FWD_VSOCK_PORT;
        la.svm_cid = VMADDR_CID_ANY;
        if (bind(ls, (struct sockaddr *)&la, sizeof la) < 0) return 1;
        if (listen(ls, MAX_CONN) < 0) return 1;
    }
    /* Outbound egress plane: loopback listener the tenant's ordinary outbound conns hit.
     * Poll ignores fd=-1 slots, so an unconfigured plane simply never fires. */
    int els = (g_egress_port > 0) ? listen_loopback(g_egress_port) : -1;
    if (g_egress_port > 0 && els < 0) return 1;

    struct pair conns[MAX_CONN];
    int nconn = 0;
    struct pollfd pfds[2 + 2 * MAX_CONN];

    for (;;) {
        pfds[0].fd = ls;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = els;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;
        for (int i = 0; i < nconn; i++) {
            pfds[2 + 2 * i].fd = conns[i].vf;
            pfds[2 + 2 * i].events = POLLIN;
            pfds[2 + 2 * i].revents = 0;
            pfds[3 + 2 * i].fd = conns[i].tf;
            pfds[3 + 2 * i].events = POLLIN;
            pfds[3 + 2 * i].revents = 0;
        }
        if (poll(pfds, (nfds_t)(2 + 2 * nconn), -1) < 0) continue;

        /* New host->guest connection: accept it and dial the tenant server. Then loop back
         * to poll() BEFORE servicing: the new pair is not in the current pfds, so servicing
         * this round would read stale revents and could block read() on a not-ready fd. */
        if (ls >= 0 && (pfds[0].revents & POLLIN)) {
            int vf = accept(ls, NULL, NULL);
            if (vf >= 0) {
                int tf = (nconn < MAX_CONN) ? dial_app() : -1;
                if (tf >= 0) {
                    conns[nconn].vf = vf;
                    conns[nconn].tf = tf;
                    nconn++;
                } else {
                    close(vf); /* pool full or server not up: refuse this conn */
                }
            }
            continue;
        }

        /* New tenant OUTBOUND connection (egress plane): accept the loopback conn and
         * bridge it to a guest->host vsock conn. Same accept-then-repoll discipline. */
        if (els >= 0 && (pfds[1].revents & POLLIN)) {
            int tf = accept(els, NULL, NULL);
            if (tf >= 0) {
                int vf = (nconn < MAX_CONN) ? dial_host_egress() : -1;
                if (vf >= 0) {
                    conns[nconn].vf = vf;
                    conns[nconn].tf = tf;
                    nconn++;
                } else {
                    close(tf); /* pool full or host egress plane off: refuse */
                }
            }
            continue;
        }

        /* Service live pairs. Closing one swaps in the last (keeping the array dense) and
         * breaks: the remaining pfds revents are then stale, so we rebuild via poll(),
         * which is level-triggered and re-fires immediately for any still-readable fd. */
        for (int i = 0; i < nconn; i++) {
            int dead = 0;
            /* Splice on ANY event (POLLIN/POLLHUP/POLLERR): a peer that closed or errored may
             * STILL have BUFFERED data to read (a normal close reports POLLIN|POLLERR|POLLHUP
             * together). So we always try to read, and only close when splice_once itself
             * returns <= 0 (a true read EOF or a read/write error) - NEVER on the poll flags
             * alone. Level-triggered poll re-fires, so a hung-up-but-nonempty fd is drained
             * fully before we close. Without this, the tail of a transfer whose sender closed
             * while data was still buffered is silently lost. */
            const short any = POLLIN | POLLHUP | POLLERR;
            if (pfds[2 + 2 * i].revents & any)
                if (splice_once(conns[i].vf, conns[i].tf) <= 0) dead = 1;
            if (!dead && (pfds[3 + 2 * i].revents & any))
                if (splice_once(conns[i].tf, conns[i].vf) <= 0) dead = 1;
            if (dead) {
                close(conns[i].vf);
                close(conns[i].tf);
                conns[i] = conns[nconn - 1];
                nconn--;
                break;
            }
        }
    }
    return 0;
}
