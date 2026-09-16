#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${HOSTESS_SIGNING_IDENTITY:-}" || "$HOSTESS_SIGNING_IDENTITY" == "-" ]]; then
	echo "Set HOSTESS_SIGNING_IDENTITY to a Developer ID Application signing identity." >&2
	exit 1
fi
if [[ -z "${HOSTESS_NOTARY_PROFILE:-}" ]]; then
	echo "Set HOSTESS_NOTARY_PROFILE to an existing notarytool keychain profile." >&2
	exit 1
fi
if [[ "$#" -ne 0 ]]; then
	echo "Usage: Scripts/release_app.sh" >&2
	exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/app/Hostess.app"
RELEASE_DIR="$ROOT_DIR/.build/releases"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	echo "CFBundleShortVersionString cannot be used in a release filename." >&2
	exit 1
fi
RELEASE_ZIP="$RELEASE_DIR/Hostess-$VERSION.zip"
if [[ -e "$RELEASE_ZIP" ]]; then
	echo "Release already exists: $RELEASE_ZIP" >&2
	exit 1
fi

"$ROOT_DIR/Scripts/build_app.sh"

# Personal development builds can use the helper, but cannot be distributed as releases.
DEVELOPER_ID_REQUIREMENT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
/usr/bin/codesign --verify --strict --test-requirement "=$DEVELOPER_ID_REQUIREMENT" "$APP_DIR"
/usr/bin/codesign --verify --strict --test-requirement "=$DEVELOPER_ID_REQUIREMENT" "$APP_DIR/Contents/Library/LaunchServices/app.hostess.Hostess.ManagedHelper"

WORK_DIR="$(/usr/bin/mktemp -d "$ROOT_DIR/.build/notarize.XXXXXX")"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
NOTARY_ZIP="$WORK_DIR/Hostess.zip"
NOTARY_RESULT="$WORK_DIR/notarization.json"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_ZIP"
/usr/bin/xcrun notarytool submit "$NOTARY_ZIP" \
	--keychain-profile "$HOSTESS_NOTARY_PROFILE" --wait --output-format json > "$NOTARY_RESULT"
if [[ "$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT")" != "Accepted" ]]; then
	echo "Notarization was not accepted. No release archive was created." >&2
	/bin/cat "$NOTARY_RESULT" >&2
	exit 1
fi

/usr/bin/xcrun stapler staple "$APP_DIR"
/usr/bin/xcrun stapler validate "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP_DIR"

/bin/mkdir -p "$RELEASE_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$WORK_DIR/Hostess-$VERSION.zip"
/bin/mv "$WORK_DIR/Hostess-$VERSION.zip" "$RELEASE_ZIP"
/usr/bin/shasum -a 256 "$RELEASE_ZIP"
echo "$RELEASE_ZIP"
