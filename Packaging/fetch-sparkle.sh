#!/bin/zsh
set -euo pipefail

if [[ "${ACOUPLET_SPARKLE_ENABLED:-YES}" == NO || "${ACOUPLET_PUBLIC_APIS_ONLY:-NO}" == YES || "${CONFIGURATION:-}" == AppStore ]]; then exit 0; fi
repo_root="${0:A:h:h}"
dependency="$repo_root/.build/Sparkle-2.10.0"
if [[ -d "$dependency/Sparkle.framework" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dependency/Sparkle.framework/Resources/Info.plist")" == 2.10.0 ]]
    exit 0
fi
if [[ -e "$dependency" ]]; then
    print -u2 "The Sparkle dependency directory is incomplete. Remove it before fetching again."
    exit 1
fi
mkdir -p "$repo_root/.build"
download="$(mktemp -d "$repo_root/.build/sparkle-download.XXXXXX")"
trap 'rm -rf "$download"' EXIT
archive="$download/Sparkle-2.10.0.tar.xz"
/usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
print -r -- "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  $archive" | /usr/bin/shasum -a 256 -c -
mkdir "$download/extracted"
/usr/bin/tar -xJf "$archive" -C "$download/extracted"
mv "$download/extracted" "$dependency"
print -r -- "Sparkle 2.10.0: $dependency"
