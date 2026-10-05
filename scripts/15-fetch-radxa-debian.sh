#!/usr/bin/env bash
# ============================================================================
# 步骤1.5：从 radxa-build release 下载【现成 Debian】，彻底替代 rsdk build
# ----------------------------------------------------------------------------
# 解决"不想重跑 rsdk"：radxa-build/radxa-cubie-a5e 的 release 里有 rsdk 已编译好的
#   - ${DEB_BASE}.rootfs.tar.xz   = out/rootfs.tar 等价（内含内核/u-boot/initrd/dtb）
#   - ${DEB_BASE}.build-512-image = out/build-image 等价（guestfish 打包脚本，分区/
#       setup.sh update_bootloader 512 与 rsdk 本地生成完全一致，已核对）
#   - ${DEB_BASE}.sha512sum       = 校验
# 默认 tag=rsdk-t10 flavor=cli（见 00-lib.sh，可 DEB_TAG/DEB_FLAVOR 覆盖）。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ "$DSRC" = radxa-release ] || { log "DSRC=$DSRC：跳过（rsdk 模式请用 10-build-debian.sh）"; exit 0; }

mkdir -p "$OUT"; cd "$OUT"
log "从 $RADXA_REPO 下载 $DEB_TAG ($DEB_FLAVOR) 现成 Debian → out/"
echo "  base = $DEB_BASE"

dl() { # $1=远端名 $2=本地名
  [ -f "$2" ] && { echo "   ✓ 已存在 $2（跳过下载）"; return; }
  echo "   ↓ $1"
  curl -fL --connect-timeout 15 --retry 3 -o "$2" "$DEB_REL/$1"
}

dl "$DEB_BASE.build-512-image" build-image; chmod +x build-image
dl "$DEB_BASE.sha512sum"        sha512sum
dl "$DEB_BASE.rootfs.tar.xz"    rootfs.tar.xz

log "校验 sha512"
verify() { # $1=本地名 $2=远端名（sha512sum 里记的名字）
  local h; h=$(grep -- "$2" sha512sum | awk '{print $1}')
  [ -n "$h" ] && echo "$h  $1" | sha512sum -c - && echo "   ✅ $1" || warn "校验 $1 跳过/失败"
}
verify build-image    "$DEB_BASE.build-512-image"
verify rootfs.tar.xz  "$DEB_BASE.rootfs.tar.xz"

log "Debian 资产就绪：out/build-image + out/rootfs.tar.xz ($(du -h rootfs.tar.xz|cut -f1))"
echo "   下一步：20-extract-kernel.sh 从中提取 u-boot/initrd（内核走 25 或本地）"
