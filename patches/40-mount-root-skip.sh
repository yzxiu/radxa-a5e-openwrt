#!/bin/sh
# 【坑2】OpenWrt fstools 的 mount_root 只认"短 PARTUUID"或"尾号02的第2分区"格式的
# root= 参数。我们是第3分区+完整UUID，mount_root 永远匹配不上 → preinit hang。
# rootfs 已由 initramfs 挂载好了，短路 mount_root 即可（无需它再挂）。
ROOTFS="$1"
MR="$ROOTFS/lib/preinit/80_mount_root"
grep -q 'mount_root skipped' "$MR" || \
  sed -i 's|mount_root start "$(compose_rootfs_mount_options)"|mount_root start "$(compose_rootfs_mount_options)" 2>/dev/null \|\| echo "mount_root skipped (already mounted)"|' "$MR"
