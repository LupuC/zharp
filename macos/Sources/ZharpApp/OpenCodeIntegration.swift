import Foundation

/// Connects OpenCode to Zharp.
///
/// The cheapest of the three by a distance. OpenCode loads plugins into its own
/// process, so a hook is a function call: no shell, no process, nothing to pay
/// per tool call. That is why this subscribes to what it needs rather than to
/// the least it can get away with, which is the shape the Codex integration was
/// forced into.
///
/// It is also the only one of the three that says when a permission has been
/// answered, so nothing has to be inferred.
///
/// The plugin is copied into OpenCode's own config directory and referenced
/// from there by a relative path, which is what OpenCode's own plugins use. An
/// absolute one would be ambiguous with an npm package name.
enum OpenCodeIntegration {

    private static let pluginName = "zharp-agent-opencode"
    private static let pluginFileName = pluginName + ".js"

    /// Where OpenCode expects the entry, relative to its config.
    private static let pluginEntry = "./plugin/" + pluginFileName

    /// What makes an entry ours, whatever it is called. Looser than the current
    /// file name so an entry written by a past version, or by the Windows build
    /// into a home directory shared with it, is still recognized and replaced.
    private static let marker = "zharp-agent"

    /// The copy that ships with Zharp.
    static var sourcePath: String? {
        Resources.url(forResource: pluginName, withExtension: "js")?.path
    }

    /// OpenCode's config directory.
    ///
    /// XDG_CONFIG_HOME is honoured, which the Windows build does not do: on a
    /// Mac it is set often enough that ignoring it would mean writing the
    /// plugin into a directory OpenCode never reads.
    static let configDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let custom = environment["ZHARP_OPENCODE_CONFIG"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/opencode")
    }()

    static var configURL: URL { configDirectory.appendingPathComponent("opencode.json") }

    static var pluginDirectory: URL { configDirectory.appendingPathComponent("plugin") }

    /// Where the plugin is installed to.
    static var installedPluginURL: URL {
        pluginDirectory.appendingPathComponent(pluginFileName)
    }

    static var isOpenCodePresent: Bool {
        FileManager.default.fileExists(atPath: configDirectory.path)
            || ShellDiscovery.findOnPath("opencode") != nil
    }

    /// Registered in the config right now.
    static func isConnected() -> Bool {
        do {
            guard let list = try AgentConfigFile.read(configURL)?["plugin"] as? [Any] else {
                return false
            }
            return list.contains(where: isOurs)
        } catch {
            App.log("opencode: could not read config: \(error)")
            return false
        }
    }

    /// Registered, running the plugin this build ships, and registered under
    /// the name this build ships it as.
    ///
    /// The file is copied rather than referenced, so an update has to refresh
    /// the copy: comparing the contents is what notices that.
    static func isCurrent() -> Bool {
        do {
            guard let source = sourcePath else { return false }
            guard let list = try AgentConfigFile.read(configURL)?["plugin"] as? [Any],
                  list.contains(where: { ($0 as? String) == pluginEntry })
            else { return false }

            let files = FileManager.default
            guard let installed = files.contents(atPath: installedPluginURL.path),
                  let shipped = files.contents(atPath: source) else { return false }
            return installed == shipped
        } catch {
            App.log("opencode: could not compare the plugin: \(error)")
            return false
        }
    }

    /// Installs or refreshes the plugin, or removes it when off.
    static func sync(enabled: Bool) {
        do {
            guard isOpenCodePresent else { return }

            if !enabled {
                guard isConnected() else { return }
                try disconnect()
                App.log("opencode: plugin removed from \(configURL.path)")
                return
            }

            guard sourcePath != nil else {
                App.log("opencode: \(pluginFileName) is missing from the bundle")
                return
            }
            if isCurrent() { return }

            try connect()
            App.log("opencode: plugin installed at \(installedPluginURL.path)")
        } catch {
            App.log("opencode: could not install the plugin: \(error)")
        }
    }

    static func connect() throws {
        guard let source = sourcePath else { return }

        let files = FileManager.default
        try files.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        removeStaleCopies(except: installedPluginURL)
        if files.fileExists(atPath: installedPluginURL.path) {
            try files.removeItem(at: installedPluginURL)
        }
        try files.copyItem(at: URL(fileURLWithPath: source), to: installedPluginURL)

        var root = try AgentConfigFile.read(configURL) ?? [:]

        // OpenCode's own config carries this, and a file without it is one we
        // are creating from nothing.
        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }

        var list = root["plugin"] as? [Any] ?? []
        list.removeAll(where: isOurs)
        list.append(pluginEntry)
        root["plugin"] = list

        try AgentConfigFile.write(root, to: configURL)
    }

    static func disconnect() throws {
        removeStaleCopies(except: nil)

        guard var root = try AgentConfigFile.read(configURL) else { return }

        if var list = root["plugin"] as? [Any] {
            list.removeAll(where: isOurs)
            if list.isEmpty {
                root.removeValue(forKey: "plugin")
            } else {
                root["plugin"] = list
            }
        }

        // A config that now says nothing but its schema is one we created.
        if root.isEmpty || (root.count == 1 && root["$schema"] != nil) {
            try? FileManager.default.removeItem(at: configURL)
            return
        }

        try AgentConfigFile.write(root, to: configURL)
    }

    /// Deletes copies of the plugin left in OpenCode's plugin directory under
    /// any name but the one being installed.
    ///
    /// Not merely tidiness. Dropping the old entry from the config list is
    /// enough to stop a stale copy being named, but a plugin directory is also
    /// somewhere OpenCode looks by convention, and a leftover that still loads
    /// would report every event a second time. Only files whose names are ours
    /// are touched.
    private static func removeStaleCopies(except keep: URL?) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: pluginDirectory.path) else {
            return
        }
        for name in names where name.contains(marker) {
            let url = pluginDirectory.appendingPathComponent(name)
            if url.path == keep?.path { continue }
            try? files.removeItem(at: url)
        }
    }

    /// Matched on part of the file name, so a differently rooted or differently
    /// named entry from an older install is still recognized and replaced.
    private static func isOurs(_ entry: Any) -> Bool {
        (entry as? String)?.contains(marker) ?? false
    }
}
