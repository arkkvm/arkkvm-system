# ========= 配置项 =========
CC  = /data/wzy/rk1106/rv1106_phx_public/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-gcc  # 根据你的交叉编译器替换
AR  = /data/wzy/rk1106/rv1106_phx_public/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-ar
CFLAGS := -Iinclude -Wall -Werror -Wno-unused-variable

LIB_OBJS := \
    mixer.o mixer_hw.o mixer_plugin.o \
    pcm.o pcm_hw.o pcm_plugin.o \
    snd_utils.o

BINARIES := tinycap tinyplay tinymix tinyhostless tinypcminfo

# ========= 目标 =========
all: libtinyalsa.a $(BINARIES)

libtinyalsa.a: $(LIB_OBJS)
	$(AR) rcs $@ $^

tinycap: tinycap.o libtinyalsa.a
	$(CC) -o $@ $< libtinyalsa.a -ldl

tinyplay: tinyplay.o libtinyalsa.a
	$(CC) -o $@ $< libtinyalsa.a -ldl

tinymix: tinymix.o libtinyalsa.a
	$(CC) -o $@ $< libtinyalsa.a -ldl

tinyhostless: tinyhostless.o libtinyalsa.a
	$(CC) -o $@ $< libtinyalsa.a -ldl

tinypcminfo: tinypcminfo.o libtinyalsa.a
	$(CC) -o $@ $< libtinyalsa.a -ldl

# ========= 清理 =========
clean:
	rm -f *.o *.a $(BINARIES)

.PHONY: all clean
