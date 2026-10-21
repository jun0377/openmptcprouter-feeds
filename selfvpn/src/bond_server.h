#ifndef BOND_SERVER_H
#define BOND_SERVER_H

#include "bond_types.h"

typedef struct bond_server bond_server_t;

int  bond_server_start(bond_runtime_t *rt, const char *bind_ip, uint16_t listen_port, const char *secret,
                       uint32_t ring_capacity, uint32_t queue_capacity);
void bond_server_stop(bond_runtime_t *rt);
void bond_server_reap(bond_runtime_t *rt);

void bond_server_pool_release(bond_server_t *srv, uint32_t ip);
bool bond_server_is_active(const bond_runtime_t *rt);

#endif /* BOND_SERVER_H */
