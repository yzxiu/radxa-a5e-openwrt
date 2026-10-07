#!/usr/bin/env bash
# ============================================================================
# 步骤3：下载 ImmortalWrt armsr/armv8 通用 rootfs（方案C 的基础 rootfs）
# ----------------------------------------------------------------------------
# 为什么 armsr 通用：官方 OpenWrt 25.12 无 A5E（需 6.15/6.16 mainline），
#   armsr armv8 是纯 rootfs（无内核），正好配 A5E 官方内核拼装。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
mkdir -p "$OWRT"
cd "$OWRT"

# ---------- 解析实际 tag + 资产 URL/digest ----------
# OWRT_TAG=latest → 取 releases 列表 published_at 最新一条（含 prerelease，同 25 步）。
API="https://api.github.com/repos/${OWRT_REPO}/releases"
if [ "${OWRT_TAG}" = "latest" ]; then
  ACTUAL_TAG="$(curl -fsSL "${API}?per_page=100" | python3 -c '
import sys, json
d=json.load(sys.stdin)
rel=[r for r in d if not r.get("draft", False)]
rel.sort(key=lambda r: r["published_at"], reverse=True)
print(rel[0]["tag_name"] if rel else "")')" || true
  [ -n "${ACTUAL_TAG}" ] || die "拿不到 ${OWRT_REPO} 的任何 release（无网/需 token）"
  log "取最新 rootfs release：${ACTUAL_TAG}"
else
  ACTUAL_TAG="${OWRT_TAG}"
  log "按 OWRT_TAG 锁定 rootfs release：${ACTUAL_TAG}"
fi

# 从该 release 资产里找 OWRT_TAR，拿下载地址 + GitHub 官方 sha256 digest
RES="$(curl -fsSL "${API}/tags/${ACTUAL_TAG}" | python3 -c '
import sys, json
name=sys.argv[1]
r=json.load(sys.stdin)
for a in r.get("assets", []):
    if a["name"] == name:
        print(a["browser_download_url"])
        print(a.get("digest", ""))' "$OWRT_TAR")" || die "查 release ${ACTUAL_TAG} 资产失败"
OWRT_URL="$(echo "${RES}" | sed -n 1p)"
DIGEST="$(echo "${RES}" | sed -n 2p)"   # 形如 sha256:<hex>，可能为空
[ -n "${OWRT_URL}" ] || die "release ${ACTUAL_TAG} 里没有 ${OWRT_TAR}"
OWRT_SHA="${DIGEST#sha256:}"
echo "   url=${OWRT_URL}"
echo "   sha256=${OWRT_SHA:-(API 未给 digest,跳过校验)}"

# ---------- 下载（已存在且 digest 匹配则复用） ----------
if [ -f "${OWRT_TAR}" ] && [ -n "${OWRT_SHA}" ] \
   && echo "${OWRT_SHA}  ${OWRT_TAR}" | sha256sum -c - >/dev/null 2>&1; then
  log "已存在 ${OWRT_TAR} 且 sha256 匹配，复用"
else
  rm -f "${OWRT_TAR}"
  log "下载 ${OWRT_TAR}"
  curl -fL --retry 3 -o "${OWRT_TAR}" "${OWRT_URL}" || die "下载失败"
fi

# ---------- 校验 ----------
if [ -n "${OWRT_SHA}" ]; then
  echo "${OWRT_SHA}  ${OWRT_TAR}" | sha256sum -c - || die "sha256 不匹配！"
else
  warn "API 未提供 digest，跳过 sha256 校验"
fi

# 记录 rootfs 版本到 build-info.env（25 步已建文件则追加，未跑 25 则自建头）
if [ ! -f "$OWRT/build-info.env" ]; then
  {
    echo "# build-info $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "DSRC=$DSRC"
    echo "KSRC=$KSRC"
    echo "DEB_TAG=$DEB_TAG"
    echo "DEB_FLAVOR=$DEB_FLAVOR"
  } > "$OWRT/build-info.env"
fi
DISTRIB=$(tar -xzf "$OWRT_TAR" -O ./etc/openwrt_release 2>/dev/null \
            | grep -m1 '^DISTRIB_DESCRIPTION=' | cut -d= -f2- | tr -d "'\"" || true)
{
  echo "ROOTFS_VER=$OWRT_VER"
  echo "ROOTFS_TAG=$ACTUAL_TAG"
  echo "ROOTFS_TAR=$OWRT_TAR"
  echo "ROOTFS_SHA256=$OWRT_SHA"
  printf "ROOTFS_DISTRIB='%s'\n" "$DISTRIB"
} >> "$OWRT/build-info.env"
log "rootfs 版本已追加 → owrt/build-info.env（DISTRIB=$DISTRIB）"
