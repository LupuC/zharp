import AppKit
import UserNotifications

/// Application entry point and process-wide helpers.
@main
final class App: NSObject, NSApplicationDelegate {
    /// The running version. Inside the .app this comes from the bundle, whose
    /// Info.plist is generated from version.txt at packaging time; the literal
    /// is the fallback for `swift run` and is kept in step by release-please.
    static let version: String = {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        if let bundled = bundled as? String, !bundled.isEmpty, bundled != "__VERSION__" {
            return bundled
        }
        return "0.18.0" // x-release-please-version
    }()

    static private(set) weak var shared: App?

    /// One settings object for the whole process. Windows share it, so a change
    /// made in any of them is what every other window reads.
    static let settings = AppSettings.load()

    /// Every open terminal window, in creation order.
    static private(set) var windows: [MainWindowController] = []

    /// The window a menu command should act on. Falls back to the last one that
    /// was key, because a tear-out drop can leave no Zharp window key at all.
    static weak var lastActive: MainWindowController?
    static var current: MainWindowController? { lastActive ?? windows.last }

    /// True while the whole app is quitting, so a window closing does not
    /// snapshot its own tabs over everyone else's.
    static var closingAll = false

    static func register(_ window: MainWindowController) {
        windows.append(window)
        lastActive = window
    }

    static func unregister(_ window: MainWindowController) {
        windows.removeAll { $0 === window }
        if lastActive === window { lastActive = windows.last }
    }

    /// Re-applies shared settings everywhere after one window changed them.
    static func broadcastSettings(from origin: MainWindowController?) {
        for window in windows where window !== origin {
            window.applySharedSettings()
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    // ---------------------------------------------------------------- lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Icons.registerFont()
        buildMenu()

        // Notification taps open Settings > About, the update landing spot.
        UNUserNotificationCenter.current().delegate = self

        let controller = MainWindowController(restoring: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A drag ghost is a window too; it must not keep the process alive
        // after the last real one closes.
        App.windows.isEmpty
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // One snapshot across every window, not one per window - otherwise the
        // last window to close would overwrite the others' tabs with its own.
        App.closingAll = true
        MainWindowController.saveSessionSnapshot()
        App.settings.save()
        return .terminateNow
    }

    // ---------------------------------------------------------------- logging

    /// Appends a line to ~/Library/Application Support/Zharp/error.log
    /// (best effort) - the counterpart of the Windows build's error.log.
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let url = AppSettings.supportDirectory.appendingPathComponent("error.log")
        do {
            try FileManager.default.createDirectory(at: AppSettings.supportDirectory,
                                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(Data(line.utf8))
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging must never take the app down.
        }
    }

    // ---------------------------------------------------------------- resources

    private static var logoCache: [String: NSImage] = [:]

    /// The brand mark for the active theme - cream on dark surfaces, ink on
    /// light ones. Cached per variant; both ship in the bundle.
    static var logoImage: NSImage? {
        let name = Chrome.current.brandLogoName
        if let cached = logoCache[name] { return cached }
        guard let url = Resources.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        logoCache[name] = image
        return image
    }

    /// Renders a Tabler glyph into an image, for menu items.
    static func glyphImage(_ glyph: String, size: CGFloat) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Icons.font(size: size),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = NSAttributedString(string: glyph, attributes: attributes)
        let bounds = text.size()
        let image = NSImage(size: NSSize(width: max(bounds.width, size),
                                         height: max(bounds.height, size)))
        image.lockFocus()
        text.draw(at: .zero)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // ---------------------------------------------------------------- menu bar

    /// macOS requires a menu bar; it exposes the same actions the Windows
    /// title-bar buttons and shortcuts do, so nothing is reachable only there.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Zharp", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Zharp", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Zharp", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let sessionItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        sessionMenu.addItem(withTitle: "New Session", action: #selector(newTab),
                            keyEquivalent: "t").target = self
        sessionMenu.addItem(withTitle: "New Window", action: #selector(newWindow),
                            keyEquivalent: "n").target = self
        sessionMenu.addItem(withTitle: "Close Session", action: #selector(closeTab),
                            keyEquivalent: "w").target = self
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Find Session…", action: #selector(toggleSearch),
                            keyEquivalent: "F").target = self
        sessionItem.submenu = sessionMenu
        mainMenu.addItem(sessionItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(copySelection), keyEquivalent: "c")
            .target = self
        editMenu.addItem(withTitle: "Paste", action: #selector(pasteClipboard), keyEquivalent: "v")
            .target = self
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Tab Panel", action: #selector(toggleSidebar),
                         keyEquivalent: "b").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
            .target = self
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
            .target = self
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
            .target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // The menu forwards to the window controller, which owns every action.
    @objc private func newTab() { App.current?.addTab() }
    @objc private func closeTab() { App.current?.closeActiveTab() }
    @objc private func newWindow() { MainWindowController.openNewWindow() }
    @objc private func toggleSearch() { App.current?.performShortcut("toggleSearch") }
    @objc private func toggleSidebar() { App.current?.performShortcut("toggleSidebar") }
    @objc private func openSettings() { App.current?.openSettings() }
    @objc private func zoomIn() { App.current?.performShortcut("zoomIn") }
    @objc private func zoomOut() { App.current?.performShortcut("zoomOut") }
    @objc private func zoomReset() { App.current?.performShortcut("zoomReset") }
    @objc private func copySelection() { App.current?.performShortcut("copy") }
    @objc private func pasteClipboard() { App.current?.performShortcut("paste") }
    @objc private func showAbout() { App.current?.showUpdatePage() }
}

extension App: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run { App.current?.showUpdatePage() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
