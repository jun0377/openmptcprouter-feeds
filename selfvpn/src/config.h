#ifndef BOND_SAMPLE_CONFIG_H
#define BOND_SAMPLE_CONFIG_H

#include <stddef.h>

#include "bond_trans_sdk.h"

#define LOG_LEVEL_ERROR		1
#define LOG_LEVEL_WARNING	2
#define LOG_LEVEL_INFO		3
#define LOG_LEVEL_DEBUG		4

int config_load(const char *path, bond_comm_param_t *comm_param,
                bond_trans_param_t *param, int *log_level,
                char *log_file, size_t log_file_size, int *log_size_mb);

#endif
