/* Minimal AF_VSOCK client for exercising Nether's virtio-vsock on aarch64.
 *
 * Connects to the host (CID 2) on port 1234, sends a line, prints the echo the
 * host's virtio-vsock engine sends back. The stock Alpine minirootfs has no
 * vsock-capable tool (busybox lacks one), so this tiny static binary ships in
 * the initramfs. Build it cross-platform with Zig's bundled clang:
 *
 *   zig cc -target aarch64-linux-musl -static -O2 tools/vsock_client.c -o vsock_client
 *
 * Then drop `vsock_client` into the initramfs (recipe in docs/running-on-hvf.md)
 * and run it in the guest after insmod-ing the vsock modules.
 */
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

/* linux/vm_sockets.h, inlined to avoid a kernel-headers dependency. */
struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[4];
};

#define VMADDR_CID_HOST 2

int main(void) {
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }

    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_port = 1234;
    a.svm_cid = VMADDR_CID_HOST;
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) { perror("connect"); return 2; }

    const char *msg = "HELLO_FROM_GUEST_VSOCK\n";
    if (write(s, msg, strlen(msg)) < 0) { perror("write"); return 3; }

    char buf[256];
    long n = read(s, buf, sizeof buf);
    if (n > 0) {
        write(1, "VSOCK_ECHO: ", 12);
        write(1, buf, (size_t)n);
    } else {
        write(1, "NO_ECHO\n", 8);
    }
    return 0;
}
