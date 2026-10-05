#!/bin/sh
# 【管理通道】dropbear 默认 option Interface 'lan'（只监听 LAN 接口）。
# LAN 不可用时 WAN 无法 SSH。修复：注释掉该限制，让 dropbear 监听所有接口（含 WAN）。
ROOTFS="$1"
sed -i "s|^\toption Interface 'lan'|#\toption Interface 'lan'   # 调试：监听所有接口（含WAN）|" "$ROOTFS/etc/config/dropbear"
