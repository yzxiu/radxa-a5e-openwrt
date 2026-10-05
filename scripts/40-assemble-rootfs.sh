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
[ -f "$UBOOT_SRC" ] || die "缺 u-boot（$UBOOT_SRC），rsdk 首次提取资产不可少"
[ -f "$INITRD_SRC" ] || warn "缺 initrd（$INITRD_SRC），将无 initramfs 引导（坑4 风险）"

log "KSRC=$KSRC  KVER=$KVER  vmlinuz=$(basename "$VMLINUZ")"

log "① 解开 openwrt 通用 rootfs → $ROOTFS_DIR"
rm -rf "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"
tar -xf "$OWRT/$OWRT_TAR" -C "$ROOTFS_DIR"

log "② 放入内核（boot/ + lib/modules + boot/dts）"
mkdir -p "$ROOTFS_DIR/boot/dts"
cp "$VMLINUZ" "$ROOTFS_DIR/boot/vmlinuz-$KVER"
[ -f "$INITRD_SRC" ] && cp "$INITRD_SRC" "$ROOTFS_DIR/boot/initrd.img-$KVER"
# 清掉 openwrt 自带模块目录，只保留 A5E 内核的（版本必须与 vmlinuz 一致）
rm -rf "$ROOTFS_DIR/lib/modules"; mkdir -p "$ROOTFS_DIR/lib/modules"
cp -a "$MODULES_SRC" "$ROOTFS_DIR/lib/modules/$KVER"
# 设备树：优先取 A5E 的 dtb，找不到就把目录里的 dtb 都拷上
if [ -f "$DTB_SRC_DIR/$DTB" ]; then
  cp "$DTB_SRC_DIR/$DTB" "$ROOTFS_DIR/boot/dts/"
else
  find "$DTB_SRC_DIR" -maxdepth 1 -name '*.dtb' -exec cp -t "$ROOTFS_DIR/boot/dts/" {} + 2>/dev/null || true
fi

log "②b 放入 u-boot（build-image 从 /usr/lib/u-boot/ copy-out 后写 SPL@LBA256）"
mkdir -p "$ROOTFS_DIR/usr/lib/u-boot"
cp -a "$(dirname "$UBOOT_SRC")/$(basename "$UBOOT_SRC")" "$ROOTFS_DIR/usr/lib/u-boot/"

log "③ 写引导配置 extlinux.conf（root= 用占位，build-image 用 blkid 注入真实 UUID）"
mkdir -p "$ROOTFS_DIR/boot/extlinux"
{
  echo "## /boot/extlinux/extlinux.conf"
  echo "default l0"; echo "menu title U-Boot menu"; echo "prompt 0"; echo "timeout 1"
  echo "label l0"; echo "    menu title OpenWrt ${KVER} (${KSRC})"
  echo "    linux /boot/vmlinuz-${KVER}"
  [ -f "$INITRD_SRC" ] && echo "    initrd /boot/initrd.img-${KVER}"
  echo "    fdtdir /boot/dts/"
  echo "    append root=PARTUUID=PLACEHOLDER ${APPEND_PARAMS}"
} > "$ROOTFS_DIR/boot/extlinux/extlinux.conf"

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
tar -C "$ROOTFS_DIR" -cf "$OWRT/openwrt-a5e-rootfs.tar" .
echo "   → $OWRT/openwrt-a5e-rootfs.tar ($(du -h "$OWRT/openwrt-a5e-rootfs.tar"|cut -f1))"
echo "完成。下一步：./scripts/50-build-image.sh（复用 out/build-image）"
