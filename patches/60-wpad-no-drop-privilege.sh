#!/bin/sh
# 【WiFi 必需】禁用 wpad 的 capabilities 降权配置。
#
# 现象：内核侧 phy0 正常注册、hostapd 也起来了，但
#         ubus wait_for hostapd   ← 永久挂住
#       `uci show wireless` 看不到运行状态，LuCI 无线页面空白，AP 实际不可用。
# 原因：/etc/capabilities/wpad.json 让 procd 把 wpad 降到 network 用户 + 受限
#       capability 集；hostapd 在非 root 下注册不上自己的 ubus 对象。
#       （板上实测：改名后同一份配置立刻 AP-ENABLED、桥进 br-lan。）
#
# 做法：改名而不是删除 —— ① 保留文件内容便于回滚和审查；② apk 升级 wpad 时会
#       重新落地 wpad.json，而本脚本每次构建都跑，改名会再次生效（幂等）。
ROOTFS="$1"
CAP="$ROOTFS/etc/capabilities"

[ -d "$CAP" ] || { echo "   (无 /etc/capabilities，跳过)"; exit 0; }

for f in wpad.json; do
  if [ -f "$CAP/$f" ]; then
    mv -f "$CAP/$f" "$CAP/$f.disabled"
    echo "   - etc/capabilities/$f → $f.disabled（hostapd 需以 root 跑才能注册 ubus 对象）"
  elif [ -f "$CAP/$f.disabled" ]; then
    echo "   - etc/capabilities/$f 已禁用（幂等，跳过）"
  fi
done
