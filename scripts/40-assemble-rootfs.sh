#!/usr/bin/env bash
# ============================================================================
# 步骤4：拼装 OpenWrt rootfs —— openwrt 通用 rootfs + A5E 内核 + 全部定制
# ----------------------------------------------------------------------------
# 这是"定制改动"真正落地的地方：整文件用 custom/，局部修改用 patches/。
# 产物：owrt/openwrt-a5e-rootfs.tar（喂给 build-image）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ -f "$OWRT/$OWRT_TAR" ]  || die "缺 openwrt rootfs，先跑 30-fetch-openwrt.sh"
[ -d "$KERNEL_DIR" ]      || die "缺内核资产，先跑 20-extract-kernel.sh"

log "① 解开 openwrt 通用 rootfs → $ROOTFS_DIR"
rm -rf "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"
tar -xf "$OWRT/$OWRT_TAR" -C "$ROOTFS_DIR"

log "② 放入 A5E 内核资产（boot/ + lib/modules）"
mkdir -p "$ROOTFS_DIR/boot/dts"
cp "$KERNEL_DIR/vmlinuz-$KVER"   "$ROOTFS_DIR/boot/"
cp "$KERNEL_DIR/initrd.img-$KVER" "$ROOTFS_DIR/boot/" 2>/dev/null || true
cp "$KERNEL_DIR/$DTB"            "$ROOTFS_DIR/boot/dts/"
# 用 A5E 内核模块替换 openwrt 自带模块目录（版本必须与 vmlinuz 一致）
rm -rf "$ROOTFS_DIR/lib/modules"
cp -a "$KERNEL_DIR/$KVER" "$ROOTFS_DIR/lib/modules/"

log "②b 放入 u-boot 资产（build-image 从 /usr/lib/u-boot/ copy-out 后写 SPL@LBA256）"
mkdir -p "$ROOTFS_DIR/usr/lib/u-boot"
cp -a "$KERNEL_DIR/$UBOOT_DIR" "$ROOTFS_DIR/usr/lib/u-boot/"

log "③ 写引导配置 extlinux.conf（root= 用占位，build-image 会用 blkid 注入真实 UUID）"
mkdir -p "$ROOTFS_DIR/boot/extlinux"
# APPEND_PARAMS 见 00-lib.sh；此处 root= 是临时值，下一步 build-image 覆盖
{
  echo "## /boot/extlinux/extlinux.conf"
  echo "default l0"
  echo "menu title U-Boot menu"
  echo "prompt 0"
  echo "timeout 1"
  echo "label l0"
  echo "    menu title Debian GNU/Linux ${KVER}"
  echo "    linux /boot/vmlinuz-${KVER}"
  echo "    initrd /boot/initrd.img-${KVER}"
  echo "    fdtdir /boot/dts/"
  echo "    append root=PARTUUID=PLACEHOLDER ${APPEND_PARAMS}"
} > "$ROOTFS_DIR/boot/extlinux/extlinux.conf"

log "④ 应用整文件定制 custom/rootfs/* （overlay 覆盖）"
cp -a "$CUSTOM/." "$ROOTFS_DIR/" 2>/dev/null || true

log "⑤ 应用局部补丁 patches/*.sh （按序，每个都带 why 注释）"
for p in "$PATCHES"/*.sh; do
  echo "   - $(basename "$p")"
  sh "$p" "$ROOTFS_DIR"
done
# bridge-modules 的 rc.d 自启符号链接（START=15 → S15）
ln -sf ../init.d/bridge-modules "$ROOTFS_DIR/etc/rc.d/S15bridge-modules"

log "⑥ 打包 rootfs.tar（保留符号链接/xattr）"
tar -C "$ROOTFS_DIR" -cf "$OWRT/openwrt-a5e-rootfs.tar" .
echo "   → $OWRT/openwrt-a5e-rootfs.tar ($(du -h "$OWRT/openwrt-a5e-rootfs.tar"|cut -f1))"
echo "完成。下一步：sudo ./scripts/50-build-image.sh"
