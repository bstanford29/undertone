#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"

MODE=preview
while (( $# > 0 )); do
    case "$1" in
        --production)
            if [[ "$MODE" != preview ]]; then
                print -u2 "error: --production may be specified only once"
                exit 2
            fi
            MODE=production
            ;;
        --help|-h)
            if (( $# != 1 )); then
                print -u2 "error: --help cannot be combined with other options"
                exit 2
            fi
            print "usage: $0 [--production]"
            exit 0
            ;;
        *)
            print -u2 "error: unknown argument: $1"
            print -u2 "usage: $0 [--production]"
            exit 2
            ;;
    esac
    shift
done

if [[ "$MODE" == production && -z "${UNDERTONE_SIGNING_IDENTITY:-}" ]]; then
    print -u2 "error: --production requires UNDERTONE_SIGNING_IDENTITY"
    exit 2
fi
if [[ "$MODE" == production && "$UNDERTONE_SIGNING_IDENTITY" == "-" ]]; then
    print -u2 "error: --production rejects ad hoc signing"
    exit 2
fi

if ! BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"; then
    print -u2 "error: cannot determine the source build commit"
    exit 1
fi

swift build --package-path "$APP_ROOT" -c release
PRODUCT="$APP_ROOT/.build/arm64-apple-macosx/release/Undertone"
if [[ ! -x "$PRODUCT" ]]; then
    PRODUCT="$APP_ROOT/.build/release/Undertone"
fi
if [[ ! -x "$PRODUCT" ]]; then
    print -u2 "error: release product was not built: Undertone"
    exit 1
fi

if [[ "$MODE" == production ]]; then
    OUTPUT="$APP_ROOT/.build/production/Undertone"
    BUNDLE_ID=com.undertone.app
    BUNDLE_NAME=Undertone
else
    OUTPUT="$APP_ROOT/.build/Undertone Preview.app"
    BUNDLE_ID=com.undertone.preview.build
    BUNDLE_NAME="Undertone Preview"
fi

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp "$PRODUCT" "$OUTPUT/Contents/MacOS/Undertone"
cp "$APP_ROOT/Info.plist" "$OUTPUT/Contents/Info.plist"
if [[ -d "$APP_ROOT/Resources" ]]; then
    cp -R "$APP_ROOT/Resources/." "$OUTPUT/Contents/Resources/"
fi

INFO="$OUTPUT/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$INFO"
plutil -replace CFBundleName -string "$BUNDLE_NAME" "$INFO"
plutil -replace CFBundleDisplayName -string "$BUNDLE_NAME" "$INFO"
plutil -insert UndertoneBuildCommit -string "$BUILD_COMMIT" "$INFO"

if [[ "$MODE" == production ]]; then
    codesign --force --sign "$UNDERTONE_SIGNING_IDENTITY" "$OUTPUT"
    codesign --verify --strict "$OUTPUT"
fi

print "$OUTPUT"
