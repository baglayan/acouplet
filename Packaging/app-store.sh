#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
unsigned=false
if (( $# )); then
    if (( $# != 1 )) || [[ "$1" != --unsigned ]]; then
        print -u2 "Usage: Packaging/app-store.sh [--unsigned]"
        exit 2
    fi
    unsigned=true
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
signing_settings=(CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES)
if [[ "$unsigned" == true ]]; then
    signing_settings+=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=)
else
    if [[ -z "${CODE_SIGN_IDENTITY:-}" || -z "${PROVISIONING_PROFILE_SPECIFIER:-}" ]]; then
        print -u2 "Set CODE_SIGN_IDENTITY to an existing Mac App Store distribution identity and PROVISIONING_PROFILE_SPECIFIER to its existing profile, or use --unsigned for a local artifact check."
        exit 1
    fi
    if [[ "$CODE_SIGN_IDENTITY" != "Apple Distribution"* && "$CODE_SIGN_IDENTITY" != "3rd Party Mac Developer Application"* ]]; then
        print -u2 "Use an existing Mac App Store distribution signing identity."
        exit 1
    fi
    signing_settings+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY" "ACOUPLET_APP_STORE_PROFILE=$PROVISIONING_PROFILE_SPECIFIER" CODE_SIGN_STYLE=Manual)
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
        signing_settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    fi
fi

mkdir -p "$repo_root/.build/app-store" "$repo_root/dist"
build_dir="$(mktemp -d "$repo_root/.build/app-store/archive.XXXXXX")"
archive_path="$build_dir/Acouplet.xcarchive"
/usr/bin/xcrun xcodebuild -project "$repo_root/Acouplet.xcodeproj" -scheme "Acouplet" \
    -configuration AppStore -destination 'generic/platform=macOS' \
    -derivedDataPath "$build_dir/DerivedData" -archivePath "$archive_path" \
    ACOUPLET_PUBLIC_APIS_ONLY=YES ACOUPLET_NO_SONY_ARTWORK=YES "${signing_settings[@]}" archive
/usr/bin/python3 "$repo_root/Packaging/check-store-bundle.py" "$archive_path"
if [[ "$unsigned" == false ]]; then
    /usr/bin/codesign --verify --deep --strict "$archive_path/Products/Applications/Acouplet.app"
fi
final_archive="$repo_root/dist/Acouplet App Store.xcarchive"
rm -rf "$final_archive"
mv "$archive_path" "$final_archive"
print -r -- "Archive: $final_archive"
if [[ "$unsigned" == true ]]; then
    print "Unsigned local validation artifact; distribution signing and Store validation are still required."
else
    print "Distribution-signed archive prepared; Store validation and submission are still required."
fi
