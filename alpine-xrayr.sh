#!/bin/sh
set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
PLAIN="\033[0m"

log() {
  printf "%s[+] %s%s\n" "$GREEN" "$1" "$PLAIN"
}

warn() {
  printf "%s[!] %s%s\n" "$YELLOW" "$1" "$PLAIN"
}

err() {
  printf "%s[!] %s%s\n" "$RED" "$1" "$PLAIN" >&2
}

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
  err "必须使用 root 运行此脚本"
  exit 1
fi

# 必须是 Alpine
if [ ! -f /etc/alpine-release ]; then
  err "检测到当前系统不是 Alpine Linux，本脚本仅适用于 Alpine。"
  exit 1
fi

# 只支持 x86_64 / amd64
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    MACHINE="64"
    ;;
  *)
    err "当前架构: $ARCH，本脚本只支持 x86_64/amd64。"
    exit 1
    ;;
esac

XRAYR_INSTALL_DIR="/usr/local/XrayR"
XRAYR_CONFIG_DIR="/etc/XrayR"
XRAYR_BIN="${XRAYR_INSTALL_DIR}/XrayR"
XRAYR_SERVICE="/etc/init.d/XrayR"
MANAGER_SCRIPT="/usr/bin/XrayR"

TMP_DIR="$(mktemp -d -t xrayr-install-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
ZIP_FILE="${TMP_DIR}/XrayR-linux-${MACHINE}.zip"

# 可选：第一个参数指定版本（如 v0.8.9 或 0.8.9）
VERSION=""
if [ $# -ge 1 ]; then
  VERSION="$1"
fi

if [ -n "$VERSION" ]; then
  case "$VERSION" in
    v*)
      TAG="$VERSION"
      ;;
    *)
      TAG="v$VERSION"
      ;;
  esac
  RELEASE_URL="https://github.com/XrayR-project/XrayR/releases/download/${TAG}/XrayR-linux-${MACHINE}.zip"
  log "指定安装版本: $TAG"
else
  RELEASE_URL="https://github.com/XrayR-project/XrayR/releases/latest/download/XrayR-linux-${MACHINE}.zip"
  log "将安装 XrayR 最新稳定版"
fi

# 安装依赖
log "更新 apk 索引并安装依赖 (curl wget unzip ca-certificates tzdata openrc)..."
if ! command -v apk >/dev/null 2>&1; then
  err "未找到 apk 命令，这看起来不是标准 Alpine 系统。"
  exit 1
fi

apk update >/dev/null || true
apk add --no-cache curl wget unzip ca-certificates tzdata openrc >/dev/null

# 配置 / 修复 OpenRC（容器里常见 rc-service / softlevel 缺失）
if ! command -v rc-service >/dev/null 2>&1; then
  warn "未检测到 rc-service，尝试安装 openrc..."
  apk add --no-cache openrc >/dev/null
fi

if [ ! -d /run/openrc ]; then
  mkdir -p /run/openrc
fi

if [ ! -f /run/openrc/softlevel ]; then
  warn "初始化 OpenRC（容器环境常见缺失 softlevel 文件的问题）..."
  openrc >/dev/null 2>&1 || true
  touch /run/openrc/softlevel
fi

# 停掉旧服务（如果有）
if [ -f "$XRAYR_SERVICE" ] && command -v rc-service >/dev/null 2>&1; then
  warn "检测到已有 XrayR OpenRC 服务，尝试先停止并移除开机自启..."
  if rc-service XrayR status >/dev/null 2>&1; then
    rc-service XrayR stop || true
  fi
  rc-update del XrayR default >/dev/null 2>&1 || true
fi

# 下载 XrayR
log "从 GitHub 下载 XrayR: $RELEASE_URL"
if ! curl -L -o "$ZIP_FILE" "$RELEASE_URL"; then
  err "下载 XrayR 失败，请检查网络或 GitHub 访问。"
  exit 1
fi

cd "$TMP_DIR"
if ! unzip -q "$ZIP_FILE"; then
  err "解压 XrayR 压缩包失败。"
  exit 1
fi

# 安装文件
log "安装 XrayR 到 ${XRAYR_INSTALL_DIR}..."
mkdir -p "$XRAYR_INSTALL_DIR" "$XRAYR_CONFIG_DIR"

if [ ! -f "$TMP_DIR/XrayR" ]; then
  err "在压缩包中未找到 XrayR 可执行文件，安装中止。"
  exit 1
fi

install -m 755 "$TMP_DIR/XrayR" "$XRAYR_BIN"

CONFIG_NEW=0
if [ -f "$TMP_DIR/config.yml" ] && [ ! -f "${XRAYR_CONFIG_DIR}/config.yml" ]; then
  install -m 644 "$TMP_DIR/config.yml" "${XRAYR_CONFIG_DIR}/config.yml"
  CONFIG_NEW=1
fi

# 一些常用数据文件，存在才拷贝，防止覆盖已有修改
for f in geoip.dat geosite.dat dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
  if [ -f "$TMP_DIR/$f" ] && [ ! -f "${XRAYR_CONFIG_DIR}/$f" ]; then
    install -m 644 "$TMP_DIR/$f" "${XRAYR_CONFIG_DIR}/$f"
  fi
done

mkdir -p /var/log/XrayR

# 安装官方管理脚本 XrayR.sh
log "安装 XrayR 管理脚本到 ${MANAGER_SCRIPT}..."
if curl -L -o "$MANAGER_SCRIPT" "https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/XrayR.sh"; then
  chmod 755 "$MANAGER_SCRIPT"
  if [ ! -e /usr/bin/xrayr ]; then
    ln -s "$MANAGER_SCRIPT" /usr/bin/xrayr
  fi
else
  warn "下载管理脚本失败，将只能通过 rc-service 管理服务。"
fi

# 创建 OpenRC 服务脚本
log "创建 OpenRC 启动脚本 ${XRAYR_SERVICE}..."
cat > "$XRAYR_SERVICE" <<'EOF'
#!/sbin/openrc-run

name="XrayR"
description="XrayR service (Xray backend framework)"

command="/usr/local/XrayR/XrayR"
command_args="--config /etc/XrayR/config.yml"
command_user="root:root"
directory="/usr/local/XrayR"
pidfile="/run/XrayR.pid"

command_background="yes"

depend() {
    need net
    use dns logger
}
EOF

chmod +x "$XRAYR_SERVICE"

# 加入开机自启
if command -v rc-update >/div/null 2>&1; then
  log "将 XrayR 加入 OpenRC 开机自启..."
  rc-update add XrayR default >/dev/null 2>&1 || true
else
  warn "未检测到 rc-update，可能 OpenRC 未完全安装，请手动将 XrayR 加入开机自启。"
fi

# 启动服务
if command -v rc-service >/dev/null 2>&1; then
  log "启动 XrayR 服务..."
  if ! rc-service XrayR restart >/dev/null 2>&1; then
    warn "rc-service 启动失败，请稍后手动执行: rc-service XrayR start"
  fi
else
  warn "未检测到 rc-service，请手动运行: /usr/local/XrayR/XrayR --config /etc/XrayR/config.yml &"
fi

echo
log "XrayR 安装完成。"
if [ "$CONFIG_NEW" -eq 1 ]; then
  echo "已生成默认配置文件: ${XRAYR_CONFIG_DIR}/config.yml"
  echo "请先编辑此文件写入面板/节点信息，然后重启服务:"
  echo "  rc-service XrayR restart"
else
  echo "保留了已有配置文件: ${XRAYR_CONFIG_DIR}/config.yml"
fi

echo
echo "OpenRC 管理命令示例:"
echo "  rc-service XrayR start"
echo "  rc-service XrayR stop"
echo "  rc-service XrayR restart"
echo "  rc-service XrayR status"
echo
if [ -x "$MANAGER_SCRIPT" ]; then
  echo "XrayR 管理脚本示例:"
  echo "  XrayR            # 显示管理菜单"
  echo "  XrayR log        # 查看日志"
  echo "  XrayR update     # 更新 XrayR"
fi
