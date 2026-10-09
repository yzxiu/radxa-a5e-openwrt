# A5E 双槽 OTA 升级 —— 设计方案（演进存档）

> 参照 `yzxiu-router` LubanCat-1（Rockchip）的双槽机制，移植到 Radxa Cubie A5E（Allwinner A527）。
> 分支：`feat/dual-slot-ota` ｜ **状态：已实施完成（2026-10-09）**

> ⚠️ **本文档是设计演进的历史存档，不是现状描述。** 写作时点为 2026-10-07，
> 其中 §2/§4/§5 的多项设计在随后两天的实机调试中被推翻或替换
> （GPT→MBR、kernel 留 rootfs→分离 p1、distro_bootpart env 切换→改 extlinux root=UUID、
> 5 分区→4 分区等）。过时章节均保留原文，并加注"【过时】"说明原因与最终方案。
> **最终实现（权威版本）见 `docs/dualslot-partition-and-firstboot.md`**，
> 踩坑全记录在 §5 K1–K13。

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

> 【时点快照】以下"A5E 现状"是 **2026-10-05**（双槽改造前、main 分支单槽镜像）的状态，
> 仅作改造前基线存档。该布局（p1 config/p2 efi/p3 rootfs，GPT）已被
> `3f88a50` 起的 MBR 双槽布局取代。

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

> 【过时】以上三条推论**最终都没采用**。2026-10-08 实机证据：① A5E U-Boot 期望
> env 在 `0:2` 的 FAT（日志 `Loading Environment from FAT... Unable to use mmc 0:2`），
> 而 env 工具链（fw_env.config 定位、fw_printenv 实测）在裁剪 rootfs 上不可靠；
> ② 转 MBR 后 layout 全变，p1 config 分区整个取消。最终切槽杠杆改为
> **改 p1 `extlinux.conf` 的 `root=UUID=`**（与 lubancat1 改 armbianEnv rootdev 同构，
> 文件操作零依赖），`distro_bootpart`/`${rootfs_uuid}`/fw_env 路线全部放弃。

---

## 4. 目标设计

> ⚠️⚠️ **【本节整体过时】** 这一版"定稿"写于 2026-10-07，当晚起的实机调试
> 连续推翻了其中三条支柱（见下逐条标注）。**最终方案：MBR 分区表 +
> 刷机包 2 分区（p1 boot FAT + p2 rootfs）→ 首启在线建 p3 槽B + p4 shared，
> kernel 分离 p1，切槽=改 p1 extlinux root=UUID。** 完整实现见
> `dualslot-partition-and-firstboot.md`。

> **2026-10-07 定稿修正**（参考 ophub `openwrt-tf`/`openwrt-install-allwinner` 后）：
> - 【过时】"不改造 build-image 出双槽镜像" → **当晚即改**：`d759339` 重写
>   custom/build-image（lubancat1 布局，kernel 分离 p2 FAT），原因是实机发现
>   U-Boot env 期望 0:2 为 FAT + ext4 上 extlinux 脏读风险。
> - 【过时】"kernel 不挪出 rootfs" → **同 commit 反转**：kernel/initrd/dtb
>   分离到独立 boot 分区（与 lubancat1/op4 实机一致）。
> - 【过时】"切换杠杆 = distro_bootpart env" → 改 extlinux root=UUID（见 §3 注）。
> - ~~不改造 build-image 出双槽镜像~~【见上方逐条标注】
> - ~~kernel 不挪出 rootfs~~【见上方逐条标注】
> - ~~切换杠杆 = `distro_bootpart` env~~【见上方逐条标注】
>
> 保留有效的部分：首启 uci-defaults 在线改造（成功自删/失败重跑的调度机制）、
> dd 副本做初始槽 B、"-U 指定 UUID"、配置迁移语义——这些在最终实现中全部保留。

### 4.1 分区布局（首启改造后）

> 【过时】这是 **GPT 5 分区**方案（p1 config/p2 efi/p3/p4/p5）。
> 被否原因：① 保留了 radxa 遗留 config/efi 分区，槽 B 排到 p4、shared p5，
> 与 lubancat1 编号错位（用户明确指出"参考 lubancat1 不要擅自设计"）；
> ② GPT 备份头机制对"dd 截断镜像刷大容量卡"是持续性坑（K1/K7）。
> **最终：MBR 4 分区** `p1 boot FAT 128M / p2 rootfs 960M 槽A / p3 rootfs-b 槽B / p4 shared`，
> 见 partition-and-firstboot.md §1。

```
p1   16M    FAT   config        ← U-Boot env (uboot.env)，不动
p2   300M   FAT   efi           ← 空置，不动
p3   ~670M  ext4  rootfs        ← 槽 A（当前运行系统）
p4   =p3    ext4  rootfs-b      ← 槽 B（dd 副本，extlinux 自指，立即可回滚）
p5   rest   ext4  shared-data   ← 共享数据（本期只建分区+挂载点，不做 docker 迁移）
```

### 4.2 首启初始化流程（uci-defaults 脚本）

> 【部分过时】流程骨架（幂等双判定 / -U UUID / dd 副本 / ready 标记）与最终实现一致，
> 但细节全变：`sgdisk`→`parted`（gptfdisk 在 feed 无二进制，K10）；
> 槽 B=p4→p3、shared=p5→p4；"sed p4 extlinux 自指"步骤取消（extlinux 集中到 p1 唯一一份）；
> `sgdisk -A bootable`→不需要（扫描命中 p1 的唯一 extlinux）。
> 最终十步流程见 partition-and-firstboot.md §3.2。

```
[0] 幂等: p4=rootfs-b 且内部有 .dualslot-ready 标记 → 退出
    (只查 label 不够: dd 中断会留半成品, 必须凭标记区分)
[1] 定位盘: /proc/cmdline root=UUID → blkid -U → /dev/mmcblk0p3 → DISK
[2] 空间检查: p4(=p3大) + 对齐余量, 不足则 die(uci-defaults 失败会下启重试)
[3] sgdisk 建 p4(与 p3 等大, 1MiB 对齐) / p5(剩余全部, -34 GPT 备份)
[4] mkfs.ext4 -U <指定UUID> -L rootfs-b / shared-data
    (-U 指定 UUID 而非随机, 便于写 extlinux; 仿 openwrt-tf)
[5] dd p3→p4 (在线; sync 先行, 复制后 e2fsck 重放 journal 修复一致性)
[6] sed p4 的 /boot/extlinux/extlinux.conf: root=UUID=<p4 uuid> (自指)
[7] sgdisk -A 4:set:2 bootable (与 build-image part-set-bootable 等效)
[8] 写 .dualslot-ready 标记 (幂等依据)
[9] fstab 加 /mnt/shared 挂载点 (只建入口)
```

### 4.3 启动与切换

> 【过时】fw_setenv/sgdisk 切换机制未采用（见 §3 注）。
> 最终：U-Boot 扫描 bootable 分区命中 p1（唯一 extlinux），切槽 =
> 改 p1 extlinux.conf 的 `root=UUID=`，见 partition-and-firstboot.md §3.4。

```
启动: U-Boot distro_boot → 枚举 bootable 分区(p2无extlinux→p3命中) → 槽 A
OTA 切槽(后续 upgrade-a5e.sh 实现):
  首选: fw_setenv distro_bootpart 4   (扫描固定到 p4 → p4 extlinux 自指 → 槽 B)
  兜底: sgdisk -A 3:clr:2 + -A 4:set:2 (bootable 列表只剩 p4)
回滚: 反向操作, 或删除 distro_bootpart env 恢复默认扫描(仍落 p3)
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

> 【过时】此表是"零改动 build-image"路线的配套，多数条目已不存在或被替换。
> 实际落地的改造（`d759339` 起，共 20+ commit）见 partition-and-firstboot.md §2/§4；
> 其中"fw_env 配置"一项**整体取消**（env 路线放弃，见 §3 注）。

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

> 【过时】第 1/2 步（fw_printenv 实测 / env 切换演练）随 env 路线取消而**不再需要做**；
> 第 3/4 步的思路保留，实际执行的验证清单见 partition-and-firstboot.md §6
> （以及 OTA 端到端演练：板上 `upgrade-a5e.sh --dry` → 全量升级 → 回滚）。

1. `fw_printenv` 确认 env 位置与可写性（板上）
2. 手工演练：p4 手动 mkfs + 复制当前 rootfs → `fw_setenv rootfs_uuid <p4 UUID>` → reboot，验证能从 p4 启动
3. build-image 双槽化后本地出 img，dd 到卡实机验证
4. 全链路 OTA 演练（debug 分支出 img.gz → 板上下载 → 升级 → 验证 → 回滚）

---

## 5. 风险与待实测项

> 【已消解】下表风险几乎全部通过**方案变更**（而非缓解措施）消除，最终状态逐条标注：

| 风险 | 缓解 |
|---|---|
| ~~`uboot.env` 实际所在 FAT 分区不明（0:1? 0:2?）~~ | **消除**：不用 env 切换（改 extlinux 文件），该风险无意义了 |
| ~~U-Boot sysboot 对 append 里 `${rootfs_uuid}` 的展开时机~~ | **消除**：不用变量展开，root= 写死具体 UUID |
| initrd 是否必须（现状 initrd 存在） | 保留现状 initrd 进 p2，不节外生枝 |
| OpenWrt 首启 resize/fstab 逻辑与双槽冲突 | **实锤为 growroot**（initramfs local-bottom，K2），用 `/etc/growroot-disabled` 空文件禁用；比原想的 resize 更隐蔽 |
| ~~新镜像仍是单槽布局~~ | **消除**：新流水线本身产出双槽首启布局（2 分区刷机包），OTA 输入固定该格式 |
| 升级中断电 | 双槽本质保护：写对侧槽期间当前槽不动；最坏情况对侧槽损坏，重跑 OTA 或切回 |

## 6. 与 yzxiu-router 的关系

- 本项目后续并入 `yzxiu-router` 作为**allwinner/a527 平台**（与 rockchip/lubancat-1 平行）
- 本期先在 `radxa-a5e-openwrt` 本仓库 `feat/dual-slot-ota` 分支调试跑通；验证稳定后再抽象平台化
- `upgrade-a5e.sh` 与 `upgrade-lubancat.sh` 保持同构（查 release→下载→双槽写入→配置迁移→切槽→reboot），便于将来在 router 仓库统一
  【2026-10-09 已实现】`upgrade-a5e.sh` + `openwrt-update-a5e` 双层脚本已落地
  （`9f18bf4`），OTA 端到端待真机演练。另注：`yzxiu-router/config/platform/radxa-a5e.conf`
  已存在（定位：纯 rootfs 产物给 docker 用，不做 ophub remake），与本仓库的
  "可刷双槽 img"是两种产物，平台化时需对齐定位
