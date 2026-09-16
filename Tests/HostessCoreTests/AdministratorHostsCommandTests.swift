import Foundation
import Testing
@testable import HostessCore

@Test func rejectsEmptyAdministratorHostsContent() {
	for content in ["", " \t\r\n"] {
		#expect(throws: AdministratorHostsCommand.ValidationError.emptyContent) {
			try AdministratorHostsCommand.script(for: content)
		}
	}
}

@Test func rejectsNullBytesInAdministratorHostsContent() {
	#expect(throws: AdministratorHostsCommand.ValidationError.nullByte) {
		try AdministratorHostsCommand.script(for: "127.0.0.1 localhost\0\n")
	}
}

@Test func limitsAdministratorHostsContentByUTF8Bytes() throws {
	let accepted = String(repeating: "é", count: 262_144)
	#expect(accepted.utf8.count == AdministratorHostsCommand.maximumContentBytes)
	#expect(throws: Never.self) {
		try AdministratorHostsCommand.script(for: accepted)
	}
	#expect(throws: AdministratorHostsCommand.ValidationError.contentTooLarge) {
		try AdministratorHostsCommand.script(for: accepted + "a")
	}
}

@MainActor @Test func compilesAdministratorHostsAppleScript() throws {
	let source = try AdministratorHostsCommand.script(for: "127.0.0.1 localhost\n")
	let script = try #require(NSAppleScript(source: source))
	var error: NSDictionary?
	#expect(script.compileAndReturnError(&error))
	#expect(error == nil)
}

@MainActor @Test func administratorHostsAppleScriptTransportsMaximumContent() throws {
	try withAdministratorCommandScratchDirectory { directory in
		let content = String(repeating: "é", count: 262_144)
		let source = try AdministratorHostsCommand.script(for: content)
		let authorizationSuffix = " with administrator privileges"
		try #require(source.hasSuffix(authorizationSuffix))
		let scratchSource = try administratorCommandForScratch(
			String(source.dropLast(authorizationSuffix.count)), directory: directory
		)
		try #require(!scratchSource.contains("administrator privileges"))
		let script = try #require(NSAppleScript(source: scratchSource))
		var error: NSDictionary?
		script.executeAndReturnError(&error)
		#expect(error == nil)
		#expect(try Data(contentsOf: directory.appendingPathComponent("hosts")) == Data(content.utf8))
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hosts"])
	}
}

@Test func administratorHostsCommandPreservesBytesWithoutExecutingContent() throws {
	try withAdministratorCommandScratchDirectory { directory in
		let marker = directory.appendingPathComponent("unexpected-execution")
		let content = """
		127.0.0.1 localhost
		# café 🚀 ' " \\
		# $(/usr/bin/touch '\(marker.path)')
		# `/usr/bin/touch '\(marker.path)'`

		"""
		let command = try AdministratorHostsCommand.shellCommand(for: content)
		#expect(!command.contains(marker.path))

		let status = try executeAdministratorCommandInScratch(command, directory: directory)
		let destination = directory.appendingPathComponent("hosts")
		#expect(status == 0)
		#expect(try Data(contentsOf: destination) == Data(content.utf8))
		#expect(!FileManager.default.fileExists(atPath: marker.path))
		let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
		#expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hosts"])
	}
}

@Test func administratorHostsCommandReplacesDestinationSymlinkWithoutFollowingIt() throws {
	try withAdministratorCommandScratchDirectory { directory in
		let target = directory.appendingPathComponent("unrelated-directory", isDirectory: true)
		let destination = directory.appendingPathComponent("hosts")
		try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
		try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
		let content = "127.0.0.1 localhost\n"
		let command = try AdministratorHostsCommand.shellCommand(for: content)

		#expect(try executeAdministratorCommandInScratch(command, directory: directory) == 0)
		#expect(try Data(contentsOf: destination) == Data(content.utf8))
		#expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
		let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
		#expect(attributes[.type] as? FileAttributeType == .typeRegular)
	}
}

@Test func administratorHostsCommandPreservesDestinationAndCleansStagingOnFailure() throws {
	try withAdministratorCommandScratchDirectory { directory in
		let destination = directory.appendingPathComponent("hosts")
		let original = Data("127.0.0.1 original\n".utf8)
		try original.write(to: destination)
		let command = try AdministratorHostsCommand.shellCommand(for: "127.0.0.1 replacement\n")
			.replacingOccurrences(of: "/usr/bin/base64 -D", with: "/usr/bin/false")

		#expect(try executeAdministratorCommandInScratch(command, directory: directory) != 0)
		#expect(try Data(contentsOf: destination) == original)
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hosts"])
	}
}

private func withAdministratorCommandScratchDirectory(
	_ body: (URL) throws -> Void
) throws {
	let directory = FileManager.default.temporaryDirectory
		.appendingPathComponent("Hostess administrator tests \(UUID().uuidString)", isDirectory: true)
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
	defer { try? FileManager.default.removeItem(at: directory) }
	try body(directory)
}

private func executeAdministratorCommandInScratch(_ command: String, directory: URL) throws -> Int32 {
	let scratchCommand = try administratorCommandForScratch(command, directory: directory)
	let scriptURL = directory.appendingPathComponent("command.sh")
	try scratchCommand.write(to: scriptURL, atomically: true, encoding: .utf8)
	defer { try? FileManager.default.removeItem(at: scriptURL) }
	let process = Process()
	process.executableURL = URL(fileURLWithPath: "/bin/sh")
	process.arguments = [scriptURL.path]
	try process.run()
	process.waitUntilExit()
	return process.terminationStatus
}

private func administratorCommandForScratch(_ command: String, directory: URL) throws -> String {
	// Execute the real command only after redirecting every system path to this
	// test's directory and replacing ownership and DNS operations with true.
	let scratchCommand = command
		.replacingOccurrences(of: "/private/etc", with: directory.path)
		.replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")
		.replacingOccurrences(of: "/usr/bin/dscacheutil -flushcache", with: "/usr/bin/true")
		.replacingOccurrences(of: "/usr/bin/killall -HUP mDNSResponder", with: "/usr/bin/true")
	try #require(!scratchCommand.contains("/private/etc"))
	return scratchCommand
}
