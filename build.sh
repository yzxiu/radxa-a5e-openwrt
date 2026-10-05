#!/usr/bin/env bash
# ============================================================================
# openwrt-a5e-build 主入口
# ----------------------------------------------------------------------------
# 日常构建（不碰 rsdk，需 kernel-actions release 已产出）：
#   ./build.sh              KSRC=kernel-actions：25→30→40→50
#   KSRC=rsdk ./build.sh    内核走 rsdk 提取：20→30→40→50
# 首次（取 u-boot/initrd/build-image 资产，需 rsdk devcontainer）：
#   ./build.sh 10           全流程 10→20→25→30→40→50
# 单独调试：scripts/90-offline-edit-image.sh（改成品镜像一个文件，秒级）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source scripts/00-lib.sh 2>/dev/null || true
STEPS=(10-build-debian 20-extract-kernel 25-fetch-kernel 30-fetch-openwrt 40-assemble-rootfs 50-build-image)
from=${1:-}
if [ -z "$from" ]; then
  case "${KSRC:-kernel-actions}" in
    kernel-actions) from=25 ;;
    *) from=20 ;;
  esac
fi
[ -d "$OWRT/a5e-kernel/radxa-cubie-a5e" ] || warn "未见 rsdk 的 u-boot 资产（owrt/a5e-kernel/），日常构建会缺 u-boot → 需先 ./build.sh 10"
for s in "${STEPS[@]}"; do
  n=${s%%-*}
  [ "$n" -lt "$from" ] && continue
  echo; echo "############ $s ############"
  bash "scripts/$s.sh"
done
echo; echo "✅ 完成：$(sha256sum "$IMG" 2>/dev/null)"
