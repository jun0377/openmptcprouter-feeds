#ifndef BOND_REACTOR_H
#define BOND_REACTOR_H

#include <stdbool.h>
#include <stdint.h>

#define REACTOR_MAX_WORKERS 16

/* 伪事件: 用于在没有 fd 事件时驱动 handler 继续处理内部队列 */
#define REACTOR_EVENT_KICK  0x80000000u

typedef struct reactor reactor_t;
typedef struct reactor_reg reactor_reg_t;

typedef void (*reactor_event_fn)(void *ctx, uint32_t events);
typedef void (*reactor_closed_fn)(void *ctx);
typedef void (*reactor_idle_fn)(void *ctx);

/*
 * 单 epoll + N worker。
 * 所有注册 fd 使用 EPOLLONESHOT, 由 reactor 在 handler 返回后统一重武装,
 * 调用方只需要通过 reactor_want() 声明是否还需要 EPOLLOUT。
 */
reactor_t *reactor_create(uint32_t workers, uint32_t max_regs);
int  reactor_start(reactor_t *r);
void reactor_stop(reactor_t *r);
void reactor_destroy(reactor_t *r);

/* events: 额外关心的事件(目前只用 EPOLLOUT); EPOLLIN 始终注册 */
reactor_reg_t *reactor_add(reactor_t *r, int fd, uint32_t events,
                           reactor_event_fn on_event, void *ctx);
void reactor_want(reactor_reg_t *reg, uint32_t events);
/* 同时设置 EPOLLIN/EPOLLOUT 需求; want_in=false 用于背压时暂停读事件 */
void reactor_want_ex(reactor_reg_t *reg, bool want_out, bool want_in);
/* 投递一次伪事件, 让 handler 在 worker 上继续处理内部队列 */
int  reactor_kick(reactor_reg_t *reg);
/* 在 handler 内部使用: 只置位, 由本次 handler 结束时继续跑, 不额外投递 */
void reactor_kick_self(reactor_reg_t *reg);
/* 暂停事件投递(不再重武装)，用于 handler 内检测到连接不可用后抑制空转 */
void reactor_disable(reactor_reg_t *reg);
/* 同步关闭: 等当前 handler 退出后回调 on_closed; 不要在 handler 内部调用(会等待自身) */
void reactor_close(reactor_reg_t *reg, reactor_closed_fn on_closed);

/* 控制面任务投递到 worker 上下文执行 */
int reactor_post(reactor_t *r, void (*fn)(void *), void *arg);

/* epoll 空闲(超时)时回调, 用于周期性回收; 多 worker 可能并发调用 */
void reactor_set_idle(reactor_t *r, reactor_idle_fn fn, void *ctx);

#endif /* BOND_REACTOR_H */
