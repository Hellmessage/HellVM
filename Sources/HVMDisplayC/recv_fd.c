#include "HVMDisplayC.h"

#include <sys/socket.h>
#include <string.h>
#include <errno.h>

ssize_t hvm_recvmsg_with_fd(int sock, void *buf, size_t buf_size, int *out_fd)
{
    struct iovec iov = { .iov_base = buf, .iov_len = buf_size };
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cbuf,
        .msg_controllen = sizeof(cbuf),
    };
    *out_fd = -1;

    ssize_t n;
    do {
        n = recvmsg(sock, &msg, 0);
    } while (n < 0 && errno == EINTR);
    if (n <= 0) return n;

    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            int fd = -1;
            memcpy(&fd, CMSG_DATA(c), sizeof(int));
            *out_fd = fd;
            break;
        }
    }
    return n;
}
