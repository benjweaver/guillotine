#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Local Developer ID signing and notarization; requires Xcode, Python 3, and gh.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
version=$(sed -n "s/.*MARKETING_VERSION: '\([^']*\)'.*/\1/p" project.yml)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid project version' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit all release changes first' >&2; exit 1; }
commit=$(git rev-parse HEAD)
[[ "$(git ls-remote origin refs/heads/main | cut -f1)" == "$commit" ]] || { echo 'Push the release commit to main first' >&2; exit 1; }
tag="v$version"
if gh release view "$tag" >/dev/null 2>&1; then echo 'Release already exists' >&2; exit 1; fi
out="${GUILLOTINE_RELEASE_DIR:-$PWD/../../work/guillotine-release-$version}"
mkdir -p "$out"
out=$(cd "$out" && pwd)
identity='Developer ID Application: Ben Weaver (AR25V66TVY)'
echo "Building Guillotine $version"
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine -configuration Release \
  -derivedDataPath "$out/build" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM=AR25V66TVY \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp build > "$out/build.log" 2>&1
products="$out/build/Build/Products/Release"
app="$products/Guillotine.app"
echo 'Running app, hardware-guard, and privileged-helper tests'
xcodebuild -project Guillotine.xcodeproj -scheme Guillotine -destination platform=macOS \
  -derivedDataPath "$out/tests" CODE_SIGN_IDENTITY=- test > "$out/tests.log" 2>&1
python3 scripts/test-guard.py "$products/GuillotineGuard" > "$out/guard-tests.log" 2>&1
python3 scripts/test-lid-helper.py "$products/GuillotineLidHelper" > "$out/helper-tests.log" 2>&1
codesign --verify --deep --strict "$app"
for binary in "$app/Contents/MacOS/Guillotine" "$app/Contents/Helpers/GuillotineGuard" "$app/Contents/Helpers/GuillotineLidHelper"; do
  archs=$(lipo -archs "$binary")
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "Missing universal slice: $binary" >&2; exit 1; }
done
echo 'Submitting to Apple for notarization'
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/notarization.zip"
xcrun notarytool submit "$out/notarization.zip" --keychain-profile notary --wait --output-format json > "$out/notarization.json"
python3 - "$out/notarization.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status')!='Accepted':
    raise SystemExit('Notarization failed; inspect notarization.json and retrieve the Apple log before retrying')
print('Notarization accepted')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
archive="$out/Guillotine-$version-macOS.zip"
source="$out/Guillotine-$version-source.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
git archive --format=zip --prefix=Guillotine/ -o "$source" "$commit"
(cd "$out" && shasum -a 256 "$(basename "$archive")" "$(basename "$source")" > SHA256SUMS.txt)
python3 - "$version" "$out/RELEASE-NOTES.md" <<'PY'
import pathlib,re,sys
text=pathlib.Path('CHANGELOG.md').read_text()
match=re.search(r'^## \['+re.escape(sys.argv[1])+r'\][^\n]*\n(.*?)(?=^## |\Z)',text,re.M|re.S)
if not match: raise SystemExit('Missing versioned changelog section')
pathlib.Path(sys.argv[2]).write_text(match.group(1).strip()+'\n')
PY
[[ "$(git rev-parse HEAD)" == "$commit" && -z "$(git status --porcelain)" ]] || { echo 'Repository changed during release' >&2; exit 1; }
# Upload a draft first so partial asset uploads never appear as a finished release.
gh release create "$tag" --target "$commit" --title "Guillotine $version" --draft \
  --notes-file "$out/RELEASE-NOTES.md" "$archive" "$source" "$out/SHA256SUMS.txt"
gh release edit "$tag" --draft=false --latest
# Update the tap directly, like Revoke; no scheduled release polling.
tapdir=$(mktemp -d)
trap 'rm -rf "$tapdir"' EXIT
gh repo clone benjweaver/homebrew-guillotine "$tapdir" -- -q
bash "$tapdir/scripts/update-cask.sh" "$tag"
if ! git -C "$tapdir" diff --quiet; then
  git -C "$tapdir" add Casks/guillotine.rb
  git -C "$tapdir" commit -m "Update Guillotine to $version" \
    -m "Point the cask at the verified notarized release archive."
  git -C "$tapdir" push
fi
echo "Published $tag from $commit and updated the Homebrew tap; artifacts: $out"
