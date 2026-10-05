#!/bin/sh
# 【坑8】A5E 串口是 Allwinner BSP 特有命名 ttyAS0（mainline 内核叫 ttyS0）。
# armsr 通用固件的 /etc/inittab 只认 ttyAMA0/ttyS0/tty1/...，不认识 ttyAS0，
# 导致串口只有内核日志、没有 login shell。修复：加 ttyAS0 的 login 条目。
ROOTFS="$1"
INITTAB="$ROOTFS/etc/inittab"
grep -q 'ttyAS0' "$INITTAB" || \
  sed -i 's|^::shutdown:/etc/init.d/rcS K shutdown|&\nttyAS0::askfirst:/usr/libexec/login.sh|' "$INITTAB"
