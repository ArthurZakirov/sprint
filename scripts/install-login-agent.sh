#!/bin/bash
set -euo pipefail

label=local.sprint.login
domain="gui/$(id -u)"
directory="$HOME/Library/LaunchAgents"
plist="$directory/$label.plist"
mkdir -p "$directory"
temporary=$(mktemp "$directory/.$label.XXXXXX")
trap 'rm -f "$temporary"' EXIT

/usr/bin/plutil -create xml1 "$temporary"
/usr/bin/plutil -insert Label -string "$label" "$temporary"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$temporary"
/usr/bin/plutil -insert ProgramArguments.0 -string "$1" "$temporary"
/usr/bin/plutil -insert ProgramArguments.1 -string --background "$temporary"
/usr/bin/plutil -insert RunAtLoad -bool YES "$temporary"
/usr/bin/plutil -lint "$temporary"

if launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$label"
fi
mv "$temporary" "$plist"
launchctl enable "$domain/$label"
launchctl bootstrap "$domain" "$plist"
