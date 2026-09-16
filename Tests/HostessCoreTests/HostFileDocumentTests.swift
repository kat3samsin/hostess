import Testing
@testable import HostessCore

@Test func parsesActiveAndCommentedEntries() {
	let content = """
	127.0.0.1 localhost
	#192.0.2.10 example.test
	::1 localhost
	"""
	let entries = HostFileDocument.entries(in: content)

	#expect(entries.count == 3)
	#expect(entries[0].hosts == ["localhost"])
	#expect(entries[1].isCommented)
	#expect(entries[1].hosts == ["example.test"])
	#expect(entries[2].ipAddress == "::1")
}

@Test func normalizesLineEndingsAndFinalNewline() {
	let content = "127.0.0.1 localhost\r\n\r\n"

	#expect(HostFileDocument.normalized(content) == "127.0.0.1 localhost\n")
}

@Test func matchesActiveProfileByFullHostsContent() {
	let profile = HostsProfile(
		fileName: "work.hst",
		displayName: "Work",
		content: "127.0.0.1 localhost\n192.0.2.10 example.test\n"
	)
	let active = HostFileDocument.activeProfile(
		for: "127.0.0.1 localhost\r\n192.0.2.10 example.test\n\n",
		in: [profile]
	)

	#expect(active?.fileName == "work.hst")
}

@Test func doesNotMatchDifferentHostsContent() {
	let profile = HostsProfile(
		fileName: "work.hst",
		displayName: "Work",
		content: "127.0.0.1 localhost\n"
	)
	let active = HostFileDocument.activeProfile(
		for: "127.0.0.1 localhost\n192.0.2.10 example.test\n",
		in: [profile]
	)

	#expect(active == nil)
}

@Test func countsOnlyActiveEntries() {
	let content = """
	127.0.0.1 localhost
	#192.0.2.10 example.test
	::1 localhost
	"""

	#expect(HostFileDocument.activeEntryCount(in: content) == 2)
}

@Test func identifiesLikelyHostsFiles() {
	#expect(HostFileDocument.isLikelyHostsFile("127.0.0.1 localhost\n"))
	#expect(!HostFileDocument.isLikelyHostsFile("not a hosts file\n"))
}

@Test func extractsLeadingProfileSymbol() {
	#expect(HostFileDocument.leadingProfileSymbol(from: "🟠") == "🟠")
	#expect(HostFileDocument.leadingProfileSymbol(from: "🟢 Local") == "🟢")
	#expect(HostFileDocument.leadingProfileSymbol(from: "Work") == nil)
}
