# Development

Use Xcode 27.2 with the macOS 27.2 SDK. The deployment target is macOS 15.4.
The native HUD requires that SDK's private framework; older systems use a fallback.
Select Xcode 27.2 under Xcode > Settings > Locations > Command Line Tools.

## Build

Fetch the build dependency, then open `Acouplet.xcodeproj`:

```sh
Packaging/fetch-sparkle.sh
open Acouplet.xcodeproj
```

Select your development team under Signing & Capabilities and run the Acouplet
scheme. Debug uses a separate bundle identifier from the installed app.

To build a local installer using an existing Apple Development certificate:

```sh
DEVELOPER_DIR="$(xcode-select -p)" Packaging/package.sh --local
```

Quit the installed app, then open `Install.command` in
`.build/local-update/Acouplet/`. See that package's README for removal instructions.
Do not rebuild while installation is running.

## Artwork and build options

The default build uses the repository's vector artwork. Product photographs
are optional and are not included in the repository. To use an external catalog:

```sh
DEVELOPER_DIR="$(xcode-select -p)" \
ACOUPLET_SONY_ARTWORK_DIR=/path/to/SonyPhotos.xcassets Packaging/package.sh --local
```

For builds in Xcode, set `ACOUPLET_NO_SONY_ARTWORK=NO` and
`ACOUPLET_SONY_ARTWORK_DIR` to that catalog. It is combined with the vectors in
DerivedData; the source tree is unchanged.

`ACOUPLET_PUBLIC_APIS_ONLY=YES` excludes private system integrations and LDAC.

## Tests

```sh
xcodebuild -project Acouplet.xcodeproj -scheme Acouplet \
  -configuration Debug -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:AcoupletTests test
python3 Packaging/check-localizations.py
python3 Packaging/check-package.py
python3 Packaging/check-install.py
```

UI tests use simulated devices. Bluetooth, audio and connection recovery need
separate testing with real hardware.
