#!/usr/bin/env bash
# ============================================================================
# 步骤2.5：从 kernel-actions（yzxiu/radxa-a5e-openwrt-kernel）下载内核资产
# ----------------------------------------------------------------------------
# 取代"重跑 rsdk 取内核"。Release（v* tag）资产：
#   vmlinuz-<KVER>          未压缩 ARM64 Image，U-Boot extlinux 直接可用
#   modules-and-dtb.tar     root/lib/modules/<KVER>（.ko 已展开、dep 已修、.bin 已删）
#                           + root/usr/lib/linux-image-<KVER>/*.dtb
#                           bridge/firewall4/tproxy/aic8800-wifi 已 builtin 进 vmlinux
#   sha256sums.txt / BUILD_INFO.env
# u-boot / initrd 不在此仓库产出 → 复用 rsdk 首次提取的 owrt/a5e-kernel/（不重跑 rsdk）。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ "$KSRC" = kernel-actions ] || { log "KSRC=$KSRC：跳过（rsdk 模式请用 20-extract-kernel.sh）"; exit 0; }

mkdir -p "$KA_DIR"; cd "$KA_DIR"
REPO="$KERNEL_ACTIONS_REPO"; TAG="$KERNEL_ACTIONS_TAG"

# ---- 带 token + 重试的 GitHub API GET -------------------------------------
# 为什么必须带 token：匿名 API 限额是 **60 次/小时/IP**，而 GitHub 托管 runner 共享
# Azure 出口 IP —— 别人的 workflow 把额度用光，你就会 403（run #19 就是这么死的，
# #15~#18 只是侥幸）。带 GITHUB_TOKEN 后是 5000 次/小时/**token**，与 IP 无关。
# 读公共仓的 release 元数据用本仓的 github.token 就够，不需要跨仓授权（仅当 kernel
# 仓是私有仓时才需 PAT）。资产下载走 objects.githubusercontent.com，不吃这个额度。
GH_AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  GH_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
  echo "  （用 GITHUB_TOKEN 访问 API：限额 5000/h，按 token 计）"
else
  warn "未提供 GITHUB_TOKEN，匿名访问 API（限额 60/h/IP，runner 共享 IP 极易 403）"
fi
ghapi() {  # $1=url  $2=输出文件；403/429/5xx/网络错误按 15s×n 退避重试 5 次
  local url="$1" out="$2" try code msg
  for try in 1 2 3 4 5; do
    code=$(curl -sSL ${GH_AUTH[@]+"${GH_AUTH[@]}"} \
             -H "Accept: application/vnd.github+json" \
             -H "X-GitHub-Api-Version: 2022-11-28" \
             -o "$out" -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    [ "$code" = 200 ] && return 0
    msg=$(head -c 220 "$out" 2>/dev/null | tr -d '\n')
    warn "API HTTP $code（第 $try/5 次）$url"
    [ -n "$msg" ] && echo "       $msg"
    case "$code" in 403|429|5*|000) sleep $((try * 15));; *) return 1;; esac
  done
  return 1
}

log "解析 release tag（latest → 实际 tag）"
API="https://api.github.com/repos/$REPO/releases"
# CI 匿名调用共享 IP 易撞 rate limit；有 GITHUB_TOKEN 时用认证请求(quota 5000\/h)
if [ "$TAG" = latest ]; then
  # 直接取 releases 列表里 published_at 最新的一条（正式/pre 都算，不含 draft）
  ghapi "$API?per_page=100" "/tmp/ka_rel.$$" \
    || die "拿不到 release 列表（上方有 HTTP 状态与报文；403 大概率是限流，请传 GITHUB_TOKEN）"
  TAG=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1]))
rel = [r for r in d if not r.get("draft", False)]
rel.sort(key=lambda r: r["published_at"] or r["created_at"], reverse=True)
print(rel[0]["tag_name"] if rel else "")' "/tmp/ka_rel.$$")
  [ -n "$TAG" ] || { rm -f "/tmp/ka_rel.$$"; die "该仓库没有非 draft 的 release"; }
  ghapi "$API/tags/$TAG" "/tmp/ka_rel.$$" || die "拿不到 release $TAG 的详情"
  REL_INFO=$(python3 -c '
import sys, json
r = json.load(open(sys.argv[1]))
print("title=", repr(r.get("name")), "published=", repr(r.get("published_at")),
      "prerelease=", repr(r.get("prerelease")), "created_at=", repr(r.get("created_at")))' "/tmp/ka_rel.$$")
  rm -f "/tmp/ka_rel.$$"
  log "取最新 release：$TAG"
  echo "  $REL_INFO"
else
  log "按 KERNEL_ACTIONS_TAG 锁定 release：$TAG"
fi
echo "  tag = $TAG"

log "枚举并下载 release 资产"
# 用 API 拿每个资产的下载地址（含 vmlinuz-*，名字随 KVER 变）
ghapi "$API/tags/$TAG" "/tmp/ka_tag.$$" || die "拿不到 release $TAG 的资产列表"
python3 -c '
import sys, json, re
for a in json.load(open(sys.argv[1])).get("assets", []):
    n = a["name"]
    if re.search(r"vmlinuz|modules-and-dtb|sha256sums|BUILD_INFO", n):
        print(a["browser_download_url"])' "/tmp/ka_tag.$$" > "/tmp/ka_urls.$$"
rm -f "/tmp/ka_tag.$$"
[ -s "/tmp/ka_urls.$$" ] || { rm -f "/tmp/ka_urls.$$"; die "release 里没有匹配的内核资产"; }
while read -r url; do
  f=$(basename "$url"); echo "   - $f"
  curl -fL --retry 3 --retry-delay 5 -o "$f" "$url" || die "下载失败：$f"
done < "/tmp/ka_urls.$$"
rm -f "/tmp/ka_urls.$$"

log "校验 sha256"
# ⚠ 不能直接 `sha256sum -c sha256sums.txt`：kernel 仓记的名字与 release 资产名对不上
# （记的是 `vmlinuz`，资产叫 `vmlinuz-<KVER>`；还列了我们根本不下载的 deb），于是每条
# 都是 "FAILED open or read"，再被 `|| warn ... 继续` 吞掉 —— 实测这等于**从来没校验过**。
# 改成逐条只校"本地确实存在的文件"，并明确统计到底校验了几个。
if [ -f sha256sums.txt ]; then
  ok=0; bad=0; skip=0
  while read -r sum name _rest; do
    [ -n "${sum:-}" ] && [ -n "${name:-}" ] || continue
    case "$sum" in \#*) continue;; esac
    target="$name"; note=""
    if [ ! -f "$target" ]; then
      # kernel 仓记的是 `vmlinuz`，而资产叫 `vmlinuz-<KVER>` —— 做**唯一前缀匹配**把
      # 最关键的 vmlinuz 救回来。只在恰好匹配到一个文件时才采用，避免校错东西；
      # 匹配不到（例如我们根本不下载的 deb）就计作 skip。
      m=$(ls -1 ${name}* 2>/dev/null || true)
      n=$(printf '%s\n' "$m" | grep -c . || true)
      if [ "$n" = 1 ]; then target="$m"; note="（前缀匹配 $name → $m）"; else skip=$((skip+1)); continue; fi
    fi
    if printf '%s  %s\n' "$sum" "$target" | sha256sum -c --status 2>/dev/null; then
      ok=$((ok+1)); echo "   ✓ $target $note"
    else
      bad=$((bad+1)); echo "   ✗ $target 校验失败 $note"
    fi
  done < sha256sums.txt
  echo "   小计：通过 $ok / 失败 $bad / 对不上而跳过 $skip"
  [ "$bad" -eq 0 ] || die "sha256 校验失败（上方标 ✗ 的项）"
  [ "$ok" -gt 0 ] || warn "sha256sums.txt 里没有一个文件名能对上（kernel 仓命名不一致）——本次等于未校验"
else
  warn "release 没提供 sha256sums.txt"
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

# 记录构建信息（CI release notes / 本地留档）：内核 release tag + BUILD_INFO.env
# 每次重建（25 重跑）时整文件刷新，rootfs 信息由 30 步追加。
{
  echo "# build-info $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "DSRC=$DSRC"
  echo "KSRC=$KSRC"
  echo "DEB_TAG=$DEB_TAG"
  echo "DEB_FLAVOR=$DEB_FLAVOR"
  echo "KERNEL_RELEASE_TAG=$TAG"
  echo "KERNEL_RELEASE_URL=https://github.com/$REPO/releases/tag/$TAG"
  sed 's/^/KA_/' BUILD_INFO.env 2>/dev/null || true
  echo "KERNEL_KVER=$KA_KVER"
  echo "KERNEL_VMLINUZ=$VML"
} > "$OWRT/build-info.env"
log "构建信息 → owrt/build-info.env（含内核版本，rootfs 信息由 30 步追加）"
