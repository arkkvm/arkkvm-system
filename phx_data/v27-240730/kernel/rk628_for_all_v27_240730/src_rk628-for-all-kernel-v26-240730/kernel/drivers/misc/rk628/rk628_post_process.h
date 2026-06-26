// SPDX-License-Identifier: BSD-3-Clause
/*
 * Copyright (c) 2021 Rockchip Electronics Co. Ltd.
 *
 * Author: Guochun Huang <hero.huang@rock-chips.com>
 */

#ifndef POST_PROCESS_H
#define POST_PROCESS_H

void rk628_post_process_init(struct rk628 *rk628);
void rk628_post_process_enable(struct rk628 *rk628);
void rk628_post_process_disable(struct rk628 *rk628);
void rk628_post_process_create_debugfs_file(struct rk628 *rk628);
#endif
