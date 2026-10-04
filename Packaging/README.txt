Acouplet - local development installer

Requires macOS 15.4 or later. This package is not notarized.

Install or update

1. Finish any active headphone operation and quit Acouplet.
2. Keep the extracted package together and open Install.command without sudo.
3. Open Acouplet from Applications.

The installer preserves settings and adds a login service that restarts the app
if it crashes. Manage background access in System Settings > General > Login
Items & Extensions. If installation fails, keep any recovery files named in
the error.

LDAC setup

Use the app's LDAC setup action, approve macOS Installer, then restart the Mac.
Restarting only the app does not reload the audio driver. The output appears
under your device's name, for example WF-1000XM5 LDAC.

Remove

Run Uninstall Service.command, then move the app to Trash. Preferences are kept.
To remove the audio driver, stop LDAC, quit the app and run Uninstall LDAC
Output.command. Authorize removal, then restart the Mac.

Licenses

See LICENSE and THIRD-PARTY-NOTICES.md.
