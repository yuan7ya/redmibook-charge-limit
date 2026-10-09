#!/bin/bash
# 一次性抓取 EC + 电池 + 内核 的完整状态
set -uo pipefail
NODE=""
for p in /sys/kernel/debug/ec/ec0/io /sys/kernel/debug/ec0/io; do
  [[ -e "$p" ]] && { NODE="$p"; break; }
done

echo "=== 时间 ==="
date '+%Y-%m-%d %H:%M:%S'

if [[ -n "$NODE" ]]; then
  echo
  echo "=== EC 关键寄存器 ==="
  python3 - "$NODE" <<'PY'
import sys, os
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    d = os.pread(fd, 0x100, 0)
finally:
    os.close(fd)
for a in (0xA4, 0xA5):
    print(f"  0x{a:02X} = 0x{d[a]:02X} ({d[a]})")
print(f"  0xA5 解读: {'未限制 100%' if d[0xA5]==100 else f'限制 {d[0xA5]}%'}")
PY
else
  echo "=== EC 节点不存在（ec_sys 未加载）==="
fi

echo
echo "=== 电池 ==="
for a in status capacity power_now voltage_now energy_now energy_full; do
  printf '  %-12s = %s\n' "$a" "$(cat /sys/class/power_supply/BAT0/$a 2>/dev/null)"
done

echo
echo "=== 适配器 ==="
printf '  online = %s\n' "$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)"

echo
echo "=== 内核近期消息 ==="
dmesg 2>/dev/null | tail -30 | grep -iE "ec_|acpi|bat|charg" || echo "  （无）"
