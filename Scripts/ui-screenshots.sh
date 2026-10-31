#!/bin/zsh
# Visual review: runs ScreenshotUITests (every screen, light and dark, minimum and large window)
# and exports the screenshots as PNG files named after each screen and state.
#
#   Scripts/ui-screenshots.sh <output folder> [derived data folder]
#
# The UI test runner is sandboxed and usually lacks Screen Recording permission, so this script
# does the capturing: the test writes "<name>.request" (the window's screen rect) into its
# temporary folder, this script captures that rect with `screencapture` and writes "<name>.png"
# back, and the test attaches it to the result bundle. Only the MacVault window area is captured.
# Keep other windows off the display the MacVault window opens on while this runs.
set -euo pipefail

out=${1:?usage: ui-screenshots.sh <output folder> [derived data folder]}
root=${0:A:h:h}
derived=${2:-$root/.build/ui-screenshots-dd}
exchange="$HOME/Library/Containers/com.macvault.uitests.xctrunner/Data/tmp/macvault-shots"
bundle="$out.xcresult"

mkdir -p "$out" "$exchange"
rm -rf "${bundle:?}"
find "${exchange:?}" -type f -delete

# Capture loop: answers each request from the test. `screencapture` can't write into the runner's
# container, so it captures to a scratch file that is then moved in.
scratch=$(mktemp -d)
(
  set +e
  while true; do
    for request in "$exchange"/*.request(N); do
      name=${request:t:r}
      rect=$(<"$request")
      if screencapture -x -R"$rect" "$scratch/$name.png"; then
        mv "$scratch/$name.png" "$exchange/$name.png"
      else
        echo "screencapture failed for $name ($rect)" >&2
      fi
      rm -f "$request"
    done
    sleep 0.1
  done
) &
watcher=$!
trap 'kill $watcher 2>/dev/null || true; rm -rf "${scratch:?}"' EXIT

cd "$root"
xcodegen generate >/dev/null
result=0
TEST_RUNNER_MACVAULT_SCREENSHOTS=shell xcodebuild -project MacVault.xcodeproj -scheme MacVault-Direct \
  -derivedDataPath "$derived" CODE_SIGN_IDENTITY=- test \
  -only-testing:MacVaultUITests/ScreenshotUITests -resultBundlePath "$bundle" > "$out.log" 2>&1 || result=$?

# Export attachments with their screen names.
raw=$(mktemp -d)
xcrun xcresulttool export attachments --path "$bundle" --output-path "$raw" >/dev/null
python3 -I - "$raw" "$out" <<'PY'
import json, os, shutil, sys
raw, out = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(raw, "manifest.json"))):
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName") or item["exportedFileName"]
        name = name.split("_0_")[0].rsplit(".", 1)[0]
        shutil.copy(os.path.join(raw, item["exportedFileName"]), os.path.join(out, name + ".png"))
PY
rm -rf "$raw"
echo "$(ls "$out" | wc -l | tr -d ' ') screenshots in $out (log: $out.log, result bundle: $bundle)"
exit $result
