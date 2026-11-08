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

    /// Standard macOS secure input runs in its own UI process. The token is returned
    /// through a private pipe, never through command arguments, files, or logs.
    public static func promptToken() async throws -> String {
        let script = """
        set answer to display dialog "Paste your Slack User OAuth Token (xoxp-). It will be verified and stored in macOS Keychain." default answer "" with hidden answer buttons {"Cancel", "Connect"} default button "Connect" with title "Connect Slack to Task Manager"
        return text returned of answer
        """
        let token = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ManagerError.invalid("Slack connection cancelled or secure prompt unavailable") }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        try validateToken(token)
        return token
    }

    public static func showResult(title: String, message: String) async {
        // Pass non-secret display text as arguments so workspace names cannot become script code.
        let script = """
        on run argv
            display dialog (item 1 of argv) buttons {"OK"} default button "OK" with title (item 2 of argv)
        end run
        """
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, message, title]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
        }.value
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
