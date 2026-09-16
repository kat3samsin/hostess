import Foundation

public struct HostEntry: Equatable, Sendable {
	public let lineNumber: Int
	public let ipAddress: String
	public let hosts: [String]
	public let isCommented: Bool
	public let rawLine: String

	public init(
		lineNumber: Int,
		ipAddress: String,
		hosts: [String],
		isCommented: Bool,
		rawLine: String
	) {
		self.lineNumber = lineNumber
		self.ipAddress = ipAddress
		self.hosts = hosts
		self.isCommented = isCommented
		self.rawLine = rawLine
	}
}

public struct HostsProfile: Equatable, Sendable {
	public let fileName: String
	public let displayName: String
	public let content: String

	public init(fileName: String, displayName: String, content: String) {
		self.fileName = fileName
		self.displayName = displayName
		self.content = content
	}
}

public enum HostFileDocument {
	public static func normalized(_ content: String) -> String {
		let normalizedLineEndings = content.replacingOccurrences(of: "\r\n", with: "\n")
		let trimmedTrailingNewlines = normalizedLineEndings
			.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
		return trimmedTrailingNewlines + "\n"
	}

	public static func entries(in content: String) -> [HostEntry] {
		normalized(content)
			.components(separatedBy: "\n")
			.enumerated()
			.compactMap { index, line in
				parseLine(line, lineNumber: index + 1)
			}
	}

	public static func activeProfile(
		for hostsContent: String,
		in profiles: [HostsProfile]
	) -> HostsProfile? {
		let normalizedHosts = normalized(hostsContent)
		return profiles.first {
			normalized($0.content) == normalizedHosts
		}
	}

	public static func activeEntryCount(in content: String) -> Int {
		entries(in: content).filter { !$0.isCommented }.count
	}

	public static func isLikelyHostsFile(_ content: String) -> Bool {
		let entries = entries(in: content)
		return entries.contains {
			$0.hosts.contains("localhost")
		}
	}

	public static func leadingProfileSymbol(from displayName: String) -> String? {
		guard let firstCharacter = displayName.first,
			firstCharacter.unicodeScalars.contains(where: { scalar in
				scalar.properties.isEmojiPresentation || isSymbol(scalar)
			})
		else {
			return nil
		}

		return String(firstCharacter)
	}

	private static func parseLine(
		_ line: String,
		lineNumber: Int
	) -> HostEntry? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		let isCommented = trimmed.hasPrefix("#")
		let uncommented = isCommented
			? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
			: line
		let hostConfig = uncommented
			.components(separatedBy: "#")
			.first?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let parts = hostConfig
			.split(whereSeparator: { $0 == " " || $0 == "\t" })
			.map(String.init)

		guard parts.count >= 2, isIPAddress(parts[0]) else {
			return nil
		}

		return HostEntry(
			lineNumber: lineNumber,
			ipAddress: parts[0],
			hosts: Array(parts.dropFirst()),
			isCommented: isCommented,
			rawLine: line
		)
	}

	private static func isIPAddress(_ value: String) -> Bool {
		isIPv4(value) || value.contains(":")
	}

	private static func isSymbol(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.properties.generalCategory {
		case .currencySymbol, .mathSymbol, .modifierSymbol, .otherSymbol:
			return true
		default:
			return false
		}
	}

	private static func isIPv4(_ value: String) -> Bool {
		let parts = value.split(separator: ".")
		guard parts.count == 4 else {
			return false
		}

		return parts.allSatisfy { part in
			guard let number = Int(part), number >= 0, number <= 255 else {
				return false
			}
			return String(number) == part
		}
	}
}
