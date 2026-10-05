# ============================================================================
# openwrt-a5e-build 构建参数库
#   被各 scripts/*.sh 通过 `source scripts/00-lib.sh` 引用。
#   修改版本/URL 只改这里。
# ============================================================================

# ---- 目标板 / 内核 ----
BOARD=radxa-cubie-a5e                 # rsdk 板名
KVER=6.6.98-1-aw2607                  # Allwinner A527 BSP 内核（非 mainline）
DTB=sun55i-a527-cubie-a5e.dtb         # A5E 设备树（注意 a527 命名，非 a5e）
UBOOT_DIR=radxa-cubie-a5e             # u-boot 资产目录名（setup.sh + u-boot-sunxi-with-spl.bin）

# ---- OpenWrt 根文件系统（armsr/armv8 通用 = 方案C） ----
# 官方 OpenWrt 25.12 不支持 A5E（要 6.15/6.16 mainline），故用 armsr 通用 rootfs
# + A5E 官方内核拼装。rootfs 来自网络编译的 ImmortalWrt。
OWRT_VER=25.12.2
OWRT_TAG=ImmortalWrt-25.12.2-20261004-2241
OWRT_REPO=yzxiu/router
OWRT_TAR=immortalwrt-armsr-armv8-generic-rootfs.tar.gz
# 下载后校验；版本变更时更新
OWRT_SHA=65b66c918e8dbbc290e1c0c303c36f55e9105668ff6196c5a87f2db502b23191
OWRT_URL="https://github.com/${OWRT_REPO}/releases/download/${OWRT_TAG}/${OWRT_TAR}"

# ---- 路径（相对仓库外层工作区根 radxa-a5e/）----
WORK=${WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}   # = openwrt-a5e-build/
WS=$(cd "$WORK/.." && pwd)                                        # = radxa-a5e/（工作区）
OUT="$WS/out"                    # rsdk Debian 构建产物
OWRT="$WS/owrt"                  # OpenWrt 中间产物 + 内核资产
ROOTFS_DIR="$OWRT/rootfs"        # 拼装中的 rootfs 目录
KERNEL_DIR="$OWRT/a5e-kernel"    # 从 Debian 提取的内核资产
IMG="$WS/owrt-a5e.img"           # 最终镜像
CUSTOM="$WORK/custom/rootfs"     # 整文件定制（overlay 源）
PATCHES="$WORK/patches"          # sed 补丁脚本

# ---- 镜像分区布局（rsdk build-image 的 GPT，用于离线 debugfs 编辑）----
# sda1=config(vfat,32768-65535)  sda2=efi(vfat,65536-679935)  sda3=rootfs(ext4,679936-…)
# ⚠ 扇区数随 rootfs 大小变，重 build 后务必用 sgdisk -i 3 / blkid 重新确认，勿硬依赖。
ROOTFS_LBA=${ROOTFS_LBA:-679936}
ROOTFS_SECT=${ROOTFS_SECT:-998433}

# ---- Debian 资产来源 DSRC（u-boot/initrd/build-image/rootfs，步骤20/50 的输入）----
# radxa-release（默认，免 rsdk）：从 radxa-build release 下载现成 Debian rootfs+build-image。
# rsdk：本地 rsdk build 生成 out/（需 devcontainer）。
DSRC=${DSRC:-radxa-release}
RADXA_REPO=${RADXA_REPO:-radxa-build/radxa-cubie-a5e}
DEB_TAG=${DEB_TAG:-rsdk-t10}
DEB_FLAVOR=${DEB_FLAVOR:-cli}                          # cli / kde
DEB_V=$(echo "$DEB_TAG" | sed 's/rsdk-//')            # t10
DEB_BASE=radxa-cubie-a5e_trixie_${DEB_FLAVOR}_${DEB_V}
DEB_REL="https://github.com/$RADXA_REPO/releases/download/$DEB_TAG"

# ---- 内核来源 KSRC -----------------------------------------------------------
# kernel-actions（默认，日常构建，不碰 rsdk）：从 yzxiu/radxa-a5e-openwrt-kernel 的
#   GitHub Release 下载 vmlinuz(未压缩) + modules-and-dtb.tar(.ko 已展开、dep 已修、
#   bridge·fw4·tproxy 已 builtin)。u-boot/initrd 仍复用 rsdk 首次提取的现有资产。
# rsdk（仅首次取 u-boot/initrd/build-image 资产时才用，需 devcontainer）。
KSRC=${KSRC:-kernel-actions}
KERNEL_ACTIONS_REPO=${KERNEL_ACTIONS_REPO:-yzxiu/radxa-a5e-openwrt-kernel}
KERNEL_ACTIONS_TAG=${KERNEL_ACTIONS_TAG:-latest}      # latest 或具体 v*
KA_DIR="$OWRT/a5e-kernel-actions"                      # 下载/解压目录
# u-boot / initrd 来源（两模式都用 rsdk 首次提取的现有资产，不重跑 rsdk）
UBOOT_SRC="$KERNEL_DIR/$UBOOT_DIR"
INITRD_SRC="$KERNEL_DIR/initrd.img-$KVER"

# ---- 引导参数（extlinux append；root=UUID 由 build-image 用 blkid 注入，勿硬编码）----
APPEND_PARAMS="console=ttyAS0,115200n8 earlyprintk=sunxi-uart,0x2500000 rootwait clk_ignore_unused mac_addr=\${mac} mac1_addr=\${mac1} loglevel=4 rw earlycon consoleblank=0 console=tty1 coherent_pool=2M irqchip.gicv3_pseudo_nmi=0"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[err] %s\033[0m\n' "$*" >&2; exit 1; }
