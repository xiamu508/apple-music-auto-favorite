#!/usr/bin/env bash
set -euo pipefail

# 流程:
# 1. 读取本机正在播放的歌曲(Music/Spotify, AppleScript, 不再依赖 MediaRemote)
# 2. 用 iTunes Search API 在 Apple Music 目录中查找并核验歌手+歌名(含简繁转换)
# 3. 核验通过后在 Music.app 中打开该歌曲页面(不会自动播放)
# 4. 通过辅助功能点击歌曲行的"更多"按钮 -> 弹出菜单 -> 点击"喜爱"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/read-now-playing.applescript"
READER_SWIFT_SRC="$SCRIPT_DIR/read-now-playing.swift"
MATCHER="$SCRIPT_DIR/match_apple_music_track.py"
FAVORITER="$SCRIPT_DIR/favorite-track.applescript"

die() {
  alert "Apple Music 收藏失败" "$1"
  echo "$1" >&2
  exit 1
}

alert() {
  /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display alert (item 1 of argv) message (item 2 of argv) as warning
end run
APPLESCRIPT
}

notify() {
  /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

json_get() {
  JSON_INPUT="$1" JSON_PATH="$2" /usr/bin/python3 - <<'PY' 2>/dev/null || true
import json
import os

value = json.loads(os.environ["JSON_INPUT"])
for part in os.environ["JSON_PATH"].split("."):
    if not part:
        continue
    value = value.get(part, "") if isinstance(value, dict) else ""
print("" if value is None else value)
PY
}

urlencode() {
  TEXT_TO_ENCODE="$1" /usr/bin/python3 - <<'PY'
import os
import urllib.parse

print(urllib.parse.quote(os.environ["TEXT_TO_ENCODE"]))
PY
}

# ---------- 第 1 步: 读取正在播放 ----------

# 读取正在播放:
# 优先系统级 Now Playing(MediaRemote, 覆盖 Music/Spotify/网易云/浏览器网页等任意来源)，
# 读不到再回退 AppleScript 直接询问 Music/Spotify。两者输出同为三行(来源/歌名/歌手)。
#
# 注: MediaRemote 在 macOS 15.4+ 只向 Apple 平台签名的进程返回数据，所以这里用
# Apple 自带且已签名的 `swift` 解释器直接跑脚本(不能编译成本地二进制，否则拿到空数据)。
# 拿不到 `swift`(未装 Xcode/命令行工具) 时自动回退到 AppleScript。
read_now_playing() {
  if command -v swift >/dev/null 2>&1; then
    local mediaremote_out
    mediaremote_out="$(swift "$READER_SWIFT_SRC" 2>/dev/null || true)"
    if [[ -n "$(printf '%s\n' "$mediaremote_out" | sed -n '2p')" ]]; then
      printf '%s' "$mediaremote_out"
      return 0
    fi
  fi
  /usr/bin/osascript "$READER" 2>/dev/null || true
}

now_playing="$(read_now_playing)"

source_app=""
title=""
artist=""
if [[ -n "$now_playing" ]]; then
  source_app="$(printf '%s\n' "$now_playing" | sed -n '1p')"
  title="$(printf '%s\n' "$now_playing" | sed -n '2p')"
  artist="$(printf '%s\n' "$now_playing" | sed -n '3p')"
fi

if [[ -z "$title" ]]; then
  manual="$(osascript -e 'text returned of (display dialog "没有读到 Music/Spotify 的正在播放信息，请手动输入：歌名 - 歌手" default answer "" buttons {"取消", "搜索"} default button "搜索")' 2>/dev/null || true)"
  [[ -n "$manual" ]] || die "没有拿到歌名。请先在 Music 或 Spotify 里播放歌曲，或手动输入。"
  parsed="$(
    MANUAL_INPUT="$manual" /usr/bin/python3 - <<'PY'
import os
import re

text = os.environ.get("MANUAL_INPUT", "").strip()
parts = re.split(r"\s+[-–—|/／]\s+", text, maxsplit=1)
if len(parts) == 2:
    print(parts[0])
    print(parts[1])
else:
    print(text)
    print("")
PY
  )"
  title="$(printf '%s\n' "$parsed" | sed -n '1p')"
  artist="$(printf '%s\n' "$parsed" | sed -n '2p')"
fi

[[ -n "$title" ]] || die "没有拿到歌名。"

query="$title"
if [[ -n "$artist" ]]; then
  query="$title $artist"
fi

# ---------- 第 2 步: Apple Music 查找 + 核验 ----------

match_json="$(
  "$MATCHER" --title "$title" --artist "$artist" --countries "${APPLE_MUSIC_COUNTRIES:-CN,HK,TW,US,JP}" 2>/dev/null || true
)"

status="$(json_get "$match_json" "status")"
reason="$(json_get "$match_json" "reason")"
available_in_home="$(json_get "$match_json" "available_in_home")"
home_country="$(json_get "$match_json" "home_country")"
matched_title="$(json_get "$match_json" "match.title")"
matched_title_simplified="$(json_get "$match_json" "match.title_simplified")"
matched_title_traditional="$(json_get "$match_json" "match.title_traditional")"
matched_artist="$(json_get "$match_json" "match.artist")"
matched_album="$(json_get "$match_json" "match.album")"
music_url="$(json_get "$match_json" "match.music_url")"

if [[ "$status" != "matched" || -z "$music_url" ]]; then
  encoded="$(urlencode "$query")"
  open "music://music.apple.com/search?term=$encoded" || open "https://music.apple.com/search?term=$encoded"

  message="没有安全核对通过，已打开 Apple Music 搜索让你手动确认。"
  if [[ -n "$matched_title" ]]; then
    message="$message"$'\n\n'"最接近候选：$matched_title - $matched_artist"
  elif [[ "$reason" == "missing_artist" ]]; then
    message="$message"$'\n\n'"原因：没有读到歌手名。"
  elif [[ "$reason" == "search_failed" ]]; then
    message="$message"$'\n\n'"原因：Apple Music 在线搜索失败。"
  fi

  alert "需要手动验证" "$message"
  exit 0
fi

# 核对成功但该版本只在其他地区商店有(如香港店的 Live 版)，
# 本区账户打不开跨区链接，直接提示并打开搜索页
if [[ "$available_in_home" == "False" || "$available_in_home" == "false" ]]; then
  encoded="$(urlencode "$query")"
  open "music://music.apple.com/search?term=$encoded" || open "https://music.apple.com/search?term=$encoded"
  alert "歌曲不在本区商店" "已核对：$matched_title - $matched_artist"$'\n\n'"但这个版本只在 ${home_country} 以外的地区商店提供，你的账户无法直接打开。已打开搜索页，可手动收藏相近版本。"
  exit 0
fi

# ---------- 第 3/4 步: 打开歌曲页(不自动播放) + 点"更多">"喜爱" ----------

open_song_page() {
  # 注意: Music 未激活时直接 open location 偶尔不跳转，先 activate 再打开
  /usr/bin/osascript - "$music_url" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  tell application "Music" to activate
  delay 0.5
  tell application "Music" to open location (item 1 of argv)
end run
APPLESCRIPT
}

run_favoriter() {
  /usr/bin/osascript "$FAVORITER" \
    "$matched_title" \
    "$matched_title_simplified" \
    "$matched_title_traditional" 2>/dev/null || echo "helper_error"
}

open_song_page
sleep 1
favorite_result="$(run_favoriter)"

# Music 页面偶发加载失败/跳转不生效，重开链接最多再试 2 轮
for retry in 1 2; do
  [[ "$favorite_result" == "not_found" ]] || break
  open_song_page
  sleep 1.5
  favorite_result="$(run_favoriter)"
done

case "$favorite_result" in
  favorited)
    notify "Apple Music" "已核对并收藏：$matched_title - $matched_artist"
    ;;
  already_favorite)
    notify "Apple Music" "这首歌已经在喜爱中：$matched_title - $matched_artist"
    ;;
  accessibility_denied)
    alert "需要辅助功能授权" "已核对并打开匹配歌曲：$matched_title - $matched_artist"$'\n\n'"请在 系统设置 > 隐私与安全性 > 辅助功能 中允许运行此脚本的应用(终端/快捷指令)，然后重新运行。"
    ;;
  not_found)
    alert "已核对，需要手动点收藏" "已打开专辑页：$matched_title - $matched_artist"$'\n'"专辑：$matched_album"$'\n\n'"没有在当前页面找到该歌曲行，请手动点击歌曲旁的“更多(…)”>“喜爱”。"
    ;;
  *)
    alert "已核对，需要手动点收藏" "已打开专辑页：$matched_title - $matched_artist"$'\n'"专辑：$matched_album"$'\n\n'"自动点击“更多 > 喜爱”没有成功($favorite_result)，请手动确认。运行期间请不要点击其他窗口。"
    ;;
esac
