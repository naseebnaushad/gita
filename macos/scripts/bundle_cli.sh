#!/bin/sh
# Builds the headless `gita` command (bin/gita.dart) and puts it in
# gita.app/Contents/Resources/cli, laid out like `dart build cli` output.
# Gita copies it to ~/.gita/bin when it starts, so git can run it as the
# HTTPS credential helper without anyone installing it by hand.
# Windows and Linux do the same in their CMakeLists.txt.
#
# Run by the "Bundle gita command" build phase of the Runner target.
set -e

PROJECT_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
OUT="$TARGET_TEMP_DIR/gita_cli"
DEST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/cli"
DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"

if [ ! -x "$DART" ]; then
  echo "error: Couldn't find dart at $DART (is FLUTTER_ROOT set?)." >&2
  exit 1
fi

(cd "$PROJECT_ROOT" && "$DART" build cli --output "$OUT" --verbosity=warning) || {
  echo "error: Building the gita command (dart build cli) failed." >&2
  exit 1
}

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$OUT/bundle/" "$DEST/"

# Code inside the app must be signed with the app's identity (or ad hoc
# for local builds), or macOS refuses to run it / notarization fails.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
find "$DEST" -type f \( -perm -u+x -o -name '*.dylib' \) | while read -r f; do
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$f"
done
