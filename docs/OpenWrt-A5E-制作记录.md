# Radxa Cubie A5E 上运行 ImmortalWrt（OpenWrt）完整制作记录

> 日期：2026-10-05
> 目标：在 Radxa Cubie A5E（Allwinner A527 / sun55iw3）上运行 ImmortalWrt 25.12.2
> 成果：**成功启动并联网**（WAN DHCP 正常、Web/LuCI 可访问、SSH 可登录、双千兆网口识别）
> 最终镜像：`owrt-a5e.img`（859MB，GPT 三分区，可 `dd` 直接烧录）

---

## 1. 项目背景与硬件

### 1.1 开发板

| 项目 | 规格 |
|---|---|
| 型号 | Radxa Cubie A5E |
| SoC | Allwinner A527（sun55iw3，8×Cortex-A55） |
| 内核 | Radxa 官方 BSP 内核 `6.6.98-1-aw2607`（fork 代号 aw2607） |
| U-Boot | `u-boot-dlan17` 2026.04-4（SPL + U-Boot 合一，`u-boot-sunxi-with-spl.bin`） |
| 网口 | 双千兆以太网（eth0 / eth1） |
| WiFi | AIC8800（SDIO，WiFi6 单天线） |
| 存储 | SD 卡 / eMMC / SPI NOR |

### 1.2 关键引导事实（来自对 rsdk 源码的分析 + 实测验证）

- **启动链**：Allwinner SPL（raw 扇区 **LBA 256 / 128KB 偏移**）→ U-Boot → **extlinux**（`/boot/extlinux/extlinux.conf`）→ 内核。**不是** EFI / systemd-boot。
- **分区布局**（rsdk 生成，GPT）：
  - `p1`: config（16MB, vfat, label=config）
  - `p2`: efi（300MB, vfat, label=efi）
  - `p3`: rootfs（ext4, label=rootfs）
- U-Boot 通过 `/usr/lib/u-boot/radxa-cubie-a5e/setup.sh update_bootloader <img> 512` 把 SPL 写到 LBA 256。
- 内核/U-Boot/板级驱动全部以 **Debian 包**形式发布在 Radxa `a527-trixie-test` APT 仓库（`linux-image-6.6.98-1-aw2607`、`u-boot-dlan17`、`task-a527` 等）。**rsdk 不编译内核/U-Boot，只做组装**。

---

## 2. 方案选择

### 2.1 核心约束

- **OpenWrt 官方 25.12.x 不支持 Cubie A5E**：A5E 主线内核支持（sun55i-a527 DTS）在 Linux 6.15/6.16 才合入，而 OpenWrt 25.12 绑定 6.12 内核且不带 out-of-tree patch。官方无 A5E target。
- 社区非官方固件（kwrt/openwrt23.05 等）内核老、无 WiFi，质量参差。

### 2.2 选定方案（方案 C：拼装）

**ImmortalWrt 官方 armsr/armv8 通用 rootfs + Radxa 官方 A5E 内核/U-Boot + A5E 设备树**，用 rsdk 的镜像组装管线打包：

| 组件 | 来源 |
|---|---|
| rootfs | yzxiu/router release `ImmortalWrt-25.12.2-20261004-2241` 的 `immortalwrt-armsr-armv8-generic-rootfs.tar.gz`（52.7MB，SHA 校验通过） |
| 内核 | Radxa 官方 `vmlinuz-6.6.98-1-aw2607`（本地 rsdk 构建的 Debian 镜像里提取） |
| initramfs | Radxa 官方 `initrd.img-6.6.98-1-aw2607`（Debian initramfs-tools 生成） |
| DTB | `sun55i-a527-cubie-a5e.dtb` |
| 模块 | Radxa 官方 `/lib/modules/6.6.98-1-aw2607/`（892 个 .ko.xz） |
| U-Boot | Radxa 官方 `u-boot-sunxi-with-spl.bin` + `setup.sh` |
| 镜像组装 | rsdk `build-image`（guestfish 管线） |

---

## 3. 制作过程（可复现步骤）

### 3.1 先构建 Debian 原版镜像（提取 A5E 内核资产用）

在 rsdk devcontainer 里（本机：docker + KVM，宿主 AMD 支持 svm）：

```bash
# 环境：rsdk 官方 devcontainer（mcr.microsoft.com/devcontainers/base:bookworm + nix/devenv）
# 关键：容器需 --privileged -v /dev:/dev 才能用 KVM + 注册 binfmt

# 注册 arm64 qemu binfmt（宿主内核层）
docker run --rm --privileged tonistiigi/binfmt --install aarch64

# 构建（A5E 的内核/u-boot 只在 test 仓库，必须 -T）
devenv shell -- rsdk build -T --sector-size 512 --image-name output_512.img radxa-cubie-a5e
# 产物：out/radxa-cubie-a5e_trixie_kde/output_512.img（7.4GB，实测可启动）
```

踩坑记录：
- 缺 jsonnet/guestfish → 必须 `devenv shell --` 进入 nix 环境跑
- `arm64 can neither be executed` → binfmt_misc 未注册（上面 tonistiigi/binfmt 解决）
- `a527-trixie` release 源 404 → A5E 内核只在 test 源，必须加 `-T`（`--test-repo`）

### 3.2 提取 A5E 内核资产

```bash
# 用 guestfish 从 Debian 镜像 rootfs 里 copy-out
guestfish -a output_512.img <<EOF
run
mount /dev/sda3 /
copy-out /boot/vmlinuz-6.6.98-1-aw2607 /tmp/a5e-kernel/
copy-out /boot/initrd.img-6.6.98-1-aw2607 /tmp/a5e-kernel/
copy-out /usr/lib/linux-image-6.6.98-1-aw2607/allwinner/sun55i-a527-cubie-a5e.dtb /tmp/a5e-kernel/
copy-out /usr/lib/u-boot/radxa-cubie-a5e /tmp/a5e-kernel/
copy-out /lib/modules/6.6.98-1-aw2607 /tmp/a5e-kernel/
EOF
```

### 3.3 拼装 OpenWrt rootfs

```bash
# 解包 ImmortalWrt armsr rootfs
tar xzf immortalwrt-armsr-armv8-generic-rootfs.tar.gz -C rootfs

# 替换内核模块（armsr 原版是 6.12.103，A5E 内核用不了）
rm -rf rootfs/lib/modules/6.12.103
cp -a a5e-kernel/6.6.98-1-aw2607 rootfs/lib/modules/

# 放入内核/initrd/dtb/u-boot
mkdir -p rootfs/boot/extlinux rootfs/usr/lib/linux-image-6.6.98-1-aw2607/allwinner
cp a5e-kernel/vmlinuz-6.6.98-1-aw2607 rootfs/boot/
cp a5e-kernel/initrd.img-6.6.98-1-aw2607 rootfs/boot/
cp a5e-kernel/sun55i-a527-cubie-a5e.dtb rootfs/usr/lib/linux-image-6.6.98-1-aw2607/allwinner/
mkdir -p rootfs/usr/lib/u-boot && cp -a a5e-kernel/radxa-cubie-a5e rootfs/usr/lib/u-boot/

# 写引导配置
# rootfs/boot/extlinux/extlinux.conf + rootfs/etc/kernel/cmdline（内容见第 5 节）

# 打包（未压缩 tar，guestfish tar-in 用）
tar -C rootfs -cf openwrt-a5e-rootfs.tar .
```

### 3.4 生成镜像（复用 rsdk build-image 管线）

```bash
# build-image 是 rsdk image.jsonnet 生成的 guestfish 脚本，已验证可用
# 把 rootfs.tar 换成 openwrt 的，输出名改 owrt-a5e.img
devenv shell -- ./build-image
# 12 秒完成（KVM 加速）：分区 → 部署 rootfs → UUID 替换 → shrink → 写 U-Boot(LBA256) → 扩容
```

---

## 4. 调试过程：踩过的坑与解决方案（核心价值）

整个调试通过**串口（ttyUSB0, 115200）+ SSH（192.168.4.x）**进行。每一步都有真机验证。

### 坑 1：sunxi_mmc DMA 错误导致内核 hang

**现象**：内核启动后刷 `sunxi_mmc_host-4021000.sdmmc:[ERR]: wait dma hold bit clear timeout` / `bit clear timeout`，反复重试后系统 hang。

**根因**：内核 cmdline **缺 `coherent_pool=2M`**。Allwinner sunxi_mmc 的 DMA 需要一致性内存池，默认 256KB 不够。

**解决**：extlinux.conf append 增加（对齐 Debian 官方 cmdline）：
```
coherent_pool=2M consoleblank=0 console=tty1 irqchip.gicv3_pseudo_nmi=0
```

**对比**：Debian 官方 cmdline 有这些参数，我最初拼装时漏了。

### 坑 2：`root=` 格式（Debian initramfs vs OpenWrt fstools 的矛盾）

**现象**：`block: unable to load configuration (fstab: Entry not found)` 反复刷后 preinit hang。

**根因**：OpenWrt 的 `fstools`（`export_bootdevice` + `mount_root`）**只认 `root=PARTUUID=`（且是短格式或尾号02的第2分区）或 `root=/dev/...`**，**不认 `root=UUID=`（文件系统 UUID）**。而 Debian initramfs 认 `UUID=`。

**矛盾**：
- initramfs 挂载需要 `root=UUID=`（fs UUID）
- OpenWrt fstools 识别需要 `root=PARTUUID=`
- 一个 cmdline 只能有一个 root=

**解决**：**短路 fstools**。rootfs 已由 initramfs 挂载，不需要 mount_root 再挂。修改 `/lib/preinit/80_mount_root`：

```bash
# 原：mount_root start "$(compose_rootfs_mount_options)"
# 改：mount_root start "$(compose_rootfs_mount_options)" 2>/dev/null || echo "mount_root skipped (already mounted)"
```

**关键洞察**：官方 armsr 镜像 rootfs 恰好是第 2 分区（尾02），所以 fstools 能认；我们是第 3 分区，fstools 的模式匹配（`??02` / 短格式）永远匹配不上 → 必然 hang。

### 坑 3：UUID 字节序（最阴的一个，坑了一整轮）

**现象**：`ALERT! UUID=2d023947-3d15-9941-... does not exist. Dropping to a shell!`

**根因**：我最初用 python 提取 ext4 fs UUID 时**字节序搞反了**。ext4 superblock 的 s_uuid 前三段是**小端存储**，blkid/内核挂载时会解析回标准形式：

| 来源 | 值 | 对错 |
|---|---|---|
| 我最初 LE 转换算的 | `4739022d-153d-4199-...` | ✅ **这个才是真的**（blkid 认的） |
| 我“验证”时 hex 直读 | `2d023947-3d15-9941-...` | ❌ 我误当成“正确值”写进去，反而不存在 |

**实测验证**（最硬的证据）：
- `4739022d-...` 版本 → initramfs **挂载成功**（GROWROOT 都执行了）
- `2d023947-...` 版本 → initramfs 等 30 次重试后报 does not exist

**解决**：改回 `root=UUID=4739022d-153d-4199-bc4b-35ab086fcddb`。

**教训**：ext4 s_uuid 前 8 字节（time_low/time_mid/time_hi）是 LE 存储。`mkfs.ext4` 每次生成随机 UUID，**不要手算，要么用 build-image 的自动 sed，要么用 `blkid`/`debugfs` 读真值**。

### 坑 4：错用 Debian initramfs 引导 OpenWrt（noinitrd 之争）

**现象**：用 Debian initramfs 时走到 `mount: No such file or directory` 后行为异常。

**分析**：
- **官方 OpenWrt armsr 用 `noinitrd`**（grub.cfg 明确 `noinitrd`），内核直接挂 rootfs
- 但 **A5E BSP 内核的 mmc 初始化不稳定**，noinitrd 要求内核快速直挂 rootfs，随机卡死（有时到 6.7s，有时 1.2s 就停）
- **Debian initramfs 能给 mmc 初始化缓冲时间，稳定挂载**

**结论**：**必须用 initramfs**（Debian 的）来稳定挂载，然后用坑 2 的短路方案跳过 fstools。ophub 用 initramfs 也是同理（但 ophub 用的是 OpenWrt 自己的 initramfs，不是 Debian 的）。

### 坑 5：`init=/bin/sh` 不给 shell

**现象**：加 `init=/bin/sh` 后系统更早 hang（1.2s），连 shell 都没有。

**根因**：两个叠加——(a) noinitrd 的 mmc 不稳定（坑 4），(b) OpenWrt 的 `/bin/sh` 是 busybox 符号链接，run-init 环境下 exec 失败。

**解决**：放弃 init=/bin/sh，改走 initramfs + 短路 mount_root + 正常 procd 启动。

### 坑 6：首启中途断电导致第二次更早卡死

**现象**：第一次启动走到 `- generating board file -`，重启后第二次连 board file 都没有。

**根因**：OpenWrt 首启要做大量写操作（board.json、UCI 默认配置、overlay 初始化、GROWROOT 扩容 + resize2fs），**中途断电 = 文件系统半写脏状态**，第二次挂载异常。

**解决**：重新烧录 + **首启耐心等 5-8 分钟不断电**，让它完整跑完。

### 坑 7：br-lan 建不起来，LAN 不通（bridge 模块三连坑）

**现象**：WAN 正常（eth1，驱动 builtin），但 LAN（eth0）没反应。`br-lan: can't find device`，netifd 报 `NO_DEVICE`，`modprobe bridge` 失败（exit 255）。

这是**三层叠加**的问题，排查时逐层剥开：

#### 第 1 层：模块是 .ko.xz 压缩，OpenWrt 根本不认

```
A5E 内核模块全是 .ko.xz 压缩（Radxa BSP 内核 CONFIG_MODULE_COMPRESS_XZ=y）
  → OpenWrt 的 kmodloader/busybox 不支持 xz 解压模块（板子上连 xz 命令都没有）
  → 任何 .ko.xz 模块都加载不了（不只 bridge，还有 WiFi 驱动 aic8800 等）
```

**修复（宿主机对镜像操作）**：892 个 `.ko.xz` → `xz -dc` 解压成 `.ko`；`modules.dep`/`modules.alias`/`modules.symbols` 等元数据里的 `.ko.xz` 路径全部 `sed` 成 `.ko`；删除 `.bin` 缓存（`modules.dep.bin` 等）强制 modprobe 读文本。

#### 第 2 层：即使 .ko 格式对了，modprobe 依赖解析仍然失灵

**关键对比**（真机反复验证）：
| 操作 | 结果 |
|---|---|
| `modprobe bridge` | **exit 255**（失败）|
| `insmod llc.ko` → `insmod stp.ko` → `insmod bridge.ko`（按依赖顺序）| **成功** |

**结论**：模块文件、内核、bridge 功能**全部正常**，问题纯粹是 **OpenWrt 的 kmodloader/modprobe 对这个内核模块格式的依赖解析有 bug**（bridge 依赖 stp.ko、llc.ko，modprobe 无法自动带出依赖）。这是 aw2607 BSP 内核模块与 OpenWrt kmodloader 的兼容性问题，**改 modules.dep 治不好**。

#### 第 3 层：配置是首启生成的，别被表象误导

- 镜像里 `/etc/config/network` 是**空的** —— armsr 的 network 配置是**首启由 `config_generate` 自动生成**的（含 br-lan bridge eth0 定义）。
- 排查中一度以为：netifd 建桥（netlink）失败而 brctl（ioctl）成功是接口问题；又一度以为是我 `uci delete network.@device[0]` 误删了 br-lan 定义。**这些都是表象/弯路** —— 真正卡点始终是第 2 层的 modprobe 依赖解析。

#### 备用方案：init.d 启动早期预加载（绕过 modprobe）

> ⚠ 本方案已降级为**回退方案**。根治方案是重编内核让 `CONFIG_BRIDGE=y`，详见 **`radxa-a5e-openwrt-kernel/docs/A5E-内核编译-记录.md`**。已验证的成品镜像使用新内核（bridge builtin）；本节保留的 init.d 方案产物保留在 `owrt-a5e.img.bak-initd`，万一需回滚可直接使用。

既然 `insmod` 按依赖顺序手动加载确定能成，做成开机脚本，在 netifd（START=20）之前预加载：

`/etc/init.d/bridge-modules`（START=15，0755 可执行）：
```sh
#!/bin/sh /etc/rc.common
START=15
start() {
	local M="/lib/modules/$(uname -r)/kernel"
	grep -q '^llc '    /proc/modules || insmod "$M/net/llc/llc.ko"
	grep -q '^stp '    /proc/modules || insmod "$M/net/802/stp.ko"
	grep -q '^bridge ' /proc/modules || insmod "$M/net/bridge/bridge.ko"
}
```

并创建开机自启链接：`/etc/rc.d/S15bridge-modules -> ../init.d/bridge-modules`。

**启动链**：`init.d(15) 预加载 bridge` → `config_generate 生成 br-lan 定义` → `netifd(20) 建 br-lan（bridge 已加载）` → LAN 通。

> 备注：用户曾提议放进 initramfs 预加载，方向一致；但 bridge 不是挂载 rootfs 必需的，init.d（netifd 前）加载已足够，且不用重打包 cpio，更简单。

#### 验证方法

```bash
# 烧录后：
cat /proc/modules | grep bridge      # 应自动出现（init.d 预加载）
ip addr show br-lan                  # 应自动建好 192.168.1.1
# 电脑插 eth0 口 → 应拿到 192.168.1.x → 访问 http://192.168.1.1
```

#### 局限 / 待办

- init.d 是**绕过**方案，modprobe 依赖解析的根本 bug（kmodloader 对 aw2607 模块格式）**未根治**。其它需要 modprobe 的模块（如 WiFi）若走 kmodloader 自动加载，可能仍需类似处理。
- firewall 的 nftables/Netfilter 模块（`nf_tables`、`nft_*`）也可能是 .ko.xz → 已一并转 .ko，但其自动加载是否踩同样的坑，**待验证**（见第 6 章已知问题）。

#### 根治方案（推荐）：重编内核 使 bridge builtin

将 `CONFIG_BRIDGE=m` 改为 `CONFIG_BRIDGE=y`，Kconfig select 会自动把 `LLC`/`STP` 也拉到 `=y`（实测确认）。内核 vmlinux 自带桥 → netifd 直接建 `br-lan` → **无需 modprobe / insmod，也不需要 init.d 预加载**。

完整可复现步骤（含 patch 两种前缀、`libssl-dev:arm64`、deb 里 vmlinuz 是 gzip 的陷阱、OpenWrt 镜像安装）见 **`radxa-a5e-openwrt-kernel/docs/A5E-内核编译-记录.md`**（已包装为 GitHub Actions）。

已验证交付：
- 新镜像：`owrt-a5e.img`（sha256 见 `owrt-a5e.img.sha256`）
- 旧镜像（init.d 回退）：`owrt-a5e.img.bak-initd`

---

### 坑 8：串口有内核日志但进不了终端（ttyAS0 命名 + plymouth 占用 console）

**现象**：串口（ttyUSB0 @115200）能看到完整内核日志，但按回车/按键**始终进不了终端**，没有 login shell。

**双层根因**（逐层排查确认）：

**第 1 层：`/etc/inittab` 没有 `ttyAS0` 的 login 条目**
- A5E 串口是 Allwinner BSP 内核的 **sunxi-uart 驱动，设备名 `ttyAS0`**（mainline 内核叫 `ttyS0`）。
- armsr 通用固件的 inittab 只配了 `ttyAMA0/ttyS0/tty1/hvc0/ttymxc*/ttySC0` 等常见名，**不认识 Allwinner 特有的 `ttyAS0`**。
- 内核 cmdline `console=ttyAS0` 只负责**输出日志**（所以串口看得到日志），但 procd 没在 ttyAS0 上启动 login → 无 shell。

**第 2 层：`plymouthd`（开机画面）开机时占用 ttyAS0**
- Radxa 的 plymouth 开机画面在 console（ttyAS0）上显示，**开机阶段占用该 tty**。
- procd 启动时为 ttyAS0 创建 `askfirst`（login）会因被占用而失败；开机后 plymouthd 虽自然退出，但 procd **不会补创建** askfirst。
- 结果：ttyAS0 释放后仍没有 login。

**修复**：
1. 镜像 `/etc/inittab` 加一行：`ttyAS0::askfirst:/usr/libexec/login.sh`
2. `login.sh` 末尾是 `exec /bin/login -f root`（无密码直接给 root shell），机制正常。

**验证方式**：
- **根治需禁用 plymouth**（否则每次开机它都占用 console 导致 askfirst 失败）。
- 临时验证（不重启）：先等 plymouthd 退出，再 `setsid /usr/libexec/login.sh </dev/ttyAS0 >/dev/ttyAS0 2>&1 &` → ttyAS0 上立刻出现 root shell（实测确认串口可进终端）。

**遗留**：
- **plymouth 开机干扰未根治**：需禁用 plymouth（卸载包或禁其占用 console），否则每次重启都要手动补 login。
- **Ctrl+C（SIGINT）疑似不生效**（top 无法退出）：`login.sh` 对 `/dev/ttyAS*` 设 `TERM=vt102`，可能是 termios 的 ISIG/minicom 设置问题，**待查**（不影响基本使用）。
- 注意：板子**没有 `getty` 命令**（busybox 精简，OpenWrt 用 procd askfirst 代替），排查时别拿 getty 测。

---

### 坑 9：kernel-actions 拼装下 dtb 找不到，内核用错 fdt 卡死

**现象**（U-Boot 串口日志）：
```
Retrieving file: /usr/lib/linux-image-6.6.98-1-aw2607/...dtb
** File not found /usr/lib/linux-image-6.6.98-1-aw2607/allwinner/sun55i-a527-cubie-a5e.dtb **
Skipping fdtdir /usr/lib/linux-image-6.6.98-1-aw2607/ for failure retrieving dts
## Flattened Device Tree blob at 7bf1f5b0
   Booting using the fdt blob at 0x7bf1f5b0     ← 退回 U-Boot 自带 fdt
```
内核能 `Starting kernel` 但早期就卡住（用的不是内核包里的匹配 dtb）。

**根因（两层叠加，都在 `scripts/40-assemble-rootfs.sh`）**：
1. **dtb 拷贝路径错**：脚本② 往 `/boot/dts/` 拷，但用 `find -maxdepth 1` 找 `$DTB_SRC_DIR/*.dtb`；
   而 kernel-actions release 解出的 a5e dtb 实际在 **`…/linux-image-<KVER>/allwinner/` 子目录**，顶层没有 → `boot/dts/` 拷成空。
2. **fdtdir 与落点不一致**：`custom/rootfs/boot/extlinux/extlinux.conf` 的 overlay 把 `fdtdir` 指向
   `/usr/lib/linux-image-<KVER>/`，但脚本从没往那儿拷 dtb → fdtdir 指空目录。
   两者叠加 → dtb 彻底无处可寻。（手工拼装时第 3.3 节本来就是拷到 `usr/lib/linux-image/.../allwinner/`，
   脚本化迁移时把目标改成了 `boot/dts` 却没同步改 fdtdir，埋下不一致。）

**关键认知**：`50-build-image.sh` 里的 rsdk `build-image` 只 `sed` 替换 **`root=UUID`**，
**不碰 `fdtdir`**。所以 extlinux 的 `fdtdir` 必须与 dtb 实际落点**人工保证一致**。

**修复**：按 Debian/Radxa 内核 deb 标准布局，把 a5e dtb 放 `/usr/lib/linux-image-<KVER>/allwinner/`
（匹配 custom 的 fdtdir），并区分两种内核源的 dtb 位置：
```bash
# scripts/40-assemble-rootfs.sh ② 内
DTB_DST="$ROOTFS_DIR/usr/lib/linux-image-$KVER/allwinner"; mkdir -p "$DTB_DST"
if [ -f "$DTB_SRC_DIR/allwinner/$DTB" ]; then   # kernel-actions：在 allwinner/ 子目录
  cp "$DTB_SRC_DIR/allwinner/$DTB" "$DTB_DST/"
elif [ -f "$DTB_SRC_DIR/$DTB" ]; then           # rsdk 提取：KERNEL_DIR 顶层
  cp "$DTB_SRC_DIR/$DTB" "$DTB_DST/"
else die "找不到 a5e dtb"; fi
# 脚本③生成的 extlinux 里 fdtdir 也从 /boot/dts/ 改成 /usr/lib/linux-image-$KVER/（与 custom 一致）
# 另：删掉旧的 mkdir boot/dts 后补回 mkdir -p "$ROOTFS_DIR/boot"（openwrt armsr rootfs 不预建 /boot）
```

**验证**（`./build.sh 40` 后离线查）：
```bash
tar -tf "$OWRT/openwrt-a5e-rootfs.tar" | grep "usr/lib/linux-image-.*/allwinner/sun55i-a527-cubie-a5e.dtb"
# 成品 img：debugfs 确认同路径有 dtb + extlinux fdtdir 一致 + root=UUID==p3 superblock
dd if=owrt-a5e.img of=/tmp/v.img bs=512 skip=679936 count=<partx -g -o SECTORS --nr3 owrt-a5e.img> status=none
debugfs -R "stat /usr/lib/linux-image-$KVER/allwinner/sun55i-a527-cubie-a5e.dtb" /tmp/v.img
```

> 经验：改任何引导相关路径（dtb/cmdline/fdtdir）后，**必须离线 debugfs/tar 抽查实际落点**再烧；
> U-Boot 找不到 dtb 会静默退回自带 fdt，看似能 `Starting kernel` 实则可能卡死或驱动不对。

---

## 5. 最终配置（extlinux.conf）

```
## /boot/extlinux/extlinux.conf
default l0
menu title U-Boot menu
prompt 0
timeout 10
label l0
	menu label ImmortalWrt A5E 6.6.98-1-aw2607
	linux /boot/vmlinuz-6.6.98-1-aw2607
	initrd /boot/initrd.img-6.6.98-1-aw2607
	fdtdir /usr/lib/linux-image-6.6.98-1-aw2607/
	append root=UUID=4739022d-153d-4199-bc4b-35ab086fcddb console=ttyAS0,115200n8 earlyprintk=sunxi-uart,0x2500000 rootwait clk_ignore_unused mac_addr=${mac} mac1_addr=${mac1} loglevel=4 rw earlycon consoleblank=0 console=tty1 coherent_pool=2M irqchip.gicv3_pseudo_nmi=0
```

**注意**：`root=UUID=4739022d-...` 是**当前这张镜像的 fs UUID**。重新跑 build-image 生成新镜像时 UUID 会变，需重新读真值（`blkid` 或 guestfish 内 blkid）或依赖 build-image 的自动替换。

---

## 6. 当前状态与已知问题

### 6.1 已验证可用

- ✅ 完整启动（U-Boot SPL → extlinux → initramfs → OpenWrt procd → netifd）
- ✅ WAN（eth1）：DHCP 正常，拿到局域网 IP（192.168.4.x）
- ✅ Web/LuCI 可访问
- ✅ SSH 可登录（root，默认无密码）
- ✅ 双千兆网口内核识别（eth0/eth1 都 link up）
- ✅ bridge 模块加载（修复后），br-lan 可建，LAN 可用

### 6.2 已知问题 / 待办

| 问题 | 状态 | 说明 |
|---|---|---|
| 串口 shell 不响应 | ✅ 已定位，部分修复 | 双层根因：inittab 缺 `ttyAS0`（Allwinner BSP 命名）+ plymouthd 开机占用 console（详见坑 8）。已在镜像 inittab 加 `ttyAS0` 行（sha 7d7a34a5）；**plymouth 禁用未做**（每次开机需手动补 login），Ctrl+C 信号待查。不影响 SSH/LuCI 管理 |
| LAN/br-lan 建不起来 | ✅ 已修复待烧录验证 | 根因是 .ko.xz 模块 + modprobe 依赖解析失灵（详见坑 7）。已固化：.ko 转换 + `init.d/bridge-modules` 启动预加载（START=15），**需重新烧录**验证 br-lan 自动建 |
| WiFi（AIC8800） | 未验证 | 模块已转 .ko 可加载，但固件/配置未测 |
| rootfs 首次启动扩容 | 部分 | GROWROOT 扩分区成功，但 OpenWrt 无 cloud-initramfs-growroot 的 resize 后续，首次需完整跑完 |
| MAC 地址随机 | 已知 | eth0 用随机 MAC（`Use random mac address`），每次启动可能变 |
| root 无密码 | 安全风险 | 默认 root 空密码，需 `passwd` 设置 |

### 6.3 推荐收尾操作

```bash
# 1. 设密码
ssh root@<A5E-IP> 'passwd'

# 2. 固化网络配置（把 eth0 固定为 LAN，eth1 为 WAN）
ssh root@<A5E-IP> '
uci set network.lan.device="br-lan"
uci commit network
service network restart'

# 3. 重新烧录修复后的镜像（让 bridge 自动加载固化）
sudo dd if=owrt-a5e.img of=/dev/sdX bs=4M conv=fsync status=progress && sync
```

---

## 7. 关键文件与目录

> 路径基于工作根 `$WS`（你检出 `radxa-a5e` 的位置，例如 `$HOME/work/radxa-a5e`）。

```
$WS/
├── owrt-a5e.img                  # 最终 OpenWrt 镜像（859MB）
├── owrt-a5e.img.sha256
├── out/                          # Debian 原版镜像构建产物
│   ├── output_512.img            # Debian 原版（7.4GB，可启动）
│   ├── rootfs.tar                # Debian rootfs（5GB）
│   ├── config.yaml / manifest    # 构建配置/包清单
│   └── build-image               # rsdk 镜像组装脚本（复用）
├── owrt/                         # OpenWrt 拼装工作区
│   ├── immortalwrt-armsr-armv8-generic-rootfs.tar.gz  # 官方 rootfs
│   ├── immortalwrt-armsr-armv8-generic-ext4-rootfs.img  # 官方 ext4 镜像（参考）
│   ├── official-ext4-combined-efi.img  # 官方 combined-efi（grub.cfg 参考）
│   ├── a5e-kernel/               # A5E 内核资产（vmlinuz/initrd/dtb/modules/u-boot）
│   ├── rootfs/                   # 拼装中的 rootfs
│   └── checksums.txt
├── rsdk-src/rsdk/                # rsdk 源码（构建用）
└── yzxiu-router/                 # yzxiu/router 仓库（ophub remake 参考）
```

---

## 8. 核心经验总结

1. **A5E 引导是 Allwinner SPL@LBA256 + extlinux**，不是 EFI。OpenWrt 的 EFI 假设（armsr 官方用 grub + noinitrd + 两分区）与 A5E（三分区 + extlinux + initramfs）有本质差异，是大部分坑的来源。

2. **fstools 的 root= 解析是硬限制**：只认短 PARTUUID / 尾02第二分区 / /dev/...。三分区布局必然 hang，**短路 mount_root 是最小改动方案**（root 已被 initramfs 挂好）。

3. **ext4 UUID 字节序**：前三段 LE 存储。`mkfs.ext4` 每次随机生成，**绝不手算**，用 blkid 读真值。

4. **Radxa BSP 内核的 .ko.xz 模块与 OpenWrt busybox kmodloader 不兼容**，必须解压成 .ko + 修 modules.dep 路径 + 删 .bin 缓存。这是“WAN 能用（builtin 驱动）但 LAN/WiFi 不能用（模块驱动）”的根因。

5. **OpenWrt 首启不能断电**：board.json/UCI 配置/GROWROOT 扩容大量写盘，断电 = fs 脏 → 二次启动更糟。

6. **调试方法论**：串口抓完整启动日志定位 hang 点 → 宿主机 debugfs 离线改镜像（提取分区→改→写回）→ 烧录验证。比反复烧录快得多。

---

## 9. 后续方向（可选）

1. **固化全部修复到镜像**（当前 modules.dep 修复需重新烧录验证）
2. **WiFi 调通**（AIC8800 模块已可加载，需配固件 + hostapd）
3. **串口 getty 修复**（/etc/inittab 加 ttyAS0）
4. **首启自动扩容**（参考 ophub `openwrt-tf`）
5. **打包脚本化**（仿 ophub remake，做成可复用 `make-a5e-openwrt.sh`，一键出包）
6. **正路：OpenWrt 源码 porting**（为 sun55i-a527 添加 OpenWrt target，含 OpenWrt 内核 + OpenWrt initramfs，彻底解决兼容性问题，但工作量大）
