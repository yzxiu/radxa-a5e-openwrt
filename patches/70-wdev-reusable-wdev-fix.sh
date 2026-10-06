#!/bin/sh
# 【WiFi 必需】修 wdev.uc/common.uc 的"复用空闲接口"误判，否则 AP+STA 同开时
# AP 会在启动过程中被改名顶掉。
#
# 现象（板上实测，冷启动必现）：
#   iw dev 里只有 phy0-sta0，没有 phy0-ap0；br-lan 里也没有 ap0；
#   hostapd 每 6 秒刷 "Failed to set beacon parameters"，无限；
#   而 ubus call network.wireless status 仍报 "up": true —— 又是假象。
#   在 LuCI 上把 AP 禁用再启用，两个就都好了（所以看着像"重启才坏"）。
#
# 根因（/usr/share/hostap/common.uc 的 find_reusable_wdev）：
#   该函数只对 **fullmac** 驱动生效（AIC8800 正是 fullmac，softmac 如 ath9k/mt76
#   走不到这个分支，所以这是本板特有的坑）。它把
#       operstate == "down"
#   当作"这个 wdev 空闲、可以复用"的判据，返回第一个命中的接口；随后
#   wdev_create() 会用 rtnl RTM_SETLINK 把它**改名**成目标 ifname：
#       let reuse_ifname = find_reusable_wdev(phyidx);
#       if (reuse_ifname && (reuse_ifname == name ||
#            rtnl.request(rtnl.const.RTM_SETLINK, 0, { dev: reuse_ifname, ifname: name }) != false)) {
#               ... NL80211_CMD_SET_INTERFACE ...   // 改名复用
#       } else { ... NL80211_CMD_NEW_INTERFACE ... } // 正常新建
#   而"刚启用的 AP"在网桥端口 settling 期间 operstate 恰好读作 down：
#       [21.377] br-lan: port 2(phy0-ap0) entered blocking state
#       [21.377] br-lan: port 2(phy0-ap0) entered disabled state
#       [22.105] aicwf_sdio mmc2:390b:1 phy0-sta0: renamed from phy0-ap0 (while UP)   ← 铁证
#   于是创建 sta0 时把正在跑的 ap0 改名抢走了。注意内核那句 "(while UP)" ——
#   接口管理状态明明是 UP，operstate 却是 down，判据本身就不可靠。
#
# 修法：**已是网桥端口的接口必定在用，跳过它**（/sys/class/net/<if>/brport 只在
#   该接口是网桥端口时存在）。这是对上游判据的最小收紧，不改变它对真正空闲接口
#   （上一次配置残留、未入桥、operstate=down）的复用语义。
#
# 为什么不用"直接禁用复用"：AIC8800 实测支持 AP+STA 并发
#   （valid interface combinations: #{managed} <= 1, #{AP} <= 1, total <= 4），
#   手工 `iw phy phy0 interface add testap0 type __ap` 在 sta0 关联时也能成功。
#   但禁用整个复用分支影响面更大（会改变模式切换时的行为），先用最小修法。
#
# 验证：打了本补丁后连续两次冷启动，dmesg 里 "renamed from" 0 次、
#   logread 里 "Failed to set beacon" 0 次、AP-ENABLED 1 次，ap0/sta0 并存且
#   ap0 已桥进 br-lan。
ROOTFS="$1"
F="$ROOTFS/usr/share/hostap/common.uc"

[ -f "$F" ] || { echo "   - (无 $F，wifi-scripts 未装？跳过)"; exit 0; }

if grep -q "A5E-FIX-FIND-REUSABLE-WDEV" "$F"; then
  echo "   - common.uc 已打过补丁（幂等，跳过）"
  exit 0
fi

python3 - "$F" <<'PYEOF'
import io, sys

path = sys.argv[1]
s = io.open(path, encoding='utf-8').read()

OLD = """	for (let res in data)
		if (trim(readfile(`/sys/class/net/${res.ifname}/operstate`)) == "down")
			return res.ifname;
	return null;
}"""

NEW = """	for (let res in data) {
		/* A5E-FIX-FIND-REUSABLE-WDEV
		 * operstate=="down" 不足以判定接口空闲：刚启用的 AP 在网桥端口
		 * settling 期间 operstate 就读作 down（而管理状态是 UP，内核日志会写
		 * "renamed from phy0-ap0 (while UP)"），于是被当成备用件改名顶掉，
		 * 导致 AP+STA 同开时 AP 的 netdev 凭空消失、hostapd 无限刷
		 * "Failed to set beacon parameters"，而 ubus 仍报 up:true。
		 * 已是网桥端口的接口必定在用，跳过。
		 * 本函数只对 fullmac 驱动生效（AIC8800 是 fullmac）。 */
		if (readfile(`/sys/class/net/${res.ifname}/brport/state`))
			continue;
		if (trim(readfile(`/sys/class/net/${res.ifname}/operstate`)) == "down")
			return res.ifname;
	}
	return null;
}"""

n = s.count(OLD)
if n != 1:
    sys.stderr.write(
        "patches/70: find_reusable_wdev 的原始片段匹配到 %d 处（期望 1）。\n"
        "  上游 wifi-scripts 版本可能变了，请人工核对 /usr/share/hostap/common.uc\n"
        "  里的 find_reusable_wdev()，再更新本补丁的 OLD 片段。\n" % n)
    sys.exit(1)

io.open(path, 'w', encoding='utf-8').write(s.replace(OLD, NEW, 1))
PYEOF
[ $? -eq 0 ] || { echo "   ✗ 补丁失败（上游代码变了？）"; exit 1; }

echo "   - common.uc: find_reusable_wdev 跳过网桥端口（修 AP 被 STA 改名顶掉）"
