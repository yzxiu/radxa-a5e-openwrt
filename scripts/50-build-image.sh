#!/usr/bin/env bash
# ============================================================================
# 步骤5：用 rsdk 的 build-image(guestfish) 打成 GPT 镜像
# ----------------------------------------------------------------------------
# build-image 会：建 GPT 3 分区 → tar-in 我们的 rootfs.tar → 用 blkid 生成
#   新随机 UUID 注入 root=UUID → resize + setup.sh 写 u-boot(SPL@LBA256) → 扩容。
# ⚠ 每次运行 rootfs 的 UUID 都变！所以别在别处硬编码 UUID；离线编辑前用
#   blkid/debugfs 读真实值（见 90-offline-edit-image.sh 与 坑3）。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ -f "$OUT/build-image" ]              || die "缺 $OUT/build-image（rsdk 生成，见 10）"
[ -f "$OWRT/openwrt-a5e-rootfs.tar" ]  || die "缺 openwrt-a5e-rootfs.tar，先跑 40"

BUILD=$(mktemp -d); trap 'rm -rf "$BUILD"' EXIT
cp "$OUT/build-image" "$BUILD/build-image"; chmod +x "$BUILD/build-image"
# build-image 用相对路径读取 rootfs.tar
ln -sf "$OWRT/openwrt-a5e-rootfs.tar" "$BUILD/rootfs.tar"

log "guestfish -f build-image （需要 root：guestfish 直接写裸镜像）"
cd "$BUILD"
sudo guestfish -f ./build-image || die "build-image 失败（确认 guestfish 可用、有 root）"

log "搬回镜像 + 生成校验"
mv -f output_512.img "$IMG" 2>/dev/null || cp -f output_512.img "$IMG"
sha256sum "$IMG" > "$IMG.sha256"
echo "   → $IMG   ($(du -h "$IMG"|cut -f1))"
echo "   sha: $(cat "$IMG.sha256")"
echo "提示：新镜像 root=UUID 已被 build-image 改写，烧录前无需再改。"
