#!/bin/sh
set -eu

sparkle_output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Frameworks/Sparkle.framework"
if [ "${ACOUPLET_SPARKLE_ENABLED:-NO}" != YES ]; then
    rm -rf "$sparkle_output"
    rm -f "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/Sparkle-LICENSE.txt"
    exit 0
fi
sparkle_source="$SRCROOT/.build/Sparkle-2.10.0"
if [ ! -d "$sparkle_source/Sparkle.framework" ]; then
    printf '%s\n' 'Run Packaging/fetch-sparkle.sh before building the direct edition.' >&2
    exit 1
fi
if [ "$CONFIGURATION" != Debug ]; then
    /usr/bin/python3 - "$ACOUPLET_SPARKLE_PUBLIC_KEY" <<'PY'
import base64, sys
key = base64.b64decode(sys.argv[1], validate=True)
if len(key) != 32 or not any(key):
    sys.exit('Configure the real Sparkle Ed25519 public key before building Release.')
PY
fi
mkdir -p "$(dirname -- "$sparkle_output")"
rm -rf "$sparkle_output"
/usr/bin/ditto "$sparkle_source/Sparkle.framework" "$sparkle_output"
rm -rf "$sparkle_output/Versions/B/XPCServices/Downloader.xpc"
/bin/cp "$sparkle_source/LICENSE" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/Sparkle-LICENSE.txt"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
    for sparkle_code in "$sparkle_output/Versions/B/XPCServices/Installer.xpc" "$sparkle_output/Versions/B/Autoupdate" "$sparkle_output/Versions/B/Updater.app" "$sparkle_output"; do
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$sparkle_code"
    done
fi
