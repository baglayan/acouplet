#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
if (( $# != 2 )) || [[ ! -d "$1/Acouplet.app" ]]; then
    print -u2 "Usage: Packaging/create-dmg.sh STAGE_DIRECTORY OUTPUT.dmg (stage must contain Acouplet.app)"
    exit 2
fi
stage="${1:A}"
output="${2:A}"
appearance="${ACOUPLET_DMG_APPEARANCE:-pearl}"
if [[ "$appearance" != dark && "$appearance" != pearl ]]; then
    print -u2 "ACOUPLET_DMG_APPEARANCE must be dark or pearl."
    exit 2
fi
if [[ -e "$output" ]]; then
    print -u2 "The output disk image already exists: $output"
    exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp/}acouplet-dmg.XXXXXX")"
mount_point="$work/mount"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        /usr/bin/hdiutil detach "$mount_point" -quiet || /usr/bin/hdiutil detach "$mount_point" -force -quiet
    fi
    /bin/rm -rf "$work"
}
trap cleanup EXIT
mkdir "$mount_point"
size_kb=$(( $(/usr/bin/du -sk "$stage" | /usr/bin/awk '{print $1}') * 11 / 10 + 16384 ))
/usr/bin/hdiutil create -volname Acouplet -srcfolder "$stage" -fs HFS+ -format UDRW -size "${size_kb}k" "$work/layout.dmg" -quiet
/usr/bin/hdiutil attach "$work/layout.dmg" -mountpoint "$mount_point" -readwrite -noverify -noautoopen -nobrowse -quiet
mounted=true
mkdir -p "$mount_point/.background"
if [[ ! -e "$mount_point/Applications" ]]; then /bin/ln -s /Applications "$mount_point/Applications"; fi
/usr/bin/swift "$repo_root/Packaging/DMGBackground.swift" \
    "$mount_point/Acouplet.app/Contents/Resources/AppIcon.icns" "$mount_point/.background/background.tiff" "$appearance"
/usr/bin/osascript - "$mount_point" <<'APPLESCRIPT'
on run arguments
    set volumeFolder to POSIX file (item 1 of arguments) as alias
    tell application "Finder"
        set diskWindow to make new Finder window to volumeFolder
        set current view of diskWindow to icon view
        set toolbar visible of diskWindow to false
        set statusbar visible of diskWindow to false
        set pathbar visible of diskWindow to false
        set options to icon view options of diskWindow
        set arrangement of options to not arranged
        set icon size of options to 112
        set text size of options to 13
        set label position of options to bottom
        set background color of options to {0, 0, 0}
        set background picture of options to file ".background:background.tiff" of volumeFolder
        set position of item "Acouplet.app" of volumeFolder to {170, 145}
        set position of item "Applications" of volumeFolder to {510, 145}
        set position of item ".background" of volumeFolder to {1000, 1000}
        update volumeFolder without registering applications
        delay 2
        set bounds of diskWindow to {180, 160, 860, 598}
        delay 1
        close diskWindow
        delay 2
    end tell
end run
APPLESCRIPT
/bin/sync
if [[ ! -s "$mount_point/.DS_Store" ]]; then
    print -u2 "Finder did not save the disk image layout."
    exit 1
fi
/usr/bin/hdiutil detach "$mount_point" -quiet
mounted=false
/usr/bin/hdiutil attach "$work/layout.dmg" -mountpoint "$mount_point" -readwrite -noverify -noautoopen -nobrowse -quiet
mounted=true
/usr/bin/python3 - "$mount_point/.DS_Store" <<'PYTHON'
import struct
import sys
from pathlib import Path

store = Path(sys.argv[1])
data = bytearray(store.read_bytes())
record = data.index(b"bwspblob") + 8
size = struct.unpack_from(">I", data, record)[0]
start = record + 4
window = data[start:start + size]
offset_size, _, count, _, table = struct.unpack(">6xBBQQQ", window[-32:])
for index in range(count):
    offset = int.from_bytes(window[table + index * offset_size:table + (index + 1) * offset_size], "big")
    if window[offset] == 0x09:
        data[start + offset] = 0x08
store.write_bytes(data)
PYTHON
/usr/bin/hdiutil detach "$mount_point" -quiet
mounted=false
/usr/bin/hdiutil convert "$work/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$output" -quiet
print -r -- "Created disk image: $output"
