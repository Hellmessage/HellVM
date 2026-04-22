/*
 * iosurface-probe —— HellVM P4 Sprint 2 的端到端验证工具
 *
 * 用途: 连 QEMU 的 iosurface display socket, 握手, 通过 SCM_RIGHTS 收到
 *       framebuffer shm fd, mmap, 把当前帧 dump 成 PPM(P6 24bit RGB) 图片。
 *
 * 编译:
 *   clang -O2 -Wall -o build/iosurface-probe tools/iosurface-probe.c
 *
 * 用法:
 *   ./build/iosurface-probe /path/to/vm/iosurface.sock output.ppm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define PROTO_VERSION 1u

enum {
    MSG_HELLO = 0x01,
    MSG_SURFACE = 0x02,
    MSG_UPDATE_HINT = 0x03,
    MSG_CURSOR = 0x04,
    MSG_MOUSE_SET = 0x05,
};

#pragma pack(push, 1)
typedef struct {
    uint32_t type;
    uint32_t payload_len;
} MsgHeader;

typedef struct {
    uint32_t protocol_version;
} HelloPayload;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t format;
} SurfacePayload;
#pragma pack(pop)

static int connect_socket(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(fd);
        return -1;
    }
    return fd;
}

static int send_hello(int fd)
{
    MsgHeader h = { .type = MSG_HELLO, .payload_len = sizeof(HelloPayload) };
    HelloPayload p = { .protocol_version = PROTO_VERSION };
    struct iovec iov[2] = {
        { .iov_base = &h, .iov_len = sizeof(h) },
        { .iov_base = &p, .iov_len = sizeof(p) },
    };
    struct msghdr m = { .msg_iov = iov, .msg_iovlen = 2 };
    if (sendmsg(fd, &m, 0) < 0) {
        perror("sendmsg(HELLO)");
        return -1;
    }
    return 0;
}

/* 读 SURFACE 消息: 主体 + SCM_RIGHTS 附带 shm fd */
static int recv_surface(int fd, MsgHeader *hdr, SurfacePayload *payload,
                        int *out_shm_fd)
{
    struct iovec iov[2] = {
        { .iov_base = hdr,     .iov_len = sizeof(*hdr) },
        { .iov_base = payload, .iov_len = sizeof(*payload) },
    };
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct msghdr msg = {
        .msg_iov = iov,
        .msg_iovlen = 2,
        .msg_control = cbuf,
        .msg_controllen = sizeof(cbuf),
    };
    ssize_t n = recvmsg(fd, &msg, 0);
    if (n < (ssize_t)(sizeof(*hdr) + sizeof(*payload))) {
        fprintf(stderr, "recvmsg short: %zd errno=%d\n", n, errno);
        return -1;
    }
    *out_shm_fd = -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            memcpy(out_shm_fd, CMSG_DATA(c), sizeof(int));
            break;
        }
    }
    if (*out_shm_fd < 0) {
        fprintf(stderr, "no SCM_RIGHTS fd received\n");
        return -1;
    }
    return 0;
}

/* 从 shm 映射读 BGRA 像素, 转写成 PPM(P6, 24bit RGB) */
static int dump_ppm(uint8_t *pixels, uint32_t w, uint32_t h, uint32_t stride,
                    const char *out_path)
{
    FILE *f = fopen(out_path, "wb");
    if (!f) {
        perror("fopen");
        return -1;
    }
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (uint32_t y = 0; y < h; y++) {
        uint8_t *row = pixels + (size_t)y * stride;
        for (uint32_t x = 0; x < w; x++) {
            uint8_t b = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t r = row[x * 4 + 2];
            fputc(r, f);
            fputc(g, f);
            fputc(b, f);
        }
    }
    fclose(f);
    printf("wrote %s (%ux%u)\n", out_path, w, h);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <socket-path> <out.ppm>\n", argv[0]);
        return 2;
    }
    const char *sock_path = argv[1];
    const char *out_path = argv[2];

    int fd = connect_socket(sock_path);
    if (fd < 0) return 1;
    if (send_hello(fd) < 0) return 1;

    MsgHeader hdr;
    SurfacePayload sp;
    int shm_fd = -1;
    if (recv_surface(fd, &hdr, &sp, &shm_fd) < 0) {
        return 1;
    }
    if (hdr.type != MSG_SURFACE) {
        fprintf(stderr, "unexpected msg type=%u\n", hdr.type);
        return 1;
    }
    printf("got SURFACE: %ux%u stride=%u fmt=0x%08x shmfd=%d\n",
           sp.width, sp.height, sp.stride, sp.format, shm_fd);

    size_t size = (size_t)sp.stride * sp.height;
    void *ptr = mmap(NULL, size, PROT_READ, MAP_SHARED, shm_fd, 0);
    if (ptr == MAP_FAILED) {
        perror("mmap");
        close(shm_fd);
        return 1;
    }

    /* 给 QEMU 一点时间填首帧 (switch 回调已 memcpy 过, 但 BGRA 在 UEFI 阶段
     * 只有背景, 稍等让 logo 画上去) */
    usleep(100 * 1000);

    int rc = dump_ppm((uint8_t *)ptr, sp.width, sp.height, sp.stride, out_path);

    munmap(ptr, size);
    close(shm_fd);
    close(fd);
    return rc;
}
