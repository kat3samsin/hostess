import CryptoKit
import Foundation
import Security

public enum HostessSigningError: LocalizedError {
	case untrustedBuild

	public var errorDescription: String? {
		"Passwordless switching requires Hostess signed with an Apple Development or Developer ID certificate and Hardened Runtime."
	}
}

public enum HostessCodeSigning {
	enum SigningAuthority {
		case developerID
		case appleDevelopment(certificateHash: String)
	}

	private static let developerIDRequirement = """
	anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
	and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
	"""
	private static let appleDevelopmentRequirement = """
	anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists \
	and certificate leaf[field.1.2.840.113635.100.6.1.12] exists
	"""

	static let prohibitedEntitlements = [
		"com.apple.security.get-task-allow",
		"com.apple.security.cs.disable-library-validation",
		"com.apple.security.cs.allow-dyld-environment-variables",
		"com.apple.security.cs.disable-executable-page-protection",
		"com.apple.security.cs.allow-unsigned-executable-memory",
	]

	public static func peerRequirement(identifier: String) throws -> String {
		var code: SecCode?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
			throw HostessSigningError.untrustedBuild
		}

		var requirement: SecRequirement?
		func satisfies(_ source: String) -> Bool {
			SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess
				&& SecCodeCheckValidity(code, [], requirement) == errSecSuccess
		}
		let isDeveloperID = satisfies(developerIDRequirement)
		guard isDeveloperID || satisfies(appleDevelopmentRequirement) else {
			throw HostessSigningError.untrustedBuild
		}

		var information: CFDictionary?
		var staticCode: SecStaticCode?
		guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
			SecCodeCopySigningInformation(
			staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
		) == errSecSuccess,
			let information = information as? [String: Any],
			let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
			let ownIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
			let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
			flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0
		else {
			throw HostessSigningError.untrustedBuild
		}

		let authority: SigningAuthority
		if isDeveloperID {
			authority = .developerID
		} else {
			guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
				let certificate = certificates.first
			else {
				throw HostessSigningError.untrustedBuild
			}
			// Personal builds trust only peers signed with this exact development certificate.
			let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
			authority = .appleDevelopment(certificateHash: digest.map { String(format: "%02x", $0) }.joined())
		}
		let ownRequirement = try requirementString(identifier: ownIdentifier, teamIdentifier: team, authority: authority)
		guard SecRequirementCreateWithString(
			ownRequirement as CFString, [], &requirement
		) == errSecSuccess,
			SecCodeCheckValidity(code, [], requirement) == errSecSuccess
		else {
			throw HostessSigningError.untrustedBuild
		}

		return try requirementString(identifier: identifier, teamIdentifier: team, authority: authority)
	}

	static func requirementString(
		identifier: String, teamIdentifier: String, authority: SigningAuthority = .developerID
	) throws -> String {
		guard [HostessPrivilegedHelper.appIdentifier, HostessPrivilegedHelper.label].contains(identifier),
			teamIdentifier.range(of: "^[A-Z0-9]{10}\\z", options: .regularExpression) != nil
		else {
			throw HostessSigningError.untrustedBuild
		}
		let authorityRequirement: String
		switch authority {
		case .developerID:
			authorityRequirement = developerIDRequirement
		case .appleDevelopment(let certificateHash):
			guard certificateHash.range(of: "^[a-fA-F0-9]{40}\\z", options: .regularExpression) != nil else {
				throw HostessSigningError.untrustedBuild
			}
			authorityRequirement = appleDevelopmentRequirement + " and certificate leaf = H\"\(certificateHash)\""
		}

		let entitlementRequirements = prohibitedEntitlements.map {
			"entitlement[\"\($0)\"] absent"
		}
		return ([
			authorityRequirement,
			"identifier \"\(identifier)\"",
			"certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
		] + entitlementRequirements).joined(separator: " and ")
	}
}
