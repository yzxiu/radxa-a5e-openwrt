# A5E 双槽：刷机包分区配置 + 首启分区脚本 详解

> 本文档记录 **最终实现**（feat/dual-slot-ota 分支）。演进过程见
> `docs/dual-slot-ota-design.md`（含已作废方案的历史记录）。
>
> 参照系：`yzxiu-router` 的 LubanCat-1（ophub 生态，op4 = 192.168.4.1 实机）。
> 布局与编号与 lubancat1 对齐；分区表用 MBR（lubancat1 同为 MBR）。

---

## 1. 最终分区布局

### 刷机包（2 分区，`custom/build-image` 产出）

```
MBR (msdos) 分区表，img truncate 到 p2 末尾（~1.2G raw）

NR  START     END SECTORS  SIZE  FS    LABEL   内容
 1  32768  294911  262144  128M  FAT   boot    extlinux.conf + vmlinuz + initrd.img + dtb/
 2 294912 2260991 1966080  960M  ext4  rootfs  槽 A 纯系统（无 kernel）
```

### 首启后（4 分区，`99-a5e-init-dualslot` 在线建立）

```
NR   START      END  SECTORS  SIZE  FS    LABEL       内容
 1   32768   294911   262144  128M  FAT   boot        同刷机包（唯一一份 boot 件）
 2  294912  2260991  1966080  960M  ext4  rootfs      槽 A（当前运行）
 3 2260992  4227071  1966080  960M  ext4  rootfs-b    槽 B（dd 副本，立即可回滚）
 4 4227072 62333918 58106847  ~剩余 ext4  shared-data 共享数据（/mnt/shared，本期不做 docker 迁移）
```

### 与 lubancat1（op4 实机）对照

| | LubanCat-1 (rockchip) | A5E (allwinner) |
|---|---|---|
| p1 | BOOT **ext4** 383M（vmlinuz+dtb+initrd+引导配置） | boot **FAT** 128M（同内容） |
| p2 | ROOTFS1 btrfs 1.28G | rootfs ext4 960M（槽A） |
| p3 | ROOTFS2 btrfs 1G（当前运行） | rootfs-b ext4 960M（槽B） |
| p4 | SHARED btrfs 55.6G（docker） | shared-data ext4 剩余全部 |
| 分区表 | MBR（ophub 全系列） | **MBR**（`part-init /dev/sda msdos`） |
| 切槽杠杆 | 改 p1 `armbianEnv.txt` 的 `rootdev=UUID=` | 改 p1 `extlinux.conf` 的 `root=UUID=` |
| boot 文件 | 随固件在 p1（rockchip U-Boot 走 boot.scr） | 随固件在 p1（Allwinner U-Boot 走 extlinux） |

差异说明：
- **boot 分区文件系统**：op4 用 ext4，A5E 用 FAT。保留 FAT 是用户拍板（"分区类型保留现状"）。
  历史原因：A5E U-Boot 的 env 期望 `0:2` 为 FAT（`Loading Environment from FAT...
  Unable to use mmc 0:2` 警告的由来）；且早期排查过 ext4 上 extlinux 读取乱码
  （后查明是 growroot 扩容期间的瞬态，非 ext4 固有问题，见 §5-K2）。
- **kernel 在独立 boot 分区**：与 lubancat1 一致（rootfs 槽里不含 kernel），
  两槽共享 p1 的 kernel——OTA 升固件时 p1 一并更新；KVER 变化时回滚槽的
  `/lib/modules` 与新 kernel 不匹配（本期 KVER 固定 `6.6.98-1-aw2607` 无影响）。

---

## 2. 打包分区配置（`custom/build-image`）

guestfish 命令脚本（50 步执行）。逐段说明：

### 2.1 分区表：MBR 而非 GPT

```
part-init /dev/sda msdos
```

**决策链**（实机教训，§5-K1/K7）：GPT 有主/备份双头机制，img 为省空间
truncate 到 p2 末尾后，备份头位于 img 尾；`dd` 到更大容量的卡，备份头
不在真实盘尾 → `parted` 非交互模式拒绝一切写操作
（`Unable to satisfy all constraints`）。MBR 没有备份头概念，
dd 到任意容量卡都天然一致。lubancat1（ophub）本来就用 MBR。

### 2.2 几何参数（扇区）

| 参数 | 值 | 计算 |
|---|---|---|
| p1 start | 32768 | 16MiB（SPL@LBA256 + 分区表保留区，沿用 radxa 原厂值） |
| p1 end | 294911 | 32768 + 262144 - 1（128MiB = 262144 sectors） |
| p2 start | 294912 | p1 end + 1（恰好 1MiB 对齐 ✓） |
| p2 end | 2260991 | 294912 + 1966080 - 1（960MiB，参考 lubancat ROOT1=960M） |

960MiB 参考 lubancat1 的 ROOT1；A5E rootfs 实际 ~600M，960M 有余量。
**两处必须一致**：build-image 的 p2 与首启脚本 `SLOT_B` 与槽 A 等大逻辑
（槽 B 取槽 A 实际分区大小，几何漂移时自动跟随）。

### 2.3 p1 boot（FAT 128M）内容

```
mkfs vfat /dev/sda1 label:boot
copy-in ./boot-files/vmlinuz   /boot/     ← 实际落 p1 根（/boot 是 guestfish 挂载点）
copy-in ./boot-files/initrd.img /boot/
copy-in ./boot-files/dtb        /boot/
```

- `boot-files/` 由 40 步产出（vmlinuz/initrd.img/dtb/ 从 rootfs 分离出来）。
- **挂载点视角坑**（§5-K6）：guestfish 把 p1 挂到 `/boot` 后，`copy-in /boot/x`
  落在 **p1 根 `/x`**。mtools 校验时路径是 `::/dtb/`、`::/extlinux/`，不是 `::/boot/...`。
- 128M ≥ kernel(27M) + initrd(46M) + dtb(0.2M) ≈ 73M，余量充足。
- `part-set-bootable /dev/sda 1 true`：MBR boot flag，**U-Boot distro_boot 扫描依据**。

### 2.4 p2 rootfs（ext4 960M 固定，不收缩）

```
mkfs ext4 /dev/sda2 label:rootfs
mount /dev/sda2 /
tar-in rootfs.tar / xattrs:true
```

- 原版 radxa build-image 有 `resize2fs -M` 收缩段（img 缩到 fs 实际大小）；
  双槽版**去掉**——p2 分区/文件系统固定 960M，槽 B 按分区大小复制要求源分区
  不大于目标，等大最稳。img 体积由 truncate 控制（见 2.5），不受 fs 内空闲影响。

### 2.5 truncate 与 MBR 无关项清理

```
unmount-all; sync; shutdown
truncate --size=$(( ( $(parted -m -s output_512.img unit s print | awk -F: '$1==2{...}') + 1 ) * 512 )) output_512.img
```

- 尺寸 = p2 end + 1（MBR 无 GPT 备份头，不需要 +34/sgdisk -ge——原版 GPT 的
  `sgdisk -ge` 修复段整体删除）。
- 取 end 用 `parted -m`（`sgdisk` 只认 GPT）。
- dd 刷卡后 p1/p2 数据完整，MBR 在 LBA0 不受影响；卡剩余空间全部空闲，
  留给首启脚本建槽 B/shared。

### 2.6 磁盘信息注入

```
fstab:    UUID=<p1> /boot vfat ... 0 2 ； UUID=<p2> / ext4 defaults 0 1
extlinux.conf: append root=UUID=<p2> ...（用 blkid 真值替换 PLACEHOLDER）
/etc/kernel/cmdline: 同上
```

- 种子文件的 `root=UUID=PLACEHOLDER` 由 sed 剔除重注（正则 `s/\s*root=\S*\s*/ /g`
  先清后注，两个文件同一来源 `APPEND_PARAMS`）。
- CI 校验断言 extlinux 的 root=UUID 与 p2 fstab UUID 一致（防注入错位）。

### 2.7 bootloader

```
./temp_dir/u-boot/radxa-cubie-a5e/setup.sh update_bootloader output_512.img 512
```

从 rootfs `/usr/lib/u-boot/` copy-out 的 radxa 官方写盘工具，SPL@LBA256 +
U-Boot 主程序。**与分区表类型无关**（裸扇区写）。

---

## 3. 首次启动分区脚本（`99-a5e-init-dualslot`）

路径：`custom/rootfs/etc/uci-defaults/99-a5e-init-dualslot`（40 步 overlay 进 rootfs）。

### 3.1 触发与调度：uci-defaults

- OpenWrt 首启自动执行 `/etc/uci-defaults/*`，**成功自删**；失败/中途断电
  文件保留，**下次启动重跑**——天然的两段式调度（不需要 flag 文件安排重试）。
- 序号 99：排在 `10-fstab`（生成 /etc/config/fstab）之后，脚本可安全 uci 操作 fstab。
- **首启耗时**：分区秒级 + mkfs 数秒 + dd 960M（约 40 秒，分块打百分比进度）+ e2fsck 数秒。
  期间控制台停在 `root@(none)`、网卡全 DOWN——**这是正常中间态**（uci-defaults
  跑在网络服务启动之前），不是故障。完成后继续启动 → `root@ImmortalWrt`。
- **首启日志（带 `>>>` 前缀直接上串口，混在 dmesg 里一眼可辨）**：
  系统起来后查看：`logread -e dualslot`（busybox logread 按标签过滤用 `-e`，
  `-t` 只是显示时间戳）。串口实时窗口期约 1 分钟，错过可在系统内用该命令回看
  （重启后内存日志清空，需留存的话 `logread -e dualslot > /root/firstboot.log`）。

### 3.2 执行流程（10 步）

```
[1] 定位引导盘   cmdline root=UUID=<x> → blkid -U <x> → /dev/mmcblkXpY → DISK/PT_PRE
                  布局自检：根应在 p2（非 p2 只警告不拦，兼容旧布局）
[2] 幂等检查     p3 的 LABEL=rootfs-b 且内部 .dualslot-ready → 退出
                  （只查 label 不够：dd 中断的半成品 label 也是 rootfs-b）
[3] 几何解析     parted -m -s unit s print：
                  DISK_SECTORS(第2行第2列) / p2 start,end($1==2) / DISK_LAST=盘总-34
[3b] 占满检测    p2 end >= DISK_LAST → die 明确指引（rootfs 被扩到盘尾无法在线收缩）
[4] 建 p3/p4     已存在则跳过（半成品恢复）；parted -s mkpart primary ext4 <start>s <end>s
                  （end=最后一个扇区，含；msdos 无分区名，槽位识别靠 fs LABEL）
                  → partprobe（parted 包自带）重读分区表（BLKPG 增量，不动在用的 p2）
[5] mkfs         -U 指定 UUID（tune2fs 依赖）-L rootfs-b/shared-data
                  -E lazy_journal_init=0,lazy_itable_init=0（前台初始化，防后台 IO 抖动；
                  注意正确拼写是 itable 不是 table，§5-K5）
[6] dd 副本      sync 后 dd p2→p3 bs=4M conv=fsync；e2fsck -f -y 重放 journal 修一致性
[7] UUID/LABEL   tune2fs -U <UUID_B> -L rootfs-b p3
   去重            ★ dd 位级复制会把槽 A 的 fs UUID 和 LABEL 一并带走——
                  两槽 UUID 相同则 OTA 按 root=UUID 切槽失效；不改 label 人看
                  blkid 分不清槽位。mkfs 时指定的 UUID/LABEL 已被 dd 覆盖，必须重设。
[8] /boot 挂载   uci fstab 加 /boot 段（enabled 1，uuid=p1 FAT UUID）+ 立即 mount
                  （vfat 已 kernel builtin，挂载零依赖）
[8b] shared      uci fstab 加 /mnt/shared 段（enabled 1）
[9] 完成         touch /etc/.dualslot-initialized（记录用，调度不依赖它）
```

### 3.3 幂等设计

| 场景 | 判定 | 行为 |
|---|---|---|
| 全新首启 | 无 p3 | 全流程 |
| 完成后再启动 | uci-defaults 已自删 | 不执行（文件没了） |
| dd 中断（半成品 p3） | 有 p3 无 ready | [4] 跳过建分区，[5] mkfs 重做，[6] 重 dd |
| 断电于 mkfs 后 dd 前 | 有 p3 有 label 无 ready | 同上 |
| 空间不足 | 几何检查 | die + 明确指引，uci-defaults 保留下启重试 |

### 3.4 切槽机制（本脚本不做，OTA 用）

extlinux.conf 唯一一份在 p1（FAT）。切槽 = 改它的 `root=UUID=` 指向
槽 A 或槽 B（等价 lubancat1 改 armbianEnv.txt 的 rootdev）。
系统内随时可操作：`/boot` 由 [8] 保证自动挂载。

---

## 4. 依赖链（保障方式与最终归属）

> **归属原则（2026-10-09 定）**：运行时用到的工具/内核能力，**最终归属**在
> 上游而非本仓库的构建期兜底——rootfs 包 → `yzxiu-router/config/platform/radxa-a5e.conf`
> （该 rootfs 是本流水线 30 步的输入）；内核能力 → `radxa-a5e-openwrt-kernel/configs/a5e-openwrt.config`。
> 本仓库 40 步的 `apk add` 兜底**保留**（防御 rootfs 来源未更新的过渡期），
> 等上游 release 验证后可评估去留。

| 依赖 | 最终归属 | 本仓库过渡保障 | 原因 |
|---|---|---|---|
| parted/fdisk/lsblk/losetup 等 | router radxa-a5e.conf A 组（`5044c0d`） | 40 步 `apk add` | 首启分区/OTA 的磁盘工具链 |
| **tune2fs** | router radxa-a5e.conf D 组（`41e1d5d`） | 40 步 `apk add`+`apk fix` | e2fsprogs 拆分子包独立包名；apk db 记录与文件脱节时 add 不装文件需 fix 补 |
| **mtools** | router radxa-a5e.conf D 组（`41e1d5d`） | OTA 脚本运行提示 | OTA 无 loop 方案从 img FAT p1 提取文件（@@偏移 mcopy） |
| **kmod**（完整 depmod/modprobe） | router radxa-a5e.conf D 组（`41e1d5d`） | 40 步 `depmod -b` | 裁剪系统缺 modules.dep.bin 时 kmodloader 全灭（modprobe exit 255） |
| modules.dep.bin | kernel-actions 打包改进 或 板上 kmod | 40 步 `depmod -b $ROOTFS_DIR`（workflow host 装 kmod） | kernel-actions 只打包文本 .dep；kmodloader 只认 .bin |
| vfat builtin | kernel configs（`1d16dac`） | — | 挂载 /boot 不依赖模块加载链 |
| **BLK_DEV_LOOP builtin** | kernel configs（`ccce8d6`） | OTA 无 loop 方案（偏移 dd+mtools） | 板上实机无 loop 节点；补齐后 losetup 可用 |
| WiFi 驱动打印 | kernel vendor/aic8800（`488d88d`） | — | 裸 printk 降 pr_debug |
| growroot 禁用 | overlay `custom/rootfs/etc/growroot-disabled` | — | radxa initrd 自带 growroot，检测到此文件即跳过 |

**rootfs 定位**（router radxa-a5e.conf 注释，2026-10-09）：
主用途 = 直接系统的 rootfs（被本流水线 30 步消费）；备用 = docker import 基础层。

---

## 5. 实机踩坑记录（时间线，全部已修）

### K1. GPT 备份头 vs dd 大容量卡（→ 转 MBR 的决定性证据）
- **现象**：刷机首启后跑首启脚本，`parted -s mkpart` 报
  `Unable to satisfy all constraints on the partition`。
- **根因**：img truncate 到 1.1G → dd 到 58G 卡 → GPT 主头声称备份头在 LBA 2261024，
  实际盘尾在 122138623 → parted 非交互模式拒绝。
- **修复过程**：先加 `printf 'fix' | parted ---pretend-input-tty`（修得对，但
  判断条件 `parted -s print` 只读不失败 → fix 永不触发）；**最终转 MBR 根除**
  （lubancat1 本来 MBR，用户拍板）。
- commit：`625a562`（MBR 化）、`d29e990`（fix 逻辑，后随 MBR 删除）

### K2. "extlinux 乱码"实为 growroot 扩容瞬态
- **现象**：首启 U-Boot 读 extlinux.conf 乱码（`Ignoring unknown command: ���`），
   later 又正常。
- **根因**：initramfs `local-bottom/growroot`（cloud-initramfs-tools，radxa Debian
  initrd 自带）首启把 rootfs 分区扩到盘尾 + resize2fs，期间 ext4 不一致；
  U-Boot 无 fsck 能力读到脏状态。系统首启 fsck 修复后恢复。
- **次生**：扩容占满盘 → 首启脚本空间不足退出（连续两次刷机都中招）。
- **修复**：rootfs overlay `etc/growroot-disabled`（growroot 检测此文件即跳过）。
- commit：`05d0ede`；根因定位：dmesg `EXT4-fs mounted ff6879c9` + initrd 解包发现 growroot

### K3. kernel 放 rootfs 内 vs 独立 boot 分区
- 初版布局 kernel 在 rootfs 里（extlinux 也在 rootfs）——被三个实机问题否定：
  ① U-Boot env 期望 0:2 为 FAT；② ext4 上 extlinux 的脏读风险（K2）；
  ③ 与 lubancat1 结构不同构。参考 op4 实机后改为独立 p1 boot 分区。
- commit：`d759339`

### K4. parted name 编号残留 + msdos 不支持分区名
- 4 分区对齐改造时 `parted name 4 rootfs-b` 应为 p3；且 msdos 无分区名字段。
  槽位识别改用 fs LABEL（mkfs -L）。
- commit：`d29e990`、`625a562`

### K5. `lazy_itable_init` 笔误
- 写成 `lazy_table_init`（正解 itable）→ 板上老 e2fsprogs 打印帮助退出。
- commit：`d29e990`

### K6. mtools/guestfish 挂载点视角差
- guestfish 挂 p1 到 `/boot` 后 `copy-in /boot/x` 落 **p1 根 /x**；CI 校验用
  mtools 按 `::/boot/dtb/` 找 → not found（文件其实在）。改 `::/dtb/`。
  同类坑：mtools 镜像偏移语法是 `@@`（双@）。
- commit：`2b88849`、`0c2d405`

### K7. modprobe 全灭（modules.dep.bin 缺失）
- kernel-actions 打包只有文本 modules.dep；OpenWrt kmodloader 只认 .bin →
  `modprobe vfat` exit 255 → FAT 挂不上。
- 修复：40 步 `depmod -b`（workflow host 装 kmod）。**后随 kernel vfat builtin
  变为次要**（其他 =m 模块仍需要）。
- commit：`94d9164`

### K8. vfat =m → builtin（用户要求）
- "不满意模块加载链，要在 kernel 中 buildin"。kernel 仓加
  `FAT_FS/VFAT_FS/NLS/NLS_CODEPAGE_437/NLS_ISO8859_1 = y`（NLS 必须同步 builtin，
  vfat 默认 cp437/iso8859-1）。image 侧删 modules.d/75-vfat。
- commit：kernel `1d16dac`、image `7a9207f`

### K9. /etc/fstab 的行不会被自动挂载
- OpenWrt 自动挂载走 uci `/etc/config/fstab` + block-mount；busybox mount 不解析
  `UUID=`。且 `/etc/config/fstab` 是首启 `10-fstab` 才生成的 conffile——build-image
  里 copy-out 它报 not a file。
- 修复：首启脚本运行时（10-fstab 之后）uci add /boot 段 + 立即挂载。
- commit：`8dcae58`

### K10. apk "已满足"陷阱（db 与文件脱节）
- `apk add tune2fs` 无 Installing 行（db 有记录、二进制被 remake 裁剪）→ 仍缺。
  `apk fix` 补装缺失文件。e2fsprogs 是拆分子包，tune2fs 独立包名。
- commit：`ad08148`、`96ad716`

### K11. CI 匿名 GitHub API rate limit
- runner 共享出口 IP 匿名配额 60/h 易耗尽 → 30 步拿不到 release。
  workflow 25/30 步注入 GITHUB_TOKEN（5000/h，读公共仓合法）。
- commit：`56c1d43`；插曲：重复 GITHUB_TOKEN key 致 workflow 启动即失败（0 job），
  `bebcc56` 修复。注意：本地 yaml.safe_load 对重复 key 静默覆盖，**查不出**。

### K13. 首启日志"看不见"三连（输出通道被层层吞掉）
- **现象**：首启分区过程串口无任何输出，像卡死。
- **根因链**：uci-defaults 由 procd boot 服务执行，其 **stdout 被吞**
  （裸 echo 不可见）→ 加 `logger -s`（写 stderr）**也被吞** → 最终
  `echo "<5>>> dualslot: ..." > /dev/kmsg` 走 kernel console 通道必达。
  另一教训：`logread -t dualslot` 的 `-t` 是"显示时间戳"不是按标签过滤，
  过滤要用 `-e`（busybox logread）。
- **顺带**：kmsg 消息默认格式与内核日志雷同易淹没在 dmesg 洪流里，故加
  `>>>` 醒目前缀 + notice 级别；dd 进度改分块复制（busybox dd 无
  status=progress），每 10 块打百分比。
- commit：`62d5d5e`（logger -s 版）、`8f0636c`（kmsg 版）、`d03103b`（>>> 醒目版）

### K12. 其他小坑
- `etc/kernel` 目录忘建（重写 40 步 ③ 段时丢了 mkdir）→ `e413c00`
- `/boot/extlinux` mkdir 在 mount p1 之前（建在 p2 上）→ `ad3c01b`
- p2 几何算错差 1MiB（959M vs 960M）→ CI 分区表断言抓住 → `52f97fe`
- dd 复制带走 LABEL（p3 显示 rootfs）→ tune2fs 合并 `-L rootfs-b` → `4e5d28f`
- push 空提交不触发 CI（paths 过滤）→ 加真实改动触发 → `03e752f`
- release job 限定 `github.ref == 'refs/heads/main'`：feat 分支构建只出
  artifact 不发 release（防测试镜像误烧），artifact 验证分区表与内容。

---

## 6. 刷机后验证清单

```sh
partx -s /dev/mmcblk1          # 4 行: 128M / 960M / 960M / 剩余
fdisk -l /dev/mmcblk1 | grep Disklabel   # dos (MBR)
blkid /dev/mmcblk1p2 /dev/mmcblk1p3      # LABEL rootfs / rootfs-b，UUID 不同
ls /etc/uci-defaults/          # 空（首启成功自删）
mount | grep -E "/boot |shared"          # 均已挂载
cat /proc/filesystems | grep vfat        # builtin 直出（无模块加载）
dmesg | grep -c GROWROOT                 # 0（扩容已禁用）
cat /mnt/mmcblk1p3/.dualslot-ready       # slot=b uuid=<槽B UUID>
logread -e dualslot                     # 首启全程日志（>>> 前缀，38 行左右）
```

OTA 主脚本已落地（`9f18bf4`）：`usr/sbin/upgrade-a5e.sh`（查 release→下载，
仿 upgrade-lubancat.sh）+ `usr/sbin/openwrt-update-a5e`（底层双槽写入，仿
openwrt-update-rockchip：dd 对侧槽 + 配置迁移 + 改 p1 extlinux root=UUID 切槽）。
