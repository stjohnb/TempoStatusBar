import Cocoa
import SwiftUI
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!
    var popover: NSPopover!
    private let stateManager = WorklogStateManager.shared
    
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
    
    func setupStateObserver() {
        // Use Combine to observe the state manager changes
        Task {
            for await _ in stateManager.$daysSinceLastWorklog.values {
                updateStatusBarDisplay()
            }
        }
        
        Task {
            for await _ in stateManager.$errorMessage.values {
                updateStatusBarDisplay()
            }
        }
        
        Task {
            for await _ in stateManager.$hasCredentials.values {
                updateStatusBarDisplay()
            }
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
            Task { @MainActor in
                self.stateManager.checkCredentialsAndRefresh()
            }
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
                Task { @MainActor in
                    self.stateManager.checkCredentialsAndRefresh()
                }
                // Remove the observer to avoid memory leaks
                NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: settingsPopover)
            }
            
            settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateStatusBarDisplay() {
        guard let button = statusBarItem.button else { return }
        
        if let errorMessage = stateManager.errorMessage {
            // Handle error state
            button.title = "❌"
            
            if !stateManager.hasCredentials {
                button.toolTip = "No credentials configured. Click to open settings and configure your Tempo credentials."
            } else if errorMessage.contains("Unauthorized") {
                button.toolTip = "API token invalid. Click to open settings and check your credentials."
            } else if errorMessage.contains("Forbidden") {
                button.toolTip = "Access forbidden. Check your account permissions."
            } else if errorMessage.contains("not found") {
                button.toolTip = "Account not found. Click to open settings and check your Account ID."
            } else if errorMessage.contains("Network") {
                button.toolTip = "Network error. Check your internet connection."
            } else {
                button.toolTip = "Error: \(errorMessage)"
            }
        } else {
            // Handle normal state
            button.title = stateManager.statusBarTitle
            
            if let days = stateManager.daysSinceLastWorklog {
                let color: NSColor
                if days <= stateManager.warningThreshold {
                    color = .systemGreen
                } else if days <= stateManager.warningThreshold + 1 {
                    color = .systemOrange
                } else {
                    color = .systemRed
                }
                
                button.attributedTitle = NSAttributedString(
                    string: stateManager.statusBarTitle,
                    attributes: [.foregroundColor: color]
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
