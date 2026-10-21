#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/epoll.h>
#include <sys/socket.h>

#include "core.h"
#include "bond_trans_tool.h"

/* 老内核头文件可能没有定义 MPTCP 协议号 */
#ifndef IPPROTO_MPTCP
#define IPPROTO_MPTCP 262
#endif

int core_epoll_create(void)
{
	int efd = epoll_create1(EPOLL_CLOEXEC);

	if (efd < 0)
		bt_log_error(LOG_ALL_OUT, "epoll_create1 failed! errno:%d errMsg:%s\n",
		             errno, strerror(errno));

	return efd;
}

int core_epoll_add(int efd, int fd, uint32_t events, uint64_t data)
{
	struct epoll_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.events = events;
	ev.data.u64 = data;

	if (0 != epoll_ctl(efd, EPOLL_CTL_ADD, fd, &ev)) {
		bt_log_error(LOG_ALL_OUT, "epoll add fd:%d failed! errno:%d errMsg:%s\n",
		             fd, errno, strerror(errno));
		return -1;
	}

	return 0;
}

int core_epoll_mod(int efd, int fd, uint32_t events, uint64_t data)
{
	struct epoll_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.events = events;
	ev.data.u64 = data;

	if (0 != epoll_ctl(efd, EPOLL_CTL_MOD, fd, &ev)) {
		bt_log_error(LOG_ALL_OUT, "epoll mod fd:%d failed! errno:%d errMsg:%s\n",
		             fd, errno, strerror(errno));
		return -1;
	}

	return 0;
}

int core_epoll_del(int efd, int fd)
{
	if (0 != epoll_ctl(efd, EPOLL_CTL_DEL, fd, NULL)) {
		bt_log_error(LOG_ALL_OUT, "epoll del fd:%d failed! errno:%d errMsg:%s\n",
		             fd, errno, strerror(errno));
		return -1;
	}

	return 0;
}

int core_epoll_wait(int efd, struct epoll_event *events, int max_events, int timeout_ms)
{
	int ret;

	do {
		ret = epoll_wait(efd, events, max_events, timeout_ms);
	} while (ret < 0 && EINTR == errno);

	return ret;
}

int core_wait_fd(int fd, uint32_t events, int timeout_ms)
{
	struct epoll_event ev;
	int efd;
	int ret;

	efd = core_epoll_create();
	if (efd < 0)
		return -1;

	if (0 != core_epoll_add(efd, fd, events, 0)) {
		close(efd);
		return -1;
	}

	ret = core_epoll_wait(efd, &ev, 1, timeout_ms);
	close(efd);

	if (ret < 0)
		return -1;
	if (0 == ret) {
		errno = ETIMEDOUT;
		return -1;
	}
	if (!(ev.events & events)) {
		errno = EIO;
		return -1;
	}

	return 0;
}

static int core_socket_create(void)
{
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, IPPROTO_MPTCP);

	if (fd < 0) {
		bt_log_error(LOG_ALL_OUT, "MPTCPv1 socket failed! errno:%d, fallback to TCP\n", errno);
		fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	}

	return fd;
}

void core_socket_tune(int fd, int send_buf, int recv_buf)
{
	int yes = 1;

	if (fd < 0)
		return;

	(void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

	if (send_buf > 0)
		(void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_buf, sizeof(send_buf));
	if (recv_buf > 0)
		(void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &recv_buf, sizeof(recv_buf));
}

void core_socket_nonblock(int fd)
{
	int flags = fcntl(fd, F_GETFL);

	if (flags >= 0)
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

void core_socket_shutdown(int fd)
{
	if (fd >= 0)
		shutdown(fd, SHUT_RDWR);
}

bool core_socket_alive(int fd)
{
	ssize_t ret;

	if (fd < 0)
		return false;

	ret = send(fd, NULL, 0, MSG_NOSIGNAL);
	if (ret < 0) {
		if (EPIPE == errno || ECONNRESET == errno || ENOTCONN == errno || EBADF == errno)
			return false;
	}

	return true;
}

static int core_connect_wait(int fd, int timeout_ms)
{
	int efd;
	int ret;
	int so_error = 0;
	socklen_t slen = sizeof(so_error);

	efd = core_epoll_create();
	if (efd < 0)
		return -1;

	if (0 != core_epoll_add(efd, fd, EPOLLOUT, 0)) {
		close(efd);
		return -1;
	}

	struct epoll_event ev;
	ret = core_epoll_wait(efd, &ev, 1, timeout_ms);
	close(efd);

	if (ret < 0)
		return -1;
	if (0 == ret) {
		errno = ETIMEDOUT;
		return -1;
	}

	if (0 != getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &slen))
		return -1;

	if (0 != so_error) {
		errno = so_error;
		return -1;
	}

	return 0;
}

int core_socket_connect(const char *server_ip, int server_port,
                        const char *local_ip, int timeout_sec)
{
	struct sockaddr_in addr;
	int fd;
	int flags;
	int ret;

	if (NULL == server_ip || '\0' == server_ip[0])
		return -1;

	fd = core_socket_create();
	if (fd < 0) {
		bt_log_error(LOG_ALL_OUT, "socket create failed! errno:%d errMsg:%s\n",
		             errno, strerror(errno));
		return -1;
	}

	/* 为空时交给 MPTCP/内核选择出口 */
	if (NULL != local_ip && '\0' != local_ip[0]) {
		struct sockaddr_in local_addr;

		memset(&local_addr, 0, sizeof(local_addr));
		local_addr.sin_family = AF_INET;
		local_addr.sin_port = 0;
		if (1 != inet_pton(AF_INET, local_ip, &local_addr.sin_addr)) {
			bt_log_error(LOG_ALL_OUT, "invalid local ip:%s\n", local_ip);
			close(fd);
			return -1;
		}
		if (0 != bind(fd, (struct sockaddr *)&local_addr, sizeof(local_addr))) {
			bt_log_error(LOG_ALL_OUT, "bind local addr %s failed! errno:%d\n", local_ip, errno);
			close(fd);
			return -1;
		}
	}

	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)server_port);
	if (1 != inet_pton(AF_INET, server_ip, &addr.sin_addr)) {
		bt_log_error(LOG_ALL_OUT, "invalid server ip:%s\n", server_ip);
		close(fd);
		return -1;
	}

	flags = fcntl(fd, F_GETFL);
	if (flags < 0 || 0 != fcntl(fd, F_SETFL, flags | O_NONBLOCK)) {
		close(fd);
		return -1;
	}

	ret = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
	if (0 != ret && EINPROGRESS != errno) {
		bt_log_error(LOG_ALL_OUT, "connect %s:%d failed! errno:%d errMsg:%s\n",
		             server_ip, server_port, errno, strerror(errno));
		fcntl(fd, F_SETFL, flags);
		close(fd);
		return -1;
	}

	if (0 != ret && 0 != core_connect_wait(fd, timeout_sec * 1000)) {
		bt_log_error(LOG_ALL_OUT, "connect %s:%d timeout! errno:%d errMsg:%s\n",
		             server_ip, server_port, errno, strerror(errno));
		close(fd);
		return -1;
	}

	(void)fcntl(fd, F_SETFL, flags);

	return fd;
}

int core_socket_listen(const char *bind_ip, int listen_port)
{
	struct sockaddr_in addr;
	int fd;
	int yes = 1;

	fd = core_socket_create();
	if (fd < 0) {
		bt_log_error(LOG_ALL_OUT, "socket create failed! errno:%d errMsg:%s\n",
		             errno, strerror(errno));
		return -1;
	}

	if (0 != setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes))) {
		bt_log_error(LOG_ALL_OUT, "setsockopt SO_REUSEADDR failed! errno:%d\n", errno);
		close(fd);
		return -1;
	}

	/* 多进程部署时允许复用监听端口; 不支持也不影响单进程 */
	if (0 != setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes)))
		bt_log_info(LOG_ALL_OUT, "SO_REUSEPORT not available, errno:%d\n", errno);

	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)listen_port);
	if (NULL == bind_ip || '\0' == bind_ip[0] || 0 == strcmp(bind_ip, "0.0.0.0")) {
		addr.sin_addr.s_addr = htonl(INADDR_ANY);
	} else if (1 != inet_pton(AF_INET, bind_ip, &addr.sin_addr)) {
		bt_log_error(LOG_ALL_OUT, "invalid listen bind ip:%s\n", bind_ip);
		close(fd);
		return -1;
	}

	if (0 != bind(fd, (struct sockaddr *)&addr, sizeof(addr))) {
		bt_log_error(LOG_ALL_OUT, "bind %s:%d failed! errno:%d errMsg:%s\n",
		             bind_ip, listen_port, errno, strerror(errno));
		close(fd);
		return -1;
	}

	if (0 != listen(fd, 100)) {
		bt_log_error(LOG_ALL_OUT, "listen %d failed! errno:%d errMsg:%s\n",
		             listen_port, errno, strerror(errno));
		close(fd);
		return -1;
	}

	return fd;
}

int core_socket_accept(int listen_fd, struct sockaddr_in *peeraddr)
{
	socklen_t addrlen = sizeof(*peeraddr);
	int fd;

	for (;;) {
		fd = accept4(listen_fd, (struct sockaddr *)peeraddr, &addrlen,
			     SOCK_NONBLOCK | SOCK_CLOEXEC);
		if (fd < 0 && ENOSYS == errno) {
			fd = accept(listen_fd, (struct sockaddr *)peeraddr, &addrlen);
			if (fd >= 0) {
				core_socket_nonblock(fd);
				(void)fcntl(fd, F_SETFD, FD_CLOEXEC);
			}
		}
		if (fd >= 0)
			return fd;
		if (EINTR != errno)
			return -1;
	}
}

ssize_t core_socket_recv(int fd, void *buf, size_t len)
{
	ssize_t ret;

	do {
		ret = read(fd, buf, len);
	} while (ret < 0 && EINTR == errno);

	return ret;
}

ssize_t core_socket_sendmsg(int fd, const struct iovec *iov, int iovcnt)
{
	struct msghdr msg;
	ssize_t ret;

	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = (struct iovec *)iov;
	msg.msg_iovlen = (size_t)iovcnt;

	do {
		ret = sendmsg(fd, &msg, MSG_NOSIGNAL);
	} while (ret < 0 && EINTR == errno);

	return ret;
}

int core_read_exact(int fd, void *buf, size_t len, int timeout_ms)
{
	uint8_t *p = buf;
	size_t offset = 0;

	while (offset < len) {
		ssize_t ret;

		if (0 != core_wait_fd(fd, EPOLLIN, timeout_ms))
			return -1;

		ret = core_socket_recv(fd, p + offset, len - offset);
		if (ret < 0) {
			if (EAGAIN == errno || EWOULDBLOCK == errno)
				continue;
			return -1;
		}
		if (0 == ret)
			return -1;

		offset += (size_t)ret;
	}

	return 0;
}

int core_write_exact(int fd, const void *buf, size_t len, int timeout_ms)
{
	const uint8_t *p = buf;
	size_t offset = 0;

	while (offset < len) {
		ssize_t ret;

		if (0 != core_wait_fd(fd, EPOLLOUT, timeout_ms))
			return -1;

		ret = send(fd, p + offset, len - offset, MSG_NOSIGNAL);
		if (ret < 0) {
			if (EAGAIN == errno || EWOULDBLOCK == errno)
				continue;
			return -1;
		}
		if (0 == ret)
			return -1;

		offset += (size_t)ret;
	}

	return 0;
}

int core_sendmsg_all(int fd, struct iovec *iov, int iovcnt,
                     size_t *sent, int timeout_ms)
{
	struct iovec local[CORE_IOV_MAX];
	struct iovec *cur = local;
	int cur_cnt = iovcnt;
	size_t total = 0;
	size_t done = 0;
	int i;

	if (NULL == iov || iovcnt <= 0 || iovcnt > CORE_IOV_MAX) {
		errno = EINVAL;
		return -1;
	}

	memcpy(local, iov, sizeof(struct iovec) * (size_t)iovcnt);
	for (i = 0; i < iovcnt; i++)
		total += local[i].iov_len;

	while (done < total && cur_cnt > 0) {
		ssize_t ret = core_socket_sendmsg(fd, cur, cur_cnt);
		size_t off;

		if (ret < 0) {
			if (EAGAIN == errno || EWOULDBLOCK == errno) {
				if (0 != core_wait_fd(fd, EPOLLOUT, timeout_ms)) {
					if (NULL != sent)
						*sent = done;
					return -1;
				}
				continue;
			}
			if (NULL != sent)
				*sent = done;
			return -1;
		}
		if (0 == ret) {
			if (NULL != sent)
				*sent = done;
			return -1;
		}

		done += (size_t)ret;

		off = (size_t)ret;
		while (off > 0 && cur_cnt > 0) {
			if (off >= cur->iov_len) {
				off -= cur->iov_len;
				cur++;
				cur_cnt--;
			} else {
				cur->iov_base = (char *)cur->iov_base + off;
				cur->iov_len -= off;
				off = 0;
			}
		}
	}

	if (NULL != sent)
		*sent = done;

	return 0;
}
