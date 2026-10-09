#!/bin/bash
# 读取 EC 内存指定地址（只读，安全）
# 用法: sudo ./ec-read.sh [起始地址] [长度]
set -uo pipefail

START="${1:-0x00}"
LEN="${2:-0x100}"

echo "=== 1. 加载 ec_sys 模块 ==="
if grep -q '^ec_sys' < <(lsmod); then
  echo "  已加载"
else
  modprobe ec_sys 2>&1 && echo "  加载成功" || { echo "  加载失败"; exit 1; }
fi

echo
echo "=== 2. 确认节点 ==="
NODE=""
for p in /sys/kernel/debug/ec/ec0/io /sys/kernel/debug/ec0/io; do
  [[ -e "$p" ]] && { NODE="$p"; break; }
done
if [[ -z "$NODE" ]]; then
  echo "  未找到 EC io 节点，列出 debugfs/ec:"
  ls -la /sys/kernel/debug/ec/ 2>&1
  exit 1
fi
echo "  节点: $NODE"
ls -la "$NODE"

echo
echo "=== 3. 读取 EC 内存 $START 起 $LEN 字节 ==="
python3 - "$NODE" "$START" "$LEN" <<'PY'
import sys, os
node, start, length = sys.argv[1], int(sys.argv[2],0), int(sys.argv[3],0)
with open(node, 'rb') as f:
    data = f.read()
print(f"  EC 总大小: {len(data)} 字节")
end = min(start+length, len(data))
print()
for base in range(start, end, 16):
    chunk = data[base:base+16]
    hexs = ' '.join(f'{b:02X}' for b in chunk)
    print(f"  {base:04X}: {hexs}")
print()
print("=== 关注地址 ===")
for a in (0xA4, 0xA5):
    if a < len(data):
        print(f"  0x{a:02X} = 0x{data[a]:02X}  ({data[a]})")
PY

echo
echo "=== 4. 卸载模块（可选）==="
echo "  如需卸载: sudo modprobe -r ec_sys"
