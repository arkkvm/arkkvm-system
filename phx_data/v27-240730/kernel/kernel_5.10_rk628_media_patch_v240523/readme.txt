1.该补丁包仅针对kernel-5.10的内核版本。如果客户内核版本在5.10之前，请使用for-all的补丁包。

2.media-rk628f-patch
该目录是kernel-5.10版本drivers/media/i2c/rk628所有的提交补丁，客户可以根据自己该目录的代码版本，择需打上补丁。

3.media-i2c-rk628-src
该目录是新版本rk628的驱动源代码，可以直接将rk628文件直接替换到kernel-5.10/drivers/media/i2c/rk628即可

4.rk3588-evb7-v11-rk628-hdmi2csi.dts
该文件是RK3588平台参考的dts配置，旧的平台（如rk356X/rk3399等）可以直接参考for-all补丁包的配置。