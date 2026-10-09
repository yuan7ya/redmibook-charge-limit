#!/bin/bash
# 对照实验：在当前电量下，通过开关上限观察充电行为是否随之改变
# 这是证明"上限真的在起作用"最直接的证据
set -uo pipefail

CALL=/proc/acpi/call
read_bat() {
  printf '  电量 %s%%  状态 %-14s 功率 %s uW\n' \
    "$(cat /sys/class/power_supply/BAT0/capacity)" \
    "$(cat /sys/class/power_supply/BAT0/status)" \
    "$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null)"
}
wmaa() {  # $1=FUN4
  printf '%s\n' "\\_SB.PC00.WMID.WMAA 0x1 0x1 {0x00,0xFB,0x00,0x10,0x02,0x00,0x0$(printf '%X' "$1"),0x00,0x00,0x00}" > "$CALL"
  cat "$CALL" | tr -d '\000' >/dev/null
}
read_ec() {
  python3 - /sys/kernel/debug/ec/ec0/io <<'PY'
import sys, os
d=os.pread(os.open(sys.argv[1], os.O_RDONLY), 0x100, 0)
print(f"  LONL(0xA4)=0x{d[0xA4]:02X} bit0={d[0xA4]&1}   AFBC(0xA5)={d[0xA5]}")
PY
}

echo "############ 对照实验 ############"
echo
echo "[初始状态]"
read_ec; read_bat

echo
echo "[A] 关闭上限 (FUN4=0)，等 5 秒看是否开始充电"
wmaa 0
sleep 5
read_ec; read_bat

echo
echo "[B] 重新开启上限 (FUN4=1)，等 5 秒看是否停止充电"
wmaa 1
sleep 5
read_ec; read_bat

echo
echo "############ 解读 ############"
echo "  若 A 变为 Charging/功率>0、B 变回 Not charging/0  -> 上限确实在实时控制充电 ✓"
echo "  若 A、B 都保持 Not charging                    -> 本电量下看不出差别，需放电到 80% 以下再测"
echo "  若 A、B 都保持 Charging                        -> 上限未生效 ✗"
