#!/bin/sh
#=============================================================================
# A5E 固件自动升级脚本（在设备上运行，仿 upgrade-lubancat.sh）
#
# 功能:
#   1. 查询 yzxiu/radxa-a5e-openwrt 最新 release，定位 owrt-a5e.img.tar.gz
#   2. 下载到 /tmp/upload/
#   3. 调用 openwrt-update-a5e 执行双槽 OTA（写对侧槽 + 配置迁移 + 切槽）
#
# 用法:
#   sh upgrade-a5e.sh            # 查询最新并用最新版
#   sh upgrade-a5e.sh <tag>      # 指定版本, 如 rel-20261008-064157-r19
#   sh upgrade-a5e.sh --dry      # 只查询最新固件 URL, 不下载不升级
#
# 依赖: curl(自带), openwrt-update-a5e(本仓库镜像自带)
# 代理回退: GitHub 直连失败时自动改走本机 sing-box mixed 入口 127.0.0.1:1087
#=============================================================================
set -u

REPO="yzxiu/radxa-a5e-openwrt"
TAG="${1:-}"
DRY=0
[ "${TAG}" = "--dry" ] && { DRY=1; TAG=""; }

UPLOAD_DIR="/tmp/upload"
PROXY_URL="http://127.0.0.1:1087"   # 本机 sing-box mixed 入口 (http/socks 双协议, 仅回环)
mkdir -p "${UPLOAD_DIR}"

# github_curl <args...>  —— 直连优先, 失败自动带代理重试
github_curl() {
    if curl -fsSL --connect-timeout 10 "$@" 2>/dev/null; then
        return 0
    fi
    if netstat -tln 2>/dev/null | grep -q "127.0.0.1:1087"; then
        echo "      (直连失败, 改走本机代理 ${PROXY_URL})" >&2
        curl -fsSL --connect-timeout 10 -x "${PROXY_URL}" "$@"
    else
        return 1
    fi
}

echo "======================================================================"
echo " Radxa Cubie A5E 固件自动升级 (双槽 OTA)"
echo "======================================================================"

# ---------- 1. 确定 release tag ----------
if [ -n "${TAG}" ]; then
    echo "[1/4] 使用指定版本: ${TAG}"
    RELEASE_URL="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
else
    echo "[1/4] 查询最新 release ..."
    RELEASE_URL="https://api.github.com/repos/${REPO}/releases/latest"
fi

REL_JSON=$(github_curl "${RELEASE_URL}") \
    || { echo "[ERROR] 无法访问 GitHub API (网络不通或版本不存在)"; exit 1; }

REL_TAG=$(echo "${REL_JSON}" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
echo "      -> release tag: ${REL_TAG}"

# ---------- 2. 从 assets 定位固件 ----------
FW_NAME=$(echo "${REL_JSON}" \
    | sed -n 's/.*"name": *"\([^"]*owrt-a5e[^"]*\.img\.tar\.gz\)".*/\1/p' \
    | head -n1)
FW_URL=$(echo "${REL_JSON}" \
    | sed -n 's/.*"browser_download_url": *"\([^"]*owrt-a5e[^"]*\.img\.tar\.gz\)".*/\1/p' \
    | head -n1)

if [ -z "${FW_NAME}" ] || [ -z "${FW_URL}" ]; then
    echo "[ERROR] 在 release ${REL_TAG} 中未找到 owrt-a5e 的 .img.tar.gz 固件"
    exit 1
fi
echo "[2/4] 固件: ${FW_NAME}"

if [ "${DRY}" = "1" ]; then
    echo "(dry-run) 下载地址:"
    echo "  ${FW_URL}"
    echo "下载到: ${UPLOAD_DIR}/${FW_NAME}"
    echo "升级命令: openwrt-update-a5e ${UPLOAD_DIR}/${FW_NAME}"
    exit 0
fi

# ---------- 3. 下载 ----------
FW_PATH="${UPLOAD_DIR}/${FW_NAME}"
if [ -f "${FW_PATH}" ]; then
    echo "[3/4] 已存在 ${FW_NAME}, 跳过下载 (要强制重下请先删除)"
else
    echo "[3/4] 下载中 ..."
    if ! curl -fL --connect-timeout 15 -o "${FW_PATH}" "${FW_URL}"; then
        rm -f "${FW_PATH}"
        if netstat -tln 2>/dev/null | grep -q "127.0.0.1:1087"; then
            echo "      (直连下载失败, 改走本机代理 ${PROXY_URL})"
            curl -fL --connect-timeout 15 -x "${PROXY_URL}" -o "${FW_PATH}" "${FW_URL}" || {
                echo "[ERROR] 下载失败 (直连与代理均不通)"; rm -f "${FW_PATH}"; exit 1; }
        else
            echo "[ERROR] 下载失败"; exit 1
        fi
    fi
    echo "      下载完成: $(du -h "${FW_PATH}" | awk '{print $1}')"
fi

# ---------- 4. 触发升级 ----------
echo "[4/4] 启动升级 (openwrt-update-a5e) ..."
command -v openwrt-update-a5e >/dev/null 2>&1 \
    || { echo "[ERROR] 设备缺 openwrt-update-a5e（非本仓库镜像?）"; exit 1; }

echo ">>> 即将重启设备, 升级过程请勿断电。Ctrl+C 取消..."
sleep 5
openwrt-update-a5e "${FW_PATH}"
