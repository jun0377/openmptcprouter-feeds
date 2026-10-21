#ifndef BOND_CORE_H
#define BOND_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <netinet/in.h>
#include <sys/epoll.h>
#include <sys/types.h>
#include <sys/uio.h>

#include "bond_types.h"

#define CORE_EPOLL_MAX_EVENTS  64
#define CORE_IOV_MAX           64

/* ---------------- epoll ---------------- */

int core_epoll_create(void);
int core_epoll_add(int efd, int fd, uint32_t events, uint64_t data);
int core_epoll_mod(int efd, int fd, uint32_t events, uint64_t data);
int core_epoll_del(int efd, int fd);
int core_epoll_wait(int efd, struct epoll_event *events, int max_events, int timeout_ms);

/* 一次性等待 fd 就绪：内部创建临时 epoll，适合握手等低频路径 */
int core_wait_fd(int fd, uint32_t events, int timeout_ms);

/* ---------------- socket 生命周期 ---------------- */

/* 建立连接（MPTCP 不可用时回退普通 TCP），返回已连接 fd */
int core_socket_connect(const char *server_ip, int server_port,
                        const char *local_ip, int timeout_sec);

/* 创建监听 socket（MPTCP 不可用时回退普通 TCP），返回监听 fd */
int core_socket_listen(const char *bind_ip, int listen_port);

/* accept 一个连接，失败返回 -1 并保留 errno（EAGAIN 表示暂无连接） */
int core_socket_accept(int listen_fd, struct sockaddr_in *peeraddr);

void core_socket_nonblock(int fd);
void core_socket_shutdown(int fd);
bool core_socket_alive(int fd);

/* 连接建立后调优: 始终开启 TCP_NODELAY; 缓冲非 0 时显式设置 */
void core_socket_tune(int fd, int send_buf, int recv_buf);

/* ---------------- 数据收发 ---------------- */

/* 单次收/发，EINTR 自动重试；EAGAIN 时返回 -1 并保留 errno */
ssize_t core_socket_recv(int fd, void *buf, size_t len);
ssize_t core_socket_sendmsg(int fd, const struct iovec *iov, int iovcnt);

/* 等待 epoll 可读/可写后精确读/写 len 字节 */
int core_read_exact(int fd, void *buf, size_t len, int timeout_ms);
int core_write_exact(int fd, const void *buf, size_t len, int timeout_ms);

/* 把 iov 全部发完，EAGAIN 时用 epoll 等待可写；sent 返回实际发送字节数 */
int core_sendmsg_all(int fd, struct iovec *iov, int iovcnt,
                     size_t *sent, int timeout_ms);

#endif /* BOND_CORE_H */
