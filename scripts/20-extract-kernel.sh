#!/usr/bin/env bash
# ============================================================================
# 步骤2：【仅首次】从 Debian 的 out/rootfs.tar 提取 A5E 资产 → owrt/a5e-kernel/
# ----------------------------------------------------------------------------
# ⚠ 日常构建的内核改用 kernel-actions（25-fetch-kernel.sh）。本步只需在首次跑一次，
#   目的从“取内核”转为“取 u-boot + initrd”（这两样 kernel-actions 不产出）：
#     u-boot: setup.sh + u-boot-sunxi-with-spl.bin（SPL 写到 LBA 256，非传统 LBA0/8）
#     initrd: initrd.img-<KVER>（Debian initramfs，坑4 靠它稳定挂载）
# ----------------------------------------------------------------------------
# 需要的资产（后续拼进 OpenWrt rootfs）：
#   vmlinuz-<KVER> / initrd.img-<KVER> / <DTB> / lib/modules/<KVER>（含 .ko.xz）
#   u-boot: setup.sh + u-boot-sunxi-with-spl.bin（SPL 写到 LBA 256，非传统 LBA0/8）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ -f "$OUT/rootfs.tar" ] || [ -f "$OUT/rootfs.tar.xz" ] || die "缺 out/rootfs.tar(.xz)，先跑 15-fetch-radxa-debian.sh 或 10-build-debian.sh"
ROOTFS_TGZ="$OUT/rootfs.tar"; [ -f "$ROOTFS_TGZ" ] || ROOTFS_TGZ="$OUT/rootfs.tar.xz"

mkdir -p "$KERNEL_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
log "选择性提取内核资产（只取需的路径，跳过 /dev 设备节点 → 非 root 也能解）"
# tar -xf 自动识别 .tar/.tar.xz；--wildcards 按模式提取，不解整个 rootfs
tar -xf "$ROOTFS_TGZ" -C "$TMP" --wildcards \
  "./boot/vmlinuz-$KVER" "./boot/initrd.img-$KVER" \
  "./usr/lib/modules/$KVER*" "./lib/modules/$KVER*" \
  "./usr/lib/u-boot/$UBOOT_DIR/*" \
  "./usr/lib/linux-image-$KVER/*" 2>/dev/null || warn "部分通配未命中（继续校关键项）"

# vmlinuz / initrd
[ -f "$TMP/boot/vmlinuz-$KVER" ] || die "rootfs 里没找到 boot/vmlinuz-$KVER"
cp "$TMP/boot/vmlinuz-$KVER"      "$KERNEL_DIR/"
cp "$TMP/boot/initrd.img-$KVER"   "$KERNEL_DIR/" 2>/dev/null || warn "无 initrd（坑4 靠它稳定挂载，建议保留）"

# 设备树：linux-image-<KVER>/allwinner/<DTB>（或 /boot/dtb）
DTB_PATH=$(find "$TMP" -name "$DTB" | head -1)
[ -n "$DTB_PATH" ] && cp "$DTB_PATH" "$KERNEL_DIR/" || die "找不到 dtb $DTB"

# 内核模块（保留 .ko.xz；rsdk 内核路线靠 patches/50 转换，kernel-actions 路线不用）
# Debian usr-merge：模块可能在 ./usr/lib/modules 或 ./lib/modules，两处都试
MODSRC=""; for c in "$TMP/usr/lib/modules/$KVER" "$TMP/lib/modules/$KVER"; do [ -d "$c" ] && MODSRC="$c" && break; done
[ -n "$MODSRC" ] || die "缺 lib/modules/$KVER"
cp -a "$MODSRC" "$KERNEL_DIR/$KVER"

# u-boot（SPL@LBA256 引导链关键；kernel-actions 不产，必须从 Debian 取）
cp -a "$TMP/usr/lib/u-boot/$UBOOT_DIR" "$KERNEL_DIR/" 2>/dev/null || die "缺 u-boot/$UBOOT_DIR"

log "提取完成：$KERNEL_DIR"
ls "$KERNEL_DIR"
