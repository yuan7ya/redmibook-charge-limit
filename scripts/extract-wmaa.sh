#!/bin/bash
# 导出 ACPI 表并反编译，定位 WMAA 方法定义（只读，不改动任何状态）
set -uo pipefail
OUT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$OUT" || exit 1

echo "=== 1. 确保 iasl 可用 ==="
if ! command -v iasl >/dev/null 2>&1; then
  echo "  iasl 未安装，正在安装 acpica-tools ..."
  apt-get install -y acpica-tools || { echo "安装失败"; exit 1; }
fi
iasl -v 2>&1 | grep -i version | head -1

echo
echo "=== 2. 从 sysfs 拷贝 ACPI 表（比 acpidump 更可靠）==="
rm -f ./*.aml ./*.dat ./*.dsl 2>/dev/null
cp /sys/firmware/acpi/tables/DSDT ./dsdt.aml 2>/dev/null && echo "  dsdt.aml: $(stat -c%s dsdt.aml) 字节" || { echo "  拷贝 DSDT 失败"; exit 1; }

shopt -s nullglob
for t in /sys/firmware/acpi/tables/SSDT*; do
  n="$(basename "$t")"
  cp "$t" "./${n}.aml" 2>/dev/null && echo "  ${n}.aml: $(stat -c%s "${n}.aml") 字节"
done
shopt -u nullglob

echo
echo "=== 3. 找出含 WMAA 的表 ==="
HAS=()
for f in ./*.aml; do
  if strings "$f" 2>/dev/null | grep -q "WMAA"; then
    echo "  含 WMAA: $(basename "$f")"
    HAS+=("$f")
  fi
done
[[ ${#HAS[@]} -eq 0 ]] && echo "  （没有表在明文串里含 WMAA，反编译后再找）"

echo
echo "=== 4. 反编译所有表 ==="
for f in ./*.aml; do
  echo "  iasl -d $(basename "$f")"
  iasl -d "$f" >/dev/null 2>&1
done
ls -la ./*.dsl 2>/dev/null | head

echo
echo "=== 5. 搜索 WMAA 方法 ==="
grep -ln "WMAA" ./*.dsl 2>/dev/null | while read -r f; do
  echo "  --- $(basename "$f") ---"
  grep -n "WMAA" "$f" | head -10
done

echo
echo "=== 6. 打印 WMAA 方法全文 ==="
for f in ./*.dsl; do
  [[ -f "$f" ]] || continue
  if grep -q "Method (WMAA" "$f" 2>/dev/null; then
    echo "########## $(basename "$f") ##########"
    # 从 Method (WMAA 开始，打印到方法结束（缩进回到同级的 }）
    awk '/Method \(WMAA/{flag=1} flag{print} flag&&/^        }/{exit}' "$f"
    echo
  fi
done

echo
echo "=== 7. 所有 WM* 方法名 ==="
grep -hoE "Method \(WM[A-Z0-9_]{2}" ./*.dsl 2>/dev/null | sort -u

echo
echo "=== 8. WMID 设备定义 ==="
for f in ./*.dsl; do
  [[ -f "$f" ]] || continue
  if grep -q "Device (WMID" "$f" 2>/dev/null; then
    echo "########## $(basename "$f") ##########"
    awk '/Device \(WMID/{flag=1} flag{print} flag&&/^        }/{exit}' "$f" | head -80
  fi
done

echo
echo "=== 完成。关键文件: $OUT/dsdt.dsl ==="
