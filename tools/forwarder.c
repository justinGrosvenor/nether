/* nether in-guest data-plane forwarder (Phase 2 of docs/park-concurrency-plan.md, 3b).
 *
 * The host dials this forwarder's vsock port (FWD_VSOCK_PORT); for each accepted vsock
 * connection the forwarder opens a TCP connection to the tenant's ordinary localhost
 * server (127.0.0.1:<app_port>, from `nether.app_port` on the kernel cmdline) and splices
 * bytes both ways. So a tenant runs a completely ordinary loopback TCP server - zero vsock
 * awareness - and swerver reaches it as a concurrent upstream via the host bridge.
 *
 * One poll() reactor handles many concurrent connections: the listen socket plus, per live
 * connection, the vsock fd and the tcp fd. Static aarch64 musl, no libc dep on the rootfs.
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
#define FWD_VSOCK_PORT 5001 /* the agent owns 5000; the data plane uses 5001 */
#define MAX_CONN 64         /* mirrors the host vsock engine's MAX_CONNS */

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

static void read_app_port(void) {
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) return;
    char line[4096];
    char *got = fgets(line, sizeof line, f);
    fclose(f);
    if (!got) return;
    char *p = strstr(line, "nether.app_port=");
    if (!p) return;
    p += strlen("nether.app_port=");
    g_app_port = atoi(p);
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

/* Read from `from`, write it all to `to`. Returns 0 on EOF/error (caller closes the pair). */
static int splice_once(int from, int to) {
    char buf[16384];
    ssize_t r = read(from, buf, sizeof buf);
    if (r <= 0) return 0;
    size_t off = 0;
    while (off < (size_t)r) {
        ssize_t w = write(to, buf + off, (size_t)r - off);
        if (w <= 0) return 0;
        off += (size_t)w;
    }
    return 1;
}

int main(void) {
    read_app_port();
    if (g_app_port <= 0) return 0; /* not configured: nothing to forward */

    int ls = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (ls < 0) return 1;
    struct sockaddr_vm la;
    memset(&la, 0, sizeof la);
    la.svm_family = AF_VSOCK;
    la.svm_port = FWD_VSOCK_PORT;
    la.svm_cid = VMADDR_CID_ANY;
    if (bind(ls, (struct sockaddr *)&la, sizeof la) < 0) return 1;
    if (listen(ls, MAX_CONN) < 0) return 1;

    struct pair conns[MAX_CONN];
    int nconn = 0;
    struct pollfd pfds[1 + 2 * MAX_CONN];

    for (;;) {
        pfds[0].fd = ls;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        for (int i = 0; i < nconn; i++) {
            pfds[1 + 2 * i].fd = conns[i].vf;
            pfds[1 + 2 * i].events = POLLIN;
            pfds[1 + 2 * i].revents = 0;
            pfds[2 + 2 * i].fd = conns[i].tf;
            pfds[2 + 2 * i].events = POLLIN;
            pfds[2 + 2 * i].revents = 0;
        }
        if (poll(pfds, (nfds_t)(1 + 2 * nconn), -1) < 0) continue;

        /* New host->guest connection: accept it and dial the tenant server. */
        if (pfds[0].revents & POLLIN) {
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
        }

        /* Service live pairs. Closing one swaps in the last (keeping the array dense) and
         * breaks: the remaining pfds revents are then stale, so we rebuild via poll(),
         * which is level-triggered and re-fires immediately for any still-readable fd. */
        for (int i = 0; i < nconn; i++) {
            int dead = 0;
            if (pfds[1 + 2 * i].revents & POLLIN)
                if (!splice_once(conns[i].vf, conns[i].tf)) dead = 1;
            if (!dead && (pfds[2 + 2 * i].revents & POLLIN))
                if (!splice_once(conns[i].tf, conns[i].vf)) dead = 1;
            if (!dead && ((pfds[1 + 2 * i].revents | pfds[2 + 2 * i].revents) & (POLLHUP | POLLERR)))
                dead = 1;
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
