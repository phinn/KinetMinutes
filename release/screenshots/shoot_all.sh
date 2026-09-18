#!/bin/bash
# KinetMinutes 截图:实启 app(指定语言)→ 打开会议库 → 截屏 2560×1600
# 用法: KM_LANGS="zh-Hans en ja zh-Hant" ./shoot_all.sh
set -e
cd "$(dirname "$0")"
LANGS="${KM_LANGS:-en ja zh-Hans zh-Hant}"
APP="/tmp/KinetMinutes.app"
OUT_ROOT="$(cd ../.. && pwd)/release/screenshots"

pkill -f "$APP/Contents/MacOS/KinetMinutes" 2>/dev/null || true
sleep 1

for LANG in $LANGS; do
  mkdir -p "$OUT_ROOT/$LANG"
  (KM_AUTO_OPEN=1 KM_LANG="$LANG" "$APP/Contents/MacOS/KinetMinutes" &>/dev/null &)
  sleep 5
  # 找 KinetMinutes 窗口并截屏(screencapture -l 按窗口 ID)
  WID=$(python3 - <<EOF
import Quartz, json
wl = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
for w in wl:
    name = w.get('kCGWindowOwnerName','')
    if 'KinetMinutes' in name:
        bounds = w.get('kCGWindowBounds')
        if bounds and bounds['Width'] > 500:
            print(w['kCGWindowNumber']); break
EOF
)
  if [ -n "$WID" ]; then
    screencapture -o -l "$WID" "$OUT_ROOT/$LANG/01-library.png"
    echo "shot $LANG wid=$WID"
  else
    echo "no window for $LANG"
  fi
  osascript -e 'tell application "KinetMinutes" to quit' 2>/dev/null || pkill -f "$APP/Contents/MacOS/KinetMinutes"
  sleep 2
done
echo done
