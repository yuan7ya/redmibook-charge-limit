#!/bin/bash
# 安装/卸载 开机自动开启 80% 充电上限
#
#   sudo ./install.sh          安装并立即启用
#   sudo ./install.sh uninstall 卸载
#
# ⚠️ 声明: 本脚本由 AI 模型 DS4.1F 生成，非专业开发者所为。这是对固件私有接口的
#    逆向使用，未经厂商认可；仅在 TM2307 实测过，不保证适用于其他机器/BIOS。
#    使用产生的一切后果由使用者自行承担，作者与 AI 模型均不承担任何责任。风险自负。
#
# 服务文件里的路径会按本仓库的实际位置（自定位）自动生成，
# 因此仓库放在任何目录都能用。
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
UNIT_DIR=/etc/systemd/system
MODLOAD=/etc/modules-load.d/acpi_call.conf
SVC=ec-charge-limit.service
SVC_VERIFY=ec-charge-limit-verify.service

if [[ $EUID -ne 0 ]]; then
  echo "[FAIL] 需要 root：sudo $0 ${1:-}" >&2
  exit 1
fi

install_all() {
  echo "=== 仓库位置: $REPO ==="

  echo "[1/4] 生成 systemd 服务（替换 @REPO@）"
  sed "s|@REPO@|$REPO|g" "$REPO/systemd/$SVC.in"      > "$UNIT_DIR/$SVC"
  sed "s|@REPO@|$REPO|g" "$REPO/systemd/$SVC_VERIFY.in" > "$UNIT_DIR/$SVC_VERIFY"
  chmod 644 "$UNIT_DIR/$SVC" "$UNIT_DIR/$SVC_VERIFY"

  echo "[2/4] 配置 acpi_call 开机自动加载"
  echo acpi_call > "$MODLOAD"

  echo "[3/4] 重载 systemd"
  systemctl daemon-reload

  echo "[4/4] 启用并立即启动"
  systemctl enable --now "$SVC"

  echo
  echo "=== 结果 ==="
  systemctl status "$SVC" --no-pager || true
  echo
  systemctl is-enabled "$SVC" 2>/dev/null && echo "  开机自启: 已启用"
}

uninstall_all() {
  echo "=== 卸载 ==="
  systemctl disable --now "$SVC" 2>/dev/null || true
  rm -f "$UNIT_DIR/$SVC" "$UNIT_DIR/$SVC_VERIFY" "$MODLOAD"
  systemctl daemon-reload
  echo "已卸载。注意: 本次开机内 EC 的上限位仍然有效，重启后恢复默认。"
}

case "${1:-install}" in
  install)   install_all ;;
  uninstall) uninstall_all ;;
  *) echo "用法: sudo $0 [install|uninstall]" >&2; exit 2 ;;
esac
