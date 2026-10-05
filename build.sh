#!/usr/bin/env bash
# ============================================================================
# openwrt-a5e-build 主入口
# ----------------------------------------------------------------------------
# 默认全链路（10→15→20→25→30→40→50），各步按 DSRC/KSRC 自动决定"做/跳过"，
# 因此**默认即可全程免 rsdk 编译**：
#   DSRC=radxa-release → 10跳过、15下载现成 Debian（rootfs+build-image）
#   KSRC=kernel-actions → 25下载自编译内核；rsdk → 25跳过、用20提取的内核
#   20 总跑（提取 u-boot/initrd，kernel-actions 不产这两样）
# 覆盖来源示例：
#   DEB_TAG=rsdk-t8 ./build.sh          用别的 Debian tag
#   DEB_FLAVOR=kde ./build.sh           用 kde 版
#   KSRC=rsdk ./build.sh                内核也用 Debian 自带的（不打 kernel-actions）
#   DSRC=rsdk ./build.sh                真要在 devcontainer 里本地 rsdk build
#   ./build.sh 40                        只重拼装+打包（改完定制后）
# 单独调试：scripts/90-offline-edit-image.sh（改成品镜像一个文件，秒级）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source scripts/00-lib.sh 2>/dev/null || true
STEPS=(10-build-debian 15-fetch-radxa-debian 20-extract-kernel 25-fetch-kernel 30-fetch-openwrt 40-assemble-rootfs 50-build-image)
from=${1:-10}
echo "DSRC=$DSRC  KSRC=$KSRC  DEB=$DEB_BASE  KERNEL_ACTIONS_TAG=$KERNEL_ACTIONS_TAG"
for s in "${STEPS[@]}"; do
  n=${s%%-*}
  [ "$n" -lt "$from" ] && continue
  echo; echo "############ $s ############"
  bash "scripts/$s.sh"
done
echo; echo "✅ 完成：$(sha256sum "$IMG" 2>/dev/null)"
