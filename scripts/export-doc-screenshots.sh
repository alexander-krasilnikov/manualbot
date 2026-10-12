#!/bin/sh
# Takes the documentation screenshots in light mode and copies each one to docs/images/<name>.png. Run from anywhere;
# build-for-testing first, or let xcodebuild build.
#   scripts/export-doc-screenshots.sh                    # stub models (DocsScreenshotsUITests), iPad Pro 13-inch (M5)
#   scripts/export-doc-screenshots.sh --real             # real models (DocsRealScreenshotsUITests): downloads them if
#                                                        # needed and runs Reset demo, so use a simulator you can wipe
#   DEVICE='ManualBot Docs' scripts/export-doc-screenshots.sh --real
set -eu

cd "$(dirname "$0")/.."
DEVICE="${DEVICE:-iPad Pro 13-inch (M5)}"
TEST=DocsScreenshotsUITests
OPT_IN=TEST_RUNNER_DOCS_SCREENSHOTS
if [ "${1:-}" = "--real" ]; then TEST=DocsRealScreenshotsUITests; OPT_IN=TEST_RUNNER_DOCS_SCREENSHOTS_REAL; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" >/dev/null
PREVIOUS="$(xcrun simctl ui "$DEVICE" appearance)"
xcrun simctl ui "$DEVICE" appearance light
restore() { xcrun simctl ui "$DEVICE" appearance "$PREVIOUS"; rm -rf "$WORK"; }
trap restore EXIT

env "$OPT_IN=1" xcodebuild test -project ManualBot.xcodeproj -scheme ManualBot \
  -destination "platform=iOS Simulator,name=$DEVICE" -parallel-testing-enabled NO \
  -only-testing:"ManualBotUITests/$TEST" -resultBundlePath "$WORK/shots.xcresult" -quiet

xcrun xcresulttool export attachments --path "$WORK/shots.xcresult" --output-path "$WORK/attachments" >/dev/null

# manifest.json lists each test's attachments: the name given in the test (suggestedHumanReadableName, with a suffix the
# export adds) and the exported file.
python3 -I - "$WORK/attachments" docs/images <<'EOF'
import json, os, re, shutil, sys
source, target = sys.argv[1], sys.argv[2]
copied = []
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-F-]{36}$", "", os.path.splitext(attachment["suggestedHumanReadableName"])[0])
        shutil.copyfile(os.path.join(source, attachment["exportedFileName"]), os.path.join(target, name + ".png"))
        copied.append(name)
print("copied:", ", ".join(sorted(copied)))
open(os.path.join(source, "copied.txt"), "w").write("\n".join(copied) + "\n")
EOF

# Full-resolution screenshots are about 450 KB each; 1024 px wide is enough at the width GitHub shows them.
while read -r name; do
  sips -Z 1024 "docs/images/$name.png" >/dev/null
  if command -v oxipng >/dev/null; then oxipng -q -o 4 --strip safe "docs/images/$name.png"; fi
done < "$WORK/attachments/copied.txt"
