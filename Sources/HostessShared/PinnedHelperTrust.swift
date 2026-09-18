import Darwin
import Foundation
import Security

public enum PinnedHelperError: LocalizedError {
	case invalidBuild
	case invalidEnrollment

	public var errorDescription: String? {
		switch self {
		case .invalidBuild:
			return "This Hostess build could not be verified. Install the app through Homebrew before setting up passwordless switching."
		case .invalidEnrollment:
			return "Passwordless switching needs setup for this Hostess version. Choose Enable Passwordless Switching from the menu."
		}
	}
}

public struct PinnedHelperIdentity: Equatable {
	public let appCDHash: String
	public let helperCDHash: String
	public let helperSHA256: String

	public var helperRequirement: String {
		get throws {
			try PinnedHelperTrust.requirement(identifier: HostessPrivilegedHelper.label, cdHash: helperCDHash)
		}
	}
}

public enum PinnedHelperTrust {
	public static let helperHashKey = "HostessHelperCDHash"
	public static let helperSHA256Key = "HostessHelperSHA256"

	public static func isHex(_ value: String, count: Int) -> Bool {
		value.utf8.count == count && value.utf8.allSatisfy {
			(48...57).contains($0) || (97...102).contains($0)
		}
	}

	public static func requirement(identifier: String, cdHash: String) throws -> String {
		guard [HostessPrivilegedHelper.appIdentifier, HostessPrivilegedHelper.label].contains(identifier),
			isHex(cdHash, count: 40)
		else { throw PinnedHelperError.invalidBuild }
		return (["identifier \"\(identifier)\"", "cdhash H\"\(cdHash)\""] +
			HostessCodeSigning.prohibitedEntitlements.map { "entitlement[\"\($0)\"] absent" }
		).joined(separator: " and ")
	}

	public static func currentCodeHash(identifier: String) throws -> String {
		var code: SecCode?
		var staticCode: SecStaticCode?
		var information: CFDictionary?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
			SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
			SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			let information = information as? [String: Any],
			let digest = information[kSecCodeInfoUnique as String] as? Data,
			let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
			flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0
		else { throw PinnedHelperError.invalidBuild }
		let cdHash = digest.map { String(format: "%02x", $0) }.joined()
		try validateSelf(try requirement(identifier: identifier, cdHash: cdHash))
		return cdHash
	}

	public static func currentIdentity() throws -> PinnedHelperIdentity {
		let appHash = try currentCodeHash(identifier: HostessPrivilegedHelper.appIdentifier)
		guard let helperHash = Bundle.main.object(forInfoDictionaryKey: helperHashKey) as? String,
			let helperSHA256 = Bundle.main.object(forInfoDictionaryKey: helperSHA256Key) as? String,
			isHex(helperHash, count: 40), isHex(helperSHA256, count: 64)
		else { throw PinnedHelperError.invalidBuild }
		// Check the captured metadata against the running app's sealed identity, not just
		// a mutable bundle on disk. The installer can then trust these exact helper bytes.
		let source = try requirement(identifier: HostessPrivilegedHelper.appIdentifier, cdHash: appHash)
			+ " and info[\(helperHashKey)] = \"\(helperHash)\""
			+ " and info[\(helperSHA256Key)] = \"\(helperSHA256)\""
		try validateSelf(source)
		return PinnedHelperIdentity(appCDHash: appHash, helperCDHash: helperHash, helperSHA256: helperSHA256)
	}

	private static func validateSelf(_ source: String) throws {
		var code: SecCode?
		var requirement: SecRequirement?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
			SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
			SecCodeCheckValidity(code, [], requirement) == errSecSuccess
		else { throw PinnedHelperError.invalidBuild }
	}
}

public struct PinnedHelperEnrollment: Equatable {
	public let allowedUID: uid_t
	public let appCDHash: String
	public let helperCDHash: String

	public static func decode(_ data: Data) throws -> PinnedHelperEnrollment {
		guard data.count <= 16_384,
			let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
			let number = values["AllowedUID"] as? NSNumber,
			CFGetTypeID(number) != CFBooleanGetTypeID(),
			let uid = uid_t(exactly: number.int64Value), uid != 0, uid != uid_t.max,
			number.doubleValue == Double(uid),
			let appHash = values["AppCDHash"] as? String,
			let helperHash = values["HelperCDHash"] as? String,
			PinnedHelperTrust.isHex(appHash, count: 40), PinnedHelperTrust.isHex(helperHash, count: 40)
		else { throw PinnedHelperError.invalidEnrollment }
		return PinnedHelperEnrollment(allowedUID: uid, appCDHash: appHash, helperCDHash: helperHash)
	}

	public static func read() throws -> PinnedHelperEnrollment {
		let descriptor = open(PinnedHelperInstallation.configPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
		guard descriptor >= 0 else { throw PinnedHelperError.invalidEnrollment }
		let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		defer { try? file.close() }
		var metadata = stat()
		guard fstat(descriptor, &metadata) == 0, metadata.st_uid == 0,
			metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o022 == 0,
			metadata.st_size > 0, metadata.st_size <= 16_384
		else { throw PinnedHelperError.invalidEnrollment }
		return try decode(file.readToEnd() ?? Data())
	}

	public func matches(_ identity: PinnedHelperIdentity, uid: uid_t) -> Bool {
		allowedUID == uid && appCDHash == identity.appCDHash && helperCDHash == identity.helperCDHash
	}
}
