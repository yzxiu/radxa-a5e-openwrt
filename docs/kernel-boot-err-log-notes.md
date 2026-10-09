# A5E 内核启动 ERR 日志逐条定性（v0.1.0 实测）

> 适用：radxa-a5e-openwrt v0.1.0（kernel 6.6.98-1-aw2607，AW BSP 7139763e7b），
> 板 Cubie A5E（sun55iw3）。来源：2026-10-09 两块板（p3 槽 OTA 后）串口/dmesg 实测。
>
> **结论先行：全部为全志 BSP 常规噪音，无一影响功能，与镜像组装/双槽脚本无关。**
> WiFi(aic8800)/eth/双槽挂载/loop 设备实测全部正常。官方 RadxaOS 同源 BSP，
> 启动同样打印这些 ERR——判据是"官方也打"，不是"我们打"。

---

## 功能面实测快照（打 ERR 的同一块板）

```
WiFi:    phy0 + phy0-ap0 UP（aic8800 固件加载成功, SDIO 150MHz 协商）
网口:    eth1 UP（eth0 无网线 NO-CARRIER 正常）
存储:    /dev/mmcblk1p3 挂 /，p1→/boot，p4→/mnt/shared
loop:    loop0-7 存在（CONFIG_BLK_DEV_LOOP=y 生效）
uci-defaults: 空（全部成功自删）
```

## ERR 分类总表

| # | 日志关键字 | 来源模块 | 条数级 | 定性 | 影响功能 |
|---|---|---|---|---|---|
| 1 | `smc 0 p2 err, cmd 1, RTO`（4022000） | sdmmc（SD 卡槽） | ~150 刷屏 | 空 SD 卡槽探测重试 | 无（插卡即消） |
| 2 | `smc 2 p1 err, cmd 52/7, RTO`（4021000） | sdmmc（SDIO WiFi） | ~60 | WiFi SDIO 初始化早期暂败，驱动重试后成功 | 无（6.4s 后固件加载 OK） |
| 3 | `libcrc32c: exports duplicate symbol crc32c` | 内核 module loader | 1 | 内核 config 小瑕疵：builtin 与模块重复导出 | 无（纯警告，不阻模块） |
| 4 | `unknown pin`（pin-2000000.pinctrl） | pinctrl | ~10 | DTS 引用了不存在的 pin 名 | 无 |
| 5 | `failed to find dram_clk` / `NSI no topo` / `ccu-ng` | BSP 时钟/拓扑框架 | 各 1-6 | 性能监控/DVFS 探测噪音 | 无 |
| 6 | `axp2101-6-0036: Unable to match OF ID` | PMIC（副 0x36） | 1 | 双 PMIC 板设计：0x36 无 DT 匹配属正常 | 无（0x34 主 PMIC loaded） |
| 7 | `axp2202_battery not configed` / `bldo1 Restricting voltage` / `rfkill wlan power set voltage failed` | PMIC/rfkill | 各 1-13 | 无电池设计 + WiFi 供电走 aicbsp 自管理 | 无（WiFi 实测 UP） |
| 8 | `sunxi-hdmi` / `drm offline mode` / `dw-pcie` / `irrx` / `inno-combphy select3v3` | 未使用外设 | 各几条 | HDMI 未接/PCIe 空槽/红外未配/供电 dummy | 无 |

---

## 逐条详解

### #1 SD 卡槽空槽探测刷屏（量最大）

```
sunxi:sunxi_mmc_host-4022000.sdmmc:[ERR]: smc 0 p2 err, cmd 1, RTO !!
...（重复 ~150 条）
sunxi:sunxi_mmc_host-4022000.sdmmc:[ERR]: retry:set phase failed or over retry times
sunxi:sunxi_mmc_host-4022000.sdmmc:[ERR]: retry:give up
```

- 4022000 = sdmmc2/SD 卡槽（4020000=eMMC 所在 sdc0 不支持 tuning 属正常提示，
  4021000=SDIO WiFi）。cmd 1 = SDIO 协议 `IO_SEND_OP_COND`。
- 全志 BSP sdmmc 驱动对**无卡的槽**会持续发探测命令，超时（RTO）后重试到上限。
- **验证方法**：插入一张 SD 卡，`dmesg | tail` 应出现 `mmc2: new high speed card`
  类消息且刷屏停止。
- 同类前导噪音（同槽）：`Could not get mbus/store/msi_lite clock`——BSP 驱动
  对可选时钟的 devm_clk_get 失败打印，A5E 的 DT 未提供，无影响。

### #2 WiFi SDIO 初始化早期 RTO（自愈型）

```
sunxi:sunxi_mmc_host-4021000.sdmmc:[ERR]: smc 2 p1 err, cmd 52, RTO !!
sunxi:sunxi_mmc_host-4021000.sdmmc:[ERR]: smc 2 p1 err, cmd 7, RTO !!
...
（数秒后）
rwnx_load_firmware :firmware path = .../aic8800D80/fw_patch_8800d80_u02_ext0.bin
aicbsp: aicbsp_get_feature, set FEATURE_SDIO_CLOCK 150 MHz
```

- aic8800 WiFi 上电时序慢于 mmc 控制器探测：早期 cmd52/cmd7 超时，aicbsp
  驱动完成供电/复位后重试成功。
- **判定依据**：同一段 dmesg 内固件加载 + `phy0-ap0` UP，链路已通。
  6.4s 附近的 `axp2202-bldo1: Restricting voltage` + `rfkill set power failed`
  也属此时序（见 #7）。

### #3 libcrc32c 重复导出（唯一真正"我们的"问题，可选修）

```
libcrc32c: exports duplicate symbol crc32c (owned by kernel)
```

- 根因：内核 config 把 `CONFIG_LIBCRC32C=y`（builtin，符号 crc32c 已归内核），
  同时树里另有模块（crc32c_generic 等）导出同名符号。任何模块 insmod 时
  module loader 都会提示一次。
- **无功能影响**（不阻止 aic8800 等模块加载），纯日志噪音。
- 若要消除：kernel 仓 `configs/a5e-openwrt.config` 将 `CONFIG_LIBCRC32C=y`
  改为 `=m` 或删除（走模块路径）。属锦上添花，建议下次内核例行更新顺手做。

### #4 pinctrl unknown pin

```
sunxi:pin-2000000.pinctrl:[ERR]: unknown pin
```

- BSP 基础 dtsi 与板级 DTS 的 pin 名不匹配（引用了 sun55i 平台未定义的
  pin 配置）。10 条全部在 2.3s 早期初始化阶段，之后无追加。
- 判定：非我们改动引入（我们只改内核 config 与 aic8800 驱动日志级别，
  未动 DTS/pinctrl）。

### #5 BSP 时钟/拓扑框架探测噪音

```
sunxi:ccu_ddr-2001000.clk_ddr:[ERR]: failed to find dram_clk
NSI_PMU 2020000.nsi-controller: no topo process for clk path type:0
no topo process for topo type:0
NSI_PMU ... Get ra_pmu_data_unit failed / Get ia_pmu_data_unit failed
sun50i_cpufreq_nvmem:[ERR]: failed to get dcxo clock source
```

- dram_clk 仅在 DRAM DVFS/频率调节路径使用；NSI/PMU 是性能监控单元未配置；
  dcxo 时钟源缺失只影响 nvmem 读频点兜底路径。均为探测期一次性打印。
- 所有 sun55i BSP 内核标准输出，官方镜像同样打印。

### #6 副电源管理芯片探测失败（设计如此）

```
sunxi:axp2101-6-0036:[ERR-1944977408]: Unable to match OF ID
```

- A5E 是双 PMIC：I2C1 总线 6-0034（AXP2202 主）+ 6-0036（副）。DT 只为
  0x34 提供 compatible 匹配；驱动扫总线到 0x36 找不到匹配 → 打印后跳过。
- 紧随其后的 `AXP20x variant AXP2202 found` / `AXP20X driver loaded` 证明
  主 PMIC 正常。`axp2101-pek DMA mask not set` 同属无害提示。

### #7 电池/WiFi 供电路径提示

```
sunxi:axp2202_battery:[ERR]: axp2202-battery device is not configed
axp2202-bldo1: Restricting voltage, 3300000-1800000uV
sunxi-rfkill soc@3000000:rfkill: wlan power[0] (axp2202-bldo1) set voltage failed
sunxi-rfkill soc@3000000:rfkill: get gpio chip_en failed
```

- A5E 无电池，battery 驱动报"未配置"即退出，正常。
- bldo1 电压窗口（1.8-3.3V）与 rfkill DTS 要求（3.3V）冲突 → rfkill 供电
  路径失败。**WiFi 实际由 aicbsp 驱动自管理上电序列**，不走 rfkill 路径，
  phy0-ap0 UP 为证。`get gpio chip_en failed` 同理（未定义该 GPIO）。

### #8 未使用外设的探测噪音

```
[drm:commit_init_connecting] *ERROR* offline mode: init connecting not found
sunxi-dw-pcie 4800000.pcie: Phy link never came up
sunxi:irrx-2005000.irrx:[ERR]: ... get ir protocol failed
inno-combphy 4f00000.phy: get select3v3-supply fail
sunxi-rfkill: get gpio chip_en failed
```

- HDMI（未接显示器/未配显示拓扑）、PCIe（空槽，Phy link 不上来属预期）、
  红外（未配置协议）、combphy（3v3 供电 dummy regulator）。全为"外设不在/
  未用"的一次性打印。

---

## 与双槽/镜像链路的交叉排除

排查时特别核对过（均正常，证明 ERR 与 v0.1.0 镜像/脚本无关）：

- 根分区按 UUID 挂载正确（p3），`/boot`、`/mnt/shared` 挂载正常；
- `uci-defaults` 目录空（首启全部成功自删）；
- `loop0-7` 存在（CONFIG_BLK_DEV_LOOP=y，r21 内核修复生效）；
- vfat builtin（/boot 为 vfat 挂载，无模块加载日志）；
- aic8800 固件路径/加载正常（r74 起 WiFi 固件已入 rootfs）。

## 处置建议

1. **保持现状**：全量日志利于后续排查，不建议 loglevel 压制。
2. 唯一可选优化：#3 libcrc32c（kernel 仓 config 改 `=m`），等内核例行更新
   顺手处理；改前回归验证 aic8800/target 等模块仍正常。
3. SD 卡槽(#1)刷屏若碍眼可插卡验证后忽略。
