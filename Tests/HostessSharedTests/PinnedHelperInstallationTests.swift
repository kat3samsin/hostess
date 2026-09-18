import CryptoKit
import Foundation
import Security
import Testing
@testable import HostessShared

private let pinnedTestAppHash = String(repeating: "a", count: 40)
private let pinnedTestHelperHash = String(repeating: "b", count: 40)
private let pinnedTestSHA256 = String(repeating: "c", count: 64)

@Test func pinnedInstallationRejectsInvalidEnrollmentInputs() {
	for sourcePath in ["", "relative/path", "/helper\0suffix"] {
		#expect(throws: PinnedHelperInstallation.ValidationError.self) {
			try pinnedInstallCommand(sourcePath: sourcePath)
		}
	}
	for uid: UInt32 in [0, UInt32.max] {
		#expect(throws: PinnedHelperInstallation.ValidationError.self) {
			try pinnedInstallCommand(allowedUID: uid)
		}
	}
	for hash in ["", String(repeating: "a", count: 39), String(repeating: "g", count: 40), pinnedTestAppHash.uppercased(), pinnedTestAppHash + "\n", pinnedTestAppHash + "\" or true"] {
		#expect(throws: PinnedHelperInstallation.ValidationError.self) {
			try pinnedInstallCommand(appCDHash: hash)
		}
		#expect(throws: PinnedHelperInstallation.ValidationError.self) {
			try pinnedInstallCommand(helperCDHash: hash)
		}
	}
	for hash in ["", String(repeating: "a", count: 63), String(repeating: "g", count: 64), pinnedTestSHA256.uppercased(), pinnedTestSHA256 + "\n"] {
		#expect(throws: PinnedHelperInstallation.ValidationError.self) {
			try pinnedInstallCommand(helperSHA256: hash)
		}
	}
}

@Test func pinnedInstallationCommandsParseAsShell() throws {
	try withPinnedInstallationScratch { directory in
		for command in [try pinnedInstallCommand(sourcePath: "/Applications/Hostess's app/$(false)`false`/helper"), PinnedHelperInstallation.removalCommand] {
			let script = directory.appendingPathComponent("syntax.sh")
			try command.write(to: script, atomically: true, encoding: .utf8)
			#expect(try pinnedTestProcess("/bin/sh", ["-n", script.path]) == 0)
		}
	}
}

@Test func pinnedInstallationPreservesQuotedSourceAndInstallsValidatedBytes() throws {
	try withPinnedInstallationScratch { directory in
		let source = directory.appendingPathComponent("helper ' $(touch UNEXPECTED) `touch UNEXPECTED`")
		let hashes = try createPinnedTestHelper(at: source)
		let command = try pinnedInstallCommand(
			sourcePath: source.path, helperSHA256: hashes.sha256, helperCDHash: hashes.cdhash
		)
		#expect(try runPinnedCommandInScratch(command, directory: directory) == 0)
		let installed = pinnedScratchPath(PinnedHelperInstallation.toolPath, directory: directory)
		#expect(try Data(contentsOf: installed) == Data(contentsOf: source))
		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("UNEXPECTED").path))
		let configuration = try pinnedTestPlist(pinnedScratchPath(PinnedHelperInstallation.configPath, directory: directory))
		#expect(configuration["AllowedUID"] as? UInt32 == 501)
		#expect(configuration["AppCDHash"] as? String == pinnedTestAppHash)
		#expect(configuration["HelperCDHash"] as? String == hashes.cdhash)
		let daemon = try pinnedTestPlist(pinnedScratchPath(PinnedHelperInstallation.plistPath, directory: directory))
		#expect(daemon["ProgramArguments"] as? [String] == [PinnedHelperInstallation.toolPath, "--pinned-helper"])
		#expect(daemon["MachServices"] as? [String: Bool] == [PinnedHelperInstallation.label: true])
		let actions = try String(contentsOf: directory.appendingPathComponent("launch-actions"), encoding: .utf8)
		#expect(actions.split(separator: "\n").map(String.init) == ["print", "enable", "bootstrap"])
		#expect(try pinnedStageDirectories(directory).isEmpty)
		let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
		#expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
	}
}


@Test func pinnedInstallationDoesNotCopyDownloadedHelperExtendedAttributes() throws {
	try withPinnedInstallationScratch { directory in
		let source = directory.appendingPathComponent("downloaded-helper")
		let hashes = try createPinnedTestHelper(at: source)
		let attributes = [
			"com.apple.quarantine": "0081;5f000000;HostessTests;",
			"app.hostess.installation-test": "source-only metadata",
			"com.apple.ResourceFork": "source-only resource fork",
		]
		for (name, value) in attributes {
			try #require(pinnedTestProcess("/usr/bin/xattr", ["-w", name, value, source.path]) == 0)
		}
		let command = try pinnedInstallCommand(
			sourcePath: source.path, helperSHA256: hashes.sha256, helperCDHash: hashes.cdhash
		)
		#expect(try runPinnedCommandInScratch(command, directory: directory) == 0)
		let installed = pinnedScratchPath(PinnedHelperInstallation.toolPath, directory: directory)
		#expect(try Data(contentsOf: installed) == Data(contentsOf: source))
		for name in attributes.keys {
			#expect(try pinnedTestProcess("/usr/bin/xattr", ["-p", name, source.path]) == 0)
			#expect(try pinnedTestProcess("/usr/bin/xattr", ["-p", name, installed.path]) != 0, "Installed helper retained \(name)")
		}
		#expect(try pinnedTestProcess("/usr/bin/codesign", ["--verify", "--strict", installed.path]) == 0)
	}
}

@Test func pinnedInstallationRejectsChangedHelperBeforeTouchingInstalledService() throws {
	try withPinnedInstallationScratch { directory in
		let source = directory.appendingPathComponent("helper")
		let hashes = try createPinnedTestHelper(at: source)
		let marker = directory.appendingPathComponent("helper-was-executed")
		try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".write(to: source, atomically: true, encoding: .utf8)
		let installed = pinnedScratchPath(PinnedHelperInstallation.toolPath, directory: directory)
		let original = Data("existing helper".utf8)
		try original.write(to: installed)
		for sha256 in [hashes.sha256, SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()] {
			let command = try pinnedInstallCommand(sourcePath: source.path, helperSHA256: sha256, helperCDHash: hashes.cdhash)
			#expect(try runPinnedCommandInScratch(command, directory: directory) != 0)
			#expect(try Data(contentsOf: installed) == original)
			#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch-actions").path))
			#expect(!FileManager.default.fileExists(atPath: marker.path))
			#expect(try pinnedStageDirectories(directory).isEmpty)
		}
	}
}

@Test func pinnedInstallationRejectsUnsafeParentsAndDestinations() throws {
	try withPinnedInstallationScratch { directory in
		let source = directory.appendingPathComponent("helper")
		let hashes = try createPinnedTestHelper(at: source)
		let command = try pinnedInstallCommand(sourcePath: source.path, helperSHA256: hashes.sha256, helperCDHash: hashes.cdhash)
		let parent = pinnedScratchPath("/Library/Preferences", directory: directory)
		try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: parent.path)
		#expect(try runPinnedCommandInScratch(command, directory: directory) != 0)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
		let destination = pinnedScratchPath(PinnedHelperInstallation.configPath, directory: directory)
		let unrelated = directory.appendingPathComponent("unrelated")
		try Data("untouched".utf8).write(to: unrelated)
		try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: unrelated)
		#expect(try runPinnedCommandInScratch(command, directory: directory) != 0)
		#expect(try String(contentsOf: unrelated, encoding: .utf8) == "untouched")
		try FileManager.default.removeItem(at: destination)
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
		#expect(try runPinnedCommandInScratch(command, directory: directory) != 0)
		#expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch-actions").path))
	}
}

@Test func pinnedInstallationRejectsSpecialAndOversizedSourcesWithoutBlocking() throws {
	try withPinnedInstallationScratch { directory in
		let source = directory.appendingPathComponent("helper")
		let hashes = try createPinnedTestHelper(at: source)
		let symlink = directory.appendingPathComponent("symlink-helper")
		try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
		let fifo = directory.appendingPathComponent("fifo-helper")
		try #require(mkfifo(fifo.path, 0o600) == 0)
		let oversized = directory.appendingPathComponent("oversized-helper")
		try Data([0]).write(to: oversized)
		let file = try FileHandle(forWritingTo: oversized)
		try file.truncate(atOffset: 64 * 1024 * 1024 + 1)
		try file.close()
		let installed = pinnedScratchPath(PinnedHelperInstallation.toolPath, directory: directory)
		try Data("existing helper".utf8).write(to: installed)
		for path in [symlink.path, fifo.path, "/dev/zero", oversized.path] {
			let command = try pinnedInstallCommand(sourcePath: path, helperSHA256: hashes.sha256, helperCDHash: hashes.cdhash)
			#expect(try runPinnedCommandInScratch(command, directory: directory) != 0)
			#expect(try String(contentsOf: installed, encoding: .utf8) == "existing helper")
			#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch-actions").path))
			#expect(try pinnedStageDirectories(directory).isEmpty)
		}
	}
}

@Test func pinnedInstallationAllowsDenyOnlyACLsButRejectsAccessGrants() throws {
	try withPinnedInstallationScratch { directory in
		let source = directory.appendingPathComponent("helper")
		let hashes = try createPinnedTestHelper(at: source)
		let command = try pinnedInstallCommand(sourcePath: source.path, helperSHA256: hashes.sha256, helperCDHash: hashes.cdhash)
		let parent = pinnedScratchPath("/Library/Preferences", directory: directory)
		defer { _ = try? pinnedTestProcess("/bin/chmod", ["-N", parent.path]) }
		try #require(pinnedTestProcess("/bin/chmod", ["+a", "everyone deny delete", parent.path]) == 0)
		#expect(try runPinnedCommandInScratch(command, directory: directory) == 0)
		try FileManager.default.removeItem(at: directory.appendingPathComponent("launch-actions"))
		try #require(pinnedTestProcess("/bin/chmod", ["-N", parent.path]) == 0)
		try #require(pinnedTestProcess("/bin/chmod", ["+a", "everyone allow add_file", parent.path]) == 0)
		#expect(try runPinnedCommandInScratch(command, directory: directory) != 0)
		#expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch-actions").path))
	}
}

@Test func pinnedInstallationStopsWhenLaunchdCannotConfirmOrStopExistingService() throws {
	try withPinnedInstallationScratch { directory in
		let source = directory.appendingPathComponent("helper")
		let hashes = try createPinnedTestHelper(at: source)
		let command = try pinnedInstallCommand(sourcePath: source.path, helperSHA256: hashes.sha256, helperCDHash: hashes.cdhash)
		let installed = pinnedScratchPath(PinnedHelperInstallation.toolPath, directory: directory)
		try Data("existing helper".utf8).write(to: installed)
		for (behavior, expectedActions) in [
			("print) exit 5 ;;", "print\n"),
			("print) exit 0 ;; bootout) exit 5 ;;", "print\nbootout\n"),
		] {
			let actions = directory.appendingPathComponent("launch-actions")
			try? FileManager.default.removeItem(at: actions)
			#expect(try runPinnedCommandInScratch(command, directory: directory, launchBehavior: behavior) != 0)
			#expect(try String(contentsOf: installed, encoding: .utf8) == "existing helper")
			#expect(try String(contentsOf: actions, encoding: .utf8) == expectedActions)
			#expect(try pinnedStageDirectories(directory).isEmpty)
		}
	}
}

@Test func pinnedRemovalLeavesOtherHelperInstallationsAlone() throws {
	try withPinnedInstallationScratch { directory in
		for path in [PinnedHelperInstallation.toolPath, PinnedHelperInstallation.plistPath, PinnedHelperInstallation.configPath] {
			try Data("pinned".utf8).write(to: pinnedScratchPath(path, directory: directory))
		}
		let managed = pinnedScratchPath("/Library/Preferences/\(HostessPrivilegedHelper.label).plist", directory: directory)
		let legacy = pinnedScratchPath(HostessPrivilegedHelper.legacyInstalledToolPath, directory: directory)
		try Data("managed".utf8).write(to: managed)
		try Data("legacy".utf8).write(to: legacy)
		#expect(try runPinnedCommandInScratch(PinnedHelperInstallation.removalCommand, directory: directory, launchBehavior: "print) exit 0 ;;") == 0)
		for path in [PinnedHelperInstallation.toolPath, PinnedHelperInstallation.plistPath, PinnedHelperInstallation.configPath] {
			#expect(!FileManager.default.fileExists(atPath: pinnedScratchPath(path, directory: directory).path))
		}
		#expect(try String(contentsOf: managed, encoding: .utf8) == "managed")
		#expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy")
		#expect(try String(contentsOf: directory.appendingPathComponent("launch-actions"), encoding: .utf8) == "disable\nprint\nbootout\n")
	}
}

private func pinnedInstallCommand(
	sourcePath: String = "/Applications/Hostess.app/helper", helperSHA256: String = pinnedTestSHA256,
	appCDHash: String = pinnedTestAppHash, helperCDHash: String = pinnedTestHelperHash,
	allowedUID: UInt32 = 501
) throws -> String {
	try PinnedHelperInstallation.installCommand(
		sourcePath: sourcePath, helperSHA256: helperSHA256,
		appCDHash: appCDHash, helperCDHash: helperCDHash, allowedUID: allowedUID
	)
}

private func withPinnedInstallationScratch(_ body: (URL) throws -> Void) throws {
	let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hostess pinned tests \(UUID().uuidString)")
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
	defer { try? FileManager.default.removeItem(at: directory) }
	for path in ["/Library", "/Library/Preferences", "/Library/PrivilegedHelperTools", "/Library/LaunchDaemons"] {
		try FileManager.default.createDirectory(at: pinnedScratchPath(path, directory: directory), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
	}
	try body(directory)
}

private func pinnedScratchPath(_ path: String, directory: URL) -> URL {
	directory.appendingPathComponent(String(path.dropFirst()))
}

private func runPinnedCommandInScratch(
	_ command: String, directory: URL, launchBehavior: String = "print) exit 113 ;;"
) throws -> Int32 {
	let launcher = directory.appendingPathComponent("launchctl")
	let launchSource = """
	#!/bin/sh
	printf '%s\\n' "$1" >> '\(directory.path)/launch-actions'
	case "$1" in \(launchBehavior) esac
	exit 0
	"""
	try launchSource.write(to: launcher, atomically: true, encoding: .utf8)
	try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
	// Only ownership/root checks and launchd operations are substituted. Real
	// copying, hashing, signature validation, mode checks and renames still run.
	let scratchCommand = command
		.replacingOccurrences(of: "/Library", with: directory.path + "/Library")
		.replacingOccurrences(of: "[ \"$(/usr/bin/id -u)\" = 0 ]", with: "[ \"$(/usr/bin/id -u)\" = \(getuid()) ]")
		.replacingOccurrences(of: "[ \"$(/usr/bin/stat -f '%u' \"$1\")\" = 0 ]", with: "[ \"$(/usr/bin/stat -f '%u' \"$1\")\" = \(getuid()) ]")
		.replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")
		.replacingOccurrences(of: "/bin/launchctl", with: "'\(launcher.path)'")
	try #require(!scratchCommand.contains("'/Library"))
	try #require(!scratchCommand.contains("/bin/launchctl"))
	try #require(!scratchCommand.contains("chown root"))
	let script = directory.appendingPathComponent("install.sh")
	try scratchCommand.write(to: script, atomically: true, encoding: .utf8)
	return try pinnedTestProcess("/bin/sh", [script.path], directory: directory)
}

private func createPinnedTestHelper(at url: URL) throws -> (sha256: String, cdhash: String) {
	#if arch(arm64)
	let architecture = "arm64e"
	#else
	let architecture = "x86_64"
	#endif
	#expect(try pinnedTestProcess("/usr/bin/lipo", ["/usr/bin/true", "-thin", architecture, "-output", url.path]) == 0)
	#expect(try pinnedTestProcess("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", "--identifier", HostessPrivilegedHelper.label, url.path]) == 0)
	var code: SecStaticCode?
	#expect(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
	var information: CFDictionary?
	#expect(SecCodeCopySigningInformation(try #require(code), [], &information) == errSecSuccess)
	let info = try #require(information as? [String: Any])
	let digest = try #require(info[kSecCodeInfoUnique as String] as? Data)
	return (
		SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(),
		digest.map { String(format: "%02x", $0) }.joined()
	)
}

private func pinnedTestPlist(_ url: URL) throws -> [String: Any] {
	try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

private func pinnedStageDirectories(_ directory: URL) throws -> [String] {
	try FileManager.default.contentsOfDirectory(atPath: pinnedScratchPath("/Library/PrivilegedHelperTools", directory: directory).path)
		.filter { $0.hasPrefix(".hostess.") }
}

private func pinnedTestProcess(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> Int32 {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: executable)
	process.arguments = arguments
	process.currentDirectoryURL = directory
	process.standardOutput = FileHandle.nullDevice
	process.standardError = FileHandle.nullDevice
	let finished = DispatchSemaphore(value: 0)
	process.terminationHandler = { _ in finished.signal() }
	try process.run()
	if finished.wait(timeout: .now() + 10) == .timedOut {
		process.terminate()
		Issue.record("Installer test subprocess timed out: \(executable)")
	}
	process.waitUntilExit()
	return process.terminationStatus
}
