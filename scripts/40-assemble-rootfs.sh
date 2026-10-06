#!/usr/bin/env bash
# ============================================================================
# 步骤4：拼装 OpenWrt rootfs —— openwrt 通用 rootfs + 内核 + 全部定制
# ----------------------------------------------------------------------------
# 内核来源由 KSRC 决定（见 00-lib.sh）：
#   kernel-actions：vmlinuz/modules/dtb 来自 $KA_DIR（已展开.ko、bridge·fw4 builtin）
#   rsdk          ：来自 $KERNEL_DIR（需 patches/50 做 .ko.xz→.ko）
# u-boot / initrd 两模式都复用 $KERNEL_DIR（rsdk 首次提取，日常不重跑 rsdk）。
# 产物：owrt/openwrt-a5e-rootfs.tar（喂给 build-image）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ -f "$OWRT/$OWRT_TAR" ] || die "缺 openwrt rootfs，先跑 30-fetch-openwrt.sh"

# ---- 依据 KSRC 定位内核各部件 ----
if [ "$KSRC" = kernel-actions ]; then
  [ -d "$KA_DIR/root/lib/modules" ] || die "缺内核资产，先跑 25-fetch-kernel.sh"
  KVER=$(ls "$KA_DIR/root/lib/modules/")
  VMLINUZ="$KA_DIR/vmlinuz-$KVER"
  MODULES_SRC="$KA_DIR/root/lib/modules/$KVER"
  DTB_SRC_DIR="$KA_DIR/root/usr/lib/linux-image-$KVER"
  KO_CONVERT=0                      # 内核已展开 .ko，无需 patch50
else
  [ -d "$KERNEL_DIR" ] || die "缺内核资产，先跑 20-extract-kernel.sh"
  VMLINUZ="$KERNEL_DIR/vmlinuz-$KVER"
  MODULES_SRC="$KERNEL_DIR/$KVER"
  DTB_SRC_DIR="$KERNEL_DIR"
  KO_CONVERT=1
fi
[ -d "$UBOOT_SRC" ] || die "缺 u-boot 目录（$UBOOT_SRC），rsdk 首次提取资产不可少"
[ -f "$INITRD_SRC" ] || warn "缺 initrd（$INITRD_SRC），将无 initramfs 引导（坑4 风险）"

log "KSRC=$KSRC  KVER=$KVER  vmlinuz=$(basename "$VMLINUZ")"

log "① 解开 openwrt 通用 rootfs →（全新临时装配目录，避开历史 root 属主残留）"
# 每次用独立临时目录装配：既干净可复现，又绕开 owrt/rootfs 里可能存在的
# 非本用户可删的 root 属主文件（guestfish/sudo 遗留）。
ROOTFS_DIR=$(mktemp -d "$OWRT/.assemble.XXXXXX")
# 安全清理：③b 会在 ROOTFS_DIR 下 bind mount proc/sys/dev。若卸载失败还照常
# rm -rf，会顺着 bind mount 删到宿主的 /proc —— 必须先确认无残留挂载点再删。
cleanup_rootfs() {
  local d
  for d in dev sys proc; do
    mountpoint -q "$ROOTFS_DIR/$d" 2>/dev/null && \
      { umount -l "$ROOTFS_DIR/$d" 2>/dev/null || sudo umount -l "$ROOTFS_DIR/$d" 2>/dev/null || true; }
  done
  if mount | grep -qF "$ROOTFS_DIR/"; then
    warn "$ROOTFS_DIR 下仍有挂载残留，跳过 rm -rf（请手工 umount 后清理）"; return 0
  fi
  rm -rf "$ROOTFS_DIR"
}
trap cleanup_rootfs EXIT
tar -xf "$OWRT/$OWRT_TAR" -C "$ROOTFS_DIR"

log "② 放入内核（boot/ + lib/modules + usr/lib/linux-image dtb）"
mkdir -p "$ROOTFS_DIR/boot"
cp "$VMLINUZ" "$ROOTFS_DIR/boot/vmlinuz-$KVER"
[ -f "$INITRD_SRC" ] && cp "$INITRD_SRC" "$ROOTFS_DIR/boot/initrd.img-$KVER"
# 清掉 openwrt 自带模块目录，只保留 A5E 内核的（版本必须与 vmlinuz 一致）
rm -rf "$ROOTFS_DIR/lib/modules"; mkdir -p "$ROOTFS_DIR/lib/modules"
cp -a "$MODULES_SRC" "$ROOTFS_DIR/lib/modules/$KVER"
# 设备树：放进 /usr/lib/linux-image-<KVER>/allwinner/（Debian/Radxa 内核 deb 标准布局），
# 匹配 extlinux 的 fdtdir /usr/lib/linux-image-<KVER>/（Radxa u-boot 按 compatible 到 allwinner/ 匹配）。
# ❗ 之前拷到 /boot/dts 且按 maxdepth 1 找，kernel-actions 的 dtb 在 allwinner/ 子目录 → 拷空。
DTB_DST="$ROOTFS_DIR/usr/lib/linux-image-$KVER/allwinner"
mkdir -p "$DTB_DST"
if [ -f "$DTB_SRC_DIR/allwinner/$DTB" ]; then
  cp "$DTB_SRC_DIR/allwinner/$DTB" "$DTB_DST/"      # kernel-actions：在 allwinner/ 子目录
elif [ -f "$DTB_SRC_DIR/$DTB" ]; then
  cp "$DTB_SRC_DIR/$DTB" "$DTB_DST/"                # rsdk：KERNEL_DIR 顶层
else
  die "找不到 a5e dtb（$DTB）于 $DTB_SRC_DIR（allwinner/ 或顶层均无）"
fi
echo "   dtb → $DTB_DST/$DTB"

log "②b 放入 u-boot（build-image 从 /usr/lib/u-boot/ copy-out 后写 SPL@LBA256）"
mkdir -p "$ROOTFS_DIR/usr/lib/u-boot"
cp -a "$(dirname "$UBOOT_SRC")/$(basename "$UBOOT_SRC")" "$ROOTFS_DIR/usr/lib/u-boot/"

log "②c 放入 WiFi 固件（AIC8800D80）"
# 驱动用 filp_open 直读 CONFIG_AIC_FW_PATH（不走 request_firmware），落点必须与
# kernel 仓 configs/a5e-openwrt.config 里的路径逐字一致。缺了不会报错，
# 只会让内核里的异步初始化线程永远轮询不到固件 → 没有 phy0。
[ -d "$AIC_FW_DIR" ] || die "缺 WiFi 固件 $AIC_FW_DIR，先跑 20-extract-kernel.sh"
mkdir -p "$ROOTFS_DIR/lib/firmware/$(dirname "$AIC_FW_SUB")"
rm -rf "$ROOTFS_DIR/lib/firmware/$AIC_FW_SUB"
cp -a "$AIC_FW_DIR" "$ROOTFS_DIR/lib/firmware/$AIC_FW_SUB"
echo "   固件 $(ls "$ROOTFS_DIR/lib/firmware/$AIC_FW_SUB" | wc -l) 个 → /lib/firmware/$AIC_FW_SUB"

log "③ 写引导配置 extlinux.conf（root= 用占位，build-image 用 blkid 注入真实 UUID）"
mkdir -p "$ROOTFS_DIR/boot/extlinux"
{
  echo "## /boot/extlinux/extlinux.conf"
  echo "default l0"; echo "menu title U-Boot menu"; echo "prompt 0"; echo "timeout 1"
  echo "label l0"; echo "    menu title OpenWrt ${KVER} (${KSRC})"
  echo "    linux /boot/vmlinuz-${KVER}"
  [ -f "$INITRD_SRC" ] && echo "    initrd /boot/initrd.img-${KVER}"
  echo "    fdtdir /usr/lib/linux-image-$KVER/"
  echo "    append root=PARTUUID=PLACEHOLDER ${APPEND_PARAMS}"
} > "$ROOTFS_DIR/boot/extlinux/extlinux.conf"

log "③b chroot 内 apk 安装用户态必装包：$WIFI_PKGS"
# 为何要 chroot：wifi-scripts/iw 都有 post-install 脚本（建符号链、注册 hotplug），
# 手工解 .apk 会漏掉脚本和 apk DB 记录。宿主是 x86_64，靠 qemu-user + binfmt
# 跑 aarch64（CI 里 apt 装 qemu-user-static；本地容器/devcontainer 已具备）。
# 放在 overlay（④）之前：若包自带同名配置，以我们的 overlay 为准。
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"
command -v chroot >/dev/null || die "缺 chroot"
for d in proc sys dev; do
  mkdir -p "$ROOTFS_DIR/$d"
  $SUDO mount --bind "/$d" "$ROOTFS_DIR/$d" 2>/dev/null || true
done
# /etc/resolv.conf 是指向 /tmp/resolv.conf 的符号链接（镜像里尚未生成），
# 直接 cp 会报 dangling symlink → 写到链接目标
mkdir -p "$ROOTFS_DIR/tmp"
$SUDO cp /etc/resolv.conf "$ROOTFS_DIR/tmp/resolv.conf"
# 真功能检查：chroot 里能不能跑 aarch64 二进制。
# ⚠ 别用 `[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]` 判断——binfmt_misc 是宿主全局
# 机制，容器里即使看不到注册文件（--privileged 下 /proc/sys/fs/binfmt_misc 可能没挂
# 进来）执行照样能成功；反之文件在也可能解释器缺失。实测过这个假阴性。
# CI 上反过来也有坑：apt 装了 qemu-user-static 但 systemd-binfmt 没重启 → 注册未生效。
# 所以这里按代价从小到大依次尝试，全部幂等；均失败则打出诊断再 die。
ensure_aarch64_chroot() {
  $SUDO chroot "$ROOTFS_DIR" /bin/uname -m >/dev/null 2>&1 && return 0
  warn "chroot 里跑不了 aarch64，尝试启用 binfmt…"
  $SUDO mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
  $SUDO systemctl restart systemd-binfmt 2>/dev/null || true
  $SUDO update-binfmts --enable qemu-aarch64 2>/dev/null || true
  $SUDO update-binfmts --enable qemu-aarch64-static 2>/dev/null || true
  # 手工注册（内核支持 \xNN 转义；F = 注册时就打开解释器，容器内也能用）
  local Q
  for Q in /usr/bin/qemu-aarch64-static /usr/bin/qemu-aarch64; do
    [ -x "$Q" ] || continue
    printf ':qemu-aarch64:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:%s:F\n' "$Q" \
      | $SUDO tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 || true
  done
  $SUDO chroot "$ROOTFS_DIR" /bin/uname -m >/dev/null 2>&1 && return 0
  # 最后手段：docker 预装多架构 binfmt（GH runner 有 docker；无 docker 则跳过）
  if command -v docker >/dev/null 2>&1; then
    warn "改用 multiarch/qemu-user-static 注册 binfmt"
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || true
  fi
  $SUDO chroot "$ROOTFS_DIR" /bin/uname -m >/dev/null 2>&1 && return 0
  # 均失败 → 把现场打出来，别让人对着空日志猜
  {
    echo "--- binfmt/chroot 诊断 ---"
    echo "host arch : $(uname -m)"
    echo "binfmt_misc 挂载: $(grep -c binfmt_misc /proc/mounts 2>/dev/null || echo 0) 处"
    echo "binfmt 条目: $(ls /proc/sys/fs/binfmt_misc/ 2>&1 | tr '\n' ' ')"
    for Q in /usr/bin/qemu-aarch64-static /usr/bin/qemu-aarch64; do
      [ -x "$Q" ] && echo "解释器 : $Q 存在" || echo "解释器 : $Q 缺失"
    done
    echo "chroot 实际报错："
    $SUDO chroot "$ROOTFS_DIR" /bin/uname -m 2>&1 | head -3
  } >&2
  return 1
}
ensure_aarch64_chroot \
  || die "chroot 里跑不了 aarch64（上方有诊断）——需 qemu-user + binfmt_misc 就绪"
# 部分 feed（amlogic/video）在本 target 不存在，apk 会刷 WARNING 但不影响安装
$SUDO chroot "$ROOTFS_DIR" /usr/bin/apk add $WIFI_PKGS \
  || die "chroot apk add 失败（查 qemu-user-static/binfmt 是否可用、网络是否通）"
for d in dev sys proc; do
  $SUDO umount "$ROOTFS_DIR/$d" 2>/dev/null || $SUDO umount -l "$ROOTFS_DIR/$d" 2>/dev/null || true
done
# 清 chroot 痕迹（否则会被打进镜像）
$SUDO rm -f  "$ROOTFS_DIR/tmp/resolv.conf"
$SUDO rm -rf "$ROOTFS_DIR/tmp/cache" "$ROOTFS_DIR/tmp/log" "$ROOTFS_DIR/etc/apk/cache"
for f in /sbin/wifi /usr/sbin/iw /lib/netifd/wireless/mac80211.sh; do
  [ -e "$ROOTFS_DIR$f" ] || die "包装上了但缺 $f（WIFI_PKGS 不对？）"
done
echo "   ✓ /sbin/wifi + /usr/sbin/iw + mac80211.sh 就位"

log "④ 应用整文件定制 custom/rootfs/*（overlay 覆盖）"
cp -a "$CUSTOM/." "$ROOTFS_DIR/" 2>/dev/null || true

log "⑤ 应用局部补丁 patches/*.sh（按序，每个带 why 注释）"
for p in "$PATCHES"/*.sh; do
  b=$(basename "$p")
  # kernel-actions 内核已展开 .ko 且 bridge 已 builtin → 跳过这两类补丁
  if [ "$KSRC" = kernel-actions ]; then
    case "$b" in
      50-modules-ko-convert.sh) echo "   - (跳过 $b：内核已展开 .ko)"; continue;;
    esac
  fi
  echo "   - $b"; sh "$p" "$ROOTFS_DIR"
done
# bridge 预加载 init.d：rsdk 内核才需要（kernel-actions 已 builtin bridge）
if [ "$KSRC" != kernel-actions ]; then
  ln -sf ../init.d/bridge-modules "$ROOTFS_DIR/etc/rc.d/S15bridge-modules"
else
  rm -f "$ROOTFS_DIR/etc/init.d/bridge-modules" "$ROOTFS_DIR/etc/rc.d/S15bridge-modules"
  echo "   - (kernel-actions：bridge 已 builtin，不装 bridge-modules)"
fi

log "⑥ 打包 rootfs.tar（保留符号链接/xattr）"
# 输出可能是历史 root 属主的同名文件；owrt/ 当前用户可写 → 先 unlink 再写
OUTTAR="$OWRT/openwrt-a5e-rootfs.tar"
rm -f "$OUTTAR" 2>/dev/null || true
tar -C "$ROOTFS_DIR" -cf "$OUTTAR" .
echo "   → $OWRT/openwrt-a5e-rootfs.tar ($(du -h "$OWRT/openwrt-a5e-rootfs.tar"|cut -f1))"
echo "完成。下一步：./scripts/50-build-image.sh（复用 out/build-image）"
