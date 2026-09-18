import Foundation

public enum HostessPrivilegedHelper {
	public static let appIdentifier = "app.hostess.Hostess"
	public static let label = "app.hostess.Hostess.ManagedHelper"
	public static let plistFileName = label + ".plist"
	public static let configDomain = "/Library/Preferences/\(label)"
	public static let configPath = configDomain + ".plist"
	public static let bundledToolPath = "Contents/Library/LaunchServices/\(label)"
	public static let bundledPlistPath = "Contents/Library/LaunchDaemons/\(plistFileName)"
	public static let legacyLabel = "app.hostess.Hostess.Helper"
	public static let legacyInstalledToolPath = "/Library/PrivilegedHelperTools/\(legacyLabel)"
	public static let legacyInstalledPlistPath = "/Library/LaunchDaemons/\(legacyLabel).plist"
	public static let legacyInstalledConfigPath = "/Library/Preferences/\(legacyLabel).plist"
}

@objc(HostessHelperProtocol)
public protocol HostessHelperProtocol: NSObjectProtocol {
	func ping(withReply reply: @escaping (Bool) -> Void)
	func writeHostsFile(_ content: String, withReply reply: @escaping (Bool, String?) -> Void)
}
