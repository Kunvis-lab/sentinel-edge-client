#!/bin/sh
# Sentinel Edge gateway one-click installer (OpenWrt / linux-arm64).
# Usage:
#   curl -fsSLk <dist>/install.sh | sh -s -- [flags]
# Flags: --platform URL    platform endpoint (default below)
#        --lan IFACE       LAN bridge/interface (default: auto, OpenWrt br-lan)
#        --reinstall       upgrade/repair an existing install without asking
#        --yes             assume yes for the upgrade prompt (non-interactive)
#        --dry-run         print generated configs only, change nothing
#        --no-autostart    install without enabling boot start
#        --no-activate     do not create the activation marker
#        --uninstall       stop, disable and remove the product
#        --purge           with --uninstall: also remove account data
# Output contract: numbered stages + [OK]/[INFO]/[WARN]/[ERROR] markers, a
# result block at the end, honest states only, no secrets in output or logs.
# Trust chain: this script pins the sha256 of every artifact it downloads,
# including the signed release.json whose payload pins the binary hashes.
set -eu

VERSION=0.1.9
DIST_BASE=
PLATFORM_URL=
PKG_SHA=bca5708da8dbcef0bd5d00d5d14d79a2049d5e9470ffdd261dc5cfb4783be2e2
REL_SHA=2f1cacff93b5d9196433e4176593d7e15407c98d0a1260b9ad62fa6041e77e3a
MAN_SHA=ce23a6eb15cb5101e920b27efd261f83c1119dcda7525d25b443731f7d59f04d
BOOT_SHA=2eec60f5de4bafd32f8a7083afe4f78a0b5f6289cbaeccfd02ed0e9e2267a02b
PUBKEY_SHA=08aff65705c22bf0052e74ffa43f79dcb8292e784e176c717b48efc52a7c7453
CA_SHA=1855e6dd6093a295114536c17879e15e801b377f444c365c98164b70c9905936
RELPUB_SHA=6d6951bdfe11efb4124c1bb952e892c2ab79d548a0d19c1c8fe465875646488c

LAN_IFACE="" DRY=0 REINSTALL=0 ASSUME_YES=0 AUTOSTART=1 ACTIVATE=1 UNINSTALL=0 PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM_URL=$2; shift 2 ;;
    --lan) LAN_IFACE=$2; shift 2 ;;
    --dist) DIST_BASE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --reinstall) REINSTALL=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --no-autostart) AUTOSTART=0; shift ;;
    --no-activate) ACTIVATE=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    *) printf '[ERROR] 未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -z "$DIST_BASE" ] && { printf '[ERROR] 缺少分发地址：请加 --dist <供应商提供的分发地址>
' >&2; exit 2; }
[ -z "$PLATFORM_URL" ] && { printf '[ERROR] 缺少平台地址：请加 --platform <供应商提供的平台地址>
' >&2; exit 2; }

START_TS=$(date +%s)
STAGE_DESC="准备" ERR_CODE="INTERNAL" STATE_NOTES="" BACKUP_PATH=""

rule() { printf -- '------------------------------------------------------------\n'; }
stage() { printf '\n\033[36m[%s/6] %s\033[0m\n' "$1" "$2"; STAGE_DESC="$1/6 $2"; }
ok()   { printf '  [\033[32mOK\033[0m] %s\n' "$1"; }
info() { printf '  [INFO] %s\n' "$1"; }
warn() { printf '  [\033[33mWARN\033[0m] %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
fail_exit() { # fail_exit CODE REASON
  ERR_CODE=$1
  printf '\n'
  rule; printf '  \033[31m安装失败\033[0m\n'; rule
  printf '  失败阶段    %s\n' "$STAGE_DESC"
  printf '  失败原因    %s\n' "$2"
  printf '  当前状态\n'
  if [ -n "$STATE_NOTES" ]; then printf '%s' "$STATE_NOTES"; else note '安装尚未开始，系统未做任何更改。'; fi
  [ -n "$BACKUP_PATH" ] && note "升级前的备份保留在 $BACKUP_PATH"
  printf '  建议处理\n'
  case "$ERR_CODE" in
    ENV_UNSUPPORTED) note '1. 核对设备为 OpenWrt / ARM64。'; note '2. 确认磁盘剩余空间不少于 150MB。' ;;
    DOWNLOAD_FAILED|VERIFY_FAILED) note '1. 检查设备的网络连接。'; note '2. 网络恢复后重新运行本命令，已下载部分不会重复计算。' ;;
    INSTALL_FAILED) note '1. 重新运行本命令重试。'; note '2. 若再次失败，保留屏幕输出联系供应商。' ;;
    START_FAILED) note '1. 稍候刷新管理面板确认服务状态。'; note '2. 若持续未启动，保留屏幕输出联系供应商。' ;;
    *) note '1. 重新运行本命令。'; note '2. 若再次失败，保留屏幕输出联系供应商。' ;;
  esac
  printf '  错误编号    %s\n' "$ERR_CODE"
  exit 1
}

[ "$(id -u)" = 0 ] || { printf '[ERROR] 请以 root 运行。\n' >&2; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
  [ -x /opt/sentinel-edge/edge ] || { printf '[ERROR] 未检测到安装。\n' >&2; exit 1; }
  info '停止并移除服务…'
  /etc/init.d/sentinel-edge stop >/dev/null 2>&1 || true
  /etc/init.d/sentinel-edge disable >/dev/null 2>&1 || true
  rm -f /etc/init.d/sentinel-edge /etc/rc.d/*sentinel-edge
  rm -rf /opt/sentinel-edge /opt/sentinel-bootstrap /etc/sentinel-edge /etc/sentinel-update /etc/sentinel-guard /sentinel-ram
  if [ "$PURGE" = 1 ]; then
    rm -rf /etc/sentinel-edge-account && ok '账号数据已删除'
  else
    ok '账号数据已保留（/etc/sentinel-edge-account，--purge 可一并删除）'
  fi
  rule; printf '  卸载完成\n'; rule
  exit 0
fi

# ---- silent preflight: fills banner fields and detects existing install ----
command -v tar >/dev/null 2>&1 || fail_exit ENV_UNSUPPORTED '缺少 tar。'
command -v sha256sum >/dev/null 2>&1 || fail_exit ENV_UNSUPPORTED '缺少 sha256sum。'
command -v curl >/dev/null 2>&1 || fail_exit ENV_UNSUPPORTED '缺少 curl。'
command -v openssl >/dev/null 2>&1 || fail_exit ENV_UNSUPPORTED '缺少 openssl（opkg install openssl-util）。'
[ -f /etc/openwrt_release ] || fail_exit ENV_UNSUPPORTED '当前系统不是 OpenWrt，本安装包仅支持 OpenWrt。'
[ "$(uname -m)" = "aarch64" ] || fail_exit ENV_UNSUPPORTED "本安装包仅含 ARM64 构建（当前 $(uname -m)）。"
OS_REL=$(sed -n "s/DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release)
df -Pk /overlay | awk 'NR==2 && $4 < 150*1024 {exit 1}' || fail_exit ENV_UNSUPPORTED '/overlay 剩余空间不足 150MB。'
LAN_IFACE=${LAN_IFACE:-$(uci -q get network.lan.device || uci -q get network.lan.ifname || echo br-lan)}
MGMT_IP=$(ip -4 addr show "$LAN_IFACE" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}')
[ -n "$MGMT_IP" ] || fail_exit ENV_UNSUPPORTED "无法获取接口 $LAN_IFACE 的 IPv4 地址（可用 --lan 指定）。"

EXISTING=0 INSTALLED_VER=""
if [ -x /opt/sentinel-edge/edge ]; then
  EXISTING=1
  INSTALLED_VER=$(tr -d ' \n' < /etc/sentinel-update/current.json 2>/dev/null | sed -n 's/.*"version":*"\([0-9.]*\)".*/\1/p')
  [ -n "$INSTALLED_VER" ] || INSTALLED_VER="未知"
fi

if [ "$EXISTING" = 1 ] && [ "$INSTALLED_VER" = "$VERSION" ] && [ "$REINSTALL" = 0 ] && [ "$DRY" = 0 ]; then
  rule; printf '  无需安装\n'; rule
  printf '  当前版本    v%s\n  目标版本    v%s\n' "$INSTALLED_VER" "$VERSION"
  printf '  当前已是目标版本，未执行任何更改。如需修复安装，可加 --reinstall 重新运行。\n'
  exit 0
fi

if [ "$EXISTING" = 1 ] && [ "$REINSTALL" = 0 ] && [ "$DRY" = 0 ]; then
  rule; printf '  检测到已有安装\n'; rule
  printf '  已安装版本  v%s\n  目标版本    v%s\n' "$INSTALLED_VER" "$VERSION"
  if /etc/init.d/sentinel-edge status >/dev/null 2>&1; then SVC_STATE='运行中'; else SVC_STATE='已停止'; fi
  printf '  服务状态    %s\n' "$SVC_STATE"
  printf '  本次操作\n'
  note '升级程序文件。'
  note '保留现有配置和业务数据（升级前自动备份到 /root）。'
  note '升级期间服务将短暂中断。'
  if [ "$ASSUME_YES" = 1 ]; then
    REINSTALL=1
  elif [ -c /dev/tty ]; then
    printf '  继续升级？[y/N]: '
    read answer </dev/tty || answer=''
    case "$answer" in y|Y|yes|YES) REINSTALL=1 ;; *) REINSTALL=2 ;; esac
  else
    REINSTALL=2
  fi
  if [ "$REINSTALL" = 2 ]; then
    printf '\n'
    rule; printf '  安装已取消\n'; rule
    printf '  系统配置未更改。\n'
    exit 0
  fi
fi

MODE_TXT=$([ "$EXISTING" = 1 ] && echo 升级 || echo 安装)
BANNER_TXT="${MODE_TXT}程序"
[ "$DRY" = 1 ] && { MODE_TXT=预览; BANNER_TXT='安装预览'; }
printf '\n'
rule; printf '  Sentinel Edge %s\n' "$BANNER_TXT"; rule
printf '\n'
printf '  安装版本    v%s\n' "$VERSION"
printf '  操作系统    OpenWrt %s\n' "$OS_REL"
printf '  系统架构    ARM64\n'
printf '  安装目录    /opt/sentinel-edge\n'
printf '  管理面板    https://%s:18081\n' "$MGMT_IP"

if [ "$REINSTALL" = 1 ]; then
  stage 1 "检查升级条件"
  ok "当前版本 v${INSTALLED_VER} 支持直接升级"
  ok "网络接口 $LAN_IFACE / $MGMT_IP"
  stage 2 "备份现有安装"
  BACKUP_PATH="/root/sentinel-backup-$INSTALLED_VER-$(date +%Y%m%d%H%M%S).tar.gz"
  if tar -czf "$BACKUP_PATH" -C / etc/sentinel-edge etc/sentinel-edge-account 2>/dev/null; then
    chmod 600 "$BACKUP_PATH"; ok '配置文件已备份'; ok '账号数据已备份'
    printf '  备份位置    %s\n' "$BACKUP_PATH"
  else
    rm -f "$BACKUP_PATH"; BACKUP_PATH=""
    warn '备份未完成（将继续升级；失败时配置无法自动回退）'
  fi
  STAGE_LABEL_GET="获取新版本"
else
  stage 1 "检查安装环境"
  ok '操作系统受支持（OpenWrt ARM64）'
  ok '当前权限满足要求（root）'
  ok "可用磁盘空间充足（$(df -h /overlay | awk 'NR==2{print $4}') 剩余）"
  ok "网络接口 $LAN_IFACE / $MGMT_IP"
  STAGE_LABEL_GET="获取安装文件"
fi

# ---- download + verify -----------------------------------------------------
FETCH_NO=2; [ "$REINSTALL" = 1 ] && FETCH_NO=3
stage $FETCH_NO "$STAGE_LABEL_GET"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
CAFILE="$WORK/platform-ca.crt"
STATE_NOTES="$(note '尚未安装程序。')"

fetch() { curl -fsSLk --http1.1 --retry 3 --retry-delay 2 "$1" -o "$2"; }
fetch_verified() { curl -fsSL --http1.1 --retry 3 --retry-delay 2 --cacert "$CAFILE" "$1" -o "$2"; }

fetch_big() { # URL OUT TOTAL — chunked resumable download with a progress bar
  url=$1 out=$2 total=$3 chunk=2097152 tries=0
  : > "$out"
  got=0
  while [ "$got" -lt "$total" ]; do
    end=$((got + chunk - 1)); [ "$end" -ge "$total" ] && end=$((total - 1))
    if curl -fsSL --http1.1 --cacert "$CAFILE" --max-time 90 -r "$got-$end" "$url" -o "$WORK/.chunk"; then
      cat "$WORK/.chunk" >> "$out"
      got=$(wc -c < "$out")
      tries=0
      pct=$((got * 100 / total)); filled=$((got * 20 / total)); empty=$((20 - filled))
      bar=''; i=0; while [ $i -lt $filled ]; do bar="${bar}█"; i=$((i+1)); done
      i=0; while [ $i -lt $empty ]; do bar="${bar}░"; i=$((i+1)); done
      printf '\r  下载进度  [%s] %3d%%  %d.%d / %d.%d MB   ' "$bar" "$pct" $((got/1048576)) $(( (got%1048576)*10/1048576 )) $((total/1048576)) $(( (total%1048576)*10/1048576 ))
    else
      tries=$((tries + 1))
      [ "$tries" -ge 12 ] && { printf '\n'; fail_exit DOWNLOAD_FAILED '分块下载连续 12 次中断。'; }
      printf '\n'
      warn "下载中断，准备重试（$tries/12）"
    fi
  done
  printf '\n'
  rm -f "$WORK/.chunk"
}

info '正在连接下载服务器…'
fetch "$DIST_BASE/platform-ca.crt" "$CAFILE" || fail_exit DOWNLOAD_FAILED '无法连接下载服务器。'
[ "$(sha256sum "$CAFILE" | awk '{print $1}')" = "$CA_SHA" ] || fail_exit VERIFY_FAILED '平台 CA 校验失败。'
fetch_verified "$DIST_BASE/v$VERSION/linux-arm64/release.json" "$WORK/release.json" || fail_exit DOWNLOAD_FAILED '下载签名清单失败。'
fetch_verified "$DIST_BASE/v$VERSION/linux-arm64/manifest.json" "$WORK/manifest.json" || fail_exit DOWNLOAD_FAILED '下载安装清单失败。'
PKG_TOTAL=$(tr -d ' \n' < "$WORK/manifest.json" | sed -n 's/.*"packageSize":*\([0-9]*\).*/\1/p')
[ -n "$PKG_TOTAL" ] || fail_exit VERIFY_FAILED '安装清单缺少包大小。'
info "正在下载 v$VERSION …"
fetch_big "$DIST_BASE/v$VERSION/linux-arm64/package.tar.gz" "$WORK/package.tar.gz" "$PKG_TOTAL"
ok '下载完成'
fetch_verified "$DIST_BASE/edge-bootstrap-linux-arm64" "$WORK/edge-bootstrap" || fail_exit DOWNLOAD_FAILED '下载启动器失败。'
fetch_verified "$DIST_BASE/platform-public-key.txt" "$WORK/platform.pub" || fail_exit DOWNLOAD_FAILED '下载平台公钥失败。'
fetch_verified "$DIST_BASE/release-public.txt" "$WORK/release-public.txt" || fail_exit DOWNLOAD_FAILED '下载发布公钥失败。'

sha_of() { sha256sum "$1" | awk '{print $1}'; }
[ "$(sha_of "$WORK/package.tar.gz")" = "$PKG_SHA" ] || fail_exit VERIFY_FAILED '软件包哈希与脚本内置值不符。'
[ "$(sha_of "$WORK/release.json")"    = "$REL_SHA" ] || fail_exit VERIFY_FAILED '签名清单哈希与脚本内置值不符。'
[ "$(sha_of "$WORK/manifest.json")"   = "$MAN_SHA" ] || fail_exit VERIFY_FAILED '安装清单哈希与脚本内置值不符。'
[ "$(sha_of "$WORK/edge-bootstrap")"  = "$BOOT_SHA" ] || fail_exit VERIFY_FAILED '启动器哈希与脚本内置值不符。'
[ "$(sha_of "$WORK/platform.pub")"    = "$PUBKEY_SHA" ] || fail_exit VERIFY_FAILED '平台公钥哈希与脚本内置值不符。'
[ "$(sha_of "$WORK/release-public.txt")" = "$RELPUB_SHA" ] || fail_exit VERIFY_FAILED '发布公钥哈希与脚本内置值不符。'
PKG_IN_MANIFEST=$(tr -d ' \n' < "$WORK/release.json" | sed -n 's/.*"packageSha256":*"\([0-9a-f]*\)".*/\1/p')
[ -n "$PKG_IN_MANIFEST" ] && [ "$PKG_IN_MANIFEST" = "$PKG_SHA" ] || fail_exit VERIFY_FAILED '签名清单与软件包哈希不一致。'
mkdir -p "$WORK/pkg" && tar -xzf "$WORK/package.tar.gz" -C "$WORK/pkg"
ok '文件完整性校验通过（签名链完整）'

# instance/gateway id: preserved across upgrades, generated once on fresh install
if [ "$REINSTALL" = 1 ] && [ -f /etc/sentinel-edge/network-policy.json ]; then
  INSTANCE=$(tr -d ' \n' < /etc/sentinel-edge/network-policy.json | sed -n 's/.*"instance":*"\([0-9a-f]*\)".*/\1/p')
  APPUID=$(tr -d ' \n' < /etc/sentinel-edge/network-policy.json | sed -n 's/.*"appUid":*\([0-9]*\).*/\1/p')
fi
INSTANCE=${INSTANCE:-$(head -c16 /dev/urandom | md5sum | cut -c1-32)}
APPUID=${APPUID:-$(awk -F: '$3>=1000 && $3<60000 {print $3}' /etc/passwd | sort -n | awk 'BEGIN{p=999}{if($1!=p+1){print p+1;exit}p=$1}')}
GWID=$(printf '%s' "$INSTANCE" | awk '{print substr($0,1,8)"-"substr($0,9,4)"-"substr($0,13,4)"-"substr($0,17,4)"-"substr($0,21,12)}')
BACKEND=$(command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1 && echo nftables || echo iptables)

NET_POLICY=$(cat <<EOF
{
  "backend": "$BACKEND",
  "instance": "$INSTANCE",
  "appUid": $APPUID,
  "lanInterfaces": ["$LAN_IFACE"],
  "socket": "/sentinel-ram/control/helper.sock",
  "stateDir": "/etc/sentinel-guard",
  "proxyPort": 17892,
  "dnsPort": 17893,
  "dnsUpstreams": ["https://dns.alidns.com/dns-query", "https://cloudflare-dns.com/dns-query"]
}
EOF
)
BOOTSTRAP=$(cat <<EOF
{
  "installDir": "/opt/sentinel-edge",
  "stateDir": "/etc/sentinel-update",
  "ramDir": "/sentinel-ram/update",
  "incomingDir": "/sentinel-ram/incoming",
  "socket": "/sentinel-ram/control/upgrade.sock",
  "appUid": $APPUID,
  "appGid": $APPUID,
  "networkPolicy": "/etc/sentinel-edge/network-policy.json",
  "dataDir": "/etc/sentinel-edge-account/data",
  "runtimeDir": "/sentinel-ram/runtime",
  "listen": "$MGMT_IP:18081",
  "allowedHosts": "$MGMT_IP:18081",
  "tlsCert": "/etc/sentinel-edge-account/panel.crt",
  "tlsKey": "/etc/sentinel-edge-account/panel.key",
  "platformUrl": "$PLATFORM_URL",
  "platformKeyFile": "/etc/sentinel-edge-account/platform.pub",
  "platformCaFile": "/etc/sentinel-edge-account/platform-ca.crt",
  "releaseKeyFile": "/etc/sentinel-edge/release-public.txt",
  "gatewayId": "$GWID",
  "probeUrl": "https://www.gstatic.com/generate_204",
  "additionalProductStorage": ["/opt/sentinel-bootstrap","/etc/sentinel-edge"]
}
EOF
)
if [ "$DRY" = 1 ]; then
  printf '\n'
  rule; printf '  预览结束（未做任何更改）\n'; rule
  printf '\n---- network-policy.json ----\n%s\n---- bootstrap.json ----\n%s\n' "$NET_POLICY" "$BOOTSTRAP"
  exit 0
fi

# ---- install files ----------------------------------------------------------
if [ "$REINSTALL" = 1 ]; then
  stage 4 "更新程序"
  info '停止现有服务，等待进程退出…'
  /etc/init.d/sentinel-edge stop >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    ps w 2>/dev/null | grep -E 'sentinel-edge/edge|sentinel-edge/mihomo' | grep -v grep >/dev/null 2>&1 || break
    sleep 1
  done
  ok '服务已停止'
  STATE_NOTES="$(note '旧服务已停止，尚未写入新文件。')"
else
  stage 3 "安装程序"
  info '创建服务账号…'
  if command -v adduser >/dev/null 2>&1; then
    addgroup -g "$APPUID" sentinel 2>/dev/null || true
    adduser -S -H -u "$APPUID" -G sentinel -s /bin/false sentinel 2>/dev/null || true
  else
    grep -q '^sentinel:' /etc/passwd || echo "sentinel:x:$APPUID:$APPUID:Sentinel Edge:/nonexistent:/bin/false" >> /etc/passwd
    grep -q '^sentinel:' /etc/group || echo "sentinel:x:$APPUID:" >> /etc/group
  fi
  mkdir -p /etc/sentinel-edge /etc/sentinel-update /etc/sentinel-guard /etc/sentinel-edge-account/data
  chmod 700 /etc/sentinel-update /etc/sentinel-guard /etc/sentinel-edge-account/data
  ok '服务账号与数据目录已创建'
fi
mkdir -p /opt/sentinel-bootstrap /opt/sentinel-edge /sentinel-ram
cp "$WORK/edge-bootstrap" /opt/sentinel-bootstrap/edge-bootstrap && chmod 755 /opt/sentinel-bootstrap/edge-bootstrap
cp "$WORK/pkg/edge" /opt/sentinel-edge/edge && chmod 755 /opt/sentinel-edge/edge
cp "$WORK/pkg/mihomo" /opt/sentinel-edge/mihomo && chmod 755 /opt/sentinel-edge/mihomo
cp "$WORK/platform.pub" /etc/sentinel-edge-account/platform.pub
cp "$WORK/platform-ca.crt" /etc/sentinel-edge-account/platform-ca.crt
cp "$WORK/release-public.txt" /etc/sentinel-edge/release-public.txt
ok '程序文件已安装'
STATE_NOTES="$(note '程序文件已写入，服务尚未启动。')$(printf '\n')$(note "升级备份：$BACKUP_PATH")"
# The upgrade engine verifies installed binaries against the signed manifest;
# any install (fresh or reinstall) must carry current.json forward with them.
cp "$WORK/manifest.json" /etc/sentinel-update/current.json && chmod 600 /etc/sentinel-update/current.json
cp "$WORK/release.json" /etc/sentinel-edge/release.json && chmod 644 /etc/sentinel-edge/release.json
ok '版本清单已登记'

# ---- fresh-install configuration -------------------------------------------
if [ "$REINSTALL" = 0 ]; then
  stage 4 "初始化配置"
  echo "$NET_POLICY" > /etc/sentinel-edge/network-policy.json
  echo "$BOOTSTRAP" > /etc/sentinel-edge/bootstrap.json
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /etc/sentinel-edge-account/panel.key -out /etc/sentinel-edge-account/panel.crt -days 3650 -subj "/CN=$MGMT_IP" -addext "subjectAltName=IP:$MGMT_IP" >/dev/null 2>&1 || fail_exit INSTALL_FAILED '面板证书生成失败。'
  chmod 600 /etc/sentinel-edge/bootstrap.json; chmod 640 /etc/sentinel-edge/network-policy.json
  chgrp "$APPUID" /etc/sentinel-edge/network-policy.json 2>/dev/null || true
  # The launcher requires: /etc/sentinel-edge-account itself stays root:root,
  # only data/ belongs to the app user; certs stay root-owned (key group-app).
  chown "$APPUID:$APPUID" /etc/sentinel-edge-account/data
  chgrp "$APPUID" /etc/sentinel-edge-account/panel.key 2>/dev/null || true
  chmod 640 /etc/sentinel-edge-account/panel.key
  chmod 644 /etc/sentinel-edge-account/panel.crt /etc/sentinel-edge-account/platform.pub /etc/sentinel-edge-account/platform-ca.crt
  [ "$ACTIVATE" = 1 ] && touch /etc/sentinel-edge/activation-approved
  ok '配置文件已生成'
  ok '目录权限已设置'
fi

cat > /etc/init.d/sentinel-edge <<'INIT'
#!/bin/sh /etc/rc.common
START=12
STOP=01
USE_PROCD=1
start_service() {
 [ -f /etc/sentinel-edge/activation-approved ] || { echo 'activation not approved' >&2; return 1; }
 [ -d /sentinel-ram ] && [ ! -L /sentinel-ram ] || return 1
 if ! awk '$2=="/sentinel-ram" && $3=="tmpfs" {found=1} END {exit !found}' /proc/mounts; then
  mount -t tmpfs -o size=192m,mode=0711 sentinel-edge /sentinel-ram || return 1
 fi
 procd_open_instance
 procd_set_param command /opt/sentinel-bootstrap/edge-bootstrap --config /etc/sentinel-edge/bootstrap.json
 procd_set_param user root
 procd_set_param group root
 procd_set_param limits nofile="4096 4096" core="0"
 procd_set_param respawn 3600 5 3
 procd_set_param term_timeout 12
 procd_set_param stdout 1
 procd_set_param stderr 1
 procd_close_instance
}
INIT
chmod 755 /etc/init.d/sentinel-edge
sha256sum /opt/sentinel-edge/edge /opt/sentinel-edge/mihomo /opt/sentinel-bootstrap/edge-bootstrap /etc/sentinel-edge/bootstrap.json /etc/sentinel-edge/network-policy.json /etc/sentinel-edge/release-public.txt /etc/sentinel-edge/release.json /etc/sentinel-update/current.json /etc/init.d/sentinel-edge > /etc/sentinel-edge/files-prepared.sha256
chmod 600 /etc/sentinel-edge/files-prepared.sha256
[ "$REINSTALL" = 0 ] && ok '系统服务入口已建立'

# ---- start ------------------------------------------------------------------
stage 5 "启动服务"
info '正在注册并启动服务…'
[ "$AUTOSTART" = 1 ] && { /etc/init.d/sentinel-edge enable && ok '开机启动已启用'; }
/etc/init.d/sentinel-edge start || true
info '正在等待服务就绪…'
READY=0 INFO=''
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  sleep 1
  INFO=$(curl -sk "https://$MGMT_IP:18081/api/bootstrap" 2>/dev/null || true)
  case "$INFO" in *'"version"'*) READY=1; break ;; esac
done
if [ "$READY" = 1 ]; then ok '服务已启动'; else warn '服务在 15 秒内未就绪'; fi

# ---- verify -------------------------------------------------------------------
stage 6 "验证$MODE_TXT 结果"
PANEL_VER=$(printf '%s' "$INFO" | tr -d ' \n' | sed -n 's/.*"version":*"\([0-9.]*\)".*/\1/p')
if [ "$READY" = 1 ] && [ "$PANEL_VER" = "$VERSION" ]; then
  ok "版本检查通过（v$PANEL_VER）"
  ok '服务状态正常'
else
  warn "面板版本读取为 '${PANEL_VER:-未响应}'，请稍后手动刷新确认"
fi

# ---- result block --------------------------------------------------------------
DURATION=$(( $(date +%s) - START_TS ))
printf '\n'
rule; printf '  %s完成\n' "$MODE_TXT"; rule
printf '\n'
if [ "$READY" = 1 ]; then printf '  服务状态    运行中\n'; else printf '  服务状态    启动中（请稍后刷新面板确认）\n'; fi
[ "$AUTOSTART" = 1 ] && printf '  开机启动    已启用\n' || printf '  开机启动    未启用（--no-autostart）\n'
printf '  当前版本    v%s\n' "$VERSION"
[ "$EXISTING" = 1 ] && printf '  版本变化    v%s → v%s\n' "$INSTALLED_VER" "$VERSION"
[ "$EXISTING" = 1 ] && printf '  配置处理    已保留\n'
[ -n "$BACKUP_PATH" ] && printf '  升级备份    %s\n' "$BACKUP_PATH"
printf '  访问地址    https://%s:18081\n' "$MGMT_IP"
printf '  登录账号    请联系供应商获取\n'
printf '  安装耗时    %d 秒\n' "$DURATION"
printf '\n'
printf '  下一步：浏览器打开访问地址（首次访问的证书提示选择继续），\n'
printf '  使用供应商提供的账号登录。\n'
printf '\n'
rule
