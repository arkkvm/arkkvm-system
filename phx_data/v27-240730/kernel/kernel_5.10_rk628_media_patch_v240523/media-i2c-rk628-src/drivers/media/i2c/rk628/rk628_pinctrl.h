/* SPDX-License-Identifier: BSD-3-Clause
 *  *
 *   *
 *    * Copyright (c) 2020 Fuzhou Rockchip Electronics Co., Ltd\
 *
 */

#ifndef RK628_PINCTRL_H
#define RK628_PINCTRL_H

int rk628_pinctrl_set_mux(struct rk628 *rk628, int gpio, int mux);
int rk628_gpio_get_value(struct rk628 *rk628, int gpio);
int rk628_gpio_set_value(struct rk628 *rk628, int gpio, int value);
int rk628_gpio_set_direction(struct rk628 *rk628, int gpio, int direction);
int rk628_iomux_init(struct rk628 *rk628);
int rk628_gpio_direction_input(struct rk628 *rk628, int gpio);
int rk628_gpio_direction_output(struct rk628 *rk628, int gpio, int value);
int rk628_gpio_test_all(struct rk628 *rk628);
int rk628_gpio_set_pull_highz_up_down(struct rk628 *rk628, int gpio, int pull);

#endif
