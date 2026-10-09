#!/bin/bash
# 观察电池状态变化，帮助判断 80% 上限是否生效
# 用法: ./observe.sh [间隔秒] [次数]
set -uo pipefail
INTERVAL="${1:-30}"
COUNT="${2:-10}"

echo "监控 BAT0 状态，每 ${INTERVAL}s 一次，共 ${COUNT} 次"
echo "时间      status        capacity  power_now  电压"
echo "---------------------------------------------------------"

prev_cap=""
for ((i=1; i<=COUNT; i++)); do
  st=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)
  cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
  pw=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null)
  v=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null)
  ac=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)

  mark=""
  [[ "$cap" != "$prev_cap" && -n "$prev_cap" ]] && mark="  ← 变化"
  [[ "$ac" == "0" ]] && mark="$mark  [电池供电]"

  printf '%-8s  %-12s  %-8s  %-10s  %s%s\n' \
    "$(date +%H:%M:%S)" "$st" "$cap%" "${pw}uW" "${v}uV" "$mark"
  prev_cap="$cap"

  [[ $i -lt $COUNT ]] && sleep "$INTERVAL"
done

echo
echo "=== 判读 ==="
echo "  · 若放电到 <80% 后插电，capacity 停在 80 不再上升 → 上限生效"
echo "  · 若继续充到 81,82...100 → 未生效"
