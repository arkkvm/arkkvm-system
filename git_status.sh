#!/bin/bash

# 保存包含.git目录的数组
git_dirs=(
"./sysdrv/tools/board/idb_bootconfig"
"./sysdrv/drv_ko/wifi"
"./sysdrv/drv_ko/motor"
"./sysdrv/drv_ko"
"./sysdrv/cfg"
"./sysdrv/source/uboot/u-boot"
"./sysdrv/source/uboot/rkbin"
"./sysdrv/source/kernel"
"./sysdrv"
"./media/ive/ive"
"./media/ive"
"./media/common_algorithm/common_algorithm"
"./media/iva/iva"
"./media/iva"
"./media/avs"
"./media/samples"
"./media/cfg"
"./media/security/bin"
"./media/security/librkcrypto"
"./media/security/rk_tee_user"
"./media/rkpostisp"
"./media/rockit/rockit"
"./media"
"./media/sysutils"
"./tools/windows/Rockchip_AVS_tool"
"./tools"
"./tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf"
"./.repo/manifests"
"./.repo/repo"
"./project/make_meta"
"./project/app/ipcweb/ipcweb-backend"
"./project/app/ipcweb"
"./project/app/rkipc/rkipc"
"./project/app/rkipc"
"./project/app/aov_sample"
"./project/app/component/third_libs"
"./project/app/component/rkadk/rkadk"
"./project/app/component/rkadk"
"./project/app/component/lvgl/lvgl"
"./project/app/component/lvgl"
"./project/app/component/rkfsmk"
"./project/app/component/rkfsmk/rkfsmk"
"./project/app/uvc_app_tiny"
"./project/app/wifi_app"
"./project/cfg"
"./project"
)

# 输出文件路径
output_file="$(pwd)/git_status_results.txt"

# 清空或初始化结果文件
> "$output_file"

# 遍历数组中的每个目录
for dir in "${git_dirs[@]}"; do
    if [ -d "$dir/.git" ]; then
        echo "Checking Git status in $dir..."
        
        # 进入目录并获取 git status 输出
        cd "$dir" || { echo "Failed to enter directory $dir"; continue; }
        git_status=$(git status)
        
        # 检查是否包含 "nothing to commit, working tree clean"
        if ! echo "$git_status" | grep -q "nothing to commit, working tree clean"; then
            # 如果不是干净的状态，写入目录名和 git status 到文件
            {
                echo "Repository: $dir"
                echo "$git_status"
                echo "-----------------------------"
            } >> "$output_file"
        fi

        # 返回到原始目录
        cd - > /dev/null || exit
    else
        echo "Skipping $dir: Not a Git repository"
    fi
done

echo "Processing complete. Results saved to $output_file"
