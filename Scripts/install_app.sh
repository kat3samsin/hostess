#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Hostess.app"
APP_DIR="$ROOT_DIR/.build/app/$APP_NAME"

case "${1:---user}" in
	--user)
		DEST_DIR="$HOME/Applications"
		;;
	--system)
		DEST_DIR="/Applications"
		;;
	*)
		DEST_DIR="$1"
		;;
esac

"$ROOT_DIR/Scripts/build_app.sh" >/dev/null

mkdir -p "$DEST_DIR"

if [[ ! -w "$DEST_DIR" ]]; then
	echo "Cannot write to $DEST_DIR. Try a writable path or run this script yourself with elevated permissions." >&2
	exit 1
fi

if pgrep -x Hostess >/dev/null 2>&1; then
	osascript -e 'quit app "Hostess"' >/dev/null 2>&1 || pkill -x Hostess || true
	sleep 1
fi

rm -rf "$DEST_DIR/$APP_NAME"
ditto "$APP_DIR" "$DEST_DIR/$APP_NAME"

open "$DEST_DIR/$APP_NAME"
echo "Installed $DEST_DIR/$APP_NAME"
