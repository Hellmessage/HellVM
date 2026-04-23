// HVMDisplayC —— Swift 访问 POSIX socket SCM_RIGHTS 的 C 辅助
//
// CMSG_* 是 C 宏, Swift 不能直接调; 把 recvmsg + ancillary data 解析封装起来。
#pragma once

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 从 AF_UNIX socket 读一条消息, 同时抽取 SCM_RIGHTS 附带的单个 fd。
///
/// @param sock     已连接的 socket fd
/// @param buf      接收数据缓冲区
/// @param buf_size 缓冲区大小
/// @param out_fd   出参; 成功且带 fd 则 >= 0 (调用方负责 close),
///                 成功但无 fd 则 -1
/// @return         读到的数据字节数; 0 = EOF; < 0 = 错误(errno 已设)
ssize_t hvm_recvmsg_with_fd(int sock, void *buf, size_t buf_size, int *out_fd);

#ifdef __cplusplus
}
#endif
