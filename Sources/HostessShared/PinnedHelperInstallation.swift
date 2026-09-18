import Foundation

public enum PinnedHelperInstallation {
	public static let label = "app.hostess.Hostess.PinnedHelper"
	public static let toolPath = "/Library/PrivilegedHelperTools/\(label)"
	public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
	public static let configPath = "/Library/Preferences/\(label).plist"

	public enum ValidationError: LocalizedError {
		case invalidSourcePath
		case invalidHash
		case invalidUserIdentifier

		public var errorDescription: String? {
			switch self {
			case .invalidSourcePath:
				return "The bundled helper must have an absolute file path."
			case .invalidHash:
				return "The app or helper code signature is missing a valid hash."
			case .invalidUserIdentifier:
				return "Passwordless switching must be set up for a user account."
			}
		}
	}

	public static func installCommand(
		sourcePath: String, helperSHA256: String, appCDHash: String,
		helperCDHash: String, allowedUID: UInt32
	) throws -> String {
		guard sourcePath.hasPrefix("/"), !sourcePath.utf8.contains(0) else {
			throw ValidationError.invalidSourcePath
		}
		guard PinnedHelperTrust.isHex(helperSHA256, count: 64), PinnedHelperTrust.isHex(appCDHash, count: 40),
			PinnedHelperTrust.isHex(helperCDHash, count: 40)
		else {
			throw ValidationError.invalidHash
		}
		guard allowedUID != 0, allowedUID != UInt32.max else {
			throw ValidationError.invalidUserIdentifier
		}

		let configuration: [String: Any] = [
			"AllowedUID": NSNumber(value: allowedUID),
			"AppCDHash": appCDHash,
			"HelperCDHash": helperCDHash,
		]
		let daemon: [String: Any] = [
			"Label": label,
			"ProgramArguments": [toolPath, "--pinned-helper"],
			"MachServices": [label: true],
			"RunAtLoad": true,
		]
		let configurationData = try PropertyListSerialization.data(
			fromPropertyList: configuration, format: .xml, options: 0
		)
		let daemonData = try PropertyListSerialization.data(
			fromPropertyList: daemon, format: .xml, options: 0
		)
		let helperRequirement = "cdhash H\"\(helperCDHash)\" and identifier \"\(HostessPrivilegedHelper.label)\""

		// The running app supplies hashes bound to its own code signature. All
		// privileged validation happens after copying into protected staging.
		return """
		\(parentChecks)
		if [ ! -e '/Library/PrivilegedHelperTools' ] && [ ! -L '/Library/PrivilegedHelperTools' ]; then
			/bin/mkdir -m 755 '/Library/PrivilegedHelperTools'
			/bin/chmod -N '/Library/PrivilegedHelperTools'
		fi
		hostess_check_directory '/Library/PrivilegedHelperTools'
		\(destinationChecks)
		hostess_stage=$(/usr/bin/mktemp -d '/Library/PrivilegedHelperTools/.hostess.XXXXXXXX')
		trap '/bin/rm -rf "$hostess_stage"' EXIT
		trap 'exit 1' HUP INT TERM
		/bin/chmod -N "$hostess_stage"
		/bin/chmod 700 "$hostess_stage"
		/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/perl -e \(shellQuote(boundedCopy)) -- \(shellQuote(sourcePath)) "$hostess_stage/helper"
		/bin/chmod -N "$hostess_stage/helper"
		/bin/chmod 600 "$hostess_stage/helper"
		hostess_digest=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/shasum -a 256 "$hostess_stage/helper")
		[ "${hostess_digest%% *}" = '\(helperSHA256)' ] || {
			printf '%s\\n' 'The bundled helper changed before it could be installed.' >&2
			exit 1
		}
		/usr/bin/codesign --verify --strict --test-requirement \(shellQuote("=" + helperRequirement)) "$hostess_stage/helper"
		printf '%s' '\(configurationData.base64EncodedString())' | /usr/bin/base64 -D > "$hostess_stage/config.plist"
		printf '%s' '\(daemonData.base64EncodedString())' | /usr/bin/base64 -D > "$hostess_stage/daemon.plist"
		/usr/bin/plutil -lint "$hostess_stage/config.plist" "$hostess_stage/daemon.plist"
		/usr/sbin/chown root:wheel "$hostess_stage/helper" "$hostess_stage/config.plist" "$hostess_stage/daemon.plist"
		/bin/chmod -N "$hostess_stage/config.plist" "$hostess_stage/daemon.plist"
		/bin/chmod 755 "$hostess_stage/helper"
		/bin/chmod 644 "$hostess_stage/config.plist" "$hostess_stage/daemon.plist"
		\(stopCommand)
		/bin/mv -fh "$hostess_stage/helper" '\(toolPath)'
		/bin/mv -fh "$hostess_stage/config.plist" '\(configPath)'
		/bin/mv -fh "$hostess_stage/daemon.plist" '\(plistPath)'
		/bin/launchctl enable 'system/\(label)'
		/bin/launchctl bootstrap system '\(plistPath)'
		"""
	}

	public static var removalCommand: String {
		"""
		\(parentChecks)
		if [ -e '/Library/PrivilegedHelperTools' ] || [ -L '/Library/PrivilegedHelperTools' ]; then
			hostess_check_directory '/Library/PrivilegedHelperTools'
		fi
		\(destinationChecks)
		/bin/launchctl disable 'system/\(label)'
		\(stopCommand)
		/bin/rm -f '\(toolPath)' '\(plistPath)' '\(configPath)'
		"""
	}

	private static var parentChecks: String {
		"""
		set -eu
		umask 077
		[ "$(/usr/bin/id -u)" = 0 ] || exit 1
		hostess_check_directory() {
			[ ! -L "$1" ] && [ -d "$1" ] || exit 1
			[ "$(/usr/bin/stat -f '%u' "$1")" = 0 ] || exit 1
			hostess_mode=$(/usr/bin/stat -f '%Lp' "$1")
			[ "$((0$hostess_mode & 0022))" -eq 0 ] || exit 1
			hostess_access=$(/bin/ls -lde "$1")
			if printf '%s\\n' "$hostess_access" | /usr/bin/grep -Eq '^[[:space:]]+[0-9]+: .* allow '; then
				printf '%s\\n' 'The helper installation directory has an unexpected access grant.' >&2
				exit 1
			fi
		}
		hostess_check_directory '/Library'
		hostess_check_directory '/Library/Preferences'
		hostess_check_directory '/Library/LaunchDaemons'
		"""
	}

	private static var destinationChecks: String {
		"""
		for hostess_destination in '\(toolPath)' '\(plistPath)' '\(configPath)'; do
			[ ! -L "$hostess_destination" ] || exit 1
			if [ -e "$hostess_destination" ] && [ ! -f "$hostess_destination" ]; then
				exit 1
			fi
		done
		"""
	}

	private static var stopCommand: String {
		"""
		if hostess_service_state=$(/bin/launchctl print 'system/\(label)' 2>&1); then
			/bin/launchctl bootout 'system/\(label)'
		else
			hostess_status=$?
			if [ "$hostess_status" -ne 113 ]; then
				printf '%s\\n' "$hostess_service_state" >&2
				exit "$hostess_status"
			fi
		fi
		"""
	}

	private static var boundedCopy: String {
		// Validate and read the same descriptor. A swapped symlink, FIFO or device
		// cannot redirect the copy or block it before the content hash is checked.
		// Copying only bytes also leaves quarantine and other source metadata behind.
		"""
		use strict;
		use warnings;
		use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK S_ISREG);
		my $maximum = 64 * 1024 * 1024;
		sysopen(my $input, $ARGV[0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "Cannot open bundled helper: $!\\n";
		my @source = stat($input);
		@source && S_ISREG($source[2]) && $source[7] > 0 && $source[7] <= $maximum
			or die "The bundled helper must be a regular file no larger than 64 MiB.\\n";
		sysopen(my $output, $ARGV[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
			or die "Cannot create staged helper: $!\\n";
		my $copied = 0;
		while (1) {
			my $length = $maximum - $copied + 1;
			$length = 65536 if $length > 65536;
			my $count = sysread($input, my $buffer, $length);
			defined($count) or die "Cannot read bundled helper: $!\\n";
			last if $count == 0;
			$copied += $count;
			$copied <= $maximum or die "The bundled helper grew beyond 64 MiB.\\n";
			my $offset = 0;
			while ($offset < $count) {
				my $written = syswrite($output, $buffer, $count - $offset, $offset);
				defined($written) && $written > 0 or die "Cannot write staged helper: $!\\n";
				$offset += $written;
			}
		}
		$copied == $source[7] or die "The bundled helper changed size during copying.\\n";
		close($input) or die "Cannot close bundled helper: $!\\n";
		close($output) or die "Cannot close staged helper: $!\\n";
		"""
	}

	private static func shellQuote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
