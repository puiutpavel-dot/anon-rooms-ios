#!/bin/bash
# Arhivă Release + export semnat în cloud (certificatul de distribuție îl gestionează Apple)
# + urcare în App Store Connect / TestFlight. Nu are nevoie de certificat sau profil local:
# doar de cheia App Store Connect API (rol Admin) din secretele GitHub.
set -e
APP_NAME="${APP_NAME:-AnonRooms}"
OUT_DIR="${OUT_DIR:-$PWD/ci-out}"; mkdir -p "$OUT_DIR"
: "${ASC_KEY_ID:?lipsește secretul ASC_KEY_ID}" "${ASC_ISSUER_ID:?lipsește secretul ASC_ISSUER_ID}"
: "${TEAM_ID:?lipsește TEAM_ID}" "${BUILD_NUMBER:?lipsește BUILD_NUMBER}"
KEY="$OUT_DIR/AuthKey_$ASC_KEY_ID.p8"
printf '%s\n' "$ASC_PRIVATE_KEY" > "$KEY"
trap 'rm -f "$KEY"' EXIT
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
echo "Echipa $TEAM_ID, build $BUILD_NUMBER"

archive() {  # $@ = setări de semnare
  rm -rf "$OUT_DIR/$APP_NAME.xcarchive"
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$OUT_DIR/$APP_NAME.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" DEVELOPMENT_TEAM="$TEAM_ID" "$@" \
    archive 2>&1 | tee "$OUT_DIR/archive.log" | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
  grep -q "ARCHIVE SUCCEEDED" "$OUT_DIR/archive.log"
}

set -o pipefail
if ! archive CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER=; then
  echo "Semnarea ad-hoc n-a mers; arhivez nesemnat:"; grep -E "error:" "$OUT_DIR/archive.log" | sort -u | head -20
  archive CODE_SIGNING_ALLOWED=NO || {
    echo "Arhivarea a eșuat"; grep -E "error:" "$OUT_DIR/archive.log" | sort -u | head -50; exit 1; }
fi

cat > "$OUT_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>${EXPORT_DESTINATION:-upload}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT_DIR/$APP_NAME.xcarchive" -exportPath "$OUT_DIR/export" \
  -exportOptionsPlist "$OUT_DIR/ExportOptions.plist" "${AUTH[@]}" 2>&1 | tee "$OUT_DIR/export.log" | tail -40
grep -qE "EXPORT SUCCEEDED|Upload succeeded|Uploaded" "$OUT_DIR/export.log" || { echo "Exportul / urcarea a eșuat"; exit 1; }
echo "Gata: build $BUILD_NUMBER urcat în App Store Connect (apare în TestFlight după procesare)."
