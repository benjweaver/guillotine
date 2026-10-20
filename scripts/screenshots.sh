#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Retakes docs/screenshots/guillotine-menu.png, the shot the README shows, from the latest
# released Guillotine. The shot is taken in the "macOS 27" UTM VM, which has no built-in
# panel, so the menu reads "Desktop/external panel power control unavailable". The README
# caption says so.
#
# Needs: the VM, with ssh from this Mac (MAC_HOST, default macos27); the agent-guides tools
# in ~/Dev/agent-guides (mac.sh, which reads the live Homebrew tap, and the
# benjweaver/homebrew-guillotine tap on GitHub); and passwordless sudo in the guest for
# installing into /Applications.
#
# It installs the latest release, checked against the tap's SHA-256. It opens the menu bar
# item, captures the menu's rectangle below the menu bar, presses Escape, and quits the app.
# It never picks a menu item such as "Enable Guillotine". The cleanup trap quits Guillotine,
# restores the guest's appearance and desktop icons, and runs `mac.sh down`, which only
# shuts the VM down if `mac.sh up` started it.
#
# APP=/path/to/Guillotine.app installs that build instead, for testing unreleased fixes.
#
# Writes docs/screenshots/guillotine-menu.png and prints the path it wrote.
set -eu
cd "$(dirname "$0")/.."
MAC_SH=${MAC_SH:-$HOME/Dev/agent-guides/machines/bens-macbook-pro/tools/mac.sh}
out=docs/screenshots
mkdir -p "$out"

cleanup() {
	$MAC_SH quit Guillotine >/dev/null 2>&1 || true
	$MAC_SH restore || true
	$MAC_SH down || true
}
trap cleanup EXIT

$MAC_SH up

if [[ -n ${APP:-} ]]; then
	[[ -d $APP ]] || { print -u2 "screenshots.sh: no app at $APP"; exit 1; }
	work=$(mktemp -d)
	ditto -c -k --sequesterRsrc --keepParent "$APP" "$work/override.zip"
	scp -q "$work/override.zip" "${MAC_HOST:-macos27}:/tmp/guillotine-override.zip"
	rm -rf "$work"
	installed=$($MAC_SH run 'set -e; d=$(mktemp -d /tmp/guillotine-app.XXXX); ditto -x -k /tmp/guillotine-override.zip "$d"; app=$(ls -d "$d"/*.app | head -1); name=$(basename "$app" .app); pkill -TERM -x "$name" 2>/dev/null || true; sleep 1; sudo rm -rf "/Applications/$name.app"; sudo ditto "$app" "/Applications/$name.app"; rm -rf /tmp/guillotine-override.zip "$d"; echo "/Applications/$name.app"' | tail -1)
	print "Installed $APP for testing"
else
	read -r url sha version <<< "$($MAC_SH cask benjweaver/homebrew-guillotine guillotine)"
	print "Installing Guillotine $version from $url"
	installed=$($MAC_SH install "$url" "$sha" | tail -1)
fi
print "Installed at $installed"

$MAC_SH prep light
$MAC_SH open Guillotine
sleep 6
$MAC_SH prep light
$MAC_SH menu Guillotine
sleep 2

# The menu is the on-screen window of Guillotine at layer 101. Fields 5 to 8 are x, y,
# width, and height in points. The rectangle sits below the menu bar, which keeps macOS's
# capture indicator out of it, and runs a few points past the menu on each side.
rect=$($MAC_SH windows Guillotine | awk -F'\t' '$4 == 101 { printf "%d,%d,%d,%d\n", $5 - 5, $6 - 1, $7 + 10, $8 + 9; exit }')
[[ -n $rect ]] || { print -u2 "screenshots.sh: no menu window (layer 101) found"; exit 1; }

tmp=$(mktemp -d)
$MAC_SH shot "$tmp/guillotine-menu.png" "$rect" >/dev/null
$MAC_SH key esc
cp "$tmp/guillotine-menu.png" "$out/guillotine-menu.png"
rm -rf "$tmp"
print "Wrote $out/guillotine-menu.png"
