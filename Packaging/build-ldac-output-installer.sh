#!/bin/sh
set -eu

if [ "$#" != 3 ]; then
    printf '%s\n' 'Usage: build-ldac-output-installer.sh DRIVER PACKAGE VERSION' >&2
    exit 2
fi
ldac_driver="$1"
ldac_package="$2"
ldac_version="$3"
ldac_packaging="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -L "$ldac_driver" ] || [ ! -d "$ldac_driver" ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ldac_driver/Contents/Info.plist")" != dev.baglayan.Acouplet.LDACOutput ]; then
    printf '%s\n' 'The driver does not match the owned Acouplet LDAC output identity.' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict --all-architectures "$ldac_driver"
ldac_stage="$(mktemp -d "${TMPDIR:-/tmp}/acouplet-ldac-output-package.XXXXXX")"
trap 'rm -rf "$ldac_stage"' EXIT HUP INT TERM
ldac_team="$(/usr/bin/codesign --display --verbose=4 "$ldac_driver" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
case "$ldac_team" in
    [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *)
        if [ -n "${ACOUPLET_INSTALLER_SIGNING_IDENTITY:-}" ]; then
            printf '%s\n' 'The driver must have a valid signing team before signed packaging.' >&2
            exit 1
        fi
        ldac_team=''
        ;;
esac
mkdir "$ldac_stage/root" "$ldac_stage/scripts"
for script in preinstall postinstall; do
    /usr/bin/sed "s/@ACOUPLET_LDAC_SIGNING_TEAM_ID@/$ldac_team/g" "$ldac_packaging/LDACOutputInstaller/$script" > "$ldac_stage/scripts/$script"
    chmod 755 "$ldac_stage/scripts/$script"
done
/usr/bin/ditto "$ldac_driver" "$ldac_stage/root/AcoupletLDACOutput.driver"
if [ -n "${ACOUPLET_INSTALLER_SIGNING_IDENTITY:-}" ]; then
    /usr/bin/pkgbuild --root "$ldac_stage/root" --component-plist "$ldac_packaging/LDACOutputInstaller/components.plist" \
        --install-location /Library/Audio/Plug-Ins/HAL --identifier dev.baglayan.Acouplet.LDACOutput \
        --version "$ldac_version" --ownership recommended --scripts "$ldac_stage/scripts" \
        --sign "$ACOUPLET_INSTALLER_SIGNING_IDENTITY" --timestamp "$ldac_package"
    /usr/sbin/pkgutil --check-signature "$ldac_package"
else
    /usr/bin/pkgbuild --root "$ldac_stage/root" --component-plist "$ldac_packaging/LDACOutputInstaller/components.plist" \
        --install-location /Library/Audio/Plug-Ins/HAL --identifier dev.baglayan.Acouplet.LDACOutput \
        --version "$ldac_version" --ownership recommended --scripts "$ldac_stage/scripts" "$ldac_package"
fi
