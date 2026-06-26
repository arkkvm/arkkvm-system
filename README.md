# ArkKVM-System

Firmware build system for ArkKVM hardware, based on the Rockchip RV1106 IPC Linux SDK.

**Default target:** Rockchip RV1106, eMMC boot, board config `BoardConfig-EMMC-NONE-RV1106_ARKKVM_V2.mk`

## Requirements

### Host OS

Linux is required. Do not copy the source tree on Windows — that can break symlinks and executable permissions.

### apt packages

Install the host tools checked by `./build.sh check`:

```bash
sudo apt-get install -y \
  device-tree-compiler \
  texinfo \
  gperf \
  g++-multilib \
  gcc-multilib \
  make \
  gzip
```

| Check | apt package | Used for |
|-------|-------------|----------|
| `dtc` | `device-tree-compiler` | U-Boot build |
| `makeinfo` | `texinfo` | gdb build |
| `gperf` | `gperf` | eudev build |
| `g++-multilib` | `g++-multilib` | multilib toolchain support |
| `gcc-multilib` | `gcc-multilib` | multilib toolchain support |
| `make` | `make` | build |
| `gzip` | `gzip` | packaging |

Verify the environment:

```bash
./build.sh check
```

### Cross toolchain

Target toolchain: `arm-rockchip830-linux-uclibcgnueabihf` (bundled under `tools/linux/toolchain/`).

```bash
cd tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/
source env_install_toolchain.sh
# or install to a custom path:
# source env_install_toolchain.sh /opt/toolchain
```

## Configuration

The active board config is selected via `.BoardConfig.mk` at the repository root. By default it points to `BoardConfig-EMMC-NONE-RV1106_ARKKVM_V2.mk`.

Select a board config:

```bash
./build.sh lunch
# or specify a config file:
./build.sh lunch BoardConfig_IPC/BoardConfig-EMMC-NONE-RV1106_ARKKVM_V2.mk
```

Inspect the current configuration:

```bash
./build.sh info
```

Board config naming:

```
BoardConfig-{boot medium}-{power}-{hw version}-{application}.mk
```

Key settings for the default ARKKVM V2 board:

| Variable | Value |
|----------|-------|
| `RK_CHIP` | `rv1106` |
| `RK_KERNEL_DTS` | `phx-rv1106-public-core-v1.dts` |
| `RK_ENABLE_OTA` | `y` |
| `RK_POST_BUILD_SCRIPT` | `rv1106-arkkvm-post.sh` |

For the full list of `RK_*` options, see [project/cfg-all-items-introduction.txt](project/cfg-all-items-introduction.txt).

## build.sh Commands

| Command | Description |
|---------|-------------|
| `./build.sh check` | Check build environment (apt dependencies, etc.) |
| `./build.sh lunch` | Interactively select a board config |
| `./build.sh lunch <BoardConfig>` | Select a specific board config file |
| `./build.sh info` | Show current board config and build parameters |
| `./build.sh clean` | Clean build artifacts from all submodules |
| `./build.sh all` | Build uboot, kernel, rootfs, media, app, and pack firmware images |
| `./build.sh updateimg` | Generate `update.img` |
| `./build.sh ota` | Generate `update_ota.tar` |

### Full firmware build

Recommended command sequence:

```bash
./build.sh clean
./build.sh all
./build.sh updateimg
./build.sh ota
```

- `clean` — remove previous build artifacts
- `all` — full build and partition image packaging
- `updateimg` — produce `output/image/update.img`
- `ota` — produce `output/image/update_ota.tar`

For a completely fresh output tree, delete the `output/` directory before running the commands above.

## Build Output

Images are written to `output/image/`:

| Command | Main outputs |
|---------|--------------|
| `all` | `uboot.img`, `boot.img`, `system.img`, `env.img`, and other partition images |
| `updateimg` | `update.img` |
| `ota` | `update_ota.tar` |

## Project Layout

```
arkkvm-system/
├── build.sh              # main entry (→ project/build.sh)
├── .BoardConfig.mk       # active board config symlink
├── sysdrv/               # U-Boot, kernel, rootfs
├── media/                # multimedia libraries
├── project/              # board configs and build scripts
├── output/image/         # firmware images
└── tools/linux/toolchain/  # cross toolchain
```

## Notes

- Do not copy the source tree on Windows.
- After changing board configuration, run `./build.sh info` to confirm the active settings.
