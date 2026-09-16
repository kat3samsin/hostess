import AppKit

@MainActor
enum AdministratorTask {
	static func run(_ source: String) throws -> String {
		guard let script = NSAppleScript(source: source) else {
			throw NSError(
				domain: "Hostess",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Could not prepare administrator authorization."]
			)
		}

		var details: NSDictionary?
		let result = script.executeAndReturnError(&details)
		if let details {
			throw NSError(
				domain: "Hostess",
				code: (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 1,
				userInfo: [
					NSLocalizedDescriptionKey: details[NSAppleScript.errorMessage] as? String
						?? "Administrator authorization failed.",
				]
			)
		}
		return result.stringValue ?? ""
	}

	static func runShell(_ command: String) throws {
		let quoted = command
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		_ = try run("do shell script \"\(quoted)\" with administrator privileges")
	}
}
