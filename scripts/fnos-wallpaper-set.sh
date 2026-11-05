#!/bin/bash
# ============================================================
#  fnos-wallpaper-set.sh
#  设置飞牛 fnOS 登录页 / 桌面壁纸（webp 转码版）
#
#  用法:
#    fnos-wallpaper-set.sh <图片路径>   # 设置壁纸（jpg/png/webp/gif 均可）
#    fnos-wallpaper-set.sh --restore    # 恢复系统原始壁纸
#    fnos-wallpaper-set.sh --status     # 查看当前状态
#
#  环境变量:
#    WALLPAPER_WIDTH    大图最大宽度，默认 2560（不会放大原图）
#    WALLPAPER_QUALITY  webp 质量 0-100，默认 85
#
#  说明:
#    飞牛的桌面壁纸和登录页壁纸共用 wallpaper-1.webp 这一个文件，
#    因此替换一次，两处会同时生效。
#
#    飞牛有守护进程会在数秒内把壁纸文件还原成系统原图，必须给目标文件
#    加 append-only 属性锁住；脚本会在替换的瞬间临时解锁、写完立刻加锁。
#
#    系统原始壁纸首次替换前会备份到 /var/lib/fnos-wallpaper/orig/，
#    随时可用 --restore 还原。
# ============================================================

set -uo pipefail

BG_DIR="/usr/trim/www/static/bg"
TH_DIR="/usr/trim/www/static/thumbnail_bg"
BG="$BG_DIR/wallpaper-1.webp"
TH="$TH_DIR/wallpaper-1.webp"

WIDTH="${WALLPAPER_WIDTH:-2560}"
QUALITY="${WALLPAPER_QUALITY:-85}"
THUMB_WIDTH="${WALLPAPER_THUMB_WIDTH:-350}"
THUMB_QUALITY="${WALLPAPER_THUMB_QUALITY:-80}"

FFMPEG="$(command -v ffmpeg || true)"
NGINX_SVC="${FNOS_NGINX_SVC:-trim_nginx}"

DATA_DIR="/var/lib/fnos-wallpaper"
ORIG_DIR="$DATA_DIR/orig"
# 兼容本工具早期版本用过的备份目录
LEGACY_ORIG_DIR="/var/lib/bing-wallpaper/orig"

# chattr 路径：也被其它工具改名成 chattrx 的情况一并兼容
CHATTR=""
for c in /usr/bin/chattr /usr/bin/chattrx /usr/sbin/chattr /sbin/chattr; do
  [ -x "$c" ] && { CHATTR="$c"; break; }
done

die()  { echo "错误: $*" >&2; exit 1; }
info() { echo "  $*"; }
warn() { echo "  警告: $*" >&2; }

usage() {
  cat <<'USAGE'
用法:
  fnos-wallpaper-set.sh <图片路径>   设置壁纸（jpg/png/webp/gif）
  fnos-wallpaper-set.sh --restore    恢复系统原始壁纸
  fnos-wallpaper-set.sh --status     查看当前壁纸状态

环境变量:
  WALLPAPER_WIDTH        大图最大宽度，默认 2560（不会放大原图）
  WALLPAPER_QUALITY      webp 质量 0-100，默认 85
  WALLPAPER_THUMB_WIDTH  缩略图宽度，默认 350

示例:
  sudo fnos-wallpaper-set.sh /vol1/1000/壁纸.jpg
  sudo WALLPAPER_WIDTH=3840 WALLPAPER_QUALITY=90 fnos-wallpaper-set.sh pic.png
USAGE
}

# 加锁 / 解锁：飞牛守护进程靠 append-only 属性挡住
lock_file()   { [ -n "$CHATTR" ] && "$CHATTR" +ai "$1" 2>/dev/null; return 0; }
unlock_file() { [ -n "$CHATTR" ] && "$CHATTR" -ai "$1" 2>/dev/null; return 0; }

reload_nginx() {
  if systemctl reload "$NGINX_SVC" 2>/dev/null; then
    info "nginx 已平滑重载"
  elif systemctl restart "$NGINX_SVC" 2>/dev/null; then
    info "nginx 已重启"
  else
    warn "nginx 重载失败，可手动执行: systemctl restart $NGINX_SVC"
  fi
}

# 转码为 webp。宽度超过 maxw 时等比缩小，不放大。
#
# 注意: 飞牛限制了 ffmpeg 直接写入 /usr/trim/www（会报 ENOENT），
#       而 cp 可以写入。所以先转码到 /tmp，再复制进去。
transcode() {
  local src="$1" out="$2" maxw="$3" q="$4"
  local vf="scale='min(${maxw},iw)':-2:flags=lanczos"
  "$FFMPEG" -y -hide_banner -loglevel error \
    -i "$src" -vf "$vf" \
    -c:v libwebp -quality "$q" -compression_level 4 \
    -f webp "$out" || return 1
  [ -s "$out" ] || return 1
  return 0
}

# 解锁 → 覆盖 → 立刻上锁。
# 无锁窗口必须尽可能短：飞牛守护进程会在这个间隙重建 static 目录。
install_file() {
  local tmp="$1" dst="$2"
  unlock_file "$dst"
  if cp -f "$tmp" "$dst" 2>/dev/null; then
    chmod 644 "$dst" 2>/dev/null
    lock_file "$dst"
    return 0
  fi
  lock_file "$dst"
  return 1
}

# 找可用的原始壁纸备份
find_orig() {
  local name="$1" f
  for f in "$ORIG_DIR/$name" "$LEGACY_ORIG_DIR/$name"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

[ "$(id -u)" -eq 0 ] || die "需要 root 权限运行，请用 sudo"

case "${1:-}" in
  ""|-h|--help)
    usage
    ;;

  --status)
    echo "大图:   $BG"
    if [ -f "$BG" ]; then ls -la "$BG"; lsattr "$BG" 2>/dev/null; else echo "  (不存在)"; fi
    echo "缩略图: $TH"
    if [ -f "$TH" ]; then ls -la "$TH"; lsattr "$TH" 2>/dev/null; else echo "  (不存在)"; fi
    echo "原始备份:"
    if [ -d "$ORIG_DIR" ] || [ -d "$LEGACY_ORIG_DIR" ]; then
      ls -la "$ORIG_DIR" "$LEGACY_ORIG_DIR" 2>/dev/null
    else
      echo "  (无)"
    fi
    ;;

  --restore)
    echo "恢复系统原始壁纸..."
    RB="$(find_orig wallpaper-1.webp.orig)" || die "找不到原始壁纸备份，无法恢复"
    RT="$(find_orig thumb-1.webp.orig || true)"

    unlock_file "$BG"; unlock_file "$TH"
    cp -a "$RB" "$BG" && chmod 644 "$BG" && info "已恢复大图 (来源 $RB)"
    if [ -n "${RT:-}" ] && [ -f "$RT" ]; then
      cp -a "$RT" "$TH" && chmod 644 "$TH" && info "已恢复缩略图"
    fi
    # 恢复默认后不再加锁，让系统回到原生状态
    reload_nginx
    echo "完成。"
    ;;

  *)
    SRC="$1"
    [ -f "$SRC" ] || die "源文件不存在: $SRC"
    [ -n "$FFMPEG" ] || die "找不到 ffmpeg，请先安装（Debian/Ubuntu: apt install ffmpeg）"
    [ -d "$BG_DIR" ] || die "目录不存在: $BG_DIR（请确认这是飞牛 fnOS 系统）"

    HAS_THUMB=1
    [ -d "$TH_DIR" ] || { HAS_THUMB=0; warn "缩略图目录不存在，跳过缩略图: $TH_DIR"; }

    echo "源图: $SRC"

    # 原始备份只做一次，且以 DATA_DIR 下这份为准。
    # 不能依赖同目录的 .orig（会被守护进程清理），也不能在 .orig 消失后
    # 重新备份 —— 那时目标文件可能已经是新图，会把新图误当原图。
    mkdir -p "$ORIG_DIR"

    # 若旧版（数据目录改名之前）已备份过，先迁移过来，
    # 否则会把当前可能已经是新图的文件误当系统原图备份。
    if [ ! -f "$ORIG_DIR/wallpaper-1.webp.orig" ] && [ -f "$LEGACY_ORIG_DIR/wallpaper-1.webp.orig" ]; then
      cp -a "$LEGACY_ORIG_DIR/wallpaper-1.webp.orig" "$ORIG_DIR/wallpaper-1.webp.orig" \
        && info "已迁移原有系统壁纸备份"
    fi
    if [ "$HAS_THUMB" -eq 1 ] && [ ! -f "$ORIG_DIR/thumb-1.webp.orig" ] && [ -f "$LEGACY_ORIG_DIR/thumb-1.webp.orig" ]; then
      cp -a "$LEGACY_ORIG_DIR/thumb-1.webp.orig" "$ORIG_DIR/thumb-1.webp.orig" \
        && info "已迁移原有缩略图备份"
    fi

    if [ ! -f "$ORIG_DIR/wallpaper-1.webp.orig" ] && [ -f "$BG" ]; then
      unlock_file "$BG"
      cp -a "$BG" "$ORIG_DIR/wallpaper-1.webp.orig" && info "已保存系统原始大图备份"
    fi
    if [ "$HAS_THUMB" -eq 1 ] && [ ! -f "$ORIG_DIR/thumb-1.webp.orig" ] && [ -f "$TH" ]; then
      unlock_file "$TH"
      cp -a "$TH" "$ORIG_DIR/thumb-1.webp.orig" && info "已保存系统原始缩略图备份"
    fi

    # 先把两张图都转码到 /tmp（耗时步骤，完全不碰系统目录）
    TMP_BG="/tmp/fnos-bg-$$-$(date +%s).webp"
    TMP_TH="/tmp/fnos-th-$$-$(date +%s).webp"
    trap 'rm -f "$TMP_BG" "$TMP_TH"' EXIT

    transcode "$SRC" "$TMP_BG" "$WIDTH" "$QUALITY" \
      || die "大图转码失败（源文件可能不是有效图片）"
    info "大图转码完成 ($(stat -c%s "$TMP_BG") 字节)"

    if [ "$HAS_THUMB" -eq 1 ]; then
      transcode "$SRC" "$TMP_TH" "$THUMB_WIDTH" "$THUMB_QUALITY" \
        || die "缩略图转码失败"
      info "缩略图转码完成 ($(stat -c%s "$TMP_TH") 字节)"
    fi

    # 再逐张「解锁 → 覆盖 → 立刻上锁」
    install_file "$TMP_BG" "$BG" || die "替换大图失败"
    info "大图已更新 ($(stat -c%s "$BG") 字节)"

    if [ "$HAS_THUMB" -eq 1 ]; then
      install_file "$TMP_TH" "$TH" || die "替换缩略图失败"
      info "缩略图已更新 ($(stat -c%s "$TH") 字节)"
    fi

    [ -n "$CHATTR" ] && info "已加文件锁" || warn "未找到 chattr，壁纸可能被系统还原"

    reload_nginx
    echo "完成。刷新页面（F5）即可看到新壁纸。"
    ;;
esac
