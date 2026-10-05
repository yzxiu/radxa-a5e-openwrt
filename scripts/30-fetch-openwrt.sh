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

if [ -f "$OWRT_TAR" ]; then
  log "已存在 $OWRT_TAR，仅校验"
else
  log "下载 $OWRT_URL"
  curl -fL --retry 3 -o "$OWRT_TAR" "$OWRT_URL"
fi

log "校验 sha256（版本变更时同步改 00-lib.sh 的 OWRT_SHA）"
echo "$OWRT_SHA  $OWRT_TAR" | sha256sum -c - || die "sha256 不匹配！"

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
  echo "ROOTFS_TAG=$OWRT_TAG"
  echo "ROOTFS_TAR=$OWRT_TAR"
  echo "ROOTFS_SHA256=$OWRT_SHA"
  printf "ROOTFS_DISTRIB='%s'\n" "$DISTRIB"
} >> "$OWRT/build-info.env"
log "rootfs 版本已追加 → owrt/build-info.env（DISTRIB=$DISTRIB）"
