import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!
    var popover: NSPopover!
    var timer: Timer?
    
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
        setupTimer()
        setupCredentialObserver()
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
        popover.contentSize = NSSize(width: 300, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
    }
    
    func setupTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            self.updateStatusBar()
        }
        
        // Add a small delay for the initial update to ensure app is fully initialized
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.updateStatusBar()
        }
    }
    
    func setupCredentialObserver() {
        // Listen for credential changes and update status bar immediately
        NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { _ in
            print("Debug: AppDelegate - Credentials changed, updating status bar...")
            self.updateStatusBar()
        }
        
        // Listen for worklog data refresh and update status bar immediately
        NotificationCenter.default.addObserver(
            forName: .worklogDataRefreshed,
            object: nil,
            queue: .main
        ) { _ in
            print("Debug: AppDelegate - Worklog data refreshed, updating status bar...")
            self.updateStatusBar()
        }
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
            // Create a settings popover
            let settingsPopover = NSPopover()
            settingsPopover.contentSize = NSSize(width: 400, height: 500)
            settingsPopover.behavior = .applicationDefined
            settingsPopover.contentViewController = NSHostingController(rootView: SettingsView())
            
            // Add a notification observer to refresh status bar when popover closes
            NotificationCenter.default.addObserver(
                forName: NSPopover.didCloseNotification,
                object: settingsPopover,
                queue: .main
            ) { _ in
                // Refresh the status bar when settings popover is closed
                self.updateStatusBar()
                // Remove the observer to avoid memory leaks
                NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: settingsPopover)
            }
            
            settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func updateStatusBar() {
        Task {
            do {
                print("Debug: AppDelegate - Loading credentials...")
                let credentials = try CredentialManager.shared.loadCredentials()
                print("Debug: AppDelegate - Credentials loaded successfully")
                
                print("Debug: AppDelegate - Fetching days since last worklog...")
                let days = await TempoService.shared.getDaysSinceLastWorklog(
                    apiToken: credentials.apiToken,
                    jiraURL: credentials.jiraURL,
                    accountId: credentials.accountId.isEmpty ? nil : credentials.accountId
                )
                print("Debug: AppDelegate - Days since last worklog: \(days?.description ?? "nil")")
                
                await MainActor.run {
                    updateStatusBarDisplay(days: days, warningThreshold: credentials.warningThreshold)
                }
            } catch {
                print("Debug: AppDelegate - Error in updateStatusBar: \(error)")
                await MainActor.run {
                    updateStatusBarDisplay(error: error)
                }
            }
        }
    }
    
    private func updateStatusBarDisplay(days: Int?, warningThreshold: Int) {
        guard let button = statusBarItem.button else { return }
        
        print("Debug: AppDelegate - updateStatusBarDisplay called with days: \(days?.description ?? "nil"), warningThreshold: \(warningThreshold)")
        
        if let days = days {
            let emoji: String
            let color: NSColor
            
            if days <= warningThreshold {
                emoji = "✅"
                color = .systemGreen
            } else if days <= warningThreshold + 1 {
                emoji = "⏰"
                color = .systemOrange
            } else {
                emoji = "🚨"
                color = .systemRed
            }
            
            button.title = "\(emoji) \(days)"
            button.attributedTitle = NSAttributedString(
                string: "\(emoji) \(days)",
                attributes: [.foregroundColor: color]
            )
            button.toolTip = "Last worklog: \(days) day\(days == 1 ? "" : "s") ago"
            print("Debug: AppDelegate - Set status bar to: \(emoji) \(days)")
        } else {
            button.title = "⏱️"
            button.toolTip = "No worklog data available"
            print("Debug: AppDelegate - Set status bar to: ⏱️ (no data)")
        }
    }
    
    private func updateStatusBarDisplay(error: Error) {
        guard let button = statusBarItem.button else { return }
        
        print("Debug: AppDelegate - updateStatusBarDisplay error: \(error)")
        
        button.title = "❌"
        
        if let credentialError = error as? CredentialError {
            switch credentialError {
            case .noStoredCredentials:
                button.toolTip = "No credentials configured. Click to open settings and configure your Tempo credentials."
            case .decodingFailed:
                button.toolTip = "Credential data corrupted. Click to open settings and re-enter your credentials."
            }
        } else if let tempoError = error as? TempoError {
            switch tempoError {
            case .unauthorized:
                button.toolTip = "API token invalid. Click to open settings and check your credentials."
            case .forbidden:
                button.toolTip = "Access forbidden. Check your account permissions."
            case .notFound:
                button.toolTip = "Account not found. Click to open settings and check your Account ID."
            case .networkError:
                button.toolTip = "Network error. Check your internet connection."
            case .apiError(let statusCode):
                button.toolTip = "API error (HTTP \(statusCode)). Check your Jira URL and credentials."
            default:
                button.toolTip = "Tempo error: \(tempoError.localizedDescription)"
            }
        } else {
            button.toolTip = "Error: \(error.localizedDescription)"
        }
        
        print("Debug: AppDelegate - Set status bar to: ❌ with tooltip: \(button.toolTip ?? "nil")")
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
