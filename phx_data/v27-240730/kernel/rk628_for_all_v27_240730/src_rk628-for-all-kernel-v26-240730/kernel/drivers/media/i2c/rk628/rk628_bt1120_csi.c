// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (c) 2022 Rockchip Electronics Co. Ltd.
 *
 *
 */

#include <linux/clk.h>
#include <linux/compat.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/kernel.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/of_graph.h>
#include <linux/platform_device.h>
#include <linux/reset.h>
#include <linux/rk-camera-module.h>
#include <linux/slab.h>
#include <linux/timer.h>
#include <linux/v4l2-dv-timings.h>
#include <linux/version.h>
#include <linux/videodev2.h>
#include <linux/workqueue.h>
#include <media/v4l2-controls_rockchip.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-dv-timings.h>
#include <media/v4l2-event.h>
#include <media/v4l2-fwnode.h>
#include <video/videomode.h>

#include "rk628.h"
#include "rk628_combrxphy.h"
#include "rk628_combtxphy.h"
#include "rk628_csi.h"
#include "rk628_cru.h"
#include "rk628_dsi.h"
#include "rk628_hdmirx.h"
#include "rk628_mipi_dphy.h"

static int debug;
module_param(debug, int, 0644);
MODULE_PARM_DESC(debug, "debug level (0-3)");

#define DRIVER_VERSION			KERNEL_VERSION(0, 0x0, 0x0)
#define RK628_BT1120_CSI_NAME			"rk628-bt1120-csi"

#define RK628_BT1120_CSI_LINK_FREQ_LOW		350000000
#define RK628_BT1120_CSI_LINK_FREQ_HIGH	400000000
#define RK628_BT1120_CSI_PIXEL_RATE_LOW	400000000
#define RK628_BT1120_CSI_PIXEL_RATE_HIGH	600000000

enum tx_mode_type {
	CSI_MODE,
	DSI_MODE,
};

struct rk628_plat_data {
	int bus_fmt;
	int tx_mode;
};

struct rk628_bt1120_csi {
	struct device *dev;
	struct i2c_client *i2c_client;
	struct rk628 *rk628;
	struct media_pad pad;
	struct v4l2_subdev sd;
	struct v4l2_dv_timings src_timings;
	struct v4l2_dv_timings timings;
	struct v4l2_ctrl_handler hdl;

	struct v4l2_ctrl *link_freq;
	struct v4l2_ctrl *pixel_rate;
	struct gpio_desc *enable_gpio;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *power_gpio;
	struct clk *soc_24M;

	struct mutex confctl_mutex;
	const struct rk628_bt1120_csi_mode *cur_mode;
	const char *module_facing;
	const char *module_name;
	const char *len_name;
	u32 module_index;
	u64 lane_mbps;
	u8 csi_lanes_in_use;
	u32 mbus_fmt_code;
	u8 fps;
	u32 stream_state;
	bool nosignal;
	bool txphy_pwron;
	bool scaler_en;
	bool i2s_enable_default;
	struct rk628_combtxphy *txphy;
	struct rk628_dsi dsi;
	const struct rk628_plat_data *plat_data;
};

struct rk628_bt1120_csi_mode {
	u32 width;
	u32 height;
	struct v4l2_fract max_fps;
	u32 hts_def;
	u32 vts_def;
	u32 exp_def;
};

static const s64 link_freq_menu_items[] = {
	RK628_BT1120_CSI_LINK_FREQ_LOW,
	RK628_BT1120_CSI_LINK_FREQ_HIGH,
};

static const struct v4l2_dv_timings_cap rk628_bt1120_csi_timings_cap = {
	.type = V4L2_DV_BT_656_1120,
	/* keep this initialization for compatibility with GCC < 4.4.6 */
	.reserved = { 0 },
	V4L2_INIT_BT_TIMINGS(1, 10000, 1, 10000, 0, 400000000,
			V4L2_DV_BT_STD_CEA861 | V4L2_DV_BT_STD_DMT |
			V4L2_DV_BT_STD_GTF | V4L2_DV_BT_STD_CVT,
			V4L2_DV_BT_CAP_PROGRESSIVE | V4L2_DV_BT_CAP_INTERLACED |
			V4L2_DV_BT_CAP_REDUCED_BLANKING |
			V4L2_DV_BT_CAP_CUSTOM)
};

static const struct rk628_bt1120_csi_mode supported_modes[] = {
	{
		.width = 1920,
		.height = 1080,
		.max_fps = {
			.numerator = 10000,
			.denominator = 600000,
		},
		.hts_def = 2200,
		.vts_def = 1125,
	},
};

static struct v4l2_dv_timings dst_timing = {
	.type = V4L2_DV_BT_656_1120,
	.bt = {
		.interlaced = V4L2_DV_PROGRESSIVE,
		.width = 1920,
		.height = 1080,
		.hfrontporch = 88,
		.hsync = 44,
		.hbackporch = 148,
		.vfrontporch = 4,
		.vsync = 5,
		.vbackporch = 36,
		.pixelclock = 148500000,
	},
};

static void rk628_post_process_setup(struct v4l2_subdev *sd);
static int rk628_bt1120_csi_s_dv_timings(struct v4l2_subdev *sd,
				 struct v4l2_dv_timings *timings);
static int mipi_dphy_power_on(struct rk628_bt1120_csi *csi);
static void mipi_dphy_power_off(struct rk628_bt1120_csi *csi);
static void enable_stream(struct v4l2_subdev *sd, bool enable);
static void rk628_bt1120_csi_set_csi(struct v4l2_subdev *sd);
static void rk628_dsi_set_scs(struct rk628_bt1120_csi *csi);
static void rk628_dsi_enable(struct v4l2_subdev *sd);

static inline struct rk628_bt1120_csi *to_csi(struct v4l2_subdev *sd)
{
	return container_of(sd, struct rk628_bt1120_csi, sd);
}

static int rk628_bt1120_csi_get_detected_timings(struct v4l2_subdev *sd,
				     struct v4l2_dv_timings *timings)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);
	// struct v4l2_bt_timings *bt = &timings->bt;

	memset(timings, 0, sizeof(struct v4l2_dv_timings));
	*timings = dst_timing;

	csi->src_timings = *timings;
	if (csi->scaler_en)
		*timings = csi->timings;

	return 0;
}

static void rk62_csi_reset(struct v4l2_subdev *sd)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	rk628_control_assert(csi->rk628, RGU_CSI);
	udelay(10);
	rk628_control_deassert(csi->rk628, RGU_CSI);

	rk628_i2c_write(csi->rk628, CSITX_SYS_CTRL0_IMD, 0x1);
	usleep_range(1000, 1100);
	rk628_i2c_write(csi->rk628, CSITX_SYS_CTRL0_IMD, 0x0);
}

static void enable_csitx(struct v4l2_subdev *sd)
{
	u32 i, ret, val;
	struct rk628_bt1120_csi *csi = to_csi(sd);

	for (i = 0; i < CSITX_ERR_RETRY_TIMES; i++) {
		rk628_bt1120_csi_set_csi(sd);
		rk628_i2c_update_bits(csi->rk628, CSITX_CSITX_EN,
					DPHY_EN_MASK |
					CSITX_EN_MASK,
					DPHY_EN(1) |
					CSITX_EN(1));
		rk628_i2c_write(csi->rk628, CSITX_CONFIG_DONE, CONFIG_DONE_IMD);
		msleep(40);
		rk628_i2c_write(csi->rk628, CSITX_ERR_INTR_CLR_IMD, 0xffffffff);
		rk628_i2c_update_bits(csi->rk628, CSITX_SYS_CTRL1,
				BYPASS_SELECT_MASK, BYPASS_SELECT(0));
		rk628_i2c_write(csi->rk628, CSITX_CONFIG_DONE, CONFIG_DONE_IMD);
		msleep(40);
		ret = rk628_i2c_read(csi->rk628, CSITX_ERR_INTR_RAW_STATUS_IMD, &val);
		if (!ret && !val)
			break;

		v4l2_err(sd, "%s csitx err, retry:%d, err status:%#x, ret:%d\n",
				__func__, i, val, ret);
	}
}

static void rk628_dsi_set_scs(struct rk628_bt1120_csi *csi)
{
	if (csi->dsi.vid_mode == VIDEO_MODE)
		rk628_i2c_write(csi->rk628, GRF_CSC_CTRL_CON,
				SW_Y2R_EN(1) | SW_YUV2VYU_SWP(1));
	else
		rk628_i2c_write(csi->rk628, GRF_CSC_CTRL_CON,
				SW_Y2R_EN(1) | SW_YUV2VYU_SWP(0));
}

static void rk628_dsi_enable(struct v4l2_subdev *sd)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	rk628_post_process_setup(sd);

	if (csi->txphy_pwron) {
		v4l2_dbg(1, debug, sd,
			"%s: txphy already power on, power off\n", __func__);
		mipi_dphy_power_off(csi);
		csi->txphy_pwron = false;
	}

	csi->dsi.rk628 = csi->rk628;
	csi->dsi.timings = csi->timings;
	csi->dsi.lane_mbps = csi->lane_mbps;
	rk628_mipi_dsi_power_on(&csi->dsi);
	csi->txphy_pwron = true;
	v4l2_dbg(2, debug, sd, "%s: txphy power on!\n", __func__);
	usleep_range(1000, 1500);
	rk628_dsi_set_scs(csi);
}

static void rk628_bt1120_decoder_enable(struct v4l2_subdev *sd)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	/* pinctrl for vop pin */
	rk628_i2c_write(csi->rk628, GRF_GPIO2AB_SEL_CON, 0xffffffff);
	rk628_i2c_write(csi->rk628, GRF_GPIO2C_SEL_CON, 0xffff5555);
	rk628_i2c_write(csi->rk628, GRF_GPIO3AB_SEL_CON, 0x10b010b);

	/* rk628: modify IO drive strength for RGB */
	rk628_i2c_write(csi->rk628, GRF_GPIO2A_D0_CON, 0xffff1111);
	rk628_i2c_write(csi->rk628, GRF_GPIO2A_D1_CON, 0xffff1111);
	rk628_i2c_write(csi->rk628, GRF_GPIO2B_D0_CON, 0xffff1111);
	rk628_i2c_write(csi->rk628, GRF_GPIO2B_D1_CON, 0xffff1111);
	rk628_i2c_write(csi->rk628, GRF_GPIO2C_D0_CON, 0xffff1111);
	rk628_i2c_write(csi->rk628, GRF_GPIO2C_D1_CON, 0xffff1111);
	rk628_i2c_write(csi->rk628, GRF_GPIO3A_D0_CON, 0xffff1011);
	rk628_i2c_write(csi->rk628, GRF_GPIO3B_D_CON, 0x10001);

	/* config sw_input_mode bt1120 */
	rk628_i2c_update_bits(csi->rk628, GRF_SYSTEM_CON0, SW_INPUT_MODE_MASK,
			      SW_INPUT_MODE(INPUT_MODE_BT1120));

	/* operation resetn_bt1120dec */
	rk628_i2c_write(csi->rk628, CRU_SOFTRST_CON00, 0x10001000);
	rk628_i2c_write(csi->rk628, CRU_SOFTRST_CON00, 0x10000000);

	rk628_clk_set_rate(csi->rk628, CGU_BT1120DEC, csi->timings.bt.pixelclock);

#ifdef BT1120_DUAL_EDGE
	rk628_i2c_update_bits(csi->rk628, GRF_RGB_DEC_CON0,
			      DEC_DUALEDGE_EN, DEC_DUALEDGE_EN);
	rk628_i2c_write(csi->rk628, GRF_BT1120_DCLK_DELAY_CON0, 0x10000000);
	rk628_i2c_write(csi->rk628, GRF_BT1120_DCLK_DELAY_CON1, 0);
#endif

	rk628_i2c_update_bits(csi->rk628, GRF_RGB_DEC_CON1, SW_SET_X_MASK,
			      SW_SET_X(csi->timings.bt.width));
	rk628_i2c_update_bits(csi->rk628, GRF_RGB_DEC_CON2, SW_SET_Y_MASK,
			      SW_SET_Y(csi->timings.bt.height));

	rk628_i2c_update_bits(csi->rk628, GRF_SYSTEM_CON0,
			      SW_BT_DATA_OEN_MASK | SW_INPUT_MODE_MASK,
			      SW_BT_DATA_OEN | SW_INPUT_MODE(INPUT_MODE_BT1120));
	rk628_i2c_write(csi->rk628, GRF_CSC_CTRL_CON, SW_Y2R_EN(1));
	rk628_i2c_update_bits(csi->rk628, GRF_RGB_DEC_CON0,
			      SW_CAP_EN_PSYNC | SW_CAP_EN_ASYNC | SW_PROGRESS_EN,
			      SW_CAP_EN_PSYNC | SW_CAP_EN_ASYNC | SW_PROGRESS_EN);
}

static void rk628_bt1120_rx_enable(struct v4l2_subdev *sd)
{
	rk628_bt1120_decoder_enable(sd);
}

static void enable_dsitx(struct v4l2_subdev *sd)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	/* rst for dsi0 */
	rk628_control_assert(csi->rk628, RGU_DSI0);
	usleep_range(20, 40);
	rk628_control_deassert(csi->rk628, RGU_DSI0);
	usleep_range(20, 40);

	rk628_dsi_enable(sd);
}

static void rk628_dsi_enable_stream(struct v4l2_subdev *sd, bool en)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	if (en) {
		rk628_bt1120_rx_enable(sd);
		rk628_i2c_write(csi->rk628, GRF_SCALER_CON0, SCL_EN(1));
		rk628_dsi_set_scs(csi);
		return;
	}

	// rk628_hdmirx_vid_enable(sd, false);
	rk628_i2c_write(csi->rk628, GRF_SCALER_CON0, SCL_EN(0));
}

static void enable_stream(struct v4l2_subdev *sd, bool en)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	v4l2_dbg(1, debug, sd, "%s: %sable\n", __func__, en ? "en" : "dis");
	if (en) {
		rk628_bt1120_rx_enable(sd);
		if (csi->plat_data->tx_mode == DSI_MODE)
			enable_dsitx(sd);
		else
			enable_csitx(sd);
	} else {
		if (csi->plat_data->tx_mode == CSI_MODE) {
			// rk628_hdmirx_vid_enable(sd, false);
			rk628_i2c_update_bits(csi->rk628, CSITX_CSITX_EN,
					      DPHY_EN_MASK |
					      CSITX_EN_MASK,
					      DPHY_EN(0) |
					      CSITX_EN(0));
			rk628_i2c_write(csi->rk628, CSITX_CONFIG_DONE,
					CONFIG_DONE_IMD);
		} else {
			rk628_dsi_enable_stream(sd, en);
		}
	}
}

static void rk628_post_process_setup(struct v4l2_subdev *sd)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);
	struct v4l2_bt_timings *bt = &csi->src_timings.bt;
	struct v4l2_bt_timings *dst_bt = &csi->timings.bt;
	struct videomode src, dst;
	u64 dst_pclk;

	src.hactive = bt->width;
	src.hfront_porch = bt->hfrontporch;
	src.hsync_len = bt->hsync;
	src.hback_porch = bt->hbackporch;
	src.vactive = bt->height;
	src.vfront_porch = bt->vfrontporch;
	src.vsync_len = bt->vsync;
	src.vback_porch = bt->vbackporch;
	src.pixelclock = bt->pixelclock;
	src.flags = 0;
	if (bt->interlaced == V4L2_DV_INTERLACED)
		src.flags |= DISPLAY_FLAGS_INTERLACED;
	if (!src.pixelclock) {
		enable_stream(sd, false);
		csi->nosignal = true;
		// schedule_delayed_work(&csi->delayed_work_enable_hotplug, HZ / 20);
		return;
	}

	dst.hactive = dst_bt->width;
	dst.hfront_porch = dst_bt->hfrontporch;
	dst.hsync_len = dst_bt->hsync;
	dst.hback_porch = dst_bt->hbackporch;
	dst.vactive = dst_bt->height;
	dst.vfront_porch = dst_bt->vfrontporch;
	dst.vsync_len = dst_bt->vsync;
	dst.vback_porch = dst_bt->vbackporch;
	dst.pixelclock = dst_bt->pixelclock;

	rk628_post_process_en(csi->rk628, &src, &dst, &dst_pclk);
	dst_bt->pixelclock = dst_pclk;
}

static void rk628_bt1120_csi_set_csi(struct v4l2_subdev *sd)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);
	// u8 video_fmt;
	u8 lanes = csi->csi_lanes_in_use;
	u8 lane_num;
	u8 dphy_lane_en;
	u32 wc_usrdef;
	// int avi_rdy;

	lane_num = lanes - 1;
	dphy_lane_en = (1 << (lanes + 1)) - 1;
	wc_usrdef = csi->timings.bt.width * 2;

	rk62_csi_reset(sd);
	rk628_post_process_setup(sd);

	if (csi->txphy_pwron) {
		v4l2_dbg(1, debug, sd,
			"%s: txphy already power on, power off\n", __func__);
		mipi_dphy_power_off(csi);
		csi->txphy_pwron = false;
	}

	mipi_dphy_power_on(csi);
	csi->txphy_pwron = true;
	v4l2_dbg(2, debug, sd, "%s: txphy power on!\n", __func__);
	usleep_range(1000, 1500);

	rk628_i2c_update_bits(csi->rk628, CSITX_CSITX_EN,
			VOP_UV_SWAP_MASK |
			VOP_YUV422_EN_MASK |
			VOP_P2_EN_MASK |
			LANE_NUM_MASK |
			DPHY_EN_MASK |
			CSITX_EN_MASK,
			VOP_UV_SWAP(1) |
			VOP_YUV422_EN(1) |
			VOP_P2_EN(1) |
			LANE_NUM(lane_num) |
			DPHY_EN(0) |
			CSITX_EN(0));
	rk628_i2c_update_bits(csi->rk628, CSITX_SYS_CTRL1,
			BYPASS_SELECT_MASK,
			BYPASS_SELECT(1));
	rk628_i2c_write(csi->rk628, CSITX_CONFIG_DONE, CONFIG_DONE_IMD);
	rk628_i2c_write(csi->rk628, CSITX_SYS_CTRL2, VOP_WHOLE_FRM_EN | VSYNC_ENABLE);
	rk628_i2c_update_bits(csi->rk628, CSITX_SYS_CTRL3_IMD,
			CONT_MODE_CLK_CLR_MASK |
			CONT_MODE_CLK_SET_MASK |
			NON_CONTINUOUS_MODE_MASK,
			CONT_MODE_CLK_CLR(0) |
			CONT_MODE_CLK_SET(0) |
			NON_CONTINUOUS_MODE(1));

	rk628_i2c_write(csi->rk628, CSITX_VOP_PATH_CTRL,
			VOP_WC_USERDEFINE(wc_usrdef) |
			VOP_DT_USERDEFINE(YUV422_8BIT) |
			VOP_PIXEL_FORMAT(0) |
			VOP_WC_USERDEFINE_EN(1) |
			VOP_DT_USERDEFINE_EN(1) |
			VOP_PATH_EN(1));
	rk628_i2c_update_bits(csi->rk628, CSITX_DPHY_CTRL,
				CSI_DPHY_EN_MASK,
				CSI_DPHY_EN(dphy_lane_en));
	rk628_i2c_write(csi->rk628, CSITX_CONFIG_DONE, CONFIG_DONE_IMD);
	v4l2_dbg(1, debug, sd, "%s csi cofig done\n", __func__);
}

static void rk628_bt1120_csi_initial_setup(struct v4l2_subdev *sd)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	/* selete int io function */
	rk628_i2c_write(csi->rk628, GRF_GPIO3AB_SEL_CON, 0x30002000);
	rk628_i2c_write(csi->rk628, GRF_GPIO1AB_SEL_CON, HIWORD_UPDATE(0x7, 10, 8));
	/* I2S_SCKM0 */
	rk628_i2c_write(csi->rk628, GRF_GPIO0AB_SEL_CON, HIWORD_UPDATE(0x1, 2, 2));
	/* I2SLR_M0 */
	rk628_i2c_write(csi->rk628, GRF_GPIO0AB_SEL_CON, HIWORD_UPDATE(0x1, 3, 3));
	/* I2SM0D0 */
	rk628_i2c_write(csi->rk628, GRF_GPIO0AB_SEL_CON, HIWORD_UPDATE(0x1, 5, 4));
	/* hdmirx int en */
	rk628_i2c_write(csi->rk628, GRF_INTR0_EN, 0x01000100);

	udelay(10);
	rk628_control_assert(csi->rk628, RGU_BT1120DEC);
	// rk628_control_assert(csi->rk628, RGU_HDMIRX_PON);
	rk628_control_assert(csi->rk628, RGU_CSI);
	udelay(10);
	rk628_control_deassert(csi->rk628, RGU_BT1120DEC);
	// rk628_control_deassert(csi->rk628, RGU_HDMIRX_PON);
	rk628_control_deassert(csi->rk628, RGU_CSI);
	udelay(10);

	rk628_i2c_update_bits(csi->rk628, GRF_SYSTEM_CON0,
			SW_INPUT_MODE_MASK |
			SW_OUTPUT_MODE_MASK |
			SW_EFUSE_HDCP_EN_MASK |
			SW_HSYNC_POL_MASK |
			SW_VSYNC_POL_MASK,
			SW_INPUT_MODE(INPUT_MODE_BT1120) |
			SW_OUTPUT_MODE(OUTPUT_MODE_CSI) |
			SW_EFUSE_HDCP_EN(0) |
			SW_HSYNC_POL(1) |
			SW_VSYNC_POL(1));

	if (csi->plat_data->tx_mode == CSI_MODE)
		mipi_dphy_power_on(csi);

	csi->txphy_pwron = true;
	// if (tx_5v_power_present(sd))
	// 	schedule_delayed_work(&csi->delayed_work_enable_hotplug, msecs_to_jiffies(1000));
}

static int rk628_bt1120_csi_s_dv_timings(struct v4l2_subdev *sd,
		struct v4l2_dv_timings *timings)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	if (!timings)
		return -EINVAL;

	if (debug)
		v4l2_print_dv_timings(sd->name, "rk628_bt1120_csi_s_dv_timings: ",
				timings, false);

#ifdef KERNEL_VERSION_4_19
	if (v4l2_match_dv_timings(&csi->timings, timings, 0, false)) {
#else
	if (v4l2_match_dv_timings(&csi->timings, timings, 0)) {
#endif
		v4l2_dbg(1, debug, sd, "%s: no change\n", __func__);
		return 0;
	}

	if (!v4l2_valid_dv_timings(timings, &rk628_bt1120_csi_timings_cap, NULL,
				NULL)) {
		v4l2_dbg(1, debug, sd, "%s: timings out of range\n", __func__);
		return -ERANGE;
	}

	csi->timings = *timings;
	enable_stream(sd, false);

	return 0;
}

static int rk628_bt1120_csi_g_dv_timings(struct v4l2_subdev *sd,
		struct v4l2_dv_timings *timings)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	*timings = csi->timings;

	return 0;
}

static int rk628_bt1120_csi_enum_dv_timings(struct v4l2_subdev *sd,
		struct v4l2_enum_dv_timings *timings)
{
	if (timings->pad != 0)
		return -EINVAL;

	return v4l2_enum_dv_timings_cap(timings, &rk628_bt1120_csi_timings_cap, NULL,
			NULL);
}

static int rk628_bt1120_csi_query_dv_timings(struct v4l2_subdev *sd,
		struct v4l2_dv_timings *timings)
{
	int ret;
	struct rk628_bt1120_csi *csi = to_csi(sd);

	mutex_lock(&csi->confctl_mutex);
	ret = rk628_bt1120_csi_get_detected_timings(sd, timings);
	mutex_unlock(&csi->confctl_mutex);
	if (ret)
		return ret;

	if (debug)
		v4l2_print_dv_timings(sd->name, "rk628_bt1120_csi_query_dv_timings: ",
				timings, false);

	if (!v4l2_valid_dv_timings(timings, &rk628_bt1120_csi_timings_cap, NULL,
				NULL)) {
		v4l2_dbg(1, debug, sd, "%s: timings out of range\n", __func__);
		return -ERANGE;
	}

	return 0;
}

static int rk628_bt1120_csi_dv_timings_cap(struct v4l2_subdev *sd,
		struct v4l2_dv_timings_cap *cap)
{
	if (cap->pad != 0)
		return -EINVAL;

	*cap = rk628_bt1120_csi_timings_cap;

	return 0;
}

#ifdef KERNEL_VERSION_5_10
static int rk628_bt1120_csi_g_mbus_config(struct v4l2_subdev *sd, unsigned int pad,
			     struct v4l2_mbus_config *cfg)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	cfg->type = V4L2_MBUS_CSI2_DPHY;
	cfg->flags = V4L2_MBUS_CSI2_CONTINUOUS_CLOCK;

	switch (csi->csi_lanes_in_use) {
	case 1:
		cfg->flags |= V4L2_MBUS_CSI2_1_LANE;
		break;
	case 2:
		cfg->flags |= V4L2_MBUS_CSI2_2_LANE;
		break;
	case 3:
		cfg->flags |= V4L2_MBUS_CSI2_3_LANE;
		break;
	case 4:
		cfg->flags |= V4L2_MBUS_CSI2_4_LANE;
		break;
	default:
		return -EINVAL;
	}

	return 0;
}
#else
static int rk628_bt1120_csi_g_mbus_config(struct v4l2_subdev *sd,
			     struct v4l2_mbus_config *cfg)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	cfg->type = V4L2_MBUS_CSI2;
	cfg->flags = V4L2_MBUS_CSI2_CONTINUOUS_CLOCK;

	switch (csi->csi_lanes_in_use) {
	case 1:
		cfg->flags |= V4L2_MBUS_CSI2_1_LANE;
		break;
	case 2:
		cfg->flags |= V4L2_MBUS_CSI2_2_LANE;
		break;
	case 3:
		cfg->flags |= V4L2_MBUS_CSI2_3_LANE;
		break;
	case 4:
		cfg->flags |= V4L2_MBUS_CSI2_4_LANE;
		break;
	default:
		return -EINVAL;
	}

	return 0;
}
#endif

static int rk628_bt1120_csi_s_stream(struct v4l2_subdev *sd, int enable)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	if (csi->plat_data->tx_mode == CSI_MODE)
		enable_stream(sd, enable);
	else
		rk628_dsi_enable_stream(sd, enable);

	return 0;
}

static int rk628_bt1120_csi_enum_mbus_code(struct v4l2_subdev *sd,
		struct v4l2_subdev_pad_config *cfg,
		struct v4l2_subdev_mbus_code_enum *code)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	switch (code->index) {
	case 0:
		code->code = csi->plat_data->bus_fmt;
		break;

	default:
		return -EINVAL;
	}

	return 0;
}

static int rk628_bt1120_csi_enum_frame_sizes(struct v4l2_subdev *sd,
				   struct v4l2_subdev_pad_config *cfg,
				   struct v4l2_subdev_frame_size_enum *fse)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	if (fse->index >= ARRAY_SIZE(supported_modes))
		return -EINVAL;

	if (fse->code != csi->plat_data->bus_fmt)
		return -EINVAL;

	fse->min_width  = supported_modes[fse->index].width;
	fse->max_width  = supported_modes[fse->index].width;
	fse->max_height = supported_modes[fse->index].height;
	fse->min_height = supported_modes[fse->index].height;

	return 0;
}

static int rk628_bt1120_csi_enum_frame_interval(struct v4l2_subdev *sd,
		struct v4l2_subdev_pad_config *cfg,
		struct v4l2_subdev_frame_interval_enum *fie)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	if (fie->index >= ARRAY_SIZE(supported_modes))
		return -EINVAL;

	if (fie->code != csi->plat_data->bus_fmt)
		return -EINVAL;

	fie->width = supported_modes[fie->index].width;
	fie->height = supported_modes[fie->index].height;
	fie->interval = supported_modes[fie->index].max_fps;
	return 0;
}

static int rk628_bt1120_csi_get_fmt(struct v4l2_subdev *sd,
		struct v4l2_subdev_pad_config *cfg,
		struct v4l2_subdev_format *format)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);

	mutex_lock(&csi->confctl_mutex);
	format->format.code = csi->mbus_fmt_code;
	format->format.width = csi->timings.bt.width;
	format->format.height = csi->timings.bt.height;
	format->format.field = csi->timings.bt.interlaced ?
		V4L2_FIELD_INTERLACED : V4L2_FIELD_NONE;
	mutex_unlock(&csi->confctl_mutex);

	v4l2_dbg(1, debug, sd, "%s: fmt code:%d, w:%d, h:%d, field code:%d\n",
			__func__, format->format.code, format->format.width,
			format->format.height, format->format.field);

	return 0;
}

static int rk628_bt1120_csi_get_reso_dist(const struct rk628_bt1120_csi_mode *mode,
		struct v4l2_mbus_framefmt *framefmt)
{
	return abs(mode->width - framefmt->width) +
	       abs(mode->height - framefmt->height);
}

static const struct rk628_bt1120_csi_mode *
rk628_bt1120_csi_find_best_fit(struct v4l2_subdev_format *fmt)
{
	struct v4l2_mbus_framefmt *framefmt = &fmt->format;
	int dist;
	int cur_best_fit = 0;
	int cur_best_fit_dist = -1;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(supported_modes); i++) {
		dist = rk628_bt1120_csi_get_reso_dist(&supported_modes[i], framefmt);
		if (cur_best_fit_dist == -1 || dist < cur_best_fit_dist) {
			cur_best_fit_dist = dist;
			cur_best_fit = i;
		}
	}

	return &supported_modes[cur_best_fit];
}

static int rk628_bt1120_csi_set_fmt(struct v4l2_subdev *sd,
		struct v4l2_subdev_pad_config *cfg,
		struct v4l2_subdev_format *format)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);
	const struct rk628_bt1120_csi_mode *mode;

	u32 code = format->format.code; /* is overwritten by get_fmt */
	int ret = rk628_bt1120_csi_get_fmt(sd, cfg, format);

	format->format.code = code;

	if (ret)
		return ret;

	switch (code) {
	case MEDIA_BUS_FMT_UYVY8_2X8:
		if (csi->plat_data->bus_fmt == MEDIA_BUS_FMT_UYVY8_2X8)
			break;
		return -EINVAL;
	case MEDIA_BUS_FMT_RGB888_1X24:
		if (csi->plat_data->bus_fmt == MEDIA_BUS_FMT_RGB888_1X24)
			break;
		return -EINVAL;
	default:
		return -EINVAL;
	}

	if (format->which == V4L2_SUBDEV_FORMAT_TRY) {
		if (csi->plat_data->bus_fmt == MEDIA_BUS_FMT_UYVY8_2X8)
			return 0;

		*v4l2_subdev_get_try_format(sd, cfg, format->pad) = format->format;
	}

	csi->mbus_fmt_code = format->format.code;
	mode = rk628_bt1120_csi_find_best_fit(format);
	csi->cur_mode = mode;

	if ((mode->width == 3840) && (mode->height == 2160)) {
		v4l2_dbg(1, debug, sd,
			"%s res wxh:%dx%d, link freq:%llu, pixrate:%u\n",
			__func__, mode->width, mode->height,
			link_freq_menu_items[1], RK628_BT1120_CSI_PIXEL_RATE_HIGH);
		__v4l2_ctrl_s_ctrl(csi->link_freq, 1);
		__v4l2_ctrl_s_ctrl_int64(csi->pixel_rate,
			RK628_BT1120_CSI_PIXEL_RATE_HIGH);
	} else {
		v4l2_dbg(1, debug, sd,
			"%s res wxh:%dx%d, link freq:%llu, pixrate:%u\n",
			__func__, mode->width, mode->height,
			link_freq_menu_items[0], RK628_BT1120_CSI_PIXEL_RATE_LOW);
		__v4l2_ctrl_s_ctrl(csi->link_freq, 0);
		__v4l2_ctrl_s_ctrl_int64(csi->pixel_rate,
			RK628_BT1120_CSI_PIXEL_RATE_LOW);
	}

	enable_stream(sd, false);

	return 0;
}

static int rk628_bt1120_csi_g_frame_interval(struct v4l2_subdev *sd,
				    struct v4l2_subdev_frame_interval *fi)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);
	const struct rk628_bt1120_csi_mode *mode = csi->cur_mode;

	mutex_lock(&csi->confctl_mutex);
	fi->interval = mode->max_fps;
	mutex_unlock(&csi->confctl_mutex);

	return 0;
}

static void rk628_bt1120_csi_get_module_inf(struct rk628_bt1120_csi *rk628_bt1120_csi,
				  struct rkmodule_inf *inf)
{
	memset(inf, 0, sizeof(*inf));
	strlcpy(inf->base.sensor, RK628_BT1120_CSI_NAME, sizeof(inf->base.sensor));
	strlcpy(inf->base.module, rk628_bt1120_csi->module_name,
		sizeof(inf->base.module));
	strlcpy(inf->base.lens, rk628_bt1120_csi->len_name, sizeof(inf->base.lens));
}

static long rk628_bt1120_csi_ioctl(struct v4l2_subdev *sd, unsigned int cmd, void *arg)
{
	struct rk628_bt1120_csi *csi = to_csi(sd);
	long ret = 0;

	switch (cmd) {
	case RKMODULE_GET_MODULE_INFO:
		rk628_bt1120_csi_get_module_inf(csi, (struct rkmodule_inf *)arg);
		break;
	default:
		ret = -ENOIOCTLCMD;
		break;
	}

	return ret;
}

static int mipi_dphy_power_on(struct rk628_bt1120_csi *csi)
{
	unsigned int val;
	u32 bus_width, mask;
	struct v4l2_subdev *sd = &csi->sd;

	if ((csi->timings.bt.width == 3840 && csi->timings.bt.height == 2160) ||
	    csi->csi_lanes_in_use <= 2) {
		csi->lane_mbps = MIPI_DATARATE_MBPS_HIGH;
	} else {
		csi->lane_mbps = MIPI_DATARATE_MBPS_LOW;
	}

	bus_width =  csi->lane_mbps << 8;
	bus_width |= COMBTXPHY_MODULEA_EN;
	v4l2_dbg(1, debug, sd, "%s mipi bitrate:%llu mbps\n", __func__,
			csi->lane_mbps);
	rk628_txphy_set_bus_width(csi->rk628, bus_width);
	rk628_txphy_set_mode(csi->rk628, PHY_MODE_VIDEO_MIPI);

	rk628_mipi_dphy_reset_assert(csi->rk628);
	rk628_mipi_dphy_init_hsfreqrange(csi->rk628, csi->lane_mbps, 0);
	usleep_range(1500, 2000);
	rk628_txphy_power_on(csi->rk628);
	rk628_mipi_dphy_reset_deassert(csi->rk628);

	usleep_range(1500, 2000);
	mask = DPHY_PLL_LOCK;
	rk628_i2c_read(csi->rk628, CSITX_CSITX_STATUS1, &val);
	if ((val & mask) != mask) {
		dev_err(csi->dev, "PHY is not locked\n");
		return -1;
	}

	udelay(10);

	return 0;
}

static void mipi_dphy_power_off(struct rk628_bt1120_csi *csi)
{
	rk628_txphy_power_off(csi->rk628);
}

#ifdef CONFIG_COMPAT
static long rk628_bt1120_csi_compat_ioctl32(struct v4l2_subdev *sd,
				  unsigned int cmd, unsigned long arg)
{
	void __user *up = compat_ptr(arg);
	struct rkmodule_inf *inf;
	long ret;

	switch (cmd) {
	case RKMODULE_GET_MODULE_INFO:
		inf = kzalloc(sizeof(*inf), GFP_KERNEL);
		if (!inf) {
			ret = -ENOMEM;
			return ret;
		}

		ret = rk628_bt1120_csi_ioctl(sd, cmd, inf);
		if (!ret) {
			ret = copy_to_user(up, inf, sizeof(*inf));
			if (ret)
				ret = -EFAULT;
		}
		kfree(inf);
		break;

	default:
		ret = -ENOIOCTLCMD;
		break;
	}

	return ret;
}
#endif

static const struct v4l2_subdev_core_ops rk628_bt1120_csi_core_ops = {
	.ioctl = rk628_bt1120_csi_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl32 = rk628_bt1120_csi_compat_ioctl32,
#endif
};

static const struct v4l2_subdev_video_ops rk628_bt1120_csi_video_ops = {
	.s_dv_timings = rk628_bt1120_csi_s_dv_timings,
	.g_dv_timings = rk628_bt1120_csi_g_dv_timings,
	.query_dv_timings = rk628_bt1120_csi_query_dv_timings,
#ifndef KERNEL_VERSION_5_10
	.g_mbus_config = rk628_bt1120_csi_g_mbus_config,
#endif
	.s_stream = rk628_bt1120_csi_s_stream,
	.g_frame_interval = rk628_bt1120_csi_g_frame_interval,
};

static const struct v4l2_subdev_pad_ops rk628_bt1120_csi_pad_ops = {
	.enum_mbus_code = rk628_bt1120_csi_enum_mbus_code,
	.enum_frame_size = rk628_bt1120_csi_enum_frame_sizes,
	.enum_frame_interval = rk628_bt1120_csi_enum_frame_interval,
	.set_fmt = rk628_bt1120_csi_set_fmt,
	.get_fmt = rk628_bt1120_csi_get_fmt,
	.enum_dv_timings = rk628_bt1120_csi_enum_dv_timings,
	.dv_timings_cap = rk628_bt1120_csi_dv_timings_cap,
#ifdef KERNEL_VERSION_5_10
	.get_mbus_config = rk628_bt1120_csi_g_mbus_config,
#endif
};

static const struct v4l2_subdev_ops rk628_bt1120_csi_ops = {
	.core = &rk628_bt1120_csi_core_ops,
	.video = &rk628_bt1120_csi_video_ops,
	.pad = &rk628_bt1120_csi_pad_ops,
};

static int rk628_bt1120_csi_probe_of(struct rk628_bt1120_csi *csi)
{
	struct device *dev = csi->dev;
	struct v4l2_fwnode_endpoint endpoint = { .bus_type = 0 };
	struct device_node *ep;
	int ret = -EINVAL;
	bool i2s_enable_default = false;
	bool scaler_en = false;

	csi->soc_24M = devm_clk_get(dev, "soc_24M");
	if (csi->soc_24M == ERR_PTR(-ENOENT))
		csi->soc_24M = NULL;
	if (IS_ERR(csi->soc_24M)) {
		ret = PTR_ERR(csi->soc_24M);
		dev_err(dev, "Unable to get soc_24M: %d\n", ret);
	}
	clk_prepare_enable(csi->soc_24M);

	csi->enable_gpio = devm_gpiod_get_optional(dev, "enable",
						     GPIOD_OUT_LOW);
	if (IS_ERR(csi->enable_gpio)) {
		ret = PTR_ERR(csi->enable_gpio);
		dev_err(dev, "failed to request enable GPIO: %d\n", ret);
		return ret;
	}

	csi->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(csi->reset_gpio)) {
		ret = PTR_ERR(csi->reset_gpio);
		dev_err(dev, "failed to request reset GPIO: %d\n", ret);
		return ret;
	}

	csi->power_gpio = devm_gpiod_get_optional(dev, "power", GPIOD_OUT_HIGH);
	if (IS_ERR(csi->power_gpio)) {
		dev_err(dev, "failed to get power gpio\n");
		ret = PTR_ERR(csi->power_gpio);
		return ret;
	}

	if (csi->enable_gpio) {
		gpiod_set_value(csi->enable_gpio, 1);
		usleep_range(10000, 11000);
	}
	gpiod_set_value(csi->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value(csi->reset_gpio, 1);
	usleep_range(10000, 11000);
	gpiod_set_value(csi->reset_gpio, 0);
	usleep_range(10000, 11000);

	if (csi->power_gpio) {
		gpiod_set_value(csi->power_gpio, 1);
		usleep_range(500, 510);
	}

	if (of_property_read_bool(dev->of_node, "i2s-enable-default"))
		i2s_enable_default = true;

	if (csi->plat_data->tx_mode == DSI_MODE) {
		if (of_property_read_bool(dev->of_node, "dsi-video-mode"))
			csi->dsi.vid_mode = VIDEO_MODE;
		else
			csi->dsi.vid_mode = COMMAND_MODE;
	}

	if (of_property_read_bool(dev->of_node, "scaler-en"))
		scaler_en = true;

	ep = of_graph_get_next_endpoint(dev->of_node, NULL);
	if (!ep) {
		dev_err(dev, "missing endpoint node\n");
		return -EINVAL;
	}
#ifdef KERNEL_VERSION_5_10
	ret = v4l2_fwnode_endpoint_alloc_parse(of_fwnode_handle(ep), &endpoint);
	if (ret) {
		dev_err(dev, "failed to parse endpoint\n");
		goto put_node;
	}

	if (endpoint.bus_type != V4L2_MBUS_CSI2_DPHY ||
	    endpoint.bus.mipi_csi2.num_data_lanes == 0) {
		dev_err(dev, "missing CSI-2 properties in endpoint\n");
		goto free_endpoint;
	}
#else
	endpoint = *v4l2_fwnode_endpoint_alloc_parse(of_fwnode_handle(ep));
	if (IS_ERR(&endpoint)) {
		dev_err(dev, "failed to parse endpoint\n");
		goto put_node;
	}

	if (endpoint.bus_type != V4L2_MBUS_CSI2 ||
	    endpoint.bus.mipi_csi2.num_data_lanes == 0) {
		dev_err(dev, "missing CSI-2 properties in endpoint\n");
		goto free_endpoint;
	}

#endif
	csi->csi_lanes_in_use = endpoint.bus.mipi_csi2.num_data_lanes;
	csi->i2s_enable_default = i2s_enable_default;
	csi->scaler_en = scaler_en;
	csi->timings = dst_timing;

	// csi->rxphy_pwron = false;
	csi->txphy_pwron = false;
	csi->nosignal = true;
	csi->stream_state = 0;

	ret = 0;

free_endpoint:
	v4l2_fwnode_endpoint_free(&endpoint);
put_node:
	of_node_put(ep);

	return ret;
}

static const struct rk628_plat_data rk628_bt1120_csi_data = {
	.bus_fmt = MEDIA_BUS_FMT_UYVY8_2X8,
	.tx_mode = CSI_MODE,
};

static const struct rk628_plat_data rk628_dsi_data = {
	.bus_fmt = MEDIA_BUS_FMT_RGB888_1X24,
	.tx_mode = DSI_MODE,
};

static const struct i2c_device_id rk628_bt1120_csi_i2c_id[] = {
	{ "rk628-bt1120-csi", 0 },
	{ "rk628-bt1120-dsi", 0 },
	{ }
};

MODULE_DEVICE_TABLE(i2c, rk628_bt1120_csi_i2c_id);

static const struct of_device_id rk628_bt1120_csi_of_match[] = {
	{ .compatible = "rockchip,rk628-bt1120-csi", .data = &rk628_bt1120_csi_data },
	{ .compatible = "rockchip,rk628-bt1120-dsi", .data = &rk628_dsi_data },
	{}
};
MODULE_DEVICE_TABLE(of, rk628_bt1120_csi_of_match);

static int rk628_bt1120_csi_probe(struct i2c_client *client,
			  const struct i2c_device_id *id)
{
	struct rk628_bt1120_csi *csi;
	struct v4l2_subdev *sd;
	struct device *dev = &client->dev;
	struct device_node *node = dev->of_node;
	char facing[2];
	int err;
	u32 val;
	struct rk628 *rk628;
	const struct of_device_id *match;

	dev_info(dev, "RK628 I2C driver version: %02x.%02x.%02x",
		DRIVER_VERSION >> 16,
		(DRIVER_VERSION & 0xff00) >> 8,
		DRIVER_VERSION & 0x00ff);

	if (!of_device_is_available(dev->of_node))
		return -ENODEV;

	csi = devm_kzalloc(dev, sizeof(*csi), GFP_KERNEL);
	if (!csi)
		return -ENOMEM;

	csi->dev = dev;
	csi->i2c_client = client;
	rk628 = rk628_i2c_register(client);
	if (!rk628)
		return -ENOMEM;

	match = of_match_node(rk628_bt1120_csi_of_match, dev->of_node);
	csi->plat_data = match->data;

	csi->rk628 = rk628;
	csi->dsi.rk628 = rk628;
	csi->cur_mode = &supported_modes[0];
	sd = &csi->sd;
	sd->dev = dev;

	err = of_property_read_u32(node, RKMODULE_CAMERA_MODULE_INDEX,
				   &csi->module_index);
	err |= of_property_read_string(node, RKMODULE_CAMERA_MODULE_FACING,
				       &csi->module_facing);
	err |= of_property_read_string(node, RKMODULE_CAMERA_MODULE_NAME,
				       &csi->module_name);
	err |= of_property_read_string(node, RKMODULE_CAMERA_LENS_NAME,
				       &csi->len_name);
	if (err) {
		dev_err(dev, "could not get module information!\n");
		return -EINVAL;
	}

	err = rk628_bt1120_csi_probe_of(csi);
	if (err) {
		v4l2_err(sd, "rk628_bt1120_csi_probe_of failed! err:%d\n", err);
		return err;
	}

	rk628_cru_initialize(csi->rk628);

	v4l2_subdev_init(sd, &rk628_bt1120_csi_ops);
	sd->flags |= V4L2_SUBDEV_FL_HAS_DEVNODE | V4L2_SUBDEV_FL_HAS_EVENTS;

	/* i2c access, read chip id*/
	err = rk628_i2c_read(csi->rk628, CSITX_CSITX_VERSION, &val);
	if (err) {
		v4l2_err(sd, "i2c access failed! err:%d\n", err);
		return -ENODEV;
	}
	v4l2_dbg(1, debug, sd, "CSITX VERSION: %#x\n", val);

	mutex_init(&csi->confctl_mutex);

	csi->txphy = rk628_txphy_register(rk628);
	if (!csi->txphy) {
		v4l2_err(sd, "register txphy failed\n");
		return -ENOMEM;
	}

	/* control handlers */
	v4l2_ctrl_handler_init(&csi->hdl, 2);
	csi->link_freq = v4l2_ctrl_new_int_menu(&csi->hdl, NULL,
			V4L2_CID_LINK_FREQ,
			ARRAY_SIZE(link_freq_menu_items) - 1,
			0, link_freq_menu_items);
	csi->pixel_rate = v4l2_ctrl_new_std(&csi->hdl, NULL,
			V4L2_CID_PIXEL_RATE, 0, RK628_BT1120_CSI_PIXEL_RATE_HIGH, 1,
			RK628_BT1120_CSI_PIXEL_RATE_HIGH);

	sd->ctrl_handler = &csi->hdl;
	if (csi->hdl.error) {
		err = csi->hdl.error;
		v4l2_err(sd, "cfg v4l2 ctrls failed! err:%d\n", err);
		goto err_hdl;
	}

	csi->pad.flags = MEDIA_PAD_FL_SOURCE;
#ifdef KERNEL_VERSION_4_19
#if defined(CONFIG_MEDIA_CONTROLLER)
	sd->entity.function = MEDIA_ENT_F_CAM_SENSOR;
	err = media_entity_pads_init(&sd->entity, 1, &csi->pad);
#endif
#else
	sd->entity.type = MEDIA_ENT_T_V4L2_SUBDEV_SENSOR;
	err = media_entity_init(&sd->entity, 1, &csi->pad, 0);
#endif
	if (err < 0) {
		v4l2_err(sd, "media entity init failed! err:%d\n", err);
		goto err_hdl;
	}

	if (csi->plat_data->tx_mode == DSI_MODE)
		csi->mbus_fmt_code = MEDIA_BUS_FMT_RGB888_1X24;
	else
		csi->mbus_fmt_code = MEDIA_BUS_FMT_UYVY8_2X8;

	memset(facing, 0, sizeof(facing));
	if (strcmp(csi->module_facing, "back") == 0)
		facing[0] = 'b';
	else
		facing[0] = 'f';

	snprintf(sd->name, sizeof(sd->name), "m%02d_%s_%s %s",
		 csi->module_index, facing,
		 RK628_BT1120_CSI_NAME, dev_name(sd->dev));
	err = v4l2_async_register_subdev(sd);
	if (err < 0) {
		v4l2_err(sd, "v4l2 register subdev failed! err:%d\n", err);
		goto err_hdl;
	}

	rk628_bt1120_csi_initial_setup(sd);

	err = v4l2_ctrl_handler_setup(sd->ctrl_handler);
	if (err) {
		v4l2_err(sd, "v4l2 ctrl handler setup failed! err:%d\n", err);
		goto err_hdl;
	}

	v4l2_info(sd, "%s found @ 0x%x (%s)\n", client->name,
		  client->addr << 1, client->adapter->name);

	return 0;

err_hdl:
	mutex_destroy(&csi->confctl_mutex);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(&csi->hdl);
	return err;
}

static int rk628_bt1120_csi_remove(struct i2c_client *client)
{
	struct rk628_bt1120_csi *csi = i2c_get_clientdata(client);

	if (csi->txphy_pwron)
		mipi_dphy_power_off(csi);

	mutex_destroy(&csi->confctl_mutex);

	rk628_control_assert(csi->rk628, RGU_BT1120DEC);
	rk628_control_assert(csi->rk628, RGU_DECODER);
	rk628_control_assert(csi->rk628, RGU_CLK_RX);
	rk628_control_assert(csi->rk628, RGU_VOP);
	rk628_control_assert(csi->rk628, RGU_CSI);

	return 0;
}

static struct i2c_driver rk628_bt1120_csi_i2c_driver = {
	.driver = {
		.name = "rk628-bt1120-csi",
		.of_match_table = of_match_ptr(rk628_bt1120_csi_of_match),
	},
	.id_table = rk628_bt1120_csi_i2c_id,
	.probe	= rk628_bt1120_csi_probe,
	.remove = rk628_bt1120_csi_remove,
};

module_i2c_driver(rk628_bt1120_csi_i2c_driver);

MODULE_DESCRIPTION("Rockchip RK628 BT1120 to MIPI CSI-2 bridge I2C driver");
MODULE_AUTHOR("Dingxian Wen <shawn.wen@rock-chips.com>");
MODULE_AUTHOR("Shunqing Chen <csq@rock-chips.com>");
MODULE_AUTHOR("Jianwei Fan <jianwei.fan@rock-chips.com>");
MODULE_LICENSE("GPL");
