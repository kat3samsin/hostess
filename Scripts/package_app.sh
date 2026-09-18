#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 0 ]]; then
	echo "Usage: Scripts/package_app.sh" >&2
	exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/app/Hostess.app"
RELEASE_DIR="$ROOT_DIR/.build/releases"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
ARCH="$(/usr/bin/uname -m)"
if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	echo "CFBundleShortVersionString cannot be used in a release filename." >&2
	exit 1
fi
case "$ARCH" in
	arm64|x86_64) ;;
	*) echo "Unsupported build architecture: $ARCH" >&2; exit 1 ;;
esac

ARCHIVE_NAME="Hostess-$VERSION-$ARCH-unnotarized.zip"
RELEASE_ZIP="$RELEASE_DIR/$ARCHIVE_NAME"
if [[ -e "$RELEASE_ZIP" || -e "$RELEASE_ZIP.sha256" ]]; then
	echo "Release already exists: $RELEASE_ZIP" >&2
	exit 1
fi

# Homebrew downloads use ad hoc signing and one helper setup approval per build.
# Never package a personal development certificate by inheriting the environment.
HOSTESS_SIGNING_IDENTITY=- "$ROOT_DIR/Scripts/build_app.sh"

WORK_DIR="$(/usr/bin/mktemp -d "$ROOT_DIR/.build/package.XXXXXX")"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
/bin/mkdir "$WORK_DIR/payload" "$WORK_DIR/verify"
/usr/bin/ditto "$APP_DIR" "$WORK_DIR/payload/Hostess.app"
/bin/cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/README.md" "$WORK_DIR/payload/"
/usr/bin/ditto -c -k --norsrc --noextattr "$WORK_DIR/payload" "$WORK_DIR/$ARCHIVE_NAME"

# Check the extracted download, including its nested helper and icon resources.
/usr/bin/ditto -x -k "$WORK_DIR/$ARCHIVE_NAME" "$WORK_DIR/verify"
VERIFIED_APP="$WORK_DIR/verify/Hostess.app"
/usr/bin/codesign --verify --deep --strict "$VERIFIED_APP"
for EXECUTABLE in "$VERIFIED_APP/Contents/MacOS/Hostess" "$VERIFIED_APP/Contents/Library/LaunchServices/app.hostess.Hostess.ManagedHelper"; do
	if [[ "$(/usr/bin/lipo -archs "$EXECUTABLE")" != "$ARCH" ]]; then
		echo "The packaged executable does not match the archive architecture: $EXECUTABLE" >&2
		exit 1
	fi
	SIGNATURE="$(/usr/bin/codesign --display --verbose=4 "$EXECUTABLE" 2>&1)"
	if ! /usr/bin/grep -q '^Signature=adhoc$' <<< "$SIGNATURE"; then
		echo "The unnotarized download must use an ad hoc signature: $EXECUTABLE" >&2
		exit 1
	fi
done

/bin/mkdir -p "$RELEASE_DIR"
/bin/mv "$WORK_DIR/$ARCHIVE_NAME" "$RELEASE_ZIP"
(
	cd "$RELEASE_DIR"
	/usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
echo "$RELEASE_ZIP"
echo "$RELEASE_ZIP.sha256"
