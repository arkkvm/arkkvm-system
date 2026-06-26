2025-08-15
kernel 6.1:
1. DWMMC 增加自动时钟关闭功能
2. SDHCI 解决RPMB和CMDQ存在兼容性问题(RK3576和RK3588)

2025-07-31
uboot：去掉dwmmc接口时钟提频率

2025-07-30
uboot：
1. 增加输出相位配置
2. 增加快启读数据前先配置读取长度
3. 增加新芯片相位配置方式
4. DWMMC接口时钟去掉默认的二分频，和kernel使用一样频率，开机提速

2025-04-22
uboot增加头文件dwmmc.h解决编译报错问题。
kernel 5.10 sdhci-of-dwcmshc.c如果编译不过，是HSQ相关报错，可以用sdhci-of-dwcmshc_nohsq.c。

2025-02-25
UBOOT修改读数据超时时间到1秒，解决个别型号的EMMC由于FW设计不合理引起读数据超时问题。

2024-11-11
kernel 6.1 增加command queue支持，dst种emmc节点需要定义"supports-cqe"启用。
支持的主控：RK3528，RK3562，RK3568，RK3576和RK3588.

2024-08-08
增加kernel 6.1
增加50Mhz下RX DLL配置，解决个别EMMC HS400ES初始化识别问题

2024-03-15
kernel 5.10 rk3568 dtsi里面compatible定义和驱动可能不匹配，增加一条补丁，如下：
0001-arm64-dts-rockchip-rk3568-Rename-sdhci-compatible-pr.patch

2024-01-17
合并之前处理补丁，优化了V2 tuning逻辑。
如果4个相位都能tuning成功，那么找不到最佳相位，回退到原来的tuning机制。

2024-01-08
u-boot驱动增加sdhc.h和mmc.h,避免编译报错。
u-boot驱动增加几个框架的文件。

RK35xx主控，如果uboot也有emmc报错，也可以更新驱动使用，没有异常可以不更新。

2023-10-23
驱动为同步内部最新版本，由于更新比较多，没法提供单独的patch
控制器驱动比较独立，可以单独替换，量产使用没有问题。
根据项目kernel版本选择对应版本下EMMC驱动更新测试。
