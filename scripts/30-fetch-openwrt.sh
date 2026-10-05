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
