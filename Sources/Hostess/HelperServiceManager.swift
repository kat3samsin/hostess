import AppKit
import HostessShared
import ServiceManagement

@MainActor
enum HelperServiceManager {
	static let service = SMAppService.daemon(plistName: HostessPrivilegedHelper.plistFileName)

	static var supportsPasswordlessSwitching: Bool {
		(try? HostessCodeSigning.peerRequirement(identifier: HostessPrivilegedHelper.label)) != nil
	}

	static var hasLegacyHelper: Bool {
		if [
			HostessPrivilegedHelper.legacyInstalledToolPath,
			HostessPrivilegedHelper.legacyInstalledPlistPath,
			HostessPrivilegedHelper.legacyInstalledConfigPath,
		].contains(where: { FileManager.default.fileExists(atPath: $0) }) {
			return true
		}
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		process.arguments = ["print", "system/\(HostessPrivilegedHelper.legacyLabel)"]
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus == 0
		} catch {
			return false
		}
	}

	static func register() throws {
		_ = try HostessCodeSigning.peerRequirement(identifier: HostessPrivilegedHelper.label)
		// Only fixed commands and this process's numeric UID cross the authorization boundary.
		// The operating system installs and verifies the bundled executable separately.
		try AdministratorTask.runShell("""
		\(legacyRemovalCommand)
		umask 077
		hostess_config_dir=$(/usr/bin/mktemp -d /Library/Preferences/.hostess-config.XXXXXXXX)
		trap '/bin/rm -rf "$hostess_config_dir"' EXIT
		trap 'exit 1' HUP INT TERM
		printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>AllowedUID</key><integer>\(getuid())</integer></dict></plist>' > "$hostess_config_dir/config.plist"
		/usr/sbin/chown root:wheel "$hostess_config_dir/config.plist"
		/bin/chmod 644 "$hostess_config_dir/config.plist"
		/bin/mv -fh "$hostess_config_dir/config.plist" '\(HostessPrivilegedHelper.configPath)'
		""")
		if service.status == .notRegistered || service.status == .notFound {
			do {
				try service.register()
			} catch {
				// macOS can report launch denied while waiting for the user's approval.
				guard service.status == .requiresApproval else { throw error }
			}
		}
	}

	static func unregister() throws {
		if service.status == .enabled || service.status == .requiresApproval {
			try service.unregister()
		}
	}

	static func removeLegacyHelper() throws {
		try AdministratorTask.runShell(legacyRemovalCommand)
	}

	private static var legacyRemovalCommand: String {
		"""
		set -eu
		/bin/launchctl disable 'system/\(HostessPrivilegedHelper.legacyLabel)'
		if hostess_service_state=$(/bin/launchctl print 'system/\(HostessPrivilegedHelper.legacyLabel)' 2>&1); then
			/bin/launchctl bootout 'system/\(HostessPrivilegedHelper.legacyLabel)'
		else
			hostess_status=$?
			if [ "$hostess_status" -ne 113 ]; then
				printf '%s\\n' "$hostess_service_state" >&2
				exit "$hostess_status"
			fi
		fi
		/bin/rm -f '\(HostessPrivilegedHelper.legacyInstalledToolPath)' '\(HostessPrivilegedHelper.legacyInstalledPlistPath)' '\(HostessPrivilegedHelper.legacyInstalledConfigPath)'
		"""
	}
}
