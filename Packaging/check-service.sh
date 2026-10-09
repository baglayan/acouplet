#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "Usage: Packaging/check-service.sh '/path/to/Debug/Acouplet.app'"
    exit 1
fi
test_app="${1:A}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$test_app/Contents/Info.plist")"
if [[ "$bundle_id" != dev.baglayan.Acouplet.debug ]]; then
    print -u2 "Refusing to launch anything except the isolated Debug application."
    exit 1
fi
test_executable="$test_app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$test_app/Contents/Info.plist")"
process_pattern="^$(print -rn -- "$test_executable" | sed 's/[][\\.^$*+?(){}|]/\\&/g')([[:space:]]|$)"
if /usr/bin/pgrep -f "$process_pattern" >/dev/null ||
   [[ "$(/usr/bin/osascript -e 'application id "dev.baglayan.Acouplet.debug" is running')" == true ]]; then
    print -u2 "The Debug application is already running. Finish its tests and quit it first."
    exit 1
fi

label="dev.baglayan.Acouplet.test-agent"
domain="gui/$(id -u)"
service_target="$domain/$label"
if /bin/launchctl print "$service_target" >/dev/null 2>&1; then
    print -u2 "The isolated test service is already loaded; nothing was changed."
    exit 1
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp/}acouplet-service-check.XXXXXX")"
plist_path="$test_dir/$label.plist"
trap 'if /bin/launchctl print "$service_target" >/dev/null 2>&1; then /bin/launchctl bootout "$service_target"; fi; rm -rf "$test_dir"' EXIT

cat > "$plist_path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.baglayan.Acouplet.test-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string></string>
        <string>-ui-testing</string>
        <string>--disconnected</string>
        <string>--background-service</string>
    </array>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
PLIST
/usr/bin/plutil -replace ProgramArguments.0 -string "$test_executable" "$plist_path"
/usr/bin/plutil -lint "$plist_path"

wait_for_pid() {
    local previous_pid="$1"
    local candidate_pid
    for attempt in {1..80}; do
        candidate_pid="$(/bin/launchctl print "$service_target" | awk '/^[[:space:]]*pid = / { print $3; exit }')"
        if [[ -n "$candidate_pid" && "$candidate_pid" != "$previous_pid" ]] &&
           /bin/kill -0 "$candidate_pid" 2>/dev/null &&
           [[ "$(/usr/bin/osascript -e 'application id "dev.baglayan.Acouplet.debug" is running')" == true ]]; then
            print -r -- "$candidate_pid"
            return
        fi
        sleep 0.25
    done
    print -u2 "The isolated service did not start within 20 seconds."
    return 1
}

/bin/launchctl bootstrap "$domain" "$plist_path"
first_pid="$(wait_for_pid '')"
expected_command="$(print -r -- "$test_executable -ui-testing --disconnected --background-service" | tr -s ' ')"
if [[ "$(/bin/ps -ww -p "$first_pid" -o command= | tr -s ' ')" != "$expected_command" ]]; then
    print -u2 "The test service PID does not match the isolated simulation command."
    /bin/ps -ww -p "$first_pid" -o command= >&2
    print -u2 "Expected: $expected_command"
    exit 1
fi
/bin/kill -KILL "$first_pid"
second_pid="$(wait_for_pid "$first_pid")"
if [[ "$(/bin/ps -ww -p "$second_pid" -o command= | tr -s ' ')" != "$expected_command" ]]; then
    print -u2 "The restarted PID does not match the isolated simulation command."
    exit 1
fi
print "Crash recovery passed: simulated process $first_pid restarted as $second_pid."

/usr/bin/osascript -e 'tell application id "dev.baglayan.Acouplet.debug" to quit'
for attempt in {1..80}; do
    if ! /bin/kill -0 "$second_pid" 2>/dev/null; then break; fi
    sleep 0.25
done
if /bin/kill -0 "$second_pid" 2>/dev/null || /usr/bin/pgrep -f "$process_pattern" >/dev/null; then
    print -u2 "The isolated service did not remain stopped after a clean exit."
    exit 1
fi
service_state="$(/bin/launchctl print "$service_target")"
if [[ "$service_state" != *"last exit code = 0"* ]]; then
    print -u2 "The simulated app did not exit cleanly."
    exit 1
fi
for attempt in {1..80}; do
    if /usr/bin/pgrep -f "$process_pattern" >/dev/null; then
        print -u2 "The isolated service restarted after a clean exit."
        exit 1
    fi
    sleep 0.25
done
print "Graceful exit passed: process $second_pid stopped without automatic relaunch."

/bin/launchctl bootout "$service_target"
if /bin/launchctl print "$service_target" >/dev/null 2>&1 ||
   /usr/bin/pgrep -f "$process_pattern" >/dev/null; then
    print -u2 "Removing the test service did not stop its process and unload its job."
    exit 1
fi
print "Service removal passed: process stopped and job unloaded."
