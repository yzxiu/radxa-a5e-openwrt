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
[ -f "$OUT/rootfs.tar" ] || die "缺 $OUT/rootfs.tar，请先跑 10-build-debian.sh"

mkdir -p "$KERNEL_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
log "解开 Debian rootfs.tar → 临时目录，定位内核资产"
tar -xf "$OUT/rootfs.tar" -C "$TMP"

# vmlinuz / initrd
cp "$TMP/boot/vmlinuz-$KVER"            "$KERNEL_DIR/" 2>/dev/null || die "无 vmlinuz-$KVER"
cp "$TMP/boot/initrd.img-$KVER"         "$KERNEL_DIR/" 2>/dev/null || warn "无 initrd（Debian initramfs 用于稳定挂载，建议保留）"

# 设备树：Allwinner 常见于 /boot/dtb/allwinner/ 或 /usr/lib/linux-image-<KVER>/
DTB_PATH=$(find "$TMP" -name "$DTB" | head -1)
[ -n "$DTB_PATH" ] && cp "$DTB_PATH" "$KERNEL_DIR/" || die "找不到 dtb $DTB"

# 内核模块（保留 .ko.xz；坑7 的转换在拼装阶段 50-modules-ko-convert.sh 做）
cp -a "$TMP/lib/modules/$KVER" "$KERNEL_DIR/"

# u-boot（SPL@LBA256 引导链关键）
cp -a "$TMP/usr/lib/u-boot/$UBOOT_DIR" "$KERNEL_DIR/" 2>/dev/null || die "缺 u-boot/$UBOOT_DIR"

log "提取完成：$KERNEL_DIR"
ls "$KERNEL_DIR"
