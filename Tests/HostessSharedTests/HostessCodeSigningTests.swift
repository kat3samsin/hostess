import Foundation
import Security
import Testing
@testable import HostessShared

private let developmentCertificateHash = "0123456789ABCDEF0123456789ABCDEF01234567"

@Test func peerRequirementsRejectAdHocImpostorsWithMatchingIdentifiers() throws {
	let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: directory) }
	for identifier in [HostessPrivilegedHelper.appIdentifier, HostessPrivilegedHelper.label] {
		let executable = directory.appendingPathComponent(identifier)
		try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
		let signer = Process()
		signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
		signer.arguments = ["--force", "--sign", "-", "--identifier", identifier, "--options", "runtime", executable.path]
		signer.standardError = Pipe()
		try signer.run()
		signer.waitUntilExit()
		#expect(signer.terminationStatus == 0)

		var staticCode: SecStaticCode?
		#expect(SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess)
		let code = try #require(staticCode)
		#expect(SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess)
		var identifierRequirement: SecRequirement?
		#expect(SecRequirementCreateWithString(
			"identifier \"\(identifier)\"" as CFString, [], &identifierRequirement
		) == errSecSuccess)
		#expect(SecStaticCodeCheckValidity(code, [], identifierRequirement) == errSecSuccess)

		for authority in [
			HostessCodeSigning.SigningAuthority.developerID,
			.appleDevelopment(certificateHash: developmentCertificateHash),
		] {
			let source = try HostessCodeSigning.requirementString(
				identifier: identifier, teamIdentifier: "ABCDEFGHIJ", authority: authority
			)
			var requirement: SecRequirement?
			#expect(SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess)
			#expect(SecStaticCodeCheckValidity(code, [], requirement) != errSecSuccess)
		}
	}
}

@Test func developmentPeerRequirementsPinCertificateAndPreserveSecurityRestrictions() throws {
	for identifier in [HostessPrivilegedHelper.appIdentifier, HostessPrivilegedHelper.label] {
		let source = try HostessCodeSigning.requirementString(
			identifier: identifier, teamIdentifier: "ABCDEFGHIJ",
			authority: .appleDevelopment(certificateHash: developmentCertificateHash)
		)
		var requirement: SecRequirement?
		#expect(SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess)
		#expect(source.contains("anchor apple generic"))
		#expect(source.contains("certificate 1[field.1.2.840.113635.100.6.2.1] exists"))
		#expect(source.contains("certificate leaf[field.1.2.840.113635.100.6.1.12] exists"))
		#expect(source.contains("certificate leaf = H\"\(developmentCertificateHash)\""))
		#expect(source.contains("identifier \"\(identifier)\""))
		#expect(source.contains("certificate leaf[subject.OU] = \"ABCDEFGHIJ\""))
		for entitlement in [
			"com.apple.security.get-task-allow",
			"com.apple.security.cs.disable-library-validation",
			"com.apple.security.cs.allow-dyld-environment-variables",
			"com.apple.security.cs.disable-executable-page-protection",
			"com.apple.security.cs.allow-unsigned-executable-memory",
		] {
			#expect(source.contains("entitlement[\"\(entitlement)\"] absent"))
		}
	}
}

@Test func peerRequirementsRejectUnknownIdentifiersAndMalformedTeams() {
	for authority in [
		HostessCodeSigning.SigningAuthority.developerID,
		.appleDevelopment(certificateHash: developmentCertificateHash),
	] {
		#expect(throws: HostessSigningError.self) {
			try HostessCodeSigning.requirementString(
				identifier: "unrelated.app", teamIdentifier: "ABCDEFGHIJ", authority: authority
			)
		}
		for team in ["", "ABCDEFGHI", "ABCDEFGHIJK", "abcdefghij", "ABCDEFGHIJ\n", "ABCDEFGHIJ\" or true"] {
			#expect(throws: HostessSigningError.self) {
				try HostessCodeSigning.requirementString(
					identifier: HostessPrivilegedHelper.appIdentifier,
					teamIdentifier: team, authority: authority
				)
			}
		}
	}
}

@Test func developmentPeerRequirementsRejectMalformedCertificateHashes() {
	for hash in [
		"",
		String(repeating: "A", count: 39),
		String(repeating: "A", count: 41),
		String(repeating: "G", count: 40),
		"\(developmentCertificateHash)\n",
		"\(developmentCertificateHash)\" or true",
	] {
		#expect(throws: HostessSigningError.self) {
			try HostessCodeSigning.requirementString(
				identifier: HostessPrivilegedHelper.appIdentifier,
				teamIdentifier: "ABCDEFGHIJ", authority: .appleDevelopment(certificateHash: hash)
			)
		}
	}
}

@Test func localTestRunnerCannotAuthorizePasswordlessSwitching() {
	#expect(throws: HostessSigningError.self) {
		try HostessCodeSigning.peerRequirement(identifier: HostessPrivilegedHelper.label)
	}
}
