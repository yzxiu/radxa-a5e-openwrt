#!/usr/bin/env bash
# ============================================================================
# openwrt-a5e-build 主入口：串起完整构建流程
# ----------------------------------------------------------------------------
#   ./build.sh          全流程 10→50（需 rsdk devcontainer：KVM+binfmt+guestfish+root）
#   ./build.sh 40       只从第 4 步（重拼装 rootfs，含全部定制）开始
# 单独调试用：scripts/90-offline-edit-image.sh（改成品镜像里的一个文件，秒级）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
STEPS=(10-build-debian 20-extract-kernel 30-fetch-openwrt 40-assemble-rootfs 50-build-image)
from=${1:-10}
for s in "${STEPS[@]}"; do
  n=${s%%-*}
  [ "$n" -lt "$from" ] && continue
  echo; echo "############ $s ############"
  bash "scripts/$s.sh"
done
echo; echo "✅ 完成：$(sha256sum "$(cd .. && pwd)/owrt-a5e.img" 2>/dev/null)"
