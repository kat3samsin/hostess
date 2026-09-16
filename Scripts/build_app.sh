#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/app/Hostess.app"
BINARY="$ROOT_DIR/.build/release/Hostess"
HELPER_BINARY="$ROOT_DIR/.build/release/HostessHelper"
HELPER_LABEL="app.hostess.Hostess.ManagedHelper"
SIGNING_IDENTITY="${HOSTESS_SIGNING_IDENTITY:--}"

cd "$ROOT_DIR"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p \
	"$APP_DIR/Contents/MacOS" \
	"$APP_DIR/Contents/Resources" \
	"$APP_DIR/Contents/Library/LaunchServices" \
	"$APP_DIR/Contents/Library/LaunchDaemons"

cp "$BINARY" "$APP_DIR/Contents/MacOS/Hostess"
cp "$HELPER_BINARY" "$APP_DIR/Contents/Library/LaunchServices/$HELPER_LABEL"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/HostessIcon.icns" "$APP_DIR/Contents/Resources/HostessIcon.icns"
cp "$ROOT_DIR/Resources/LaunchDaemons/$HELPER_LABEL.plist" "$APP_DIR/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist"

SIGNING_OPTIONS=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
	SIGNING_OPTIONS+=(--timestamp)
fi

HELPER_PATH="$APP_DIR/Contents/Library/LaunchServices/$HELPER_LABEL"
/usr/bin/codesign "${SIGNING_OPTIONS[@]}" --identifier "$HELPER_LABEL" "$HELPER_PATH"
/usr/bin/codesign "${SIGNING_OPTIONS[@]}" "$APP_DIR"
/usr/bin/codesign --verify --strict "$HELPER_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
	APP_SIGNATURE="$(/usr/bin/codesign --display --verbose=4 "$APP_DIR" 2>&1)"
	TEAM_ID="$(printf '%s\n' "$APP_SIGNATURE" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
	if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
		echo "The app signature has no valid Apple TeamIdentifier." >&2
		exit 1
	fi

	APPLE_SIGNING_REQUIREMENT="anchor apple generic and ((certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or (certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists)) and certificate leaf[subject.OU] = \"$TEAM_ID\""
	/usr/bin/codesign --verify --strict --test-requirement "=$APPLE_SIGNING_REQUIREMENT and identifier \"app.hostess.Hostess\"" "$APP_DIR"
	/usr/bin/codesign --verify --strict --test-requirement "=$APPLE_SIGNING_REQUIREMENT and identifier \"$HELPER_LABEL\"" "$HELPER_PATH"
	for SIGNED_PATH in "$APP_DIR" "$HELPER_PATH"; do
		SIGNATURE="$(/usr/bin/codesign --display --verbose=4 "$SIGNED_PATH" 2>&1)"
		if ! printf '%s\n' "$SIGNATURE" | /usr/bin/grep -Eq 'flags=.*[(,]runtime([,)]|$)'; then
			echo "Hardened runtime is missing: $SIGNED_PATH" >&2
			exit 1
		fi
	done
else
	echo "Local ad hoc build. The passwordless helper requires an Apple Development or Developer ID signed build." >&2
fi

echo "$APP_DIR"
