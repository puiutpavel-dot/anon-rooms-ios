#!/bin/bash
# Build pentru simulator (fără semnare). Folosește OUT_DIR (implicit ./ci-out).
set -o pipefail
APP_NAME="${APP_NAME:-AnonRooms}"
OUT_DIR="${OUT_DIR:-$PWD/ci-out}"; mkdir -p "$OUT_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$OUT_DIR/dd" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$OUT_DIR/build.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" \
|| true
grep -q "BUILD SUCCEEDED" "$OUT_DIR/build.log" || {
  echo "===== ERORI ====="; grep -E "error:" "$OUT_DIR/build.log" | sort -u | head -100; exit 1; }
# Verificare: limbile au ajuns în aplicație.
APP="$OUT_DIR/dd/Build/Products/Debug-iphonesimulator/$APP_NAME.app"
echo "Limbi în aplicație: $(ls "$APP" | grep '\.lproj' | sed 's/\.lproj//' | tr '\n' ' ')"
echo "Avertismente din codul aplicației:"
grep 'warning:' "$OUT_DIR/build.log" | grep "/AnonRooms/" | sed 's/.*AnonRooms\///' | sort -u | head -30 || true
