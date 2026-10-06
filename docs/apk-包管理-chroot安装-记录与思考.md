# 镜像构建中的 apk 包管理（chroot 安装）—— 完整记录与思考过程

> 范围：`radxa-a5e-openwrt` 构建流水线里**所有** `apk add` / `apk del` 操作，以及围绕它们的
> 环境、权限、可复现性问题。
>
> 这份文档刻意**保留推理过程**（包括走错的路、下错的结论、以及测量方法本身的缺陷），
> 目的是让后续能从"为什么当初这么选"继续往下推，而不是只看到一个结果。
>
> 相关代码：`scripts/40-assemble-rootfs.sh` ③b、`scripts/00-lib.sh`（`WIFI_PKGS` /
> `WIFI_WPAD_PKG`）、`.github/workflows/build.yml`（apt 依赖 + 12 条断言）。
> 相关背景：`docs/OpenWrt-A5E-制作记录.md` 坑 10。

---

## 0. TL;DR

- 整条流水线（15→20→25→30→40→50）里，**只有 40 步的 ③b 一处**动 apk，共 4 次调用：
  `apk info`（发现）→ `apk del`（卸旧 wpad）→ `apk add`（装 4 个包）→ `apk info`（兜底校验）。
- 净变化 **−1 +4**：卸 `wpad-mesh-mbedtls`；装 `wpad-mbedtls`、`iw`、`wifi-scripts`，
  以及自动带出的依赖 `ucode-mod-digest`。**包数 281 → 284**（基础 rootfs 281），
  装完 apk 报 `OK: 135.4 MiB in 284 packages`。
- **必须在 chroot 里用 apk**，不能手工解 `.apk`：三个包都有 post-install 脚本，且 apk 的
  包数据库（`/lib/apk/packages/*.list`、`/etc/apk/world`）必须同步更新。
- 三个真正的坑（全部实测踩过）：**binfmt 可用性判断**、**root 属主导致 tar 静默失败**、
  **apk 不自动替换冲突 provider**。
- 一个我自己犯过的**测量错误**：用 `| grep | tail -8` 观测 apk，退出码被管道末端吃掉、
  `ERROR:` 首行被截断，于是得出了"apk 冲突时静默成功"的错误结论。见 §6.2。

---

## 1. 为什么需要装包

### 1.1 基础 rootfs 的来源与局限

30 步下载的是 `yzxiu/router` 网络编译产出的 **ImmortalWrt armsr/armv8 通用 rootfs**
（`radxa-a5e-rootfs.tar.gz`，sha256 锁定在 `00-lib.sh` 的 `OWRT_SHA`）。

选它的原因（见制作记录 §2）：官方 OpenWrt 25.12 不支持 A5E（要 6.15/6.16 mainline），
而 armsr 是**纯 rootfs 无内核**，正好配 A5E 的 BSP 内核拼装。

代价就是：它是"通用"的，**不含任何 A5E 特定的东西**，也不含我们这套方案额外需要的包。

### 1.2 三个缺口，以及各自的症状

| 缺什么 | 症状 | 定位证据 |
|---|---|---|
| `wifi-scripts` | `wifi config` / `wifi up` 全是 `not found`；netifd 完全没有无线 handler，`ubus call network.wireless status` 空 | ImmortalWrt **25.12 把 `/sbin/wifi` 和 `/lib/netifd/wireless/mac80211.sh` 从 base-files 拆成了独立包**，通用 rootfs 没带 |
| `iw` | 就算 `/sbin/wifi` 在，`setup_phy` 阶段也会失败 | `mac80211.sh` 的 `setup_phy()` 硬依赖 `iw phy ... set antenna/distance/txpower` |
| wpad 变体不对 | 2.4G 能起，**5G 起不来** | 预装的是 `wpad-mesh-mbedtls`，描述自称 *"minimal ... (with 802.11s mesh and SAE)"*，编译时没开 `CONFIG_IEEE80211AC` / `CONFIG_IEEE80211AX` |

第三条是最后才暴露的——因为我们**一开始误判芯片是 2.4G 单频**，压根没去试 5G。
详见 §6.3 和制作记录坑 10 的"更正"小节。

---

## 2. 方案选择：四条路的权衡

| 方案 | 做法 | 判定 | 理由 |
|---|---|---|---|
| **A. 手工解 `.apk`** | 下载 `.apk`（本质是 tar），解到 rootfs | ❌ 否决 | `.apk` 里的 `.post-install` 脚本不会执行；`/lib/apk/packages/*.list` 和 `/etc/apk/world` 不会更新。后果：`apk info` 看不到这些包、以后 `apk add` 撞冲突、**开机链 `/etc/rc.d/S19wpad` 建不出来**（wpad 不自启） |
| **B. 改上游 rootfs 构建** | 去 `yzxiu/router` 的构建配置里把包加进去 | ⚠ 部分采纳（见 §9） | 最干净，但**耦合两个仓**：本仓的构建正确性会依赖另一个仓的发布节奏。目前只在 wpad 变体这一项上留作后续方向 |
| **C. chroot + apk** | qemu-user 模拟 aarch64，在装配目录里跑真 apk | ✅ **选定** | post-install 脚本真执行、包 DB 真更新、`apk add` 的依赖解析真跑一遍。代价是引入 qemu/binfmt 依赖 |
| **D. guestfish 里跑 apk** | 50 步已经用 guestfish 编辑镜像 | ❌ 否决 | guestfish 是**镜像编辑**工具（virt-* 系列），不是构建环境；在里面跑包管理器要再起 appliance，比 chroot 重得多，而且 40 步产出的是 tar、还没有镜像 |

**决策依据**：`wifi-scripts` / `iw` / `wpad-mbedtls` 三个包**都有 post-install 脚本**。
实测日志（chroot 内）：

```
(1/4) Installing iw (6.17-r1)
  Executing iw-6.17-r1.post-install
(2/4) Installing ucode-mod-digest (2026.01.16~85922056-r1)
  Executing ucode-mod-digest-2026.01.16~85922056-r1.post-install
(3/4) Installing wifi-scripts (1.0-r1)
  Executing wifi-scripts-1.0-r1.post-install
(4/4) Installing wpad-mbedtls (2025.08.26~ca266cc2-r2)
  Executing wpad-mbedtls-2025.08.26~ca266cc2-r2.post-install
OK: 135.4 MiB in 284 packages
```

只要有一个脚本没跑，产物就是"看着装了、实际半残"的状态——这类失败**不会报错**，
只会在板上表现为功能缺失。所以宁可引入 qemu 依赖也要走真 apk。

---

## 3. chroot 方案的技术细节

### 3.1 前置条件清单

```bash
# 1) bind mount 三个伪文件系统（apk 和 post-install 脚本会用到）
for d in proc sys dev; do mkdir -p "$ROOTFS_DIR/$d"; mount --bind "/$d" "$ROOTFS_DIR/$d"; done

# 2) DNS。⚠ 陷阱：rootfs 里 /etc/resolv.conf 是**指向 /tmp/resolv.conf 的符号链接**，
#    而镜像阶段 /tmp/resolv.conf 还不存在 → 直接 cp 会报：
#      cp: not writing through dangling symlink '.../etc/resolv.conf'
#    正确做法是写到链接目标：
mkdir -p "$ROOTFS_DIR/tmp"; cp /etc/resolv.conf "$ROOTFS_DIR/tmp/resolv.conf"

# 3) 仓库配置和签名密钥：基础 rootfs 自带，无需处理
#    /etc/apk/repositories.d/distfeeds.list  → downloads.immortalwrt.org/releases/25.12.2/...
#    /etc/apk/keys/                          → 已有
#    注意 apk 二进制在 /usr/bin/apk（usrmerge），不是 /sbin/apk
```

### 3.2 binfmt 可用性：两类相反方向的坑

这是整个方案里最反直觉的一段，两个坑方向相反，都实测过。

**坑 A —— 假阴性（文件不存在，但能跑）**

本地在容器里测的时候，我加过一个预检：

```bash
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && echo OK || echo "未注册"
```

结果打印"未注册"，**但 chroot 里的 apk 照样跑成功了**。原因：

- `binfmt_misc` 是**宿主内核全局**机制，不是 per-container 的
- `--privileged` 容器里 `/proc/sys/fs/binfmt_misc` 可能压根没挂进来 → 文件看不到
- 宿主注册时的 flags 是 `POCF`，其中 **`F`(fixed) = 注册时就打开解释器二进制**，
  所以容器里有没有 `/usr/bin/qemu-aarch64` 都无所谓

实测宿主注册信息：

```
$ cat /proc/sys/fs/binfmt_misc/qemu-aarch64
enabled
interpreter /usr/bin/qemu-aarch64
flags: POCF
magic 7f454c460201010000000000000000000200b700
```

→ **结论：不能用"文件是否存在"判断能力，只能用"真跑一次"判断。**

**坑 B —— 真失败（包装了，但注册没生效）**

CI（GitHub ubuntu-24.04 runner）上，`apt-get install qemu-user-static binfmt-support`
之后 binfmt 未必立刻生效：注册要靠 `systemd-binfmt.service` 应用 `/usr/lib/binfmt.d/*.conf`，
或 `binfmt-support` 的 `update-binfmts`，而 apt 的 postinst 不一定触发。

→ 所以 40 步里做成了**六级自愈**（全部幂等，按代价从小到大）：

```
1) 直接试 chroot /bin/uname -m         ← 本地/容器常态，一把过
2) mount binfmt_misc
3) systemctl restart systemd-binfmt
4) update-binfmts --enable qemu-aarch64{,-static}
5) 手工写 /proc/sys/fs/binfmt_misc/register（带 F 标志）
6) docker run --privileged multiarch/qemu-user-static --reset -p yes
全失败 → 打出 host arch / binfmt 挂载数 / 注册条目 / 解释器是否存在 / chroot 真实报错，再 die
```

第 6 步之后仍然失败才 `die`，且**必须把现场打出来**。这一条是被 run #15/#16 教的：
当时只有一句 `die "chroot 里跑不了 aarch64"`，看日志根本分不清是限流、无网、
还是 binfmt——白跑了三轮 CI 才拿到有用信息。

### 3.3 root 权限：run #15/#16/#18 连续三轮失败的真凶

**现象**：CI 步骤 10 失败，日志尾部：

```
==> ⑥ 打包 rootfs.tar
tar: ./lib/apk/db/lock: Cannot open: Permission denied
tar: Exiting with failure status due to previous errors
rm: cannot remove '.../etc/rc.wps/50-wps_sta': Permission denied
rm: cannot remove '.../usr/share/ucode/wifi/utils.uc': Permission denied
...（十几行）
```

**推理链**：

1. chroot + apk 是 `$SUDO` 跑的（CI 里脚本以 runner 身份执行）→ apk 装出来的文件属 **root**
2. `lib/apk/db/lock` 是 **0600 root** → 非 root 的 `tar` 读不了 → tar 失败
3. EXIT trap 里的 `rm -rf "$ROOTFS_DIR"` 同样删不掉 root 属主文件（父目录也 root 属主）
4. **本地一直没暴露**：我在容器里是 root 全程跑的，`SUDO=""`，属主一致

**修复**：脚本开头自提升。三个理由一起解决：

```bash
if [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null || die "需要 root（或 sudo）"
  exec sudo -E bash "$WORK/scripts/40-assemble-rootfs.sh" "$@"
fi
```

1. `tar` / `rm` 能处理 root 属主文件
2. **以 root 解包才能保留 tarball 原本的属主**——非 root 解包会把整个 rootfs 压成
   runner 的 uid（这是个独立的既有问题，见下）
3. ③b 本来就要 chroot + bind mount

**顺带修的两个属主问题**：

| 问题 | 证据 | 修法 |
|---|---|---|
| overlay 的 `cp -a` 把**宿主属主**带进镜像 | 板上实测 `/etc/config/wireless` 属主 `1000:1000`；`find /etc /usr/sbin /sbin -maxdepth 2 ! -user 0` 命中 5 个路径 | 对 overlay **确实提供的那些文件**逐个 `chown -h 0:0`。**不做全局 `chown -R`**——那会把 OpenWrt 里故意的服务用户属主一并抹平 |
| EXIT trap 的 `rm -rf` 可能顺着 bind mount 删到宿主 `/proc` | 原 trap 是 `trap 'rm -rf "$ROOTFS_DIR"' EXIT`，而 ③b 会在其下 bind mount proc/sys/dev | 改成 `cleanup_rootfs()`：先逐个 `umount -l`，再 `mount | grep -qF "$ROOTFS_DIR/"` 确认**无残留挂载点**才 `rm -rf`，否则只 warn 不删 |

**还有一处防御性改动**：⑥ 的产物显式 `chmod 0644`。因为本步现在以 root 跑，
产物属 root，而后续 `stage` / `50 打包` / `upload-artifact` 仍以原用户跑。
`sudo -E` 下 umask 实测是 `0022`（→ 644，没问题），但 **sudoers 的 umask 是可配的**，
若设成 `0077` 就会落成 600，下游 `cp` 直接 Permission denied。

### 3.4 本地复现 CI 的方法（重要，可复用）

宿主机没有免密 sudo，所以要在容器里造一个和 CI 同构的环境：

```bash
docker run --rm --privileged -v "$PWD:/ws:ro" ubuntu:24.04 bash -c '
  apt-get install -y --no-install-recommends <CI 那份 apt 列表>
  B=/home/runner/work/radxa-a5e-openwrt          # 复现 CI 的目录层级
  useradd -m -u 1001 runner                       # CI 的 runner uid 就是 1001
  echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner
  mkdir -p "$B"; cp -a /ws/radxa-a5e-openwrt "$B/"; mkdir -p "$B/owrt" "$B/out"
  cp -a /ws/owrt/{radxa-a5e-rootfs.tar.gz,a5e-kernel,a5e-kernel-actions,aic-firmware} "$B/owrt/"
  cp -a /ws/out/build-image "$B/out/"; chown -R runner:runner "$B"
  su runner -c "cd $B/radxa-a5e-openwrt && bash scripts/40-assemble-rootfs.sh"'
```

关键点：**必须以 uid 1001 的非 root 身份跑**，否则复现不出 §3.3 的属主问题
（我就是因为一开始全 root 跑，才让这个 bug 一路带到 CI 连炸三轮）。

⚠ 挂载用 `:ro` 或先复制到容器内。**不要**在 bind mount 的工作区里 `chown -R`，
那会改到宿主文件的属主。

---

## 4. 四次 apk 调用逐个讲

代码位置：`scripts/40-assemble-rootfs.sh` ③b（约 176–203 行）。

### ① `apk info` —— 动态发现预装的 wpad 变体

```bash
INSTALLED=$($SUDO chroot "$ROOTFS_DIR" /usr/bin/apk info 2>/dev/null || true)
for v in $(printf '%s\n' "$INSTALLED" | grep -E '^wpad-' || true); do
  [ "$v" = "$WIFI_WPAD_PKG" ] && continue
  echo "   - 卸掉 $v（minimal 变体，无 802.11ac/ax）"
  $SUDO chroot "$ROOTFS_DIR" /usr/bin/apk del "$v" >/dev/null 2>&1 || true
done
```

**为什么不硬编码 `apk del wpad-mesh-mbedtls`**：基础 rootfs 由另一个仓（`yzxiu/router`）
构建，它将来换 wpad 变体（比如改成 `wpad-basic-mbedtls`）是完全可能的。硬编码会导致
`del` 空转 → `add` 撞冲突 → 构建失败（好在会失败，不是静默）。动态发现 + 跳过目标包，
两种情况都能正确处理。

`apk info` 输出的是**不带版本号的包名**（实测：`hostapd-common` / `wpad-mbedtls`），
所以 `grep -qx "$WIFI_WPAD_PKG"` 这种精确匹配是可行的。

**产物侧的实测证据**（从 `openwrt-a5e-rootfs.tar` 里抽）：

```
$ tar -xOf $T ./etc/apk/world | grep -nE 'wpad|^iw$|wifi-scripts'
26:iw
279:wifi-scripts
281:wpad-mbedtls                ← world 共 283 行，无 wpad-mesh-mbedtls

$ tar -tf $T | grep 'lib/apk/packages/wpad'
./lib/apk/packages/wpad-mbedtls.conffiles_static
./lib/apk/packages/wpad-mbedtls.conffiles
./lib/apk/packages/wpad-mbedtls.rusers
./lib/apk/packages/wpad-mbedtls.list
                                ← mesh 变体的四个 DB 文件全部消失
```

这说明 `apk del` 确实把包从 **world 和 DB 两处**都清干净了（手工解包做不到这点）。

### ② `apk del` —— 必须显式卸

见 §6.1 的实测：**apk 不会自动替换冲突的 provider**，直接 add 会 `exit 2`。

`>/dev/null 2>&1 || true`：卸一个不存在的包不该让构建失败（动态发现已经保证它存在，
但多一层容错）。

### ③ `apk add "$WIFI_WPAD_PKG" $WIFI_PKGS` —— 一次装齐

```bash
WIFI_WPAD_PKG=wpad-mbedtls        # 00-lib.sh，可被环境变量覆盖
WIFI_PKGS="iw wifi-scripts"       # 同上
```

一次调用装 4 个（含自动依赖 `ucode-mod-digest`），让 apk 自己解依赖。
`|| die` 带上排障提示（binfmt / 网络）。

**噪音说明**：日志里会刷

```
WARNING: updating and opening https://downloads.immortalwrt.org/releases/25.12.2/packages/aarch64_generic/amlogic/packages.adb: unexpected end of file
ERROR: wget: exited with error 8
```

`amlogic` / `video` 两个 feed 在 armsr target 下不存在（404），apk 会报但**不影响安装**
（基础 rootfs 的 `distfeeds.list` 里带了这些通用 feed）。板上 `apk update` 也是同样输出，
属上游配置问题，不是我们的 bug。

### ④ `apk info` + `grep -qx` —— 兜底校验

```bash
printf '%s\n' "$INSTALLED" | grep -qx "$WIFI_WPAD_PKG" \
  || die "wpad 未换成 $WIFI_WPAD_PKG（当前：...）"
```

**理由（更正后的版本）**：`apk add` 冲突时是会 `exit 2` 的，上面 `|| die` 已经能拦住。
这道兜底防的是**另一种**情况——如果 ② 的 del 循环因为包名变化而空转，而基础 rootfs
里恰好又没有冲突的 wpad（比如上游改成了不带 hostapd 的组合），那 add 会"成功"，
但装上的可能不是我们想要的那个变体。这类失败的特征是 **CI 全绿、板上 5G 静默起不来**，
所以值得多花一次 `apk info`。

另外还校验三个文件确实落地：

```bash
for f in /sbin/wifi /usr/sbin/iw /lib/netifd/wireless/mac80211.sh; do
  [ -e "$ROOTFS_DIR$f" ] || die "包装上了但缺 $f（WIFI_PKGS 不对？）"
done
```

---

## 5. 刻意**不走** apk 的三样东西

| 东西 | 走什么路 | 为什么不用 apk |
|---|---|---|
| **WiFi 固件**（15 个文件，2.3 MB） | 20 步从 Radxa Debian rootfs 用 `tar --wildcards` 提取 → 40 步 ②c 落 `/lib/firmware/aic8800_fw/SDIO/aic8800D80` | 上游没有对应的 apk 包（固件在 Radxa 那边是随 DKMS 包 `aic8800-sdio` 分发的）。且路径必须与内核 `CONFIG_AIC_FW_PATH` **逐字一致**——驱动用 `filp_open` 直读、不走 `request_firmware`，路径错了是**静默失败** |
| **`/etc/config/wireless`** | `custom/rootfs/` overlay | 板级配置，不是发行版包内容。overlay 在 ③b **之后**应用，所以就算某个包自带同名文件也是我们的覆盖它 |
| **`wireless-regdb`** | **故意不装** | 见下面完整论证 |

### 5.1 为什么不装 `wireless-regdb`（完整论证）

起初的动机：内核日志里有

```
platform regulatory.0: Direct firmware load for regulatory.db failed with error -2
cfg80211: failed to load regulatory.db
```

看起来"装个包就少一条报错，还能让 `country 'CN'` 生效"。查下去发现**两头都不成立**：

**（1）装了也不起作用** —— 驱动自己管 regdomain

`vendor/aic8800/aic8800_fdrv/rwnx_mod_params.c`：

```c
COMMON_PARAM(custregd, true, true)      // ← 默认是 true
```

> 注意上游的 `MODULE_PARM_DESC(custregd, "... (Default: 0)")` 是**过时的**，与实际默认值
> 相反。我一开始就是被这行描述误导，以为默认关闭。

`custregd` 为真时：

```c
wiphy->regulatory_flags |= REGULATORY_WIPHY_SELF_MANAGED;
regulatory_set_wiphy_regd_sync(wiphy, getRegdomainFromRwnxDB(wiphy, default_ccode));
wiphy_err(wiphy, "** CAUTION: USING PERMISSIVE CUSTOM REGULATORY RULES **");
```

`REGULATORY_WIPHY_SELF_MANAGED` 意味着 **cfg80211 的 regdb 对这个 wiphy 不生效**，
`iw reg set CN` 也走驱动自己的规则。所以那条 CAUTION 就是板上看到的现象，
装 regdb 改变不了它。

**（2）装了也会被内核拒绝** —— 缺签名

```
CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y      # 构建产物 config-6.6.98-1-aw2607:2760
```

`net/wireless/reg.c`：

```c
static bool regdb_has_valid_signature(const u8 *data, unsigned int size)
{
        if (request_firmware(&sig, "regulatory.db.p7s", &reg_pdev->dev))
                return false;                       // ← p7s 缺失即判无效
        ...
}
static bool valid_regdb(...) { ... if (!regdb_has_valid_signature(...)) return false; ... }
```

而 ImmortalWrt 的包**只给 db、不给 p7s**：

```
$ apk info -L wireless-regdb
wireless-regdb-2026.05.30-r1 contains:
lib/apk/packages/wireless-regdb.list
lib/firmware/regulatory.db                        ← 只有这一个，6340 bytes
```

**（3）能不能从上游补 p7s？** 查过，不能直接用：

```
上游 wireless-regdb-2026.05.30.tar.xz:  regulatory.db  6380 bytes  sha256 2fb33ca0…
OpenWrt 包里的 regulatory.db:                          6340 bytes  sha256 2fc00dfa…
```

**字节不一致**（OpenWrt 自己重建过 regdb），而 p7s 签的是上游那份的字节 → 混用必然验签失败。
要成对就得两个文件都取上游，代价是引入 kernel.org 下载依赖 + 7.5 KB 二进制，
**收益是 0**（因为（1））。所以决定不装，并把理由写进 `00-lib.sh` 注释防止后人重踩。

---

## 6. apk 行为实测记录

### 6.1 冲突时的真实行为（板上实测）

```sh
# 当前已装 wpad-mbedtls，故意装冲突的 mesh 变体
# apk add wpad-mesh-mbedtls
ERROR: unable to select packages:
  wpad-mbedtls-2025.08.26~ca266cc2-r2:
    conflicts: wpad-mesh-mbedtls-2025.08.26~ca266cc2-r2[hostapd=2025.08.26~ca266cc2-r2]
               wpad-mesh-mbedtls-2025.08.26~ca266cc2-r2[wpa-supplicant=2025.08.26~ca266cc2-r2]
    satisfies: world[wpad-mbedtls]
  wpad-mesh-mbedtls-2025.08.26~ca266cc2-r2:
    conflicts: wpad-mbedtls-...[hostapd=...]
               wpad-mbedtls-...[wpa-supplicant=...]
    satisfies: world[wpad-mesh-mbedtls]
# echo $?
2
```

**结论**：apk **明确报错并返回 2**，什么都不装，原有包不受影响。
它不会像 `apt install` 那样自动替换冲突的 provider。

### 6.2 ⚠ 我当初的错误结论，以及成因（重点保留）

在提交 `31781ab` 里我写过：

> apk 不允许两个 provide hostapd 的包共存，`apk add wpad-mbedtls` 只会打印 conflicts
> 分析然后什么都不做（**且退出码不报错**），必须先 del。

**前半句对，括号里那句是错的。** 成因是观测方式：

```bash
apk add wpad-mbedtls 2>&1 | grep -vE "^WARNING|..." | tail -8
```

三重遮蔽：

1. **退出码被管道末端吃掉**——`$?` 拿到的是 `tail` 的 0，不是 apk 的 2（脚本没开 `pipefail`）
2. **`ERROR: unable to select packages:` 是首行**，被 `tail -8` 截掉了，只剩中间的 conflicts 明细
3. 我用的分隔符是 `;` 不是 `&&`，所以后面命令照常执行，看起来"一切正常"

于是"什么都没装 + 没有报错 + 后续照常" 被我错误归纳成 "apk 静默失败"。

**教训（写下来防止再犯）**：

- 判断一个命令的成败，**不要隔着管道看**；要么 `set -o pipefail`，要么先落盘再 `echo $?`
- `tail -N` 会截掉**开头的**错误摘要行，而很多工具（apk/apt/git）恰恰把结论放首行
- "后续步骤照常执行"不能推出"上一步成功了"，尤其在 `;` 分隔的脚本里

已提交 `86436ea` 更正 4 处（`00-lib.sh`、`40-assemble-rootfs.sh` ×2、制作记录坑 10），
并在文档里保留更正说明——**旧注释如果只删不改，后人可能照旧理解**。

### 6.3 换包 ≠ 换运行中的进程（板上实测）

装完 `wpad-mbedtls` 后 `wifi down; wifi up`，hostapd **仍然报 40 条 unknown configuration
item**。查：

```sh
# P=$(pidof hostapd); ls -l /proc/$P/exe
/usr/sbin/wpad (deleted)          ← 老进程还在跑已被删除的旧二进制
```

原因：netifd 不是每次都 fork 新 hostapd，而是通过 ubus 调 **`hostapd.add_iface`** 去找
**已在运行的守护进程**（错误信息 `hostapd.add_iface failed for phy phy0 ifname=phy0-ap0`
就是这个调用的返回）。`wifi down/up` 只拆建接口，**不重启守护进程**。

```sh
/etc/init.d/wpad restart     # ← 必须这个
# 之后 pid 变新，/proc/<pid>/exe → /usr/sbin/wpad（不再 deleted）
# 配置错误 0 条，AP-ENABLED，iw dev → channel 36 (5180 MHz), width: 80 MHz
```

**对构建流水线的影响：无**（构建期只是往 rootfs 里放文件，没有运行中的进程）。
但这条对**板上调试**极其关键——不知道它的人会以为"包装了没用"，进而怀疑包本身。

### 6.4 一个反直觉的假象：`ubus` 会报 `up: true`

hostapd `add_iface` 失败时：

```
ubus call network.wireless status  →  "up": true, "retry_setup_failed": false
iw dev                             →  Interface phy0-ap0 / type AP   ← 没有 channel 行！
```

**`ubus` 的 `up` 不代表射频在发。** 判断 AP 是否真的起来，只能看：

```sh
iw dev | grep -E "channel|width"        # 有 channel/width 才是真的在发
logread | grep AP-ENABLED               # hostapd 的状态机
cat /sys/class/net/phy0-ap0/operstate   # up
```

这条写在这里是因为它让我在 2.4G 阶段误以为"一切正常"，从而把芯片错判成单频。

---

## 7. 清理与产物

apk 在 chroot 里留下的痕迹**必须清掉，否则会被打进镜像**：

```bash
$SUDO rm -f  "$ROOTFS_DIR/tmp/resolv.conf"                              # §3.1 放进去的
$SUDO rm -rf "$ROOTFS_DIR/tmp/cache" "$ROOTFS_DIR/tmp/log"               # apk 自建
$SUDO rm -rf "$ROOTFS_DIR/etc/apk/cache"                                 # 下载的 .apk 缓存
```

（第一次做的时候漏了 `/tmp/cache`（1.4 MB）和 `/tmp/log`，是 `ls -la $MNT/tmp/`
看到时间戳才发现的。）

产物属主/权限（以 root 跑之后）：

| 项 | 值 | 备注 |
|---|---|---|
| `openwrt-a5e-rootfs.tar` | `root:root` `0644` | 显式 chmod，见 §3.3 |
| apk 装的文件 | `root:root` | 正确 |
| 基础 rootfs 的文件 | 保留 tarball 原属主 | 因为现在以 root 解包（非 root 解包会全压成 runner uid） |
| overlay 的文件 | `root:root` | 逐个 `chown -h 0:0`，见 §3.3 |

---

## 8. CI 断言：为什么放在 workflow 而不是脚本里

`.github/workflows/build.yml` 的"校验拼装产物"步骤，对 `openwrt-a5e-rootfs.tar`
做 **12 条断言**，其中 3 条与包相关：

```bash
chk  "lib/apk/packages/wpad-mbedtls\.list"   "wpad 是 full 版（含 802.11ac/ax）"
nchk "lib/apk/packages/wpad-mesh-"           "无 minimal 版 wpad 残留"
BAND=$(tar -xOf "$T" ./etc/config/wireless | grep -oE "option band '[0-9]g'" | head -1)
[ "$BAND" = "option band '5g'" ] || exit 1
```

**为什么用包 DB 文件（`lib/apk/packages/*.list`）作为证据**：它是 apk 自己写的、
代表"这个包在数据库里注册过"，比检查某个二进制文件更本质——二进制可能被别的包
provide，DB 条目不会骗人。

**为什么断言放在 workflow 而不是 40 脚本里**：40 脚本里已经有 `die` 兜底了，
但那是"过程中的自检"；workflow 的断言是**对最终产物（tar）的独立复核**，
两者互为冗余。这类失败的共同特征是**不报错**（固件缺失、包没装上、wpad 变体不对
都不会让构建失败），所以冗余是值得的。

**教训来源**：`rel-20261006-083917-r14` 就是一个"CI 全绿但 wlan 静默不在"的镜像
（`/lib/firmware` 完全是空的）。断言就是从那次事故之后加的。

---

## 9. 后续可深入的方向

按"收益 / 成本"排：

### 9.1 ⚠ 可复现性：包版本没有锁定（**最值得先做**）

现在 `apk add iw wifi-scripts wpad-mbedtls` **不带版本**，装的是仓库当时的最新：

```
iw                6.17-r1
wifi-scripts      1.0-r1
wpad-mbedtls      2025.08.26~ca266cc2-r2
ucode-mod-digest  2026.01.16~85922056-r1
```

而上游 ImmortalWrt 的 release feed（`releases/25.12.2/`）理论上应该是冻结的，
但 `packages.adb` 索引仍可能被重建。**后果**：同样的 commit 在不同时间构建，
产物可能不同——而 `OWRT_SHA` 只锁了基础 rootfs，锁不到我们后装的这几个包。

可选做法（按侵入性排序）：

1. **只记录不锁定**：装完后把解析到的版本写进 `owrt/build-info.env`（那里已经在记
   内核 release tag / rootfs 版本），至少做到**事后可追溯**
2. **显式 pin 版本**：`WIFI_PKGS="iw=6.17-r1 wifi-scripts=1.0-r1"`，升级时改一处
3. **离线安装**：把 `.apk` 缓存进仓/进 release 资产，`apk add --allow-untrusted /path/*.apk`
   —— 最彻底但引入二进制托管问题

我倾向 **1 + 2 组合**：pin 版本保证可复现，同时把实际解析结果记进 build-info
（pin 写错或仓库缺该版本时能立刻发现）。

### 9.2 从上游 rootfs 解决 wpad 变体

如果 `yzxiu/router` 的构建配置里直接把 wpad 换成 full 版，40 步的 `del`/`add`
就可以整段删掉。收益：少一次 apk 冲突处理、少一个"基础 rootfs 变了怎么办"的隐患。
成本：两仓耦合。

**判断依据**：如果 `yzxiu/router` 是我们完全掌控的、且只为 A5E 服务，就该在上游改；
如果它还服务别的板子（那些板子可能确实需要 mesh），就维持现状。

### 9.3 CI 每次联网下载包

`apk add` 在 CI 里要联网拉 `.apk`（约 2 MB）。可以缓存 `~/.cache/apk` 或
`/etc/apk/cache`，但收益很小（几秒），且引入缓存失效问题。**暂不做。**

### 9.4 `--no-cache` 的取舍

现在**没有**加 `--no-cache`，所以 apk 会把下载的包写进 `/etc/apk/cache`——
而我们在 §7 里又把它删掉了。等价于 `--no-cache` 但多了一次写盘。
可以直接加 `--no-cache` 让意图更清晰、少一次删除。**低优先级，纯清理。**

### 9.5 `apk add` 失败时的诊断还不够

现在 `|| die "chroot apk add 失败（查 binfmt / 网络）"`，但 apk 自己的输出已经打在
日志里了，所以够用。真要增强，可以在 die 之前把 `/etc/apk/repositories.d/*`、
`/etc/resolv.conf`、`apk update` 的结果一起打出来。**等真出问题再加，不预支复杂度。**

### 9.6 与"精简 initrd"那条线的关系

`libcrc32c: exports duplicate symbol crc32c (owned by kernel)` 那条报错和 apk 无关
（是 initramfs 里带的旧模块与 builtin 冲突），但它同属"镜像里的用户态资产与内核
config 不同步"这一类问题。如果将来做 initrd 精简，可以和 §9.1 的版本记录一起，
统一成一个"镜像内容清单 + 校验"的机制。

---

## 10. 相关提交索引

| commit | 内容 |
|---|---|
| `eafe1f9` | 首次引入 ③b（chroot+apk 装 `iw`/`wifi-scripts`）+ 9 条断言 |
| `d47c7c7` | binfmt 六级自愈 + 失败诊断（§3.2） |
| `6afcab5` | 40 步自提升到 root，修 tar Permission denied（§3.3） |
| `31781ab` | wpad 换 full 版 + 默认 5G/HE80 + 断言扩到 12 条（§4、§6.3） |
| `86436ea` | **更正** "apk 冲突静默成功" 的错误说法（§6.2） |

## 11. 一句话备忘

> apk 相关的失败**几乎都不会让构建失败**——它们表现为"CI 全绿、板上功能缺失"。
> 所以这条链上的每一处都必须有**独立的产物级断言**，而不是依赖命令的退出码。
