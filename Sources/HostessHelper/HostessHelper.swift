import Darwin
import Foundation
import HostessCore
import HostessShared

private enum HelperError: LocalizedError {
	case processFailed(String)
	case unauthorizedClient

	var errorDescription: String? {
		switch self {
		case .processFailed(let message):
			return message
		case .unauthorizedClient:
			return "This account is not authorized to use the Hostess helper."
		}
	}
}

private final class HelperService: NSObject, HostessHelperProtocol {
	func writeHostsFile(_ content: String, withReply reply: @escaping (Bool, String?) -> Void) {
		do {
			guard let connection = NSXPCConnection.current(),
				isAllowedClient(connection)
			else {
				throw HelperError.unauthorizedClient
			}
			try AdministratorHostsCommand.validate(content)
			try replaceHostsFile(with: content)
			reply(true, nil)
		} catch {
			reply(false, error.localizedDescription)
		}
	}

	private func replaceHostsFile(with content: String) throws {
		var template = Array("/private/etc/.hosts.hostess.XXXXXX".utf8CString)
		let descriptor = mkstemp(&template)
		guard descriptor >= 0 else {
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}
		let tempPath = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
		let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		defer {
			try? file.close()
			unlink(tempPath)
		}

		try file.write(contentsOf: Data(content.utf8))
		guard fchown(descriptor, 0, 0) == 0, fchmod(descriptor, 0o644) == 0 else {
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}
		try file.synchronize()
		try file.close()
		// rename replaces the entry itself, including a symlink, without following it.
		guard rename(tempPath, "/private/etc/hosts") == 0 else {
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}
		try runProcess("/usr/bin/dscacheutil", arguments: ["-flushcache"])
		try runProcess("/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
	}

	private func runProcess(_ executable: String, arguments: [String]) throws {
		let process = Process()
		let output = Pipe()
		let error = Pipe()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		process.standardOutput = output
		process.standardError = error

		try process.run()
		process.waitUntilExit()

		guard process.terminationStatus == 0 else {
			let stdout = String(
				data: output.fileHandleForReading.readDataToEndOfFile(),
				encoding: .utf8
			) ?? ""
			let stderr = String(
				data: error.fileHandleForReading.readDataToEndOfFile(),
				encoding: .utf8
			) ?? ""
			let message = stderr.isEmpty ? stdout : stderr
			throw HelperError.processFailed(
				message.trimmingCharacters(in: .whitespacesAndNewlines)
			)
		}
	}
}

private final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
	private let service = HelperService()
	private let clientRequirement: String

	init(clientRequirement: String) {
		self.clientRequirement = clientRequirement
	}

	func listener(
		_ listener: NSXPCListener,
		shouldAcceptNewConnection newConnection: NSXPCConnection
	) -> Bool {
		guard isAllowedClient(newConnection) else {
			return false
		}

		newConnection.exportedInterface = NSXPCInterface(with: HostessHelperProtocol.self)
		newConnection.exportedObject = service
		newConnection.setCodeSigningRequirement(clientRequirement)
		newConnection.resume()
		return true
	}
}

private func isAllowedClient(_ connection: NSXPCConnection) -> Bool {
	let uid = connection.effectiveUserIdentifier
	return uid != 0 && allowedUserIdentifier() == uid
}

private func allowedUserIdentifier() -> uid_t? {
	let descriptor = open(HostessPrivilegedHelper.configPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
	guard descriptor >= 0 else {
		return nil
	}
	let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
	defer { try? file.close() }
	var metadata = stat()
	guard fstat(descriptor, &metadata) == 0,
		metadata.st_uid == 0,
		metadata.st_mode & S_IFMT == S_IFREG,
		metadata.st_mode & 0o022 == 0,
		metadata.st_size > 0, metadata.st_size <= 16_384,
		let data = try? file.readToEnd(),
		let configuration = try? PropertyListSerialization.propertyList(
			from: data, options: [], format: nil
		) as? [String: Any],
		let allowedUID = configuration["AllowedUID"] as? NSNumber
	else {
		return nil
	}

	return uid_t(exactly: allowedUID.int64Value)
}

@main
enum HostessHelperMain {
	static func main() {
		guard geteuid() == 0,
			let requirement = try? HostessCodeSigning.peerRequirement(
				identifier: HostessPrivilegedHelper.appIdentifier
			)
		else {
			FileHandle.standardError.write(Data("Hostess helper requires a trusted signed build and Service Management.\n".utf8))
			exit(EXIT_FAILURE)
		}
		let delegate = HelperListenerDelegate(clientRequirement: requirement)
		let listener = NSXPCListener(machServiceName: HostessPrivilegedHelper.label)
		listener.setConnectionCodeSigningRequirement(requirement)
		listener.delegate = delegate
		listener.resume()
		RunLoop.current.run()
	}
}
