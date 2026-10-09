#!/bin/bash
# 通过固件正规通道 WMAA 开启 80% 充电上限（开机自动下发用）
# 原理: WMAA FUN1=0xFB00(写) FUN2=0x1000 FUN3=0x02 FUN4=1
#      固件内部执行 One | ECRD(LONL) -> ECWT(LONL)，只置 bit0，不碰其他位
#      置上后 EC 固件自己把 AFBC 从 100 改成 80
# 用法: sudo ./apply-limit-wmaa.sh [on|off]   默认 on
set -uo pipefail

CALL=/proc/acpi/call
MODE="${1:-on}"

case "$MODE" in
  on)  FUN4=1 ;;
  off) FUN4=0 ;;
  *) echo "用法: $0 {on|off}" >&2; exit 2 ;;
esac

# 1) 确保 acpi_call 已加载
if ! grep -q '^acpi_call' < <(lsmod); then
  /usr/sbin/modprobe acpi_call 2>/dev/null
  sleep 1
fi
if [[ ! -e "$CALL" ]]; then
  echo "[FAIL] $CALL 不存在（acpi_call 未加载？）"
  exit 1
fi

# 2) 下发 WMAA 写命令
arg2=$(printf '{0x00,0xFB,0x00,0x10,0x02,0x00,0x%02X,0x00,0x00,0x00}' "$FUN4")
printf '%s\n' "\\_SB.PC00.WMID.WMAA 0x1 0x1 ${arg2}" > "$CALL" 2>/dev/null || {
  echo "[FAIL] 写入 $CALL 失败"; exit 1; }
resp=$(cat "$CALL" | tr -d '\000')

# 3) 解析 SGER
sger=$(python3 - "$resp" <<'PY'
import sys, re
v=[int(x,16) for x in re.findall(r'0x[0-9A-Fa-f]{1,2}', sys.argv[1])]
print(f"{v[0]|(v[1]<<8):04X}" if len(v)>=2 else "0000")
PY
)
if [[ "$sger" != "8000" ]]; then
  echo "[FAIL] WMAA 返回 SGER=0x$sger（应为 0x8000）"
  exit 1
fi

# 4) 回读确认
sleep 1
printf '%s\n' "\\_SB.PC00.WMID.WMAA 0x1 0x1 {0x00,0xFA,0x00,0x10,0x02,0x00,0x00,0x00,0x00,0x00}" > "$CALL"
r2=$(cat "$CALL" | tr -d '\000')
cur=$(python3 - "$r2" <<'PY'
import sys, re
v=[int(x,16) for x in re.findall(r'0x[0-9A-Fa-f]{1,2}', sys.argv[1])]
print(v[6] if len(v)>=10 else -1)
PY
)
if [[ "$cur" != "$FUN4" ]]; then
  echo "[FAIL] 回读 FRD1=$cur，期望 $FUN4"
  exit 1
fi

if [[ "$MODE" == "on" ]]; then
  echo "[OK] 80% 充电上限已开启 (LONL bit0=1, AFBC→80)"
else
  echo "[OK] 充电上限已关闭 (LONL bit0=0, AFBC→100)"
fi
exit 0
