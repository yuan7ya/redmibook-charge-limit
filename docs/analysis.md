# 完整逆向与实测记录

本文是 [README](../README.md) 的详细版，保留分析过程、原始证据与走过的弯路。
所有命令均在实机执行，输出为原始粘贴。

| 项目 | 值 |
|---|---|
| 机型 | XIAOMI Redmi Book Pro 14 2024 (TM2307) |
| 主板 | TM2307 |
| BIOS | RMAMT4B0P0B0B (2025-06-10) |
| 内核 | 7.0.0-38-generic |
| 发行版 | Ubuntu 26.04 LTS |
| Secure Boot | disabled |
| 电池 | COSMX BX80，energy_full 70.813 Wh / design 76.99 Wh |

---

## 1. 问题起点

需求：**电池长期插电满电不好，希望在 Linux 下把充电限制在 80%。**

小米官方软件（小米电脑管家）在 Windows 下可以设置，但只有两档：不开 / 80%。
本机在 Linux 下没有任何 sysfs 阈值接口：

```console
$ ls /sys/class/power_supply/BAT0/ | grep -i charge
# 无 charge_control_end_threshold 等
```

---

## 2. 早期弯路：ACPI 反编译得出「不支持」

### 2.1 反编译

ACPI 表从 sysfs 拷出（`/sys/firmware/acpi/tables/`），用 `iasl -d` 反编译。
`WMAA` 定义位于 **SSDT20.dsl:314**：

```
Method (WMAA, 3, Serialized)
```

### 2.2 当时的误判

我们看到 `Case (0x1000)` 分支里有 `ECRD(SOH1)` / `ECRD(LONL)` / `ECRD(ADPW)`，
只当成「状态查询」读了一遍，于是断定：

> ~~本机固件不提供电池充电阈值能力~~

**这是错的。** 漏掉的关键是：`FUN3=0x02` 在**写**分支里同时是 `LONL` 的开关。

### 2.3 一次失败的探针

早期用 `acpi_call` 试调用，内核日志给出了决定性的结构信息：

```
ACPI: \_SB.PC00.WMID.WMAA: Excess arguments - Caller passed 4, method requires 3
ACPI BIOS Error (bug): AE_AML_BUFFER_LIMIT, Field [FUN4] at bit offset/length 48/32
    exceeds size of target Buffer (64 bits)
ACPI Error: Aborting method \_SB.PC00.WMID.WMAA due to previous error (AE_AML_BUFFER_LIMIT)
```

→ WMAA 需要 **3 个参数**，且 `Arg2` 的 `FUN4` 字段位于 bit offset 48、长 32 位，
所以 `Arg2` 至少要 **10 字节**。

**教训**：我们的探针脚本只检查返回值是否以 `Error` 开头，漏掉了 `dmesg` 里这条
决定性证据。查固件接口时 **dmesg 必须一起看**。

---

## 3. WMAA 完整规格

```
Method (WMAA, 3, Serialized)
```

### 3.1 参数与返回

```
CreateWordField  (Arg2, 0x00, FUN1)   // 2 字节
CreateWordField  (Arg2, 0x02, FUN2)   // 2 字节
CreateWordField  (Arg2, 0x04, FUN3)   // 2 字节
CreateDWordField (Arg2, 0x06, FUN4)   // 4 字节
// => Arg2 至少 10 字节

返回 Buffer RETS (0x20 = 32 字节):
CreateWordField  (RETS, 0x00, SGER)   // 状态
CreateWordField  (RETS, 0x02, FUTR)   // 回显功能码
CreateWordField  (RETS, 0x04, FRD0)   // 数据 0
CreateDWordField (RETS, 0x06, FRD1)   // 数据 1
CreateDWordField (RETS, 0x0A, FRD2)   // 数据 2
CreateDWordField (RETS, 0x0E, FRD3)   // 数据 3
```

### 3.2 调用约定

- `Arg0` 必须是 `0x01` —— 这是唯一被 `Switch` 处理的 Case。
  注意：**方法体内其实并未引用 `Arg0`**。
- `Arg1` = `FUN1`：
  - `0xFA00` — 读 (query)
  - `0xFB00` — 写 (set)
- `FUN2` 子命令：
  - `0x0800` — 风扇 / 性能模式
  - `0x0A00` — MIUT（静音/性能切换）
  - `0x1000` — **SOH1 / LONL / ADPW（含 80% 充电上限）**
  - 其他 → `SGER = 0xE000`（不支持）

### 3.3 FUN2 = 0x1000 分支（充电，SSDT20.dsl:390 读 / :505 写）

读（`FUN1 = 0xFA00`）：

```
FUN3==0x01 → FRD1 = ECRD(SOH1)                          // 电池健康度 %
FUN3==0x02 → FRD1 = (One & ECRD(LONL))                  // 充电上限开关 bit0
FUN3==0x03 → FRD1 = (ECRD(ADPW) >= 0x64) ? 0 : 1        // 适配器功率是否 < 100
```

写（`FUN1 = 0xFB00`，仅 `FUN3 == 0x02`）：

```
FUN4 == One → Local1 = (One | ECRD(LONL))
              ECWT(Local1, LONL)          // 只置 bit0 ← 关键
              SGER = 0x8000
否则        → Local1 = (One & Local0)
              Local2 = ~Local1
              Local3 = (ECRD(LONL) & Local2)
              ECWT(Local3, LONL)          // 只清 bit0
```

**要点：ACPI 表里除这一处外没有任何代码写 `LONL`；也没有任何代码写 `AFBC`。**
所以经固件通道设置的上限**固定就是 80%**，改不了别的百分比
（与小米官方软件只有「不开 / 80%」两档一致）。

### 3.4 其他 FUN2 分支（与充电无关，备查）

```
FUN2 = 0x0800（风扇）
  读: FUNR(0x16) 读 EC 字段 QFAN，映射为 FRD0 ∈ {1,2,3,4}
  写: FUN3==0x05 → ECWT(0x05, SMMD) + NTDP(5)
      FUN3==0x07 → ECWT(0x07, SMMD) + NTDP(6)
      其他       → ECWT(0, QFAN); QV20(1, 0x16)

FUN2 = 0x0A00（MIUT）
  写 FUN3==0x05: FUN4==1 → ECWT(0, MIUT) 否则 ECWT(1, MIUT); Sleep(0x96); QV20(1, 0x21)
  读: FRD1 = (MIUT == 1) ? 0 : 1
```

---

## 4. EC RAM 寄存器

`Field (ERAM)` 定义在 dsdt.dsl:41770（全 DSDT 唯一的 ERAM 定义，180 个具名字段）。

```
Offset (0x9F),
BTID  (0x9F)  PSC0 (0xA0)  PSC1 (0xA1)  PSC2 (0xA2)  PSC3 (0xA3)
LONL  (0xA4)   ← 充电上限开关，bit0 = 1 开启
AFBC  (0xA5)   ← 充电上限百分比（100 或 80，由 EC 固件自动改）
Offset (0xA7)  ← HBDA ...
```

其他电池相关字段：

- 电源/适配器：`ACIN BTIN BTST FCST PWRV ADPW`
- 遥测只读：`BTSN BTDC BTDV BTFC BTTP BTCT BTPR BTVT`
- 容量/健康：`RSOC SOH1 UCBT BTCC BATM MFGD BATT`
- 状态标志：`HBDA HBNT SEGM FEST CSSD`

> **偏移陷阱**：`AFBC` 在 `0xA5`，其后直接 `Offset(0xA7)`，`0xA6` 未命名。
> 早期版本误把 `0xA4` 当成「配套字段」，它其实是 `LONL` 本身 —— 这个错误
> 直接导致了下面第 5 节的失败实验。

EC 访问经 `Q_EC` 设备（`_HID PNP0C09`，I/O 端口 0x62/0x66）；
读 `ECRD` / 写 `ECWT` 用 `ECMT` 互斥锁。

### 4.1 一条没走通的路：ECCC 通用命令通道

DSDT 里有个通用 EC 命令入口 `ECCC`（dsdt.dsl:42192）：

```
Method (ECCC, 4, Serialized)
{
    Local0 = Acquire (ECMT, 0x07D0)
    If ((Local0 == Zero))
    {
        DAT0 = Arg1
        DAT1 = Arg2
        DAT2 = Arg3
        CMDB = Arg0          // 直接下发任意命令码
        ...等待 CMDB == 0...
    }
}
```

`CMDB`/`STAT`/`DAT0`-`DAT9` 位于共享内存
`OperationRegion (SMA2, SystemMemory, 0xFE0B0A00, 0x0100)`，
即 **EC 固件轮询的内存块**，不是 EC 端口。

**全 DSDT 里 `ECCC` 的调用点为零** —— 是固件留给厂商工具的接口。
我们没走这条路，因为不知道命令码语义，风险高于收益。

---

## 5. 失败的实验：直写 EC 的 0xA4 / 0xA5

在找到 WMAA 通道之前，我们试过直接写 EC 寄存器。

### 5.1 动机

在 Windows 用 RW-Everything 抓了两份 256 字节 EC 快照对比：

| 寄存器 | 关闭时 | 开启 80% 时 |
|---|---|---|
| `0xA4` | `0x00` | `0x31` (49) |
| `0xA5` | `0x64` (100) | `0x50` (80) |

于是（错误地）把这两个字节当成「开关 + 百分比」直接写。

### 5.2 第一轮：写 `0xA4=0x31` + `0xA5=80`

**结果：电池 75% 就完全不充电。**

```
status = Not charging
power_now = 0
capacity = 75
ADP1 online = 1        ← 插着电源
```

### 5.3 对照实验（决定性）

写回原值（`0xA4=0x00, 0xA5=100`）后，同样 75%、同样插电：

```
status = Charging
power_now = 65400000 uW    ← ≈ 65 W
capacity 75 → 76
```

→ **EC 确实读这两个字节并据此控制充电**，写入是有效的，但**整字节写入的语义错了**。

### 5.4 第二轮：只写 `0xA5=80`，`0xA4` 保持 `0x00`

```
77% → 78% → 79% → 80% → 81%     全程 Charging ~66 W
```

**完全无效，冲过 80% 不停。** → `0xA4` 确实是必需的。

### 5.5 结论与自我纠正

**不要直写 EC。** 走 WMAA。

> 关于 75% 停充，我们**当时**归因于「`0x31` 的 bit4/bit5 污染了其他功能位」。
> **这个解释是错的**：后来经 WMAA 正规通道开启后，实测 `LONL` 同样读到 `0x31`，
> 与 Windows 小米软件开启时的 `0xA4=0x31` 完全一致 —— 说明 `0x30` 是
> 「上限开启」状态的正常组成部分，不是写坏的。
> 直写失败的确切成因待考，可能是两字节写入的时序与固件不同。
> **结论不变：不要直写 EC。**

### 5.6 顺带踩的坑

`ec_sys` 模块的 debugfs 节点默认只读，`open(node,'wb')` / `pwrite` /
`lseek`+`write` 全部返回：

```
OSError: [Errno 22] Invalid argument
```

根因是 `ec_sys` 模块参数 `write_support` **默认为 0**，驱动层直接拒绝：

```bash
sudo modprobe -r ec_sys && sudo modprobe ec_sys write_support=1
```

（只是要知道原因；**现在仍然不建议写**。）

---

## 6. 转折点：内核邮件列表的外部证据

本地反编译已经得出「不支持」的错误结论，于是改为向外搜索 —— 这一步解开了问题。

**Linux 内核邮件列表**，Anton Karasev，2026-10-08，
*"bitland-mifs-wmi: battery charge limit (command 0x10) on Xiaomi models"*：
<https://lists.openwall.net/linux-kernel/2026/10/08/1628>

**他逆向的正是 TM2307 和 TM2309** —— 与我们同款主板。要点（含原文引述）：

- "command 0x10 ... is the battery interface of WMAA, and its subcommand 2 is
  the firmware's 80 % charge limit"
- `GET 0x10/1` → EC 寄存器 **SOH1**（电池健康度）
- `GET 0x10/2` → 充电上限：**1 = 开，0 = 关（EC `LONL` 的 bit 0）**
- `GET 0x10/3` → 1 if EC register **ADPW < 0x8C**
- `SET 0x10/2` → **value 1 sets bit 0 of LONL, any other value clears it**
- **"nothing else in the ACPI tables touches LONL"**
- **"With AC connected, setting the bit makes the EC change register AFBC from
  100 to 80; nothing in the ACPI tables writes AFBC, so through the firmware the
  limit is fixed at 80 %"**
- 他的实测：「Charging stopped at 80 % ("Not charging"), switching the bit at
  80 % toggled charging within about a second, and turning it on at 81 %
  stopped charging without discharging. The setting survived charger replugs,
  s2idle and about 17 hours on AC, **but not the battery running flat**.」

这与我方 ACPI 表**逐条吻合** —— 也直接解释了为什么写 `0xA5` 没用（EC 自己会改它）。

> **教训（最重要的一条）**：本地反编译说「不可能」时，**先去找同款硬件的既有证据**，
> 比自己继续深挖更有价值。解开这个问题靠的不是更深的反编译，而是外部一条同款主板的记录。

### 6.1 邮件里其他机型的信息（仅供参考，未验证）

- TM2309：`0xA7` 未使用且读 0
- Xiaomi Book Pro 14 (TM2424)：`0x10/2` 接受 level code，支持 40%–80%
- TM2424 的其他工具记录：向 EC offset **`0xA7`** 写百分比
  （CoreCharge 则在 `0xA4` bit0 切换上限 + 向 `0xA7` 写百分比）
- **TM2113（Redmi Book Pro 15 2022 Ryzen）不实现 `0x10`**

### 6.2 上游态度

邮件里明确：「please do not write to command 0x10 on Xiaomi machines for now,
kb_mode included」—— 因为 `0x10` 在原驱动里被用作 RGB 键盘模式，
直接占用会打架。作者主张按 power-supply ABI 用 `charge_types`
（"Standard"/"Long Life"）而不是 `charge_control_end_threshold`，
因为上限**固定 80%**，不是任意阈值。

**本仓库是用户态方案，不修改内核驱动**，因此不受这个冲突影响。

---

## 7. 成功：走通 WMAA

### 7.1 只读确认通道

```console
$ sudo ./scripts/wmaa-charge-limit.sh status
=== 读取充电上限开关 (WMAA 0x1000/2) ===
  调用: WMAA 0x1 0x1 {0x00,0xFA,0x00,0x10,0x02,0x00,0x00,0x00,0x00,0x00}
  原始返回: 0x0, 0x80, 0x0, 0x10, 0x2, 0x0, 0x0, 0x0, 0x0, 0x0
  SGER = 0x8000  (成功)
  FUTR = 0x1000
  FRD0 = 0x0002 (子命令)
  FRD1 = 0x00000000 (返回值)

  → 充电上限: 【已关闭】

=== 读取电池健康度 (WMAA 0x1000/1) ===
  SOH1 = 94%  (电池健康度)
```

### 7.2 开启

```console
$ sudo ./scripts/wmaa-charge-limit.sh on
=== 开启 80% 充电上限 ===
  原始返回: ...
  SGER = 0x8000  ✓ 成功
...
  → 充电上限: 【已开启】
```

### 7.3 EC 层确认

```console
$ sudo ./scripts/ec-verify-limit.sh
  LONL (0xA4) = 0x31   bit0 = 1  -> 上限开关 开
  AFBC (0xA5) = 0x50 (80)  -> 充电上限百分比
  ✓ AFBC=80，固件已把上限设为 80%
  ...
  status=Not charging  capacity=89  power_now=0  ADP1 online=1
```

**`AFBC` 被 EC 固件自主从 100 改成 80** —— 与邮件描述一致，也证明无需写 `0xA5`。

### 7.4 行为验证（决定性）

```console
$ ./scripts/observe.sh 20 40
21:26:30  Charging      78%   66359000 uW   ← 充电中
21:26:50  Charging      79%   66595000 uW
21:27:10  Charging      79%   66660000 uW   ← 66 W 全速
21:27:30  Not charging  80%          0 uW   ← 到 80% 干净切断
21:27:50  Not charging  80%          0 uW
21:29:30  Not charging  80%          0 uW
```

**66 W → 0 W 恰好发生在 80%，且不放电。**
对照第 5.4 节可知：无上限时同样条件会冲过 80%。因此这排除了
「高电量自然停充」的可能。

### 7.5 开机自启

EC 每次冷启动重置，所以由 systemd 服务开机下发（详见 README）。
重启后验证：

```
uptime:        up 5 minutes
Active:        active (exited)
ExecStartPre:  modprobe acpi_call          status=0/SUCCESS
ExecStart:     apply-limit-wmaa.sh on      status=0/SUCCESS
journal:       [OK] 80% 充电上限已开启 (LONL bit0=1, AFBC→80)
当前:          Not charging / 80% / 0 uW / 适配器在线
```

---

## 8. 修正记录

- **2026-10-09 初版**：结论「本机固件不提供电池充电阈值能力」，
  并据此建议「无法在 Linux 下设置 80% 上限」。**错误。**
- **2026-10-09 二次修正**：直写 EC 成功但行为错误（75% 停充），
  当时归因于「bit4/bit5 污染」。**该归因后经证实也是错的。**
- **2026-10-10 定稿**：经内核邮件列表交叉验证 + WMAA 实机调用确认，
  `Case(0x1000)/FUN3=0x02` 就是充电上限开关，实机已成功开启并验证行为。
  EC 偏移修正为 `0xA4=LONL`（bit0 开关）、`0xA5=AFBC`（百分比）。
  结论：**走 WMAA，不直写 EC。**
