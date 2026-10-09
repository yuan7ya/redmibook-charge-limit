#!/bin/bash
# 只读 EC 关键寄存器（不需要 write_support）
set -uo pipefail
NODE=""
for p in /sys/kernel/debug/ec/ec0/io /sys/kernel/debug/ec0/io; do
  [[ -e "$p" ]] && { NODE="$p"; break; }
done
[[ -n "$NODE" ]] || { echo "EC 节点不存在，先执行: sudo modprobe ec_sys"; exit 1; }
python3 - "$NODE" <<'PY'
import sys, os
node=sys.argv[1]
fd=os.open(node, os.O_RDONLY)
try:
    data=os.pread(fd, 0x100, 0)
finally:
    os.close(fd)
print(f"EC 节点: {node}")
print(f"  0xA4 = 0x{data[0xA4]:02X} ({data[0xA4]})")
print(f"  0xA5 = 0x{data[0xA5]:02X} ({data[0xA5]})  <- 充电上限%")
if data[0xA5]==100:
    print("  → 未限制 (100%) —— 重启已重置")
elif data[0xA5]==80:
    print("  → 限制在 80%")
else:
    print(f"  → 限制值 {data[0xA5]}%")
PY
