import Cocoa
import SwiftUI
import Combine
import OSLog

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!
    var popover: NSPopover!
    var settingsPopover: NSPopover!
    private let stateManager = WorklogStateManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoStatusBar", category: "AppDelegate")
    private var credentialObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var updateCheckTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Add minimal main menu with Edit > Paste
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        setupStatusBar()
        setupStateObserver()
        setupCredentialObserver()
        Task { await self.runAutomaticUpdateCheck() }
        scheduleAutomaticUpdateChecks()
    }
    
    func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusBarItem.button {
            button.title = "⏱️"
        }
        
        // Create the menu
        let menu = NSMenu()
        
        // Status option - shows the popover
        let statusItem = NSMenuItem(title: "Status", action: #selector(showStatus), keyEquivalent: "")
        statusItem.target = self
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())

        // About option
        let aboutItem = NSMenuItem(title: "About TempoStatusBar", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updatesItem = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdatesManually), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())

        // Settings option - shows settings view
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit option
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        // Set the menu on the status bar item
        statusBarItem.menu = menu
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 350, height: 280)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())

        settingsPopover = NSPopover()
        settingsPopover.contentSize = NSSize(width: 400, height: 640)
        settingsPopover.behavior = .applicationDefined
        settingsPopover.contentViewController = NSHostingController(rootView: SettingsView())
    }
    
    func setupStateObserver() {
        Publishers.Merge3(
            stateManager.$daysSinceLastWorklog.map { _ in () },
            stateManager.$lastError.map { _ in () },
            stateManager.$hasCredentials.map { _ in () }
        )
        .sink { [weak self] in self?.updateStatusBarDisplay() }
        .store(in: &cancellables)
    }
    
    func setupCredentialObserver() {
        // Listen for credential changes and update status bar immediately
        credentialObserver = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { _ in
            self.logger.debug("Credentials changed, updating status bar")
            Task { @MainActor in
                self.stateManager.checkCredentialsAndRefresh()
            }
        }
    }
    
    deinit {
        // Remove the credential observer to prevent memory leaks
        if let observer = credentialObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        updateCheckTimer?.invalidate()
    }
    
    @objc func showStatus() {
        if let button = statusBarItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            }
        }
    }
    
    @objc func showSettings() {
        if let button = statusBarItem.button {
            if settingsPopover.isShown {
                settingsPopover.performClose(nil)
            } else {
                settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            }
        }
    }
    
    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "TempoStatusBar"
        alert.informativeText = "Version \(appVersion)\n\nA macOS menu bar app for monitoring Jira Tempo worklogs."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func scheduleAutomaticUpdateChecks() {
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            Task { @MainActor in await self.runAutomaticUpdateCheck() }
        }
    }

    @objc private func checkForUpdatesManually() {
        Task { await self.performUpdateCheck(showUpToDateAlert: true, respectSkippedVersion: false) }
    }

    private func runAutomaticUpdateCheck() async {
        await performUpdateCheck(showUpToDateAlert: false, respectSkippedVersion: true)
    }

    private func performUpdateCheck(showUpToDateAlert: Bool, respectSkippedVersion: Bool) async {
        let result = await UpdateChecker.shared.checkForUpdates()
        switch result {
        case .upToDate(let current):
            if showUpToDateAlert { presentInfoAlert(messageText: "TempoStatusBar is up to date.", informativeText: "Version \(current)") }
        case .updateAvailable(let current, let latest, let releaseURL):
            if respectSkippedVersion && UpdateChecker.shared.skippedVersion == latest { return }
            presentUpdateAvailableAlert(current: current, latest: latest, releaseURL: releaseURL)
        case .skipped(let reason):
            if showUpToDateAlert { presentInfoAlert(messageText: "Could not check for updates.", informativeText: reason) }
        case .failed(let error):
            if showUpToDateAlert { presentWarningAlert(messageText: "Update check failed.", informativeText: error.localizedDescription) }
        }
    }

    private func presentUpdateAvailableAlert(current: String, latest: String, releaseURL: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update available"
        alert.informativeText = "Version \(latest) is available. You're currently running \(current)."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Remind Me Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(releaseURL)
        case .alertSecondButtonReturn:
            UpdateChecker.shared.skippedVersion = latest
        default:
            break
        }
    }

    private func presentInfoAlert(messageText: String, informativeText: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentWarningAlert(messageText: String, informativeText: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func updateStatusBarDisplay() {
        guard let button = statusBarItem.button else { return }

        if let error = stateManager.lastError {
            // Handle error state
            button.title = "❌"

            if !stateManager.hasCredentials {
                button.toolTip = "No credentials configured. Click to open settings and configure your Tempo credentials."
            } else {
                switch error {
                case .tempo(.unauthorized):
                    button.toolTip = "API token invalid. Click to open settings and check your credentials."
                case .tempo(.forbidden):
                    button.toolTip = "Access forbidden. Check your account permissions."
                case .tempo(.apiError(statusCode: 404)), .tempo(.missingCredentials):
                    button.toolTip = "Account not found. Click to open settings and check your Account ID."
                case .tempo(.networkError):
                    button.toolTip = "Network error. Check your internet connection."
                default:
                    button.toolTip = "Error: \(error.displayMessage)"
                }
            }
        } else {
            // Handle normal state
            button.title = stateManager.statusBarTitle
            
            if stateManager.daysSinceLastWorklog != nil {
                button.attributedTitle = NSAttributedString(
                    string: stateManager.statusBarTitle,
                    attributes: [.foregroundColor: stateManager.statusBarColor]
                )
            }
            
            button.toolTip = stateManager.statusBarTooltip
        }
    }
}

// Main entry point for the application
@main
struct TempoStatusBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
