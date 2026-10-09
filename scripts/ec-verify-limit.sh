#!/bin/bash
# 只读验证 80% 充电上限是否真正生效
# 检查: EC 的 LONL(0xA4) bit0 与 AFBC(0xA5)，以及电池/适配器状态
set -uo pipefail
NODE=""
for p in /sys/kernel/debug/ec/ec0/io /sys/kernel/debug/ec0/io; do
  [[ -e "$p" ]] && { NODE="$p"; break; }
done

echo "=== 时间 ==="
date '+%Y-%m-%d %H:%M:%S'

if [[ -n "$NODE" ]]; then
  echo
  echo "=== EC 寄存器 (LONL / AFBC) ==="
  python3 - "$NODE" <<'PY'
import sys, os
fd=os.open(sys.argv[1], os.O_RDONLY)
try:
    d=os.pread(fd, 0x100, 0)
finally:
    os.close(fd)
lonl, afbc = d[0xA4], d[0xA5]
print(f"  LONL (0xA4) = 0x{lonl:02X}   bit0 = {lonl & 1}  -> 上限开关 {'开' if lonl & 1 else '关'}")
print(f"  AFBC (0xA5) = 0x{afbc:02X} ({afbc})  -> 充电上限百分比")
if lonl & 1:
    print(f"  → 上限已开启，EC 认为应限制在 {afbc}%")
    if afbc == 80:
        print("  ✓ AFBC=80，固件已把上限设为 80%（与内核邮件描述一致）")
    else:
        print(f"  ⚠ AFBC={afbc}，不是预期的 80，需要留意")
else:
    print("  → 上限未开启（AFBC 通常为 100）")
print(f"  (参考: LONL 全字节 0b{lonl:08b}，bit0 以外的位不属于上限开关)")
PY
else
  echo "=== EC 节点不存在，请先: sudo modprobe ec_sys ==="
fi

echo
echo "=== 电池 ==="
for f in status capacity capacity_level power_now voltage_now energy_now energy_full energy_full_design cycle_count health; do
  p="/sys/class/power_supply/BAT0/$f"
  [[ -e "$p" ]] && printf '  %-20s %s\n' "$f" "$(cat "$p" 2>/dev/null)"
done

echo
echo "=== 适配器 ==="
for p in /sys/class/power_supply/A*/online /sys/class/power_supply/A*/uevent; do
  [[ -e "$p" ]] && { echo "  $p:"; sed 's/^/    /' "$p"; }
done

echo
echo "=== 判定 ==="
cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
st=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
pw=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null)
if [[ -n "$cap" && -n "$st" ]]; then
  echo "  电量 ${cap}%, 状态 ${st}, 功率 ${pw:-?} uW"
  if [[ "$st" == "Not charging" || "$st" == "Full" ]]; then
    if [[ "${cap:-0}" -ge 79 && "${cap:-0}" -le 81 ]]; then
      echo "  ✓ 停在 80% 附近且未充电 —— 上限正在起作用"
    else
      echo "  ? 未充电但电量 ${cap}%，需结合 LONL 判断（可能是上限未开或电池满）"
    fi
  elif [[ "$st" == "Charging" && "${cap:-0}" -ge 80 ]]; then
    echo "  ✗ 电量已 ${cap}% 仍在充电 —— 上限未生效"
  elif [[ "$st" == "Discharging" ]]; then
    echo "  ! 正在放电（适配器未供电？）"
  else
    echo "  充电中 ${cap}%，尚未到 80%，继续观察"
  fi
fi
