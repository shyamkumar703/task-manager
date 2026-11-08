import AppKit
import Foundation
import Security
import TaskManagerCore

public struct SlackConnectionInfo: Codable, Sendable {
    public let workspaceID: String
    public let workspaceName: String
    public let userID: String
    public var credentialAccount: String { workspaceID + ":" + userID }
}

public enum SlackConnection {
    private static let service = "com.task-manager.slack.user-token"

    /// The credential stays in this process: never in command arguments, logs, or application state.
    @MainActor public static func promptToken() throws -> String {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // A command-line executable has no application menu. Install Edit actions so
        // standard shortcuts (especially Cmd-V) reach the secure field's editor.
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Task Manager")
        applicationMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        app.mainMenu = menu
        app.finishLaunching()
        let alert = NSAlert()
        alert.messageText = "Connect Slack to Task Manager"
        alert.informativeText = "Paste your User OAuth Token (xoxp-). It will be checked with Slack and saved in macOS Keychain. Message polling is not enabled yet."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        field.isEditable = true
        field.isSelectable = true
        field.placeholderString = "xoxp-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Focus after the modal event loop has opened the window, rather than
        // relying on activation of a previously background command-line process.
        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            alert.window.makeFirstResponder(field)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { throw ManagerError.invalid("Slack connection cancelled") }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.stringValue = ""
        try validateToken(token)
        return token
    }

    @MainActor public static func showResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
        }
        alert.runModal()
    }

    public static func validateToken(_ token: String) throws {
        guard token.hasPrefix("xoxp-"), token.count <= 8192,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ManagerError.invalid("Enter the User OAuth Token beginning with xoxp-, not a bot or app token")
        }
    }

    public static func validateAuthentication(data: Data, status: Int) throws -> SlackConnectionInfo {
        struct Response: Decodable {
            let ok: Bool
            let team_id: String?
            let team: String?
            let user_id: String?
            let bot_id: String?
        }
        guard status == 200, data.count <= 1_048_576,
              let response = try? JSONDecoder().decode(Response.self, from: data), response.ok,
              response.bot_id == nil,
              let workspace = response.team_id, !workspace.isEmpty,
              let name = response.team, !name.isEmpty,
              let user = response.user_id, !user.isEmpty else {
            throw ManagerError.invalid("Slack could not verify a user connection. Check the User OAuth Token and workspace installation.")
        }
        return SlackConnectionInfo(workspaceID: workspace, workspaceName: name, userID: user)
    }

    public static func connect(token: String, stateDirectory: String) async throws -> SlackConnectionInfo {
        try validateToken(token)
        var request = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw ManagerError.invalid("Could not reach Slack to verify the token; check your connection and try again") }
        let info = try validateAuthentication(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: info.credentialAccount]
        let value = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ManagerError.storage("Could not save Slack token in Keychain (status \(status))") }
        let file = URL(fileURLWithPath: stateDirectory).appendingPathComponent("slack-connections.json")
        var connections: [SlackConnectionInfo] = []
        if FileManager.default.fileExists(atPath: file.path) {
            connections = try JSONDecoder().decode([SlackConnectionInfo].self, from: Data(contentsOf: file))
        }
        connections.removeAll { $0.credentialAccount == info.credentialAccount }
        connections.append(info)
        try JSONEncoder().encode(connections).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return info
    }
}
