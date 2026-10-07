#!/usr/bin/env bash
# ============================================================================
# 步骤5：打包 GPT 镜像（guestfish / rsdk build-image）
# ----------------------------------------------------------------------------
# guestfish 依赖 nix 版 libguestfs + supermin appliance(/dev/kvm)，两种执行方式自动选：
#   A) 当前环境已有 guestfish（直接身处 rsdk 容器）→ 就地跑
#   B) host 无 guestfish（本机器常态）→ docker cp 产物进 RSDK_CONTAINER，direnv
#        激活 nix 环境后 guestfish，再 docker cp 回
# 打包用的 build-image 来自 out/（下载 t10 的 或 rsdk 本地生成的，分区逻辑一致）。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
RT="$OWRT/openwrt-a5e-rootfs.tar"
# build-image 优先用仓库定制版（单槽 960M 布局，去 efi）；无则回退 radxa 下载版
BI="$WORK/custom/build-image"
if [ ! -f "$BI" ]; then
  BI="$OUT/build-image"
fi
[ -f "$RT" ] || die "缺 $RT，先 ./build.sh 40"
[ -f "$BI" ] || die "缺 $BI（仓库 custom/build-image 与下载版都不存在）"

# build-image 里 tar-in 引用的 rootfs 文件名因来源而异：
#   本地 rsdk 自建版 = rootfs.tar；radxa release 下载版 = <DEB_BASE>.rootfs.tar。
# 直接从 `tar-in <name>` 那一行取名，两种都吃；软链我们的 openwrt rootfs 到它。
# ⚠ 必须带 `|| true`：set -euo pipefail 下，sed/grep 无命中会让命令替换返回非零，
#   脚本在赋值那一行就静默 exit 1（零输出），下面那句兜底根本执行不到。
#   本地就因此踩过：rsdk 版 build-image 引的是纯 rootfs.tar，旧正则
#   `[^"[:space:]]+\.rootfs\.tar` 要求前缀至少一个字符，匹配不上 → 直接死。
RN=$(sed -nE 's/^[[:space:]]*tar-in[[:space:]]+([^[:space:]]+\.tar).*/\1/p' "$BI" | head -1 || true)
[ -n "$RN" ] || RN="rootfs.tar"
export RN
echo "   build-image 引用的 rootfs 名：$RN"

pack_inplace() {   # 环境里有 guestfish，直接打
  local B; B=$(mktemp -d); trap 'rm -rf "$B"' RETURN
  cp "$BI" "$B/build-image"; chmod +x "$B/build-image"; ln -sf "$RT" "$B/$RN"
  ( cd "$B" && guestfish -f ./build-image ) || die "guestfish 就地打包失败"
  mv -f "$B/output_512.img" "$IMG"
}

pack_container() { # 借 rsdk 容器打包
  docker ps -q -f "name=^${RSDK_CONTAINER}$" | grep -q . || die "容器 ${RSDK_CONTAINER} 未运行"
  local W=/tmp/a5e-build
  log "docker cp → ${RSDK_CONTAINER}:${W}"
  docker exec "$RSDK_CONTAINER" bash -lc "rm -rf $W && mkdir -p $W"
  docker cp "$RT" "$RSDK_CONTAINER:$W/$RN"
  docker cp "$BI" "$RSDK_CONTAINER:$W/build-image"
  log "容器内 direnv(nix) 激活 + guestfish 打包（~20s）"
  docker exec "$RSDK_CONTAINER" bash -lc "
    cd /workspaces/rsdk && direnv allow >/dev/null 2>&1 || true
    eval \"\$(direnv export bash)\"
    cd $W && chmod +x build-image && guestfish -f ./build-image"
  docker cp "$RSDK_CONTAINER:$W/output_512.img" "$IMG"
  docker exec "$RSDK_CONTAINER" bash -lc "rm -rf $W"
}

log "打包镜像（guestfish）"
if command -v guestfish >/dev/null 2>&1; then log "有 guestfish → 就地"; pack_inplace
else log "无 guestfish → 借容器 $RSDK_CONTAINER"; pack_container; fi

sha256sum "$IMG" > "$IMG.sha256"
echo "   → $IMG ($(du -h "$IMG"|cut -f1))  sha=$(cut -c1-16 "$IMG.sha256")…"
echo "提示：root=UUID 已由 build-image 用 blkid 注入新随机值（坑3，切勿硬编码）。"
