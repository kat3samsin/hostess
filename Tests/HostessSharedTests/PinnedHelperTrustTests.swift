import Foundation
import Security
import Testing
@testable import HostessShared

private let enrolledAppHash = String(repeating: "a", count: 40)
private let enrolledHelperHash = String(repeating: "b", count: 40)
private let enrolledHelperSHA256 = String(repeating: "c", count: 64)

private func enrollmentData(
	uid: Any = 501, appHash: Any = enrolledAppHash, helperHash: Any = enrolledHelperHash,
	padding: String = ""
) throws -> Data {
	try PropertyListSerialization.data(fromPropertyList: [
		"AllowedUID": uid,
		"AppCDHash": appHash,
		"HelperCDHash": helperHash,
		"Padding": padding,
	], format: .xml, options: 0)
}

@Test func enrollmentRequiresAnExactNonRootUID() throws {
	for uid: Any in [true, false, "501", 0, -1, 501.5, UInt32.max, Double(UInt32.max) + 1, NSNumber(value: UInt64.max)] {
		let data = try enrollmentData(uid: uid)
		#expect(throws: PinnedHelperError.self) { try PinnedHelperEnrollment.decode(data) }
	}
	for uid: UInt32 in [1, 501] {
		let enrollment = try PinnedHelperEnrollment.decode(enrollmentData(uid: NSNumber(value: uid)))
		#expect(enrollment.allowedUID == uid)
	}
	let missingUID = try PropertyListSerialization.data(fromPropertyList: [
		"AppCDHash": enrolledAppHash, "HelperCDHash": enrolledHelperHash,
	], format: .xml, options: 0)
	#expect(throws: PinnedHelperError.self) { try PinnedHelperEnrollment.decode(missingUID) }
}

@Test func enrollmentRejectsMalformedHashesAndOversizedData() throws {
	for hash: Any in [
		"", String(repeating: "a", count: 39), String(repeating: "a", count: 41),
		String(repeating: "A", count: 40), String(repeating: "g", count: 40),
		enrolledAppHash + "\n", enrolledAppHash + "\" or true", 123, true,
	] {
		let appData = try enrollmentData(appHash: hash)
		let helperData = try enrollmentData(helperHash: hash)
		#expect(throws: PinnedHelperError.self) { try PinnedHelperEnrollment.decode(appData) }
		#expect(throws: PinnedHelperError.self) { try PinnedHelperEnrollment.decode(helperData) }
	}
	let oversizedData = try enrollmentData(padding: String(repeating: "x", count: 16_384))
	#expect(oversizedData.count > 16_384)
	#expect(throws: PinnedHelperError.self) { try PinnedHelperEnrollment.decode(oversizedData) }
	#expect(throws: (any Error).self) { try PinnedHelperEnrollment.decode(Data("invalid plist".utf8)) }
	let arrayData = try PropertyListSerialization.data(fromPropertyList: [501], format: .binary, options: 0)
	#expect(throws: PinnedHelperError.self) { try PinnedHelperEnrollment.decode(arrayData) }
}

@Test func enrollmentMatchesOnlyTheApprovedUserAndBothCodeIdentities() throws {
	let enrollment = try PinnedHelperEnrollment.decode(enrollmentData())
	let identity = PinnedHelperIdentity(
		appCDHash: enrolledAppHash, helperCDHash: enrolledHelperHash, helperSHA256: enrolledHelperSHA256
	)
	#expect(enrollment.matches(identity, uid: 501))
	#expect(!enrollment.matches(identity, uid: 502))
	#expect(!enrollment.matches(identity, uid: 0))
	#expect(!enrollment.matches(PinnedHelperIdentity(
		appCDHash: enrolledHelperHash, helperCDHash: enrolledHelperHash, helperSHA256: enrolledHelperSHA256
	), uid: 501))
	#expect(!enrollment.matches(PinnedHelperIdentity(
		appCDHash: enrolledAppHash, helperCDHash: enrolledAppHash, helperSHA256: enrolledHelperSHA256
	), uid: 501))
}

@Test func pinnedRequirementsRejectMalformedInput() {
	#expect(throws: PinnedHelperError.self) {
		try PinnedHelperTrust.requirement(identifier: "unrelated.app", cdHash: enrolledAppHash)
	}
	for hash in [
		"", String(repeating: "a", count: 39), String(repeating: "a", count: 41),
		String(repeating: "A", count: 40), String(repeating: "g", count: 40),
		enrolledAppHash + "\n", enrolledAppHash + "\" or true",
	] {
		#expect(throws: PinnedHelperError.self) {
			try PinnedHelperTrust.requirement(identifier: HostessPrivilegedHelper.appIdentifier, cdHash: hash)
		}
	}
}

private struct PinnedCodeFixture {
	let code: SecStaticCode
	let cdHash: String

	func satisfies(_ source: String) throws -> Bool {
		var requirement: SecRequirement?
		try #require(SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess)
		let parsedRequirement = try #require(requirement)
		return SecStaticCodeCheckValidity(code, [], parsedRequirement) == errSecSuccess
	}
}

private func pinnedCodeFixture(
	in directory: URL, identifier: String, source: String = "/usr/bin/true",
	entitlements: [String: Bool] = [:]
) throws -> PinnedCodeFixture {
	let executable = directory.appendingPathComponent(UUID().uuidString)
	try Data(contentsOf: URL(fileURLWithPath: source)).write(to: executable)
	var arguments = ["--force", "--sign", "-", "--identifier", identifier, "--options", "runtime"]
	if !entitlements.isEmpty {
		let plist = executable.appendingPathExtension("plist")
		try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: plist)
		arguments += ["--entitlements", plist.path]
	}
	let signer = Process()
	signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
	signer.arguments = arguments + [executable.path]
	signer.standardError = Pipe()
	try signer.run()
	signer.waitUntilExit()
	try #require(signer.terminationStatus == 0)

	var staticCode: SecStaticCode?
	try #require(SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess)
	let code = try #require(staticCode)
	try #require(SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess)
	var information: CFDictionary?
	try #require(SecCodeCopySigningInformation(
		code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
	) == errSecSuccess)
	let values = try #require(information as? [String: Any])
	let digest = try #require(values[kSecCodeInfoUnique as String] as? Data)
	return PinnedCodeFixture(code: code, cdHash: digest.map { String(format: "%02x", $0) }.joined())
}

@Test func pinnedRequirementsAuthenticateCodeContentAndIdentifier() throws {
	let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: directory) }
	for identifier in [HostessPrivilegedHelper.appIdentifier, HostessPrivilegedHelper.label] {
		let approved = try pinnedCodeFixture(in: directory, identifier: identifier)
		let differentCode = try pinnedCodeFixture(in: directory, identifier: identifier, source: "/usr/bin/false")
		let differentIdentifier = try pinnedCodeFixture(in: directory, identifier: "unrelated.app")
		#expect(approved.cdHash != differentCode.cdHash)
		let requirement = try PinnedHelperTrust.requirement(identifier: identifier, cdHash: approved.cdHash)
		#expect(try approved.satisfies(requirement))
		#expect(try differentCode.satisfies("identifier \"\(identifier)\""))
		#expect(try !differentCode.satisfies(requirement))
		let wrongIdentifierRequirement = try PinnedHelperTrust.requirement(
			identifier: identifier, cdHash: differentIdentifier.cdHash
		)
		#expect(try !differentIdentifier.satisfies(wrongIdentifierRequirement))
	}
}

@Test func pinnedRequirementsRejectWeakeningEntitlementsEvenWithTheirExactHash() throws {
	let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: directory) }
	for entitlement in HostessCodeSigning.prohibitedEntitlements {
		for value in [true, false] {
			let fixture = try pinnedCodeFixture(
				in: directory, identifier: HostessPrivilegedHelper.appIdentifier, entitlements: [entitlement: value]
			)
			#expect(try fixture.satisfies("cdhash H\"\(fixture.cdHash)\""))
			let requirement = try PinnedHelperTrust.requirement(
				identifier: HostessPrivilegedHelper.appIdentifier, cdHash: fixture.cdHash
			)
			#expect(try !fixture.satisfies(requirement))
		}
	}
}
