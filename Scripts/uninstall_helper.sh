#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 0 ]]; then
	echo "Usage: sudo Scripts/uninstall_helper.sh" >&2
	exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
	echo "Run this script as root to remove the legacy passwordless helper." >&2
	exit 1
fi

# Fixed paths only. Never run an executable from the app bundle as root.
/bin/launchctl disable system/app.hostess.Hostess.Helper
if SERVICE_STATE="$(/bin/launchctl print system/app.hostess.Hostess.Helper 2>&1)"; then
	/bin/launchctl bootout system/app.hostess.Hostess.Helper
else
	STATUS="$?"
	if [[ "$STATUS" -ne 113 ]]; then
		printf '%s\n' "$SERVICE_STATE" >&2
		exit "$STATUS"
	fi
fi

/bin/rm -f \
	/Library/LaunchDaemons/app.hostess.Hostess.Helper.plist \
	/Library/PrivilegedHelperTools/app.hostess.Hostess.Helper \
	/Library/Preferences/app.hostess.Hostess.Helper.plist

echo "Removed the legacy passwordless helper. Profiles and /etc/hosts are unchanged."
