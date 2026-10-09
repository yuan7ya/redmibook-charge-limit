#!/bin/bash
# 通过固件正规通道 WMAA 控制充电上限
# 适用: 小米 Redmi Book Pro 14 2024 (TM2307) / 15 2023 (TM2309) 等
#
# 依据 Linux 内核邮件列表 (Anton Karasev, 2026-10-08) 对 TM2307/TM2309 WMAA 的逆向,
# 并经本机 (TM2307) 实测确认:
#
#   WMAA(Arg0=1, Arg1=1, Arg2={FUN1,FUN2,FUN3,FUN4})
#   FUN1=0xFB00 写 / 0xFA00 读
#   FUN2=0x1000 充电子命令
#      FUN3=0x01 -> 读 SOH1 (电池健康度)
#      FUN3=0x02 -> 读/写 LONL bit0 (充电上限开关)
#          FUN4=1 开启, 其他 关闭
#      FUN3=0x03 -> 读适配器功率是否 <0x64
#   返回 SGER=0x8000 成功
#
# 固件内部执行 One | ECRD(LONL) -> ECWT(LONL)，只置 bit0；置上后 EC 固件
# 自己把 AFBC 从 100 改成 80。因此经此通道设置的上限**固定为 80%**。
#
# 用法:
#   sudo ./wmaa-charge-limit.sh status   # 读当前开关与健康度
#   sudo ./wmaa-charge-limit.sh on       # 开启 80% 上限
#   sudo ./wmaa-charge-limit.sh off      # 关闭上限
set -uo pipefail

CALL=/proc/acpi/call
MOD=acpi_call

ensure() {
  if [[ ! -e "$CALL" ]]; then
    modprobe "$MOD" 2>/dev/null || { echo "[FAIL] 无法加载 $MOD"; exit 1; }
  fi
  [[ -e "$CALL" ]] || { echo "[FAIL] $CALL 不存在"; exit 1; }
  if ! grep -q "^$MOD" < <(lsmod); then
    echo "[FAIL] $MOD 未加载"
    exit 1
  fi
}

# 调用 WMAA; $1=FUN1 $2=FUN3 $3=FUN4
call_wmaa() {
  local fun1="$1" fun3="$2" fun4="$3"
  local b1 b3 b4
  b1=$(printf '0x%02X,0x%02X' $((fun1 & 0xFF)) $(((fun1 >> 8) & 0xFF)))
  b3=$(printf '0x%02X,0x00' $((fun3 & 0xFF)))
  b4=$(printf '0x%02X,0x00,0x00,0x00' $((fun4 & 0xFF)))
  local arg2="{${b1},0x00,0x10,${b3},${b4}}"
  echo "  调用: WMAA 0x1 0x1 ${arg2}" >&2
  > "$CALL" 2>/dev/null || true
  printf '%s\n' "\\_SB.PC00.WMID.WMAA 0x1 0x1 ${arg2}" > "$CALL" || {
    echo "  写入 $CALL 失败"; return 1; }
  cat "$CALL" | tr -d '\000'
}

show_status() {
  echo "=== 读取充电上限开关 (WMAA 0x1000/2) ==="
  local r; r=$(call_wmaa 0xFA00 0x02 0x00) || return 1
  echo "  原始返回: $r"
  # RETS: SGER(0-1) FUTR(2-3) FRD0(4-5) FRD1(6-9)
  python3 - "$r" <<'PY'
import sys, re
s=sys.argv[1]
v=[int(x,16) for x in re.findall(r'0x[0-9A-Fa-f]{1,2}', s)]
if len(v) < 10:
    print("  返回数据不足，无法解析"); sys.exit(0)
sger = v[0] | (v[1]<<8)
futr = v[2] | (v[3]<<8)
frd0 = v[4] | (v[5]<<8)
frd1 = v[6] | (v[7]<<8) | (v[8]<<16) | (v[9]<<24)
print(f"  SGER = 0x{sger:04X}  {'(成功)' if sger==0x8000 else '(失败)'}")
print(f"  FUTR = 0x{futr:04X}")
print(f"  FRD0 = 0x{frd0:04X} (子命令)")
print(f"  FRD1 = 0x{frd1:08X} (返回值)")
print()
if frd0 == 0x02:
    print(f"  → 充电上限: {'【已开启】' if (frd1 & 1) else '【已关闭】'}")
PY

  echo
  echo "=== 读取电池健康度 (WMAA 0x1000/1) ==="
  local r2; r2=$(call_wmaa 0xFA00 0x01 0x00) || return 1
  python3 - "$r2" <<'PY'
import sys, re
s=sys.argv[1]
v=[int(x,16) for x in re.findall(r'0x[0-9A-Fa-f]{1,2}', s)]
if len(v) >= 10:
    frd1 = v[6] | (v[7]<<8) | (v[8]<<16) | (v[9]<<24)
    print(f"  SOH1 = {frd1}%  (电池健康度)")
PY
}

case "${1:-status}" in
  status) ensure; show_status ;;
  on)
    ensure
    echo "=== 开启 80% 充电上限 ==="
    r=$(call_wmaa 0xFB00 0x02 0x01) || exit 1
    echo "  原始返回: $r"
    python3 - "$r" <<'PY'
import sys, re
v=[int(x,16) for x in re.findall(r'0x[0-9A-Fa-f]{1,2}', sys.argv[1])]
if len(v)>=2:
    sger=v[0]|(v[1]<<8)
    print(f"  SGER = 0x{sger:04X}  {'✓ 成功' if sger==0x8000 else '✗ 失败'}")
PY
    echo
    sleep 2
    show_status
    ;;
  off)
    ensure
    echo "=== 关闭充电上限 ==="
    r=$(call_wmaa 0xFB00 0x02 0x00) || exit 1
    echo "  原始返回: $r"
    sleep 2
    show_status
    ;;
  *) echo "用法: $0 {status|on|off}" >&2; exit 1 ;;
esac
