#!/bin/sh
# 【管理通道】br-lan 修复前 LAN 不可用，需通过 WAN 口管理（SSH/LuCI）。
# firewall wan zone input 默认 REJECT，会挡掉 SSH(22)/LuCI(80,443)。
# 修复：加规则放行这两个管理端口。wan input 保持 REJECT（安全姿态不变）。
ROOTFS="$1"
FW="$ROOTFS/etc/config/firewall"
grep -q 'Allow-SSH-WAN' "$FW" && exit 0
cat >> "$FW" <<'RULE'

config rule
	option name		'Allow-SSH-WAN'
	option src		wan
	option proto		tcp
	option dest_port	22
	option target		ACCEPT

config rule
	option name		'Allow-LuCI-WAN'
	option src		wan
	option proto		tcp
	option dest_port	'80 443'
	option target		ACCEPT
RULE
