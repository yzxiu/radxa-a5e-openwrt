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

# ---- OpenWrt 根文件系统（方案C 的基础 rootfs） ----
# 官方 OpenWrt 25.12 不支持 A5E（要 6.15/6.16 mainline），故用通用 rootfs
# + A5E 官方内核拼装。rootfs 来自 yzxiu/router 的网络编译 ImmortalWrt。
# 用 radxa-a5e 命名的包：当前内容与 armsr/armv8 通用包等同（仅 smartdns web
# 构建哈希不同），但后续 release 会针对 A5E 做差异化（预装包/配置等），
# 故锁定这个名字。版本变更时同步更新 OWRT_TAG / OWRT_SHA。
OWRT_VER=25.12.2
OWRT_TAG=ImmortalWrt-25.12.2-20261005-1909
OWRT_REPO=yzxiu/router
OWRT_TAR=radxa-a5e-rootfs.tar.gz
# 下载后校验；版本变更时更新
OWRT_SHA=2c84c4b300156a4b375a2ac1fb08ecbc35d386bcba5dd7138f5ba6465a8b4781
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

# ---- 打包执行环境 ----
# guestfish 需 nix 版 libguestfs + /dev/kvm。host 若无，50 会自动借这个 rsdk
# 容器（direnv/nix 环境）打包。容器名可用 RSDK_CONTAINER 覆盖。
RSDK_CONTAINER=${RSDK_CONTAINER:-keen_heyrovsky}

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

# ---- 板载 WiFi（AIC8800D80 / SDIO；驱动已 builtin 进内核，见 kernel 仓 vendor/aic8800）----
# 固件必须随镜像分发：驱动用 filp_open 直读 CONFIG_AIC_FW_PATH（**不走** request_firmware），
# 路径错了就是静默失败——内核里的异步初始化线程会一直轮询该目录、永远等不到，
# 表现为「没有 phy0、wlan 起不来、且 dmesg 里一条错误都没有」。来源：Radxa Debian
# rootfs 的 usr/lib/firmware/（20 步顺带提取，与 u-boot/initrd 同一个 tar）。
AIC_FW_SUB="aic8800_fw/SDIO/aic8800D80"          # 板上 dmesg 实测的芯片型号子目录
AIC_FW_DIR="$OWRT/aic-firmware/$AIC_FW_SUB"      # 20 步提取后的落点

# 用户态必装包（40 步 chroot+apk 装进 rootfs）：
#   wifi-scripts → /sbin/wifi + /lib/netifd/wireless/mac80211.sh（netifd 的无线 handler，
#                  25.12 从 base-files 新拆出来的包；缺了它 uci 无线流程全部 not found）
#   iw           → mac80211.sh 的 setup_phy 硬依赖（set antenna/distance/txpower）
# 注：**不装 wireless-regdb**。两个原因：① 驱动 rwnx_mod_params.c 里
# COMMON_PARAM(custregd, true, true) 默认为真 → phy0 走 REGULATORY_WIPHY_SELF_MANAGED、
# 用驱动自带 regdomain，cfg80211 的 regulatory.db 对它不起作用（上游 MODULE_PARM_DESC
# 写的 "Default: 0" 是过时的）；② 本内核 CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y，而
# OpenWrt 的 wireless-regdb 只给 regulatory.db、不给 regulatory.db.p7s，装了照样被拒。
WIFI_PKGS=${WIFI_PKGS:-iw wifi-scripts}

# ⚠ 必须把基础 rootfs 预装的 wpad 换成 full 版，否则 5G 起不来。
# 预装的是 wpad-mesh-mbedtls，它自己的描述就是 "minimal ... (with 802.11s mesh and SAE)"，
# 编译时**没开 CONFIG_IEEE80211AC / CONFIG_IEEE80211AX** —— 板上实测 hostapd 对
# `ieee80211ac` / `vht_capab` / `vht_oper_chwidth` / `ieee80211ax` / `he_oper_chwidth`
# 全部报 "unknown configuration item"（HE80 时 40+ 条、VHT80 时 4 条）→
# `hostapd.add_iface failed` → iw dev 里 phy0-ap0 **没有 channel 行**（根本没在发），
# 而 ubus 却报 up:true —— 典型假象，必须用 iw dev 才算数。
# wpad-mbedtls 描述是 "full featured"，实测 ac+ax 都在，HE80/ch36 能 AP-ENABLED。
# 注意：apk 不允许两个 provide hostapd 的包共存，`apk add wpad-mbedtls` 只会打印
# conflicts 分析然后什么都不做（退出码还不报错），**必须先 apk del 再 add**。
# 另：换了 wpad 后 apk 会重新落地 /etc/capabilities/wpad.json，patches/60 会再改名。
WIFI_WPAD_PKG=${WIFI_WPAD_PKG:-wpad-mbedtls}

# ---- 引导参数（extlinux append；root=UUID 由 build-image 用 blkid 注入，勿硬编码）----
APPEND_PARAMS="console=ttyAS0,115200n8 earlyprintk=sunxi-uart,0x2500000 rootwait clk_ignore_unused mac_addr=\${mac} mac1_addr=\${mac1} loglevel=4 rw earlycon consoleblank=0 console=tty1 coherent_pool=2M irqchip.gicv3_pseudo_nmi=0"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[err] %s\033[0m\n' "$*" >&2; exit 1; }
