from pathlib import Path
import plistlib, re, sys


def check_bundle(app):
    host = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    sdk = re.fullmatch(r'macosx(\d+)\.(\d+)(?:\.\d+)?', host.get('DTSDKName', ''))
    if not sdk:
        raise ValueError('Missing macOS build SDK in Acouplet Info.plist')
    extension = app / 'Contents/PlugIns/Acouplet Status.appex'
    if tuple(map(int, sdk.groups())) < (27, 3):
        if host.get('AcoupletDistribution') == 'production':
            raise ValueError('Production packaging requires the macOS 27.3 SDK or newer for Acouplet Status')
        if host.get('NSSupportsLiveActivities') or extension.exists() or extension.is_symlink():
            raise ValueError('Unexpected Live Activity in an older SDK build')
        return
    if host.get('NSSupportsLiveActivities') is not True:
        raise ValueError('Missing NSSupportsLiveActivities in Acouplet Info.plist')
    if extension.is_symlink() or not extension.is_dir():
        raise ValueError('Missing embedded Acouplet Status extension')
    info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != host['CFBundleIdentifier'] + '.status'
            or info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension'
            or any(info.get(key) != host[key] for key in ('CFBundleVersion', 'CFBundleShortVersionString'))
            or info.get('CFBundleExecutable') != 'Acouplet Status'
            or not (extension / 'Contents/MacOS/Acouplet Status').is_file()):
        raise ValueError('Incorrect embedded Acouplet Status extension')


if __name__ == '__main__':
    try:
        check_bundle(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
