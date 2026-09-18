import AppKit
import Foundation
import HostessCore
import HostessShared
import ServiceManagement

private enum AppConstants {
	static let name = "Hostess"
	static let menuFallbackTitle = "HS"
	static let legacyName = "HostMask"
	static let legacyDefaultsSuiteNames = [
		"com.katre.hostess",
		"com.katre.hostmask",
	]
}

private enum SettingsKey {
	static let selectedProfileFileName = "selectedProfileFileName"
	static let showProfileSymbolInMenuBar = "showProfileSymbolInMenuBar"
	static let passwordlessSetupPromptBuild = "passwordlessSetupPromptBuild"
}

private func defaultHostsProfileContent() -> String {
	"""
	##
	# Host Database
	#
	# localhost is used to configure the loopback interface
	# when the system is booting. Do not change this entry.
	##
	127.0.0.1\tlocalhost
	255.255.255.255\tbroadcasthost
	::1             localhost

	"""
}

private struct ProfileRecord {
	let fileName: String
	let displayName: String
	let url: URL
	let content: String

	var coreProfile: HostsProfile {
		HostsProfile(
			fileName: fileName,
			displayName: displayName,
			content: content
		)
	}
}

private enum PrivilegedHelperClientError: LocalizedError {
	case connectionFailed(String)
	case operationFailed(String)
	case timedOut


	var errorDescription: String? {
		switch self {
		case .connectionFailed(let message), .operationFailed(let message):
			return message
		case .timedOut:
			return "Timed out waiting for the privileged helper."
		}
	}
}

final class PrivilegedHelperClient {
	func writeHostsFile(_ content: String, settings: HelperConnectionSettings) throws {
		try request(content: content, settings: settings)
	}

	func checkConnection(settings: HelperConnectionSettings) throws {
		try request(content: nil, settings: settings)
	}

	private func request(content: String?, settings: HelperConnectionSettings) throws {
		let connection = NSXPCConnection(
			machServiceName: settings.name,
			options: .privileged
		)
		connection.remoteObjectInterface = NSXPCInterface(with: HostessHelperProtocol.self)
		connection.setCodeSigningRequirement(settings.requirement)

		let semaphore = DispatchSemaphore(value: 0)
		let resultLock = NSLock()
		var result: Result<Void, Error>?

		func setResult(_ nextResult: Result<Void, Error>) {
			resultLock.lock()
			if result == nil {
				result = nextResult
				semaphore.signal()
			}
			resultLock.unlock()
		}

		connection.invalidationHandler = {
			setResult(.failure(PrivilegedHelperClientError.connectionFailed(
				"The privileged helper is not installed or is not running."
			)))
		}
		connection.resume()

		guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
			setResult(.failure(PrivilegedHelperClientError.connectionFailed(
				error.localizedDescription
			)))
		}) as? HostessHelperProtocol else {
			connection.invalidate()
			throw PrivilegedHelperClientError.connectionFailed(
				"Could not create the privileged helper proxy."
			)
		}

		func sendContents() {
			guard let content else {
				setResult(.success(()))
				return
			}
			proxy.writeHostsFile(content) { success, message in
				if success {
					setResult(.success(()))
				} else {
					setResult(.failure(PrivilegedHelperClientError.operationFailed(
						message ?? "The privileged helper could not update /etc/hosts."
					)))
				}
			}
		}
		if settings.needsHandshake || content == nil {
			// Authenticate a harmless reply on this connection before sending hosts data.
			proxy.ping { accepted in
				if accepted { sendContents() }
				else { setResult(.failure(PinnedHelperError.invalidEnrollment)) }
			}
		} else {
			sendContents()
		}

		if semaphore.wait(timeout: .now() + 5) == .timedOut {
			connection.invalidate()
			throw PrivilegedHelperClientError.timedOut
		}

		connection.invalidate()

		switch result {
		case .success:
			return
		case .failure(let error):
			throw error
		case nil:
			throw PrivilegedHelperClientError.connectionFailed(
				"The privileged helper did not return a result."
			)
		}
	}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let statusItem = NSStatusBar.system.statusItem(
		withLength: NSStatusItem.variableLength
	)
	private let hostsURL = URL(fileURLWithPath: "/etc/hosts")
	private let fileManager = FileManager.default
	private var editorWindowController: ProfileEditorWindowController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		configureMainMenu()

		if let button = statusItem.button {
			button.title = AppConstants.menuFallbackTitle
			button.toolTip = AppConstants.name
			button.font = NSFont.monospacedSystemFont(
				ofSize: NSFont.systemFontSize,
				weight: .semibold
			)
		}

		do {
			try migrateLegacyDataIfNeeded()
			try ensureProfileDirectory()
			try createDefaultProfileIfNeeded()
			try normalizeSelectedProfilePreference()
		} catch {
			showError(message: "Could not prepare profile folder", details: error.localizedDescription)
		}

		rebuildMenu()
		promptToRemoveLegacyHelperIfNeeded()
		promptToEnablePasswordlessSwitchingIfNeeded()
	}

	@objc private func applyProfileFromMenu(_ sender: NSMenuItem) {
		guard let fileName = sender.representedObject as? String else {
			return
		}

		do {
			guard let profile = try loadProfiles().first(where: { $0.fileName == fileName }) else {
				showError(message: "Profile not found", details: fileName)
				return
			}

			try writeHostsFile(HostFileDocument.normalized(profile.content))
			UserDefaults.standard.set(profile.fileName, forKey: SettingsKey.selectedProfileFileName)
			rebuildMenu()
		} catch {
			showError(message: "Could not apply profile", details: error.localizedDescription)
		}
	}

	@objc private func importProfiles() {
		let panel = NSOpenPanel()
		panel.title = "Import Hosts Profiles"
		panel.message = "Choose hosts files to add to \(AppConstants.name)."
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false

		NSApp.activate(ignoringOtherApps: true)

		guard panel.runModal() == .OK else {
			return
		}

		do {
			try ensureProfileDirectory()
			for sourceURL in panel.urls {
				let content = try String(contentsOf: sourceURL, encoding: .utf8)
				guard HostFileDocument.isLikelyHostsFile(content) else {
					continue
				}

				let destinationURL = uniqueDestinationURL(for: sourceURL.lastPathComponent)
				try content.write(to: destinationURL, atomically: true, encoding: .utf8)
			}
			rebuildMenu()
		} catch {
			showError(message: "Could not import profiles", details: error.localizedDescription)
		}
	}

	@objc private func editProfiles() {
		if editorWindowController == nil {
			editorWindowController = ProfileEditorWindowController(
				profileDirectoryURL: profileDirectoryURL(),
				selectedFileName: UserDefaults.standard.string(
					forKey: SettingsKey.selectedProfileFileName
				),
				applyProfile: { [weak self] profile in
					guard let self else {
						return
					}

					try self.writeHostsFile(HostFileDocument.normalized(profile.content))
					UserDefaults.standard.set(
						profile.fileName,
						forKey: SettingsKey.selectedProfileFileName
					)
					self.rebuildMenu()
				},
				profilesChanged: { [weak self] in
					self?.rebuildMenu()
				},
				showError: { [weak self] message, details in
					self?.showError(message: message, details: details)
				}
			)
		}

		editorWindowController?.reloadAndShow()
	}

	@objc private func openHostsFile() {
		NSWorkspace.shared.open(hostsURL)
	}

	@objc private func revealProfilesFolder() {
		do {
			try ensureProfileDirectory()
			NSWorkspace.shared.open(profileDirectoryURL())
		} catch {
			showError(message: "Could not open profile folder", details: error.localizedDescription)
		}
	}

	@objc private func installPrivilegedHelperFromMenu() {
		do {
			if !HelperServiceManager.requiresApproval {
				try HelperServiceManager.register()
			}
			if HelperServiceManager.requiresApproval {
				showMessage(
					message: "Approve passwordless switching",
					details: "Enable Hostess in System Settings → Login Items to finish setup. Profile changes will use administrator approval until then."
				)
				SMAppService.openSystemSettingsLoginItems()
			} else if HelperServiceManager.isEnabled {
				showMessage(message: "Passwordless switching enabled", details: "Hostess can now switch profiles without another password prompt.")
			}
			rebuildMenu()
		} catch {
			showError(message: "Could not enable passwordless switching", details: error.localizedDescription)
		}
	}

	@objc private func disablePrivilegedHelperFromMenu() {
		do {
			try HelperServiceManager.unregister()
			rebuildMenu()
		} catch {
			showError(message: "Could not disable passwordless switching", details: error.localizedDescription)
		}
	}

	@objc private func removeLegacyHelperFromMenu() {
		do {
			try HelperServiceManager.removeLegacyHelper()
			rebuildMenu()
		} catch {
			showError(message: "Could not remove the old helper", details: error.localizedDescription)
		}
	}

	private func promptToRemoveLegacyHelperIfNeeded() {
		guard HelperServiceManager.hasLegacyHelper else {
			return
		}

		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = "Remove the old Hostess helper"
		alert.informativeText = "An older helper allows other local programs to change your hosts file. Remove it with administrator approval. Your profiles and current hosts file will stay intact."
		alert.addButton(withTitle: "Remove Old Helper")
		alert.addButton(withTitle: "Later")
		NSApp.activate(ignoringOtherApps: true)
		if alert.runModal() == .alertFirstButtonReturn {
			removeLegacyHelperFromMenu()
		}
	}

	private func promptToEnablePasswordlessSwitchingIfNeeded() {
		guard HelperServiceManager.supportsPasswordlessSwitching, !HelperServiceManager.isEnabled else { return }
		let build = (try? PinnedHelperTrust.currentIdentity().appCDHash)
			?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
		guard UserDefaults.standard.string(forKey: SettingsKey.passwordlessSetupPromptBuild) != build else { return }
		UserDefaults.standard.set(build, forKey: SettingsKey.passwordlessSetupPromptBuild)
		let alert = NSAlert()
		alert.messageText = "Set up passwordless switching"
		alert.informativeText = "Approve Hostess's helper once, then switch profiles without another password prompt. You can disable it from the menu."
		if !HelperServiceManager.usesManagedHelper {
			alert.informativeText += " After an app update, approve setup again for the new version."
		}
		alert.addButton(withTitle: "Enable Passwordless Switching")
		alert.addButton(withTitle: "Not Now")
		NSApp.activate(ignoringOtherApps: true)
		if alert.runModal() == .alertFirstButtonReturn {
			installPrivilegedHelperFromMenu()
		}
	}

	@objc private func refresh() {
		rebuildMenu()
	}

	@objc private func toggleProfileSymbolInMenuBar(_ sender: NSMenuItem) {
		let nextValue = !showProfileSymbolInMenuBar()
		UserDefaults.standard.set(nextValue, forKey: SettingsKey.showProfileSymbolInMenuBar)
		rebuildMenu()
	}

	@objc private func quit() {
		NSApp.terminate(nil)
	}

	private func configureMainMenu() {
		let mainMenu = NSMenu()
		let appMenu = NSMenu(title: AppConstants.name)
		appMenu.addItem(withTitle: "Quit \(AppConstants.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		mainMenu.addItem(withTitle: AppConstants.name, action: nil, keyEquivalent: "").submenu = appMenu

		// Standard editing shortcuts use the main menu and the current first responder.
		let editMenu = NSMenu(title: "Edit")
		editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
		let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
		redoItem.keyEquivalentModifierMask = [.command, .shift]
		editMenu.addItem(.separator())
		editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu
		NSApp.mainMenu = mainMenu
	}

	private func rebuildMenu() {
		let menu = NSMenu()
		let profiles = (try? loadProfiles()) ?? []
		let hostsContent = (try? String(contentsOf: hostsURL, encoding: .utf8)) ?? ""
		let coreProfiles = profiles.map(\.coreProfile)
		let activeProfile = HostFileDocument.activeProfile(
			for: hostsContent,
			in: coreProfiles
		)

		menu.addItem(disabledItem(AppConstants.name))

		if let activeProfile {
			menu.addItem(disabledItem("Active: \(activeProfile.displayName)"))
		} else {
			menu.addItem(disabledItem("Active: Custom /etc/hosts"))
		}

		updateStatusButton(activeProfile: activeProfile)

		menu.addItem(disabledItem("Profiles: \(profiles.count)"))
		menu.addItem(.separator())

		if profiles.isEmpty {
			menu.addItem(disabledItem("No profiles imported"))
		} else {
			for profile in profiles {
				let item = actionItem(profile.displayName, #selector(applyProfileFromMenu(_:)))
				item.representedObject = profile.fileName

				if activeProfile?.fileName == profile.fileName {
					item.state = .on
				}

				menu.addItem(item)
			}
		}

		menu.addItem(.separator())
		menu.addItem(actionItem("Edit Profiles...", #selector(editProfiles)))
		menu.addItem(actionItem("Import Hosts Files...", #selector(importProfiles)))
		menu.addItem(actionItem("Reveal Profiles Folder", #selector(revealProfilesFolder)))

		menu.addItem(.separator())
		let showSymbolItem = actionItem(
			"Show Profile Emoji in Menu Bar",
			#selector(toggleProfileSymbolInMenuBar(_:))
		)
		showSymbolItem.state = showProfileSymbolInMenuBar() ? .on : .off
		menu.addItem(showSymbolItem)
		menu.addItem(actionItem("Open /etc/hosts", #selector(openHostsFile)))
		if HelperServiceManager.supportsPasswordlessSwitching {
			let enabled = HelperServiceManager.isEnabled
			let requiresApproval = HelperServiceManager.requiresApproval
			let needsUpdate = !HelperServiceManager.usesManagedHelper && HelperServiceManager.hasPinnedHelper && !enabled
			if requiresApproval {
				menu.addItem(actionItem("Approve Passwordless Switching...", #selector(installPrivilegedHelperFromMenu)))
			}
			if needsUpdate {
				menu.addItem(actionItem("Update Passwordless Switching...", #selector(installPrivilegedHelperFromMenu)))
			}
			if enabled || requiresApproval || needsUpdate {
				menu.addItem(actionItem("Disable Passwordless Switching", #selector(disablePrivilegedHelperFromMenu)))
			} else {
				menu.addItem(actionItem("Enable Passwordless Switching...", #selector(installPrivilegedHelperFromMenu)))
			}
		} else {
			menu.addItem(disabledItem("Passwordless setup requires a verified Hostess app"))
		}
		if HelperServiceManager.hasLegacyHelper {
			menu.addItem(actionItem("Remove Old Helper...", #selector(removeLegacyHelperFromMenu)))
		}
		menu.addItem(actionItem("Refresh", #selector(refresh)))

		menu.addItem(.separator())
		menu.addItem(actionItem("Quit \(AppConstants.name)", #selector(quit)))

		statusItem.menu = menu
	}

	private func updateStatusButton(
		activeProfile: HostsProfile?
	) {
		guard let button = statusItem.button else {
			return
		}

		let isCustomHostsFile = activeProfile == nil

		if showProfileSymbolInMenuBar() {
			if let symbol = activeProfile.flatMap({ HostFileDocument.leadingProfileSymbol(from: $0.displayName) }) {
				button.title = symbol
				button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
				return
			}
		} else if let activeProfile {
			var title = activeProfile.displayName
			if let symbol = HostFileDocument.leadingProfileSymbol(from: title),
				symbol.unicodeScalars.contains(where: { $0.properties.isEmoji })
			{
				title = String(title.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
			}
			if !title.isEmpty {
				button.title = title
				button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
				return
			}
		}

		button.title = isCustomHostsFile
			? "\(AppConstants.menuFallbackTitle)!"
			: AppConstants.menuFallbackTitle
		button.font = NSFont.monospacedSystemFont(
			ofSize: NSFont.systemFontSize,
			weight: .semibold
		)
	}

	private func showProfileSymbolInMenuBar() -> Bool {
		if UserDefaults.standard.object(
			forKey: SettingsKey.showProfileSymbolInMenuBar
		) == nil {
			return true
		}

		return UserDefaults.standard.bool(
			forKey: SettingsKey.showProfileSymbolInMenuBar
		)
	}

	private func loadProfiles() throws -> [ProfileRecord] {
		try ensureProfileDirectory()

		let urls = try fileManager.contentsOfDirectory(
			at: profileDirectoryURL(),
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		)

		return try urls
			.filter { isSupportedProfileFile($0) }
			.map { url in
				let content = try String(contentsOf: url, encoding: .utf8)
				return ProfileRecord(
					fileName: url.lastPathComponent,
					displayName: displayName(for: url),
					url: url,
					content: content
				)
			}
			.sorted {
				$0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
			}
	}

	private func ensureProfileDirectory() throws {
		try fileManager.createDirectory(
			at: profileDirectoryURL(),
			withIntermediateDirectories: true
		)
	}

	private func profileDirectoryURL() -> URL {
		let appSupport = fileManager.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		)[0]
		return appSupport
			.appendingPathComponent(AppConstants.name, isDirectory: true)
			.appendingPathComponent("Profiles", isDirectory: true)
	}

	private func legacyProfileDirectoryURL() -> URL {
		let appSupport = fileManager.urls(
			for: .applicationSupportDirectory,
			in: .userDomainMask
		)[0]
		return appSupport
			.appendingPathComponent(AppConstants.legacyName, isDirectory: true)
			.appendingPathComponent("Profiles", isDirectory: true)
	}

	private func migrateLegacyDataIfNeeded() throws {
		migrateLegacyDefaultsIfNeeded()

		let currentURL = profileDirectoryURL()
		let legacyURL = legacyProfileDirectoryURL()
		guard fileManager.fileExists(atPath: legacyURL.path) else {
			return
		}

		try fileManager.createDirectory(at: currentURL, withIntermediateDirectories: true)

		let currentProfiles = try fileManager.contentsOfDirectory(
			at: currentURL,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		)
		guard !currentProfiles.contains(where: isSupportedProfileFile) else {
			return
		}

		let legacyProfiles = try fileManager.contentsOfDirectory(
			at: legacyURL,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		)

		for legacyProfile in legacyProfiles where isSupportedProfileFile(legacyProfile) {
			let destinationURL = currentURL.appendingPathComponent(legacyProfile.lastPathComponent)
			guard !fileManager.fileExists(atPath: destinationURL.path) else {
				continue
			}
			try fileManager.copyItem(at: legacyProfile, to: destinationURL)
		}
	}

	private func migrateLegacyDefaultsIfNeeded() {
		for suiteName in AppConstants.legacyDefaultsSuiteNames {
			guard let legacyDefaults = UserDefaults(suiteName: suiteName) else {
				continue
			}

			if UserDefaults.standard.object(forKey: SettingsKey.selectedProfileFileName) == nil,
				let selectedProfile = legacyDefaults.string(forKey: SettingsKey.selectedProfileFileName)
			{
				UserDefaults.standard.set(
					selectedProfile,
					forKey: SettingsKey.selectedProfileFileName
				)
			}

			if UserDefaults.standard.object(forKey: SettingsKey.showProfileSymbolInMenuBar) == nil,
				legacyDefaults.object(forKey: SettingsKey.showProfileSymbolInMenuBar) != nil
			{
				UserDefaults.standard.set(
					legacyDefaults.bool(forKey: SettingsKey.showProfileSymbolInMenuBar),
					forKey: SettingsKey.showProfileSymbolInMenuBar
				)
			}
		}
	}

	private func createDefaultProfileIfNeeded() throws {
		let urls = try fileManager.contentsOfDirectory(
			at: profileDirectoryURL(),
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		)

		guard !urls.contains(where: isSupportedProfileFile) else {
			return
		}

		let content = (try? String(contentsOf: hostsURL, encoding: .utf8))
			?? defaultHostsProfileContent()
		let defaultFileName = "Default.hst"
		try HostFileDocument.normalized(content).write(
			to: profileDirectoryURL().appendingPathComponent(defaultFileName),
			atomically: true,
			encoding: .utf8
		)

		if UserDefaults.standard.object(forKey: SettingsKey.selectedProfileFileName) == nil {
			UserDefaults.standard.set(
				defaultFileName,
				forKey: SettingsKey.selectedProfileFileName
			)
		}
	}

	private func normalizeSelectedProfilePreference() throws {
		let profiles = try loadProfiles()
		guard let firstProfile = profiles.first else {
			UserDefaults.standard.removeObject(forKey: SettingsKey.selectedProfileFileName)
			return
		}

		let selectedFileName = UserDefaults.standard.string(
			forKey: SettingsKey.selectedProfileFileName
		)
		guard profiles.contains(where: { $0.fileName == selectedFileName }) else {
			UserDefaults.standard.set(
				firstProfile.fileName,
				forKey: SettingsKey.selectedProfileFileName
			)
			return
		}
	}

	private func isSupportedProfileFile(_ url: URL) -> Bool {
		["hst", "hosts", "txt"].contains(url.pathExtension.lowercased())
	}

	private func displayName(for url: URL) -> String {
		let name = url.deletingPathExtension().lastPathComponent
		return name.isEmpty ? url.lastPathComponent : name
	}

	private func uniqueDestinationURL(for fileName: String) -> URL {
		let directoryURL = profileDirectoryURL()
		let baseURL = directoryURL.appendingPathComponent(fileName)

		if !fileManager.fileExists(atPath: baseURL.path) {
			return baseURL
		}

		let originalURL = URL(fileURLWithPath: fileName)
		let baseName = originalURL.deletingPathExtension().lastPathComponent
		let ext = originalURL.pathExtension

		for index in 2...1000 {
			let candidateName = ext.isEmpty
				? "\(baseName) \(index)"
				: "\(baseName) \(index).\(ext)"
			let candidateURL = directoryURL.appendingPathComponent(candidateName)

			if !fileManager.fileExists(atPath: candidateURL.path) {
				return candidateURL
			}
		}

		return directoryURL.appendingPathComponent(UUID().uuidString + ".hosts")
	}

	private func disabledItem(_ title: String) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		item.isEnabled = false
		return item
	}

	private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.target = self
		return item
	}

	private func writeHostsFile(_ content: String) throws {
		let normalizedContent = HostFileDocument.normalized(content)
		try AdministratorHostsCommand.validate(normalizedContent)
		if let currentContent = try? String(contentsOf: hostsURL, encoding: .utf8),
			HostFileDocument.normalized(currentContent) == normalizedContent
		{
			return
		}

		if HelperServiceManager.isEnabled {
			try PrivilegedHelperClient().writeHostsFile(normalizedContent, settings: HelperServiceManager.connectionSettings())
		} else {
			_ = try AdministratorTask.run(AdministratorHostsCommand.script(for: normalizedContent))
		}
	}

	private func showError(message: String, details: String) {
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = message
		alert.informativeText = details
		alert.addButton(withTitle: "OK")

		NSApp.activate(ignoringOtherApps: true)
		alert.runModal()
	}

	private func showMessage(message: String, details: String) {
		let alert = NSAlert()
		alert.alertStyle = .informational
		alert.messageText = message
		alert.informativeText = details
		alert.addButton(withTitle: "OK")

		NSApp.activate(ignoringOtherApps: true)
		alert.runModal()
	}

}

@MainActor
private final class ProfileEditorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
	private let profileDirectoryURL: URL
	private let applyProfile: (ProfileRecord) throws -> Void
	private let profilesChanged: () -> Void
	private let showError: (String, String) -> Void
	private let fileManager = FileManager.default
	private var profiles: [ProfileRecord] = []
	private var selectedFileName: String?
	private var isDirty = false

	private let tableView = NSTableView()
	private let titleLabel = NSTextField(labelWithString: "No profile selected")
	private let statusLabel = NSTextField(labelWithString: "")
	private let textView = NSTextView()
	private let saveButton = NSButton()
	private let applyButton = NSButton()
	private let newButton = NSButton()
	private let renameButton = NSButton()
	private let duplicateButton = NSButton()
	private let deleteButton = NSButton()

	init(
		profileDirectoryURL: URL,
		selectedFileName: String?,
		applyProfile: @escaping (ProfileRecord) throws -> Void,
		profilesChanged: @escaping () -> Void,
		showError: @escaping (String, String) -> Void
	) {
		self.profileDirectoryURL = profileDirectoryURL
		self.selectedFileName = selectedFileName
		self.applyProfile = applyProfile
		self.profilesChanged = profilesChanged
		self.showError = showError

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = "\(AppConstants.name) Profiles"
		window.setFrameAutosaveName("\(AppConstants.name)ProfileEditor")

		super.init(window: window)

		buildInterface()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func reloadAndShow() {
		do {
			try reloadProfiles(selecting: selectedFileName)
			showWindow(nil)
			window?.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
		} catch {
			showError("Could not load profiles", error.localizedDescription)
		}
	}

	func numberOfRows(in tableView: NSTableView) -> Int {
		profiles.count
	}

	func tableView(
		_ tableView: NSTableView,
		viewFor tableColumn: NSTableColumn?,
		row: Int
	) -> NSView? {
		let cell = NSTableCellView()
		let field = NSTextField(labelWithString: profiles[row].displayName)
		field.translatesAutoresizingMaskIntoConstraints = false
		field.font = NSFont.systemFont(ofSize: 18)
		field.lineBreakMode = .byTruncatingMiddle
		cell.addSubview(field)

		NSLayoutConstraint.activate([
			field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
			field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
			field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
		])

		return cell
	}

	func selectionShouldChange(in tableView: NSTableView) -> Bool {
		handleUnsavedChanges()
	}

	func tableViewSelectionDidChange(_ notification: Notification) {
		loadSelectedProfile()
	}

	func textDidChange(_ notification: Notification) {
		isDirty = true
		updateControls()
	}

	@objc private func saveProfile() {
		do {
			try saveSelectedProfile()
		} catch {
			showError("Could not save profile", error.localizedDescription)
		}
	}

	@objc private func applySelectedProfile() {
		do {
			try saveSelectedProfile()
			guard let profile = selectedProfile() else {
				return
			}

			try applyProfile(profile)
			statusLabel.stringValue = "Applied \(profile.displayName)"
		} catch {
			showError("Could not apply profile", error.localizedDescription)
		}
	}

	@objc private func createProfile() {
		guard handleUnsavedChanges(),
			let fileName = promptForProfileName(
				title: "New Profile",
				defaultName: "New Profile.hst"
			)
		else {
			return
		}

		do {
			let destinationURL = uniqueDestinationURL(for: fileName)
			let content = defaultHostsProfileContent()
			try content.write(to: destinationURL, atomically: true, encoding: .utf8)
			try reloadProfiles(selecting: destinationURL.lastPathComponent)
			profilesChanged()
		} catch {
			showError("Could not create profile", error.localizedDescription)
		}
	}

	@objc private func duplicateProfile() {
		guard handleUnsavedChanges(), let profile = selectedProfile() else {
			return
		}

		let suggestedName = "\(profile.displayName) Copy.hst"
		guard let fileName = promptForProfileName(
			title: "Duplicate Profile",
			defaultName: suggestedName
		) else {
			return
		}

		do {
			let destinationURL = uniqueDestinationURL(for: fileName)
			try profile.content.write(to: destinationURL, atomically: true, encoding: .utf8)
			try reloadProfiles(selecting: destinationURL.lastPathComponent)
			profilesChanged()
		} catch {
			showError("Could not duplicate profile", error.localizedDescription)
		}
	}

	@objc private func renameProfile() {
		guard handleUnsavedChanges(), let profile = selectedProfile() else {
			return
		}

		guard let fileName = promptForProfileName(
			title: "Rename Profile",
			defaultName: profile.fileName
		) else {
			return
		}

		do {
			let destinationURL = try renameDestinationURL(
				for: fileName,
				currentProfile: profile
			)

			guard destinationURL.path != profile.url.path else {
				return
			}

			try fileManager.moveItem(at: profile.url, to: destinationURL)
			try reloadProfiles(selecting: destinationURL.lastPathComponent)
			profilesChanged()
		} catch {
			showError("Could not rename profile", error.localizedDescription)
		}
	}

	@objc private func deleteProfile() {
		guard let profile = selectedProfile() else {
			return
		}

		let alert = NSAlert()
		alert.messageText = "Delete \(profile.displayName)?"
		alert.informativeText = "This removes the profile file from \(AppConstants.name). It does not change /etc/hosts."
		alert.addButton(withTitle: "Delete")
		alert.addButton(withTitle: "Cancel")
		alert.alertStyle = .warning

		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}

		do {
			try fileManager.removeItem(at: profile.url)
			let nextSelection = profiles
				.filter { $0.fileName != profile.fileName }
				.first?
				.fileName
			try reloadProfiles(selecting: nextSelection)
			profilesChanged()
		} catch {
			showError("Could not delete profile", error.localizedDescription)
		}
	}

	private func buildInterface() {
		guard let contentView = window?.contentView else {
			return
		}

		let sidebar = NSScrollView()
		sidebar.hasVerticalScroller = true
		sidebar.borderType = .bezelBorder
		sidebar.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
		sidebar.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(sidebar)

		let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profiles"))
		column.title = "Profiles"
		tableView.addTableColumn(column)
		tableView.headerView = nil
		tableView.delegate = self
		tableView.dataSource = self
		tableView.rowHeight = 38
		tableView.intercellSpacing = NSSize(width: 0, height: 0)
		tableView.selectionHighlightStyle = .regular
		sidebar.documentView = tableView

		let editorPanel = NSStackView()
		editorPanel.orientation = .vertical
		editorPanel.alignment = .width
		editorPanel.spacing = 0
		editorPanel.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
		editorPanel.translatesAutoresizingMaskIntoConstraints = false
		editorPanel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		contentView.addSubview(editorPanel)

		titleLabel.font = NSFont.boldSystemFont(ofSize: 18)
		titleLabel.lineBreakMode = .byTruncatingMiddle
		titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

		statusLabel.textColor = .secondaryLabelColor
		statusLabel.font = NSFont.systemFont(ofSize: 14)
		statusLabel.lineBreakMode = .byTruncatingTail
		statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let headerRow = NSStackView(views: [titleLabel, statusLabel])
		headerRow.orientation = .horizontal
		headerRow.alignment = .centerY
		headerRow.spacing = 8

		let textScrollView = NSScrollView()
		textScrollView.hasVerticalScroller = true
		textScrollView.hasHorizontalScroller = true
		textScrollView.borderType = .bezelBorder
		textScrollView.autohidesScrollers = false
		textScrollView.documentView = textView
		textScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
		textScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		textView.isRichText = false
		textView.allowsUndo = true
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
		textView.delegate = self
		textView.minSize = NSSize(width: 0, height: 0)
		textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.isHorizontallyResizable = true
		textView.isVerticallyResizable = true
		textView.textContainerInset = NSSize(width: 10, height: 8)
		textView.textContainer?.widthTracksTextView = false
		textView.textContainer?.heightTracksTextView = false
		textView.textContainer?.containerSize = NSSize(
			width: CGFloat.greatestFiniteMagnitude,
			height: CGFloat.greatestFiniteMagnitude
		)

		configureButton(newButton, title: "New", action: #selector(createProfile))
		configureButton(renameButton, title: "Rename", action: #selector(renameProfile))
		configureButton(duplicateButton, title: "Duplicate", action: #selector(duplicateProfile))
		configureButton(deleteButton, title: "Delete", action: #selector(deleteProfile))
		configureButton(saveButton, title: "Save", action: #selector(saveProfile))
		configureButton(applyButton, title: "Apply", action: #selector(applySelectedProfile))

		let leftButtons = NSStackView(views: [newButton, renameButton, duplicateButton, deleteButton])
		leftButtons.orientation = .horizontal
		leftButtons.spacing = 8

		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let rightButtons = NSStackView(views: [saveButton, applyButton])
		rightButtons.orientation = .horizontal
		rightButtons.spacing = 8

		let buttonRow = NSStackView(views: [leftButtons, spacer, rightButtons])
		buttonRow.orientation = .horizontal
		buttonRow.spacing = 8
		buttonRow.alignment = .centerY

		editorPanel.addArrangedSubview(headerRow)
		editorPanel.addArrangedSubview(textScrollView)
		editorPanel.addArrangedSubview(buttonRow)
		editorPanel.setCustomSpacing(12, after: headerRow)
		editorPanel.setCustomSpacing(14, after: textScrollView)

		NSLayoutConstraint.activate([
			sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
			sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			sidebar.widthAnchor.constraint(equalToConstant: 190),
			editorPanel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
			editorPanel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			editorPanel.topAnchor.constraint(equalTo: contentView.topAnchor),
			editorPanel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			textScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
		])
	}

	private func configureButton(_ button: NSButton, title: String, action: Selector) {
		button.title = title
		button.target = self
		button.action = action
		button.bezelStyle = .rounded
	}

	private func reloadProfiles(selecting fileName: String?) throws {
		try fileManager.createDirectory(
			at: profileDirectoryURL,
			withIntermediateDirectories: true
		)

		let urls = try fileManager.contentsOfDirectory(
			at: profileDirectoryURL,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		)

		profiles = try urls
			.filter { isSupportedProfileFile($0) }
			.map { url in
				let content = try String(contentsOf: url, encoding: .utf8)
				return ProfileRecord(
					fileName: url.lastPathComponent,
					displayName: displayName(for: url),
					url: url,
					content: content
				)
			}
			.sorted {
				$0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
			}

		tableView.reloadData()

		let selectedRow = fileName.flatMap { selectedFileName in
			profiles.firstIndex { $0.fileName == selectedFileName }
		} ?? 0

		if profiles.indices.contains(selectedRow) {
			tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
			loadSelectedProfile()
		} else {
			selectedFileName = nil
			textView.string = ""
			textView.undoManager?.removeAllActions()
			titleLabel.stringValue = "No profile selected"
			statusLabel.stringValue = "Create or import a hosts profile."
			isDirty = false
			updateControls()
		}
	}

	private func loadSelectedProfile() {
		guard let profile = selectedProfile() else {
			textView.string = ""
			textView.undoManager?.removeAllActions()
			titleLabel.stringValue = "No profile selected"
			statusLabel.stringValue = "Create or import a hosts profile."
			isDirty = false
			updateControls()
			return
		}

		selectedFileName = profile.fileName
		titleLabel.stringValue = profile.displayName
		textView.string = profile.content
		textView.undoManager?.removeAllActions()
		isDirty = false
		updateControls()
	}

	private func selectedProfile() -> ProfileRecord? {
		let row = tableView.selectedRow
		guard profiles.indices.contains(row) else {
			return nil
		}
		return profiles[row]
	}

	private func saveSelectedProfile() throws {
		guard let row = tableView.selectedRowIndexes.first,
			profiles.indices.contains(row)
		else {
			return
		}

		let content = HostFileDocument.normalized(textView.string)
		let profile = profiles[row]
		try content.write(to: profile.url, atomically: true, encoding: .utf8)
		profiles[row] = ProfileRecord(
			fileName: profile.fileName,
			displayName: profile.displayName,
			url: profile.url,
			content: content
		)
		isDirty = false
		profilesChanged()
		updateControls()
	}

	private func handleUnsavedChanges() -> Bool {
		guard isDirty, let profile = selectedProfile() else {
			return true
		}

		let alert = NSAlert()
		alert.messageText = "Save changes to \(profile.displayName)?"
		alert.informativeText = "Unsaved changes will be lost if you switch profiles."
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Discard")
		alert.addButton(withTitle: "Cancel")

		switch alert.runModal() {
		case .alertFirstButtonReturn:
			do {
				try saveSelectedProfile()
				return true
			} catch {
				showError("Could not save profile", error.localizedDescription)
				return false
			}
		case .alertSecondButtonReturn:
			isDirty = false
			return true
		default:
			return false
		}
	}

	private func updateControls() {
		let hasSelection = selectedProfile() != nil
		saveButton.isEnabled = hasSelection && isDirty
		applyButton.isEnabled = hasSelection
		renameButton.isEnabled = hasSelection
		duplicateButton.isEnabled = hasSelection
		deleteButton.isEnabled = hasSelection

		if hasSelection {
			statusLabel.stringValue = isDirty ? "Unsaved changes" : "Saved"
		}
	}

	private func promptForProfileName(title: String, defaultName: String) -> String? {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = """
		You can start the name with an emoji, like 🟢 Work, to use it as the menu bar icon.

		The icon appears when the profile is active and “Show Profile Emoji in Menu Bar” is on.

		Press Control-Command-Space to choose an emoji.
		"""
		alert.addButton(withTitle: "OK")
		alert.addButton(withTitle: "Cancel")

		let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
		input.stringValue = defaultName
		input.placeholderString = "🟢 Work"
		alert.accessoryView = input

		guard alert.runModal() == .alertFirstButtonReturn else {
			return nil
		}

		let fileName = normalizedProfileFileName(input.stringValue)
		return fileName.isEmpty ? nil : fileName
	}

	private func normalizedProfileFileName(_ rawName: String) -> String {
		let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			return ""
		}

		let sanitized = trimmed
			.replacingOccurrences(of: "/", with: "-")
			.replacingOccurrences(of: ":", with: "-")
		let url = URL(fileURLWithPath: sanitized)

		if url.pathExtension.isEmpty {
			return sanitized + ".hst"
		}

		return url.lastPathComponent
	}

	private func uniqueDestinationURL(for fileName: String) -> URL {
		let normalizedFileName = normalizedProfileFileName(fileName)
		let baseURL = profileDirectoryURL.appendingPathComponent(normalizedFileName)

		if !fileManager.fileExists(atPath: baseURL.path) {
			return baseURL
		}

		let originalURL = URL(fileURLWithPath: normalizedFileName)
		let baseName = originalURL.deletingPathExtension().lastPathComponent
		let ext = originalURL.pathExtension

		for index in 2...1000 {
			let candidateName = ext.isEmpty
				? "\(baseName) \(index)"
				: "\(baseName) \(index).\(ext)"
			let candidateURL = profileDirectoryURL.appendingPathComponent(candidateName)

			if !fileManager.fileExists(atPath: candidateURL.path) {
				return candidateURL
			}
		}

		return profileDirectoryURL.appendingPathComponent(UUID().uuidString + ".hst")
	}

	private func renameDestinationURL(
		for fileName: String,
		currentProfile: ProfileRecord
	) throws -> URL {
		let normalizedFileName = normalizedProfileFileName(fileName)
		let destinationURL = profileDirectoryURL.appendingPathComponent(normalizedFileName)

		if destinationURL.path == currentProfile.url.path {
			return destinationURL
		}

		if fileManager.fileExists(atPath: destinationURL.path) {
			throw NSError(
				domain: AppConstants.name,
				code: 1,
				userInfo: [
					NSLocalizedDescriptionKey: "A profile named \(normalizedFileName) already exists.",
				]
			)
		}

		return destinationURL
	}

	private func isSupportedProfileFile(_ url: URL) -> Bool {
		["hst", "hosts", "txt"].contains(url.pathExtension.lowercased())
	}

	private func displayName(for url: URL) -> String {
		let name = url.deletingPathExtension().lastPathComponent
		return name.isEmpty ? url.lastPathComponent : name
	}
}

@main
enum HostessMain {
	@MainActor
	static func main() {
		if CommandLine.arguments.dropFirst() == ["--unregister-helper"] {
			do {
				try HelperServiceManager.unregisterManagedHelper()
				exit(0)
			} catch {
				FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
				exit(1)
			}
		}

		let app = NSApplication.shared
		let delegate = AppDelegate()
		app.delegate = delegate
		app.run()
	}
}
