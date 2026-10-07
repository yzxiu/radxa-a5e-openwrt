# A5E 双槽 OTA 升级 —— 设计方案

> 参照 `yzxiu-router` LubanCat-1（Rockchip）的双槽机制，移植到 Radxa Cubie A5E（Allwinner A527）。
> 分支：`feat/dual-slot-ota` ｜ 状态：方案待确认，未实施

---

## 1. 参照系：LubanCat-1 双槽是怎么工作的

| 件 | 来源 | 作用 |
|---|---|---|
| `upgrade-lubancat.sh` | `yzxiu-router/files/lubancat1/usr/sbin/` | 查 GitHub 最新 release → 下载 `.img.gz` → 调 `openwrt-update-rockchip` |
| `openwrt-update-rockchip` | luci-app-amlogic 包（设备上，924 行） | OTA 主逻辑 |
| `openwrt-backup` | 同上（598 行） | 配置备份清单（60+ 项，可 `/etc/amlogic_backup_list.conf` 自定义） |

**数据流**：losetup 挂新镜像（P1=boot / P2=rootfs 只读）→ 判当前槽 → 对侧槽 `mkfs` 清空 → 从 **新镜像 P2 整树复制** 系统 → 从旧系统按 BACKUP_LIST 打包配置还原到新槽 → 改引导指向新槽 → reboot。

**语义**（与预期一致）：
- 新槽 = 新固件自带系统（软件随固件走）
- 配置（UCI/shadow/SSH key/docker.json…）随 BACKUP_LIST 保留
- 旧系统额外装的软件包**不迁移**（需新槽重装，配置已还原）
- docker 数据在 p4 SHARED 分区，跨升级天然存活

---

## 2. A5E 现状 vs LubanCat-1 差异

| | LubanCat-1 (Rockchip) | A5E (Allwinner) 现状 |
|---|---|---|
| kernel/dtb 位置 | p1 FAT boot 分区（独立于 rootfs） | **rootfs 内部**（`/boot/vmlinuz` + `/usr/lib/linux-image/*/dtb`） |
| extlinux.conf | p1 | **p3 rootfs 内部** `/boot/extlinux/` |
| rootfs 槽 | p2/p3 btrfs 双槽 | **单槽** p3 ext4 |
| shared 分区 | p4（docker 数据） | 无 |
| 分区表 | p1 boot / p2·p3 槽 / p4 shared | p1 config 16M FAT / p2 efi 300M FAT / p3 rootfs |
| 切换杠杆 | p1 里 `armbianEnv.txt` 的 `rootdev=` | 见 §3 |

**当前分区（build-image 产出）**：
```
p1  32768..65535    16M  FAT   label=config   ← 基本空置
p2  65536..679935  300M  FAT   label=efi      ← 空置（GPT 类型 EFI）
p3  679936..end    ~670M ext4  label=rootfs   ← 完整系统（含 kernel）
SPL@LBA256 → U-Boot → distro_boot 扫描 bootable 分区(p2→p3) → p3 内 extlinux.conf
```

---

## 3. A5E U-Boot 能力（从镜像 u-boot 二进制 strings 实测）

| 能力 | 结论 | 证据 |
|---|---|---|
| 引导模式 | 标准 **distro_boot** | `bootcmd=run distro_bootcmd` |
| 启动顺序 | fel → **mmc_auto** → usb0 → pxe → dhcp | `boot_targets=fel mmc_auto usb0 pxe dhcp` |
| **分区选择杠杆** | **`distro_bootpart` 环境变量优先**，否则枚举 `-bootable` 分区，fallback 分区 1 | `scan_dev_for_boot_part=if env exists distro_bootpart; then setenv devplist ${distro_bootpart}; else part list ... -bootable devplist; ...` |
| env 存储 | **FAT 文件 `uboot.env`**（ENV_IS_IN_FAT） | strings 命中 `uboot.env` |
| extlinux append 变量展开 | **支持 `${var}`** | 现行 `mac_addr=${mac}` 即 env 展开 |
| extlinux 位置 | 从 `distro_bootpart` 分区按 `/` 和 `/boot/` 前缀找 `extlinux/extlinux.conf` | `boot_prefixes=/ /boot/` |

**推论**：
- 切换启动槽**不需要改分区表属性**，`fw_setenv` 改 env 即可 → 系统内 OTA 完全可行
- `uboot.env` 大概率在 p1（label=config，16M FAT 一直空置）——**待板上 `fw_printenv` 实测确认**（env 的 FAT 分区号要看 u-boot 配置，可能是 0:1）
- extlinux.conf 用 `root=UUID=${rootfs_uuid}`，env 里存 `rootfs_uuid` + `slot=a|b`

---

## 4. 目标设计

### 4.1 分区布局（双槽）

```
p1   16M    FAT   label=config   ← U-Boot env (uboot.env)，不动
p2   128M   FAT   label=boot     ← extlinux.conf + vmlinuz + initrd + dtb（两槽共享 kernel）
p3   ~1.2G  ext4  label=rootfs-a ← 纯 rootfs（槽 A）
p4   ~1.2G  ext4  label=rootfs-b ← 纯 rootfs（槽 B，首刷空槽由首次 OTA 写入）
```

要点：
- **kernel/dtb/initrd 移出 rootfs 进 p2**（这是与现状最大的结构差异）。共享 kernel 是自洽选择：extlinux 只能从 p2 读一份 kernel，两槽必须用同一份。
- 两槽 rootfs 不再含 kernel，体积更小；16G eMMC 下两槽共 ~2.4G 无压力。
- p2 容量 128M：kernel(27M)+initrd(~50M)+dtb 足够，且 initrd 可精简。

### 4.2 启动链

```
SPL@LBA256 → U-Boot → distro_boot
  → scan_dev_for_boot_part: 无 distro_bootpart env → 枚举 bootable
  → p2 (bootable) 命中 extlinux/extlinux.conf
  → 展开 append root=UUID=${rootfs_uuid} console=ttyAS0,... mac_addr=${mac} ...
  → 从 p2 读 /vmlinuz + /initrd.img + /dtb/  → 挂载 root=UUID=${rootfs_uuid}（p3 或 p4）
```

env 默认（首次启动由 uci-defaults 或升级脚本初始化）：
```
rootfs_uuid=<槽A UUID>     ← 活动槽 rootfs 的 UUID
slot=a
```

### 4.3 OTA 流程（`upgrade-a5e.sh`，仿 upgrade-lubancat.sh）

```
[1] 查 release（GitHub API，直连优先→sing-box mixed 127.0.0.1:1087 回退）
    定位资产 owrt-a5e.img.tar.gz
[2] 下载 → /tmp/upload/
[3] 判当前槽：fw_printenv slot / 或解析 /proc/cmdline 的 root UUID
[4] 准备对侧槽：mkfs.ext4 -L rootfs-<对侧>
    （镜像布局可能是单槽 p3：losetup -f -P 挂 img → mount 其 rootfs 分区只读）
[5] 复制系统树：新镜像 rootfs → 对侧槽（tar 管道，排除 p2 已有的 boot 内核件）
[6] 配置迁移：旧系统按 BACKUP_LIST 打包 → 解到对侧槽
    （默认清单照抄 openwrt-backup 的 60+ 项，A5E 场景裁剪：
     /etc/config/ /etc/shadow /etc/ssh/ /etc/docker/daemon.json /etc/rc.local
     /etc/sysctl.d/ /etc/modprobe.d/ 等；支持 /etc/a5e_backup_list.conf 自定义）
[7] fw_setenv rootfs_uuid <对侧槽 UUID> ; fw_setenv slot <对侧>
[8] reboot → 新槽启动
[9] 验证点：新系统首启后 health check（网络/fw4），失败则手动 fw_setenv 切回（回滚）
```

### 4.4 配置迁移清单（BACKUP_LIST，初版）

```
./etc/config/                 # 整个 UCI（网络/无线/防火墙/luci/dockerd...）
./etc/shadow ./etc/passwd     # 口令
./etc/ssh/                    # host key + authorized_keys
./etc/docker/daemon.json
./etc/sysctl.d/ ./etc/modprobe.d/
./etc/rc.local ./etc/hosts ./etc/crontabs/
./root/.ssh/
```

### 4.5 build 侧改造（radxa-a5e-openwrt 仓库）

| 改动点 | 文件 | 内容 |
|---|---|---|
| 双槽 build-image | 新 `custom/build-image-dualslot` 或补丁 | 4 分区 GPT；p2 FAT 放 extlinux+vmlinuz+initrd+dtb；p3 解 rootfs；p4 mkfs 空槽 |
| 40 步分离 boot 件 | `scripts/40-assemble-rootfs.sh` | rootfs 里 /boot/vmlinuz、/boot/initrd.img、/usr/lib/linux-image 单独输出到 `$OWRT/boot-files/`，rootfs.tar 不再含 kernel |
| extlinux.conf 模板 | `custom/rootfs/boot/extlinux/extlinux.conf` 或 40 步生成 | `root=UUID=${rootfs_uuid}` 变量化 |
| fstab | rootfs 模板 | 加 `/boot → /dev/mmcblk0p2 (vfat)` 挂载（用户态工具升级 kernel 用） |
| fw_env 配置 | `custom/rootfs/etc/fw_env.config` | 指向 p1 uboot.env（**偏移/分区待板上实测后填**） |
| 升级脚本 | `custom/rootfs/usr/sbin/upgrade-a5e.sh` | §4.3 流程 |
| 备份清单 | `custom/rootfs/usr/sbin/openwrt-backup-a5e`（或内嵌 upgrade 脚本） | §4.4 |

### 4.6 调试期的验证步骤（本仓库先行，板子配合）

1. `fw_printenv` 确认 env 位置与可写性（板上）
2. 手工演练：p4 手动 mkfs + 复制当前 rootfs → `fw_setenv rootfs_uuid <p4 UUID>` → reboot，验证能从 p4 启动
3. build-image 双槽化后本地出 img，dd 到卡实机验证
4. 全链路 OTA 演练（debug 分支出 img.gz → 板上下载 → 升级 → 验证 → 回滚）

---

## 5. 风险与待实测项

| 风险 | 缓解 |
|---|---|
| `uboot.env` 实际所在 FAT 分区不明（0:1? 0:2?） | 板上 `fw_printenv` 实测；必要时 dd dump p1 头部确认；fw_env.config 按实测填 |
| U-Boot sysboot 对 append 里 `${rootfs_uuid}` 的展开时机 | `mac_addr=${mac}` 已证展开机制存在；实测确认自定义变量同样展开 |
| initrd 是否必须（现状 initrd 存在） | 保留现状 initrd 进 p2，不节外生枝 |
| OpenWrt 首启 resize/fstab 逻辑与双槽冲突 | rootfs 模板里 /etc/config/fstab 固定两个槽 UUID；resize 改为对活动槽在线 resize |
| 新镜像仍是单槽布局（本仓库旧流水线产物） | OTA 脚本兼容两种输入：losetup 后自动找 rootfs 分区（按 GPT label/type） |
| 升级中断电 | 双槽本质保护：写对侧槽期间当前槽不动；最坏情况对侧槽损坏，重跑 OTA 或切回 |

## 6. 与 yzxiu-router 的关系

- 本项目后续并入 `yzxiu-router` 作为**allwinner/a527 平台**（与 rockchip/lubancat-1 平行）
- 本期先在 `radxa-a5e-openwrt` 本仓库 `feat/dual-slot-ota` 分支调试跑通；验证稳定后再抽象平台化
- `upgrade-a5e.sh` 与 `upgrade-lubancat.sh` 保持同构（查 release→下载→双槽写入→配置迁移→切槽→reboot），便于将来在 router 仓库统一
