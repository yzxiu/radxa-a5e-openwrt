#!/usr/bin/env bash
# ============================================================================
# 步骤1：用 rsdk 构建 A5E 的 Debian 原始镜像（只为拿到内核/u-boot 资产）
# ----------------------------------------------------------------------------
# 前提：在 rsdk devcontainer 内（需 KVM 加速 + binfmt/qemu，guestfish 可用）。
#       官方 CI 用 test-repo: true，因为 a527-trixie 正式版 404，必须走测试源。
# 产物：out/output_512.img、out/rootfs.tar、out/build-image（guestfish 脚本）、
#       out/config.yaml —— 内核/u-boot 都装在这套 Debian 里，下一步从 rootfs.tar 提取。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
[ "$DSRC" = radxa-release ] && { log "DSRC=radxa-release：跳过 rsdk build（用 15-fetch-radxa-debian.sh 下现成 Debian）"; exit 0; }

log "rsdk build $BOARD  （--test-repo / -T，走 a527-trixie-test 源）"
# 在 rsdk 源码目录（rsdk-src/rsdk）内执行：
#   ./rsdk build --test-repo "$BOARD"
# 或等价的 rsdk build -T radxa-cubie-a5e
# 说明：rsdk 从 APT 仓库拉取预编译的 linux-image-radxa-cubie-a5e / u-boot-dlan17 等 deb，
#       再用 build-image(guestfish) 打成 GPT 镜像。这一步不产出 OpenWrt，只为取内核资产。
echo "  （手动执行示例） cd rsdk-src/rsdk && ./rsdk build -T $BOARD"
echo "  产物应出现在： $OUT"
ls -la "$OUT"/rootfs.tar "$OUT"/build-image 2>/dev/null || warn "未找到 out/ 产物，请先在 devcontainer 里 rsdk build"
