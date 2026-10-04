# Acouplet

A menu bar app for Sony Bluetooth headphones, earbuds and speakers.

- Noise cancellation, ambient sound and voice focus.
- Battery levels, equalizer, DSEE and listening presets.
- Multipoint connections and audio-source selection.
- Touch controls, device settings and earbud fit tests where supported.
- Experimental LDAC playback.
- English and Turkish interfaces.

This is an early alpha, primarily tested on WF-1000XM5. Other models are
recognized, but not every feature has been tested on every model. Available
controls depend on what the device supports.

## Getting started for users

Requires macOS 15.4 or later. Testing has primarily used Apple silicon and
macOS 27.2.

After downloading the release .dmg file, dragAcouplet to Applications,
open it, and allow Bluetooth access. Pair your device in
macOS Bluetooth settings first. If another headphone-control app is
running, close it before connecting through Acouplet.

For LDAC, enable the experimental feature in "More Settings…". The app includes its
audio driver installer; follow the setup prompt and restart the Mac after
installation. Restarting only the app does not reload the driver.

When reporting a problem, you may open an issue on this repository.
Please include your device model, macOS version, app version
and steps to reproduce it.

## Building from source

See [Development](NATIVE_MACOS.md) for build requirements, options and tests.

Sony product photographs are excluded from this repository because they are
third-party artwork, not assets covered by this project's MIT license. Source
builds use the included vector icons. An external photo catalog can be supplied
at build time.

## License

Built upon [Maadlou/xm5-control-macos](https://github.com/Maadlou/xm5-control-macos).
Application code is MIT-licensed. See [LICENSE](LICENSE) and
[third-party notices](THIRD-PARTY-NOTICES.md).

Acouplet is an independent project, not affiliated with Sony or Apple.
