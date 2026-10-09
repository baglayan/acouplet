#!/bin/sh
set -eu

driver_source="$(CDPATH= cd -- "$(dirname -- "$0")/../Helpers/LDAC/VirtualOutput" && pwd)"
driver_build="$(mktemp -d "${TMPDIR:-/tmp}/acouplet-virtual-output-check.XXXXXX")"
trap 'rm -rf "$driver_build"' EXIT HUP INT TERM

/usr/bin/xcrun --sdk macosx clang -std=gnu11 -fblocks -O2 -Werror -UNDEBUG -mmacosx-version-min=15.4 \
    -framework CoreAudio -framework CoreFoundation -framework Security "$driver_source/AcoupletVirtualOutputCheck.c" -o "$driver_build/check"
/usr/bin/python3 - "$driver_build/check" "$driver_source" <<'PY'
import pathlib, plistlib, re, subprocess, sys
source = pathlib.Path(sys.argv[2])
revision = int(re.search(r'kAcoupletDriverRevision = ([0-9]+);', (source / 'AcoupletVirtualOutput.c').read_text())[1])
assert plistlib.loads((source / 'Info.plist').read_bytes())['AcoupletLDACDriverRevision'] == revision
subprocess.run([sys.argv[1]], check=True, timeout=20)
PY
