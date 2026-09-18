import AppKit
import HostessShared
import ServiceManagement

struct HelperConnectionSettings {
	let name: String
	let requirement: String
	let needsHandshake: Bool
}

@MainActor
enum HelperServiceManager {
	static let service = SMAppService.daemon(plistName: HostessPrivilegedHelper.plistFileName)

	static var usesManagedHelper: Bool {
		(try? HostessCodeSigning.peerRequirement(identifier: HostessPrivilegedHelper.label)) != nil
	}

	static var supportsPasswordlessSwitching: Bool {
		usesManagedHelper || (try? PinnedHelperTrust.currentIdentity()) != nil
	}

	static var requiresApproval: Bool {
		usesManagedHelper && service.status == .requiresApproval
	}

	static var hasPinnedHelper: Bool {
		FileManager.default.fileExists(atPath: PinnedHelperInstallation.configPath)
			|| FileManager.default.fileExists(atPath: PinnedHelperInstallation.toolPath)
			|| FileManager.default.fileExists(atPath: PinnedHelperInstallation.plistPath)
	}

	static var isEnabled: Bool {
		if usesManagedHelper { return service.status == .enabled }
		guard let identity = try? PinnedHelperTrust.currentIdentity(),
			let enrollment = try? PinnedHelperEnrollment.read(),
			enrollment.matches(identity, uid: getuid())
		else { return false }
		return isServiceLoaded(PinnedHelperInstallation.label)
	}

	static func connectionSettings() throws -> HelperConnectionSettings {
		if usesManagedHelper {
			return HelperConnectionSettings(name: HostessPrivilegedHelper.label,
				requirement: try HostessCodeSigning.peerRequirement(identifier: HostessPrivilegedHelper.label), needsHandshake: false)
		}
		let identity = try PinnedHelperTrust.currentIdentity()
		guard try PinnedHelperEnrollment.read().matches(identity, uid: getuid()) else {
			throw PinnedHelperError.invalidEnrollment
		}
		return HelperConnectionSettings(name: PinnedHelperInstallation.label,
			requirement: try identity.helperRequirement, needsHandshake: true)
	}

	private static func isServiceLoaded(_ label: String) -> Bool {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		process.arguments = ["print", "system/\(label)"]
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus == 0
		} catch { return false }
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
		if !usesManagedHelper {
			let identity = try PinnedHelperTrust.currentIdentity()
			let source = Bundle.main.bundleURL.appendingPathComponent(HostessPrivilegedHelper.bundledToolPath)
			let command = try PinnedHelperInstallation.installCommand(
				sourcePath: source.path, helperSHA256: identity.helperSHA256,
				appCDHash: identity.appCDHash, helperCDHash: identity.helperCDHash, allowedUID: getuid()
			)
			try AdministratorTask.runShell(command)
			guard isEnabled else { throw PinnedHelperError.invalidEnrollment }
			try PrivilegedHelperClient().checkConnection(settings: connectionSettings())
			return
		}
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
		if !usesManagedHelper {
			if hasPinnedHelper || isServiceLoaded(PinnedHelperInstallation.label) {
				try AdministratorTask.runShell(PinnedHelperInstallation.removalCommand)
			}
			return
		}
		try unregisterManagedHelper()
	}

	// Homebrew performs pinned-helper cleanup itself using fixed system commands.
	static func unregisterManagedHelper() throws {
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
