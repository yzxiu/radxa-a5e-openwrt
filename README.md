# Radxa Cubie A5E → OpenWrt 路由器固件

把 Radxa Cubie A5E（Allwinner A527 / sun55iw3）的官方 Debian 内核 + u-boot，
与 ImmortalWrt armsr/armv8 通用 rootfs 拼装成可刷写的 OpenWrt 路由固件。

> 详细调试过程与踩坑分析见 [`docs/OpenWrt-A5E-制作记录.md`](docs/OpenWrt-A5E-制作记录.md)。
> 本仓库记录**如何复现**这套镜像的全部改动，调试过程中所有定制都在 `scripts/ custom/ patches/` 里落成源码。

## 方案（方案C）

官方 OpenWrt 25.12 不支持 A5E（要 6.15/6.16 mainline），Radxa 只提供 Debian。
折中：**A5E 官方内核(6.6.98-1-aw2607) + ImmortalWrt armsr 通用 rootfs**，
用 rsdk 的 `build-image`(guestfish) 打成 GPT 镜像，Debian initramfs 负责稳定挂载。

## 目录结构

```
openwrt-a5e-build/
├── build.sh                     # 主入口：串起 10→50 全流程
├── scripts/
│   ├── 00-lib.sh                # 版本/URL/路径/分区LBA/引导参数（改这里）
│   ├── 10-build-debian.sh       # rsdk build -T → out/（取内核/u-boot 资产）
│   ├── 10-build-debian.sh       # 【仅首次】rsdk build -T → out/（取 build-image/u-boot/initrd）
│   ├── 20-extract-kernel.sh     # 【仅首次】从 out/rootfs.tar 提取资产 → owrt/a5e-kernel/
│   ├── 25-fetch-kernel.sh       # ★日常内核来源：从 kernel-actions Release 下载 vmlinuz+modules
│   ├── 30-fetch-openwrt.sh      # 下载 ImmortalWrt armsr rootfs（校验 sha256）
│   ├── 40-assemble-rootfs.sh    # ★拼装：openwrt+A5E内核+全部定制 → rootfs.tar
│   ├── 50-build-image.sh        # guestfish 打包（有就地/无则借 rsdk 容器 direnv）→ owrt-a5e.img
│   └── 90-offline-edit-image.sh # 调试工具：离线 debugfs 改成品镜像（秒级）
├── custom/rootfs/               # 整文件定制（overlay 直接覆盖到 rootfs）
│   ├── boot/extlinux/extlinux.conf
│   ├── etc/kernel/cmdline
│   └── etc/init.d/bridge-modules
├── patches/                     # 局部修改（sed 补丁，按序应用，每个带 why）
│   ├── 10-inittab-ttyAS0.sh
│   ├── 20-firewall-wan-access.sh
│   ├── 30-dropbear-all-interfaces.sh
│   ├── 40-mount-root-skip.sh
│   └── 50-modules-ko-convert.sh
└── docs/OpenWrt-A5E-制作记录.md
```

## 改动总清单（定制点 → 实现位置 → 为什么）

| 改动 | 实现 | 对应坑 | 状态 |
|---|---|---|---|
| 内核改用自编译版(kernel-actions) | `25-fetch-kernel.sh` | 上游 linux-aw2607 + fragment，bridge/fw4/tproxy **已 builtin** → 免 .ko.xz 转换与 bridge 预加载 | ★ 推荐 |
| 引导加 `coherent_pool=2M` | `40` 的 APPEND_PARAMS | 坑1 sunxi_mmc DMA 挂死 | ✅ |
| `root=UUID=<真实fs UUID>` | `50` build-image 用 blkid 注入 | 坑2/3 引导链 | ✅ |
| 短路 `mount_root` | `patches/40-mount-root-skip.sh` | 坑2 fstools 只认短PARTUUID/尾02 | ✅ |
| 用 Debian initramfs 挂载 | `40` 放 initrd + extlinux `initrd` 行 | 坑4 noinitrd 之争 | ✅ |
| 模块 `.ko.xz → .ko` | `patches/50-modules-ko-convert.sh` | 坑7 kmodloader 不支持 xz | ✅ |
| 修 `modules.dep` 等路径 | `patches/50` | 坑7 modprobe 找不到 .ko | ✅ |
| 删 `modules.*.bin` 缓存 | `patches/50` | 坑7 强制读文本 | ✅ |
| bridge 预加载 init.d(START=15) | `custom/.../bridge-modules` + `40` ln S15 | 坑7 modprobe 依赖解析失灵→显式 insmod llc→stp→bridge | ✅待烧录验证 |
| firewall 放行 WAN 管理端口 | `patches/20-firewall-wan-access.sh` | LAN 修好前经 WAN 管理 SSH/LuCI | ✅ |
| dropbear 监听所有接口 | `patches/30-dropbear-all-interfaces.sh` | 同上（默认只 lan） | ✅ |
| inittab 加 `ttyAS0` login | `patches/10-inittab-ttyAS0.sh` | 坑8 串口进不了终端 | ✅ |
| **禁用 plymouth**（开机占 console→askfirst 失败） | 未做 | 坑8 根治 | ⚠ 待办 |
| **Ctrl+C(SIGINT) 不生效**（top 退不出） | 未查 | 坑8 遗留 | ⚠ 待办 |

> 引导参数里 **`root=` 绝不能硬编码**：每次跑 `50-build-image.sh` 都用 blkid 生成
> 新随机 UUID（坑3 血泪）。离线编辑 extlinux 前，务必 `blkid`/`debugfs` 读真实值。

## 复现步骤

```bash
# 日常全链路（下载现成 Debian + 提取 + 拼装 + 打包，零 rsdk 编译）：
#   • Debian 资产走 radxa-build release（DSRC=radxa-release，默认）
#   • 打包步(50)需 guestfish：本环境无则自动借 RSDK_CONTAINER(direnv/nix) 完成
cd openwrt-a5e-build
# 日常构建（不跑 rsdk，需 kernel-actions release 已产出）：
./build.sh                 # KSRC=kernel-actions：25→30→40→50
# 首次（取 u-boot/initrd/build-image 资产，需 rsdk devcontainer）：
./build.sh 10              # 全流程 10→20→25→30→40→50
# 或改完定制只重拼装+打包：
./build.sh 40

# 只改成品镜像里一个文件（调试用，秒级）：
./scripts/90-offline-edit-image.sh extract
debugfs -w -R 'cat /etc/inittab' /tmp/rp.img       # 看看
debugfs -w -R 'rm /etc/foo' /tmp/rp.img
debugfs -w -R 'write ./f /etc/foo' /tmp/rp.img
debugfs -w -R 'set_inode_field /etc/foo mode 0100755' /tmp/rp.img   # debugfs write 默认 0644，补可执行位
./scripts/90-offline-edit-image.sh commit

# 烧录（确认 ROOTFS_LBA 后）：
sudo dd if=../owrt-a5e.img of=/dev/sdX bs=4M conv=fsync status=progress && sync
```

## 端到端验证（实测通过）

`DSRC=radxa-release` + `KSRC=rsdk` 跑通 `15→20→40→50`，全程零 rsdk 编译：

1. **15** 下载 `rsdk-t10 (cli)` 的 `rootfs.tar.xz`(557M，**sha512 校验 OK**) + `build-512-image`（与本地 `out/build-image` 分区/setup.sh 逐行一致）
2. **20** 选择性提取 vmlinuz/initrd/dtb/u-boot + 892 模块（跳过 `/dev` mknod；兼容 usr-merge 的 `./usr/lib/modules`）
3. **40** 临时目录拼装 → `openwrt-a5e-rootfs.tar`(263M)，`patches/50` 将 `.ko.xz→.ko`
4. **50** 借 rsdk 容器 direnv 激活 guestfish，`build-image` 打包 23s → `owrt-a5e.img`

离线 `debugfs` 抽查成品 img 六项定制全部落地：inittab `ttyAS0`、`bridge.ko`(非 .ko.xz)、firewall WAN 规则、dropbear 注释 lan、`mount_root` 短路、extlinux 含 `coherent_pool=2M`+`ttyAS0`，且 `root=UUID` 被 build-image 注入为**新随机值**（实证坑3）。

## 关键事实备忘

- **SPL 写在 LBA 256**（`setup.sh`，非传统 LBA0/8）；引导 = extlinux（`/boot/extlinux/extlinux.conf`），不是 EFI/systemd-boot。
- **串口设备名 `ttyAS0`**（Allwinner BSP sunxi-uart；mainline 叫 ttyS0）。板子**无 `getty` 命令**，OpenWrt 用 procd `askfirst`+`/usr/libexec/login.sh`。
- **内核 CONFIG_MODULE_COMPRESS_XZ=y**，所有模块 `.ko.xz`，板子无 xz → 必须离线转 `.ko`。
- 首启 `config_generate` 生成网络：`br-lan`(桥 eth0)=192.168.1.1 / eth1=WAN。
- armsr rootfs 网络配置在镜像里是**空的**，首启才生成。
