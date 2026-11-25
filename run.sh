#!/bin/sh
# 탭 앱 빌드 → 호스트 빌드 → 실행(탭 연결·앱 설치·재연결은 호스트가 처리). Ctrl-C로 종료.
set -e
cd "$(dirname "$0")"
(cd android && ./gradlew -q assembleDebug)
swift build -c release --package-path host
exec host/.build/release/submonitor --apk android/app/build/outputs/apk/debug/app-debug.apk "$@"
