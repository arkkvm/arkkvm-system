// SPDX-License-Identifier: BSD-3-Clause
/*
 * Copyright (c) 2021 Rockchip Electronics Co. Ltd.
 *
 * Author: Shunqing Chen <csq@rock-chips.com>
 */

#ifndef COMBRXPHY_H
#define COMBRXPHY_H

#define COMBRX_REG(x)			((x) + 0x10000)

int rk628_combrxphy_power_on(struct rk628 *rk628, int f);
int rk628_combrxphy_power_off(struct rk628 *rk628);

#endif
