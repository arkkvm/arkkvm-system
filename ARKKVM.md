# kernel build

```bash
./build.sh lunch BoardConfig_IPC/BoardConfig-EMMC-NONE-RV1106_ARKKVM_V2.mk
./build.sh
```

默认上电，调试口为adb可连接：
修改sysdrv/source/kernel/arch/arm/boot/dts/phx-rv1106-public-core-v1.dts
文件中的
```dts
&usbdrd_dwc3 {
	dr_mode = "otg";//这里改为otg
};
```


切换otg/host
```bash
echo otg > /sys/devices/platform/ff3e0000.usb2-phy/otg_mode
echo host > /sys/devices/platform/ff3e0000.usb2-phy/otg_mode
```