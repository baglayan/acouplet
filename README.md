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

After downloading the release .dmg file, drag Acouplet to Applications,
open it, and allow Bluetooth access. Pair your device in
macOS Bluetooth settings first. If another headphone-control app is
running, close it before connecting through Acouplet.

LDAC currently requires a macOS administrator account. Enable the experimental
feature in "More Settings…". The app includes its audio driver installer; follow
the setup prompt and restart the Mac after installation. Restarting only the app
does not reload the driver.

When reporting a problem, you may open an issue on this repository.
Please include your device model, macOS version, app version
and steps to reproduce it.

## LDAC audio driver

LDAC uses an optional virtual audio output: a software device that macOS can send
sound to while Acouplet plays it through your headphones using LDAC. The driver
provides the output's timing and volume controls and coordinates Bluetooth
playback priority. Audio capture, LDAC encoding and transmission run in separate
Acouplet helper processes.

The driver is a Core Audio HAL plug-in, loaded by macOS into a sandboxed audio
service. All Acouplet code runs in user space; it installs no kernel extension
and does not replace Apple's Bluetooth driver. Installing it does not require
disabling System Integrity Protection or reducing startup security.

Administrator authorization is needed to install the plug-in in
`/Library/Audio/Plug-Ins/HAL/`. The driver is only needed for LDAC;
headphone controls and ordinary Bluetooth playback work without it.

To remove the driver, stop LDAC, then choose "Remove LDAC Audio Driver…" in
More Settings > General. Acouplet quits and opens macOS Installer for removal.
Restart the Mac afterward.

## Building from source

See [Development](NATIVE_MACOS.md) for build requirements, options and tests.

Sony product photographs are not included in the current source tree. They are
third-party artwork and are not covered by this project's MIT license. Source
builds use the included vector icons. An external photo catalog can be supplied
at build time.

## License

Built upon [Maadlou/xm5-control-macos](https://github.com/Maadlou/xm5-control-macos).
Application code is MIT-licensed. See [LICENSE](LICENSE) and
[third-party notices](THIRD-PARTY-NOTICES.md).

Acouplet is an independent project, not affiliated with Sony or Apple.
