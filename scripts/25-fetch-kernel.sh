#!/usr/bin/env bash
# ============================================================================
# 步骤2.5：从 kernel-actions（yzxiu/radxa-a5e-openwrt-kernel）下载内核资产
# ----------------------------------------------------------------------------
# 取代"重跑 rsdk 取内核"。Release（v* tag）资产：
#   vmlinuz-<KVER>          未压缩 ARM64 Image，U-Boot extlinux 直接可用
#   modules-and-dtb.tar     root/lib/modules/<KVER>（.ko 已展开、dep 已修、.bin 已删）
#                           + root/usr/lib/linux-image-<KVER>/*.dtb
#                           bridge/firewall4/tproxy 已 builtin 进 vmlinux
#   sha256sums.txt / BUILD_INFO.env
# u-boot / initrd 不在此仓库产出 → 复用 rsdk 首次提取的 owrt/a5e-kernel/（不重跑 rsdk）。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ "$KSRC" = kernel-actions ] || { log "KSRC=$KSRC：跳过（rsdk 模式请用 20-extract-kernel.sh）"; exit 0; }

mkdir -p "$KA_DIR"; cd "$KA_DIR"
REPO="$KERNEL_ACTIONS_REPO"; TAG="$KERNEL_ACTIONS_TAG"

log "解析 release tag（latest → 实际 v*）"
API="https://api.github.com/repos/$REPO/releases"
if [ "$TAG" = latest ]; then
  TAG=$(curl -fsSL "$API/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$TAG" ] || die "拿不到 latest release（该仓库可能还没打 v* tag，或无网/需 token）"
fi
echo "  tag = $TAG"

log "枚举并下载 release 资产"
# 用 API 拿每个资产的下载地址（含 vmlinuz-*，名字随 KVER 变）
curl -fsSL "$API/tags/$TAG" | python3 -c '
import sys, json, re
for a in json.load(sys.stdin).get("assets", []):
    n = a["name"]
    if re.search(r"vmlinuz|modules-and-dtb|sha256sums|BUILD_INFO", n):
        print(a["browser_download_url"])
' > /tmp/ka_urls.$$
[ -s /tmp/ka_urls.$$ ] || die "release 里没有匹配的内核资产"
while read -r url; do
  f=$(basename "$url"); echo "   - $f"
  curl -fsSL -o "$f" "$url"
done < /tmp/ka_urls.$$
rm -f /tmp/ka_urls.$$

log "校验 sha256（若提供）"
if [ -f sha256sums.txt ]; then
  sha256sum -c sha256sums.txt 2>/dev/null || warn "部分文件不在 sha256sums.txt（可能只校验 deb），继续"
fi

log "解压 modules-and-dtb.tar"
[ -f modules-and-dtb.tar ] || die "没拿到 modules-and-dtb.tar"
tar -xf modules-and-dtb.tar       # → root/lib/modules/<KVER> + root/usr/lib/linux-image-<KVER>
KA_KVER=$(ls root/lib/modules/)
VML=$(ls vmlinuz-* 2>/dev/null | head -1)
[ -n "$VML" ] || die "没拿到 vmlinuz-*"

log "内核就绪：KVER=$KA_KVER  vmlinuz=$VML"
echo "   modules → $KA_DIR/root/lib/modules/$KA_KVER"
echo "   dtb     → $KA_DIR/root/usr/lib/linux-image-$KA_KVER/"
echo "   提示：u-boot/initrd 复用 $KERNEL_DIR（rsdk 首次提取）"
