#!/bin/sh
# 【坑7】A5E 内核模块全是 .ko.xz 压缩（Radxa BSP 内核 CONFIG_MODULE_COMPRESS_XZ=y）。
# OpenWrt 的 kmodloader/busybox 不支持 xz 解压模块（板子连 xz 都没有），
# 导致 bridge（→LAN）/WiFi 等模块全部加载失败。
# 修复：①全部解压成 .ko ②modules.* 路径 .ko.xz→.ko ③删 .bin 缓存（强制读文本）。
ROOTFS="$1"
MODDIR="$ROOTFS/lib/modules/6.6.98-1-aw2607"
[ -d "$MODDIR" ] || { echo "警告: 模块目录不存在 $MODDIR"; exit 0; }
find "$MODDIR" -name '*.ko.xz' | while read f; do xz -dc "$f" > "${f%.xz}" && rm -f "$f"; done
for m in modules.dep modules.alias modules.symbols modules.softdep modules.devname modules.weakdep; do
  [ -f "$MODDIR/$m" ] && sed -i 's/\.ko\.xz/.ko/g' "$MODDIR/$m"
done
rm -f "$MODDIR"/modules.dep.bin "$MODDIR"/modules.alias.bin "$MODDIR"/modules.symbols.bin \
      "$MODDIR"/modules.builtin.bin "$MODDIR"/modules.builtin.alias.bin "$MODDIR"/modules.builtin.modinfo
