/* Nether guest agent: the in-sandbox command executor an agent platform drives.
 *
 * Connects to the host (CID 2) on the agent control port, reads one command, runs
 * it through /bin/sh, and streams the output back over the same vsock connection.
 * This is the keystone that turns the sandbox into an agent runtime: the host can
 * execute code inside an isolated guest and collect the result over the control
 * channel, with no network, ssh, or shared filesystem.
 *
 * Build static for the guest with Zig's bundled clang:
 *   zig cc -target aarch64-linux-musl -static -O2 tools/agent.c -o agent
 * Then drop `agent` into the initramfs and run it after the vsock modules load
 * (recipe in docs/running-on-hvf.md).
 */
#include <sys/socket.h>
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

int main(void) {
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }

    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_port = AGENT_PORT;
    a.svm_cid = VMADDR_CID_HOST;
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) { perror("connect"); return 2; }

    /* The host sends one command line on connect. */
    char cmd[4096];
    long n = read(s, cmd, sizeof cmd - 1);
    if (n <= 0) { close(s); return 3; }
    cmd[n] = 0;

    /* Run it and stream stdout+stderr back over the connection. */
    char shell[4160];
    snprintf(shell, sizeof shell, "%s 2>&1", cmd);
    FILE *p = popen(shell, "r");
    if (!p) { const char *m = "agent: popen failed\n"; write(s, m, strlen(m)); close(s); return 4; }

    char buf[4096];
    size_t r;
    while ((r = fread(buf, 1, sizeof buf, p)) > 0) {
        ssize_t off = 0;
        while ((size_t)off < r) {
            ssize_t w = write(s, buf + off, r - off);
            if (w <= 0) break;
            off += w;
        }
    }
    pclose(p);
    close(s);
    return 0;
}
