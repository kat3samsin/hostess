import Foundation

public enum AdministratorHostsCommand {
	public static let maximumContentBytes = 524_288

	public enum ValidationError: LocalizedError, Equatable {
		case emptyContent
		case contentTooLarge
		case nullByte

		public var errorDescription: String? {
			switch self {
			case .emptyContent:
				return "The hosts file cannot be empty."
			case .contentTooLarge:
				return "The hosts file must be 512 KiB or smaller."
			case .nullByte:
				return "The hosts file cannot contain null bytes."
			}
		}
	}

	public static func script(for content: String) throws -> String {
		let command = try shellCommand(for: content)
		let escapedCommand = command
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		return "do shell script \"\(escapedCommand)\" with administrator privileges"
	}

	public static func validate(_ content: String) throws {
		guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw ValidationError.emptyContent
		}
		guard content.utf8.count <= maximumContentBytes else {
			throw ValidationError.contentTooLarge
		}
		guard !content.utf8.contains(0) else {
			throw ValidationError.nullByte
		}
	}

	static func shellCommand(for content: String) throws -> String {
		try validate(content)
		let data = Data(content.utf8)

		// Only base64 bytes cross into shell source. The privileged process creates
		// its own staging file in a directory other local users cannot replace.
		return """
		set -eu
		umask 077
		staging=$(/usr/bin/mktemp -d '/private/etc/.hostess.XXXXXXXX')
		trap '/bin/rm -rf "$staging"' EXIT
		trap 'exit 1' HUP INT TERM
		printf '%s' '\(data.base64EncodedString())' | /usr/bin/base64 -D > "$staging/hosts"
		/usr/sbin/chown root:wheel "$staging/hosts"
		/bin/chmod 644 "$staging/hosts"
		/bin/mv -fh "$staging/hosts" '/private/etc/hosts'
		/usr/bin/dscacheutil -flushcache
		/usr/bin/killall -HUP mDNSResponder
		"""
	}
}
