#!/usr/bin/env bash
# ============================================================================
# 调试期工具：离线编辑成品镜像的 ext4 rootfs（不重新 build，秒级改一个 config）
# ----------------------------------------------------------------------------
# 这是我调试中最常用的手法（rsdk 重打整镜像 12s+，但改一个文件更快）。原理：
#   dd 提取 sda3(ext4) 到裸文件 → debugfs -w 改 → dd 写回。debugfs 能增删改文件、
#   建符号链接、设权限（mode 0100755），无需挂载 loop（免 root）。
#
# 用法：
#   ./90-offline-edit-image.sh extract            # 提取 sda3 → /tmp/rp.img
#   debugfs -w -R 'rm /etc/foo' /tmp/rp.img
#   debugfs -w -R 'write ./localfile /etc/foo' /tmp/rp.img
#   debugfs -w -R 'symlink /etc/rc.d/S15x /etc/init.d/x' /tmp/rp.img
#   debugfs -w -R 'set_inode_field /etc/init.d/x mode 0100755' /tmp/rp.img   # debugfs write 出来是 0644，需手动补可执行位
#   ./90-offline-edit-image.sh commit             # 写回镜像 + 刷新 sha256
#
# ⚠ ROOTFS_LBA/SECT 随每次重 build 变化！提取前先确认：
#     sgdisk -i 3 owrt-a5e.img        # 看 First/Last sector → ROOTFS_LBA/SECT
#     dumpe2fs -h <(dd if=owrt-a5e.img bs=512 skip=$LBA ...)   # 或直接按 partition 表
#   临时覆盖： ROOTFS_LBA=... ROOTFS_SECT=... ./90-offline-edit-image.sh extract
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.." && source scripts/00-lib.sh
RP=${RP:-/tmp/rp.img}

cmd=${1:-help}
case "$cmd" in
  extract)
    log "提取 sda3（LBA=$ROOTFS_LBA 扇区=$ROOTFS_SECT）→ $RP"
    dd if="$IMG" of="$RP" bs=512 skip="$ROOTFS_LBA" count="$ROOTFS_SECT" status=none
    echo "  完成。改文件示例： debugfs -R 'cat /etc/inittab' $RP"
    ;;
  commit)
    log "写回 $RP → $IMG（bs=512 seek=$ROOTFS_LBA notrunc）"
    dd if="$RP" of="$IMG" bs=512 seek="$ROOTFS_LBA" conv=notrunc status=none
    sha256sum "$IMG" > "$IMG.sha256"
    echo "  完成。新 sha: $(cat "$IMG.sha256")"
    ;;
  *)
    sed -n '2,40p' "$0"
    ;;
esac
