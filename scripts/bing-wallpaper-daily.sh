#!/bin/bash
# ============================================================
#  bing-wallpaper-daily.sh
#  每天抓取 Bing 每日壁纸，设为飞牛 fnOS 登录页 / 桌面背景
#
#  用法:
#    bing-wallpaper-daily.sh            抓当日壁纸并应用（同一天不重复）
#    bing-wallpaper-daily.sh --force    强制重新下载并应用
#    bing-wallpaper-daily.sh --dry-run  只下载，不修改系统
#
#  环境变量:
#    BING_MARKET   地区，默认 zh-CN（en-US / ja-JP 等为 Bing 当地每日图）
#    BING_KEEP     本地保留最近几张原图，默认 7
#
#  依赖: curl + ffmpeg + 同目录的 fnos-wallpaper-set.sh
#  建议由 root 的 cron 调用
# ============================================================

set -uo pipefail

DATA_DIR="/var/lib/fnos-wallpaper"
WALL_DIR="$DATA_DIR/wallpapers"
STATE_FILE="$DATA_DIR/last_startdate"
LOG_FILE="/var/log/fnos-bing-wallpaper.log"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SELF_DIR/fnos-wallpaper-set.sh" ]; then
  CHANGER="$SELF_DIR/fnos-wallpaper-set.sh"
elif [ -x "/usr/local/sbin/fnos-wallpaper-set.sh" ]; then
  CHANGER="/usr/local/sbin/fnos-wallpaper-set.sh"
else
  CHANGER="$SELF_DIR/fnos-wallpaper-set.sh"
fi

MARKET="${BING_MARKET:-zh-CN}"
KEEP="${BING_KEEP:-7}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

FORCE=0
DRY=0
for a in "$@"; do
  case "$a" in
    --force)   FORCE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $a（可用 --force / --dry-run / --help）" >&2; exit 2 ;;
  esac
done

mkdir -p "$WALL_DIR" 2>/dev/null || { echo "无法创建 $WALL_DIR（需要 root）" >&2; exit 1; }

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# 日志超过 512 KB 时只保留最近 300 行
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 524288 ]; then
  tail -n 300 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# ---------- 1. 取 Bing 元数据 ----------
fetch_meta() {
  local host json i
  for host in cn.bing.com www.bing.com; do
    for i in 1 2 3; do
      json=$(curl -fsSL --max-time 20 -A "$UA" \
        "https://$host/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=$MARKET" 2>/dev/null)
      if [ -n "${json:-}" ] && printf '%s' "$json" | grep -q '"urlbase"'; then
        printf '%s' "$json"
        return 0
      fi
      log "取元数据失败 ($host 第 ${i} 次)，5 秒后重试"
      sleep 5
    done
  done
  return 1
}

JSON=$(fetch_meta) || { log "ERROR 无法获取 Bing 壁纸信息，本次跳过"; echo "无法获取 Bing 壁纸信息" >&2; exit 1; }

STARTDATE=$(printf '%s' "$JSON"  | sed -n 's/.*"startdate":"\([0-9]\{8\}\)".*/\1/p' | head -1)
URLBASE=$(printf '%s' "$JSON"    | sed -n 's/.*"urlbase":"\([^"]*\)".*/\1/p'                | head -1)
COPYRIGHT=$(printf '%s' "$JSON"  | sed -n 's/.*"copyright":"\([^"]*\)".*/\1/p'              | head -1)
TITLE=$(printf '%s' "$JSON"      | sed -n 's/.*"title":"\([^"]*\)".*/\1/p'                  | head -1)

if [ -z "$STARTDATE" ] || [ -z "$URLBASE" ]; then
  log "ERROR 元数据解析失败 startdate='$STARTDATE' urlbase='$URLBASE'"
  exit 1
fi

# ---------- 2. 同一天不重复处理 ----------
if [ "$FORCE" -eq 0 ] && [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$STARTDATE" ]; then
  log "今日壁纸 ($STARTDATE) 已应用，跳过：${TITLE:-$COPYRIGHT}"
  echo "今日壁纸已应用，无需重复操作（用 --force 可强制重设）"
  exit 0
fi

log "开始处理 Bing 壁纸 $STARTDATE | ${TITLE:-} | ${COPYRIGHT:-}"

# ---------- 3. 下载（优先 4K，失败退 1080p） ----------
TARGET="$WALL_DIR/bing-$STARTDATE.jpg"
TMP="$TARGET.part"
rm -f "$TMP"

download() {
  local url="$1" sz
  curl -fsSL --max-time 120 -A "$UA" --retry 2 --retry-delay 3 -o "$TMP" "$url" 2>/dev/null || return 1
  sz=$(stat -c%s "$TMP" 2>/dev/null || echo 0)
  [ "$sz" -gt 100000 ] || { rm -f "$TMP"; return 1; }
  return 0
}

if download "https://cn.bing.com${URLBASE}_UHD.jpg"; then
  log "下载 4K 版本成功 ($(stat -c%s "$TMP") 字节)"
elif download "https://cn.bing.com${URLBASE}_1920x1080.jpg"; then
  log "下载 1080p 版本成功 ($(stat -c%s "$TMP") 字节)"
else
  log "ERROR 图片下载失败，本次跳过"
  echo "图片下载失败" >&2
  exit 1
fi

mv -f "$TMP" "$TARGET" || { log "ERROR 保存图片失败"; exit 1; }

if [ "$DRY" -eq 1 ]; then
  log "DRY-RUN 已下载到 $TARGET，未修改系统"
  echo "已下载到 $TARGET（仅试运行，未修改系统）"
  exit 0
fi

# ---------- 4. 应用 ----------
[ -f "$CHANGER" ] || { log "ERROR 找不到 $CHANGER"; echo "找不到 fnos-wallpaper-set.sh" >&2; exit 1; }

if bash "$CHANGER" "$TARGET" >> "$LOG_FILE" 2>&1; then
  echo "$STARTDATE" > "$STATE_FILE"
  log "OK 壁纸已更新为 $STARTDATE"
  echo "壁纸已更新：${TITLE:-$COPYRIGHT}"
else
  log "ERROR fnos-wallpaper-set.sh 执行失败，详见日志 $LOG_FILE"
  echo "应用失败，详见日志 $LOG_FILE" >&2
  exit 1
fi

# ---------- 5. 清理旧图 ----------
ls -1t "$WALL_DIR"/bing-*.jpg 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old"
done

exit 0
