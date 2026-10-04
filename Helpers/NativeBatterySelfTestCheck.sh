#!/bin/sh
set -eu

battery_source="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
battery_build="$(mktemp -d "${TMPDIR:-/tmp}/sony-native-battery-self-test.XXXXXX")"
trap 'rm -rf "$battery_build"' EXIT HUP INT TERM

/usr/bin/xcrun --sdk macosx clang -fobjc-arc -mmacosx-version-min=15.4 -O2 -UNDEBUG -framework Foundation -framework IOKit -framework IOBluetooth "$battery_source/SonyNativeBatteryBridge.m" -o "$battery_build/check"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none --entitlements "$battery_source/BatteryHelper.entitlements" --generate-entitlement-der "$battery_build/check"
/usr/bin/codesign --verify --strict "$battery_build/check"
/usr/bin/python3 - "$battery_build/check" <<'PY'
import plistlib, re, subprocess, sys
binary = sys.argv[1]
entitlements = plistlib.loads(subprocess.check_output(['/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', binary], stderr=subprocess.DEVNULL))
assert not any(key.startswith('com.apple.security.') for key in entitlements)
signature = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=2', binary], capture_output=True, text=True, check=True).stderr
assert re.search(r'^CodeDirectory .*flags=.*\bruntime\b', signature, re.MULTILINE)
PY
"$battery_build/check" --self-test
/usr/bin/xcrun --sdk macosx clang -fobjc-arc -mmacosx-version-min=15.4 -O2 -UNDEBUG -framework Foundation -framework IOKit -framework IOBluetooth "$battery_source/NativeBatteryCleanupCheck.m" -o "$battery_build/cleanup-check"
"$battery_build/cleanup-check"
