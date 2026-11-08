import Foundation
import TaskManagerCore

/// Delegates authentication and HTTP to gh; the adapter itself can only issue GETs.
public struct GitHubCLITransport: GitHubHTTPTransport {
    private let runner: any GHCommandExecuting

    public init(runner: any GHCommandExecuting = GHProcessRunner()) { self.runner = runner }

    public func get(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "api.github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.fragment == nil, components.path.hasPrefix("/repos/"),
              !components.path.contains("{"), !components.path.contains("}"),
              request.value(forHTTPHeaderField: "Authorization") == nil else {
            throw ManagerError.invalid("GitHub CLI transport requires a GitHub.com repository GET; authentication is managed by gh")
        }
        let endpoint = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let result = try await runner.run(arguments: [
            "api", "--hostname", "github.com", "--method", "GET", "--include",
            "--header", "Accept: application/vnd.github+json",
            "--header", "X-GitHub-Api-Version: 2022-11-28",
            endpoint,
        ])
        guard let separator = result.stdout.range(of: Data("\r\n\r\n".utf8)) ?? result.stdout.range(of: Data("\n\n".utf8)) else {
            if result.exitCode != 0 { throw GitHubError.cli(exitCode: result.exitCode) }
            throw ManagerError.invalid("gh returned an invalid HTTP response")
        }
        let header = String(decoding: result.stdout[..<separator.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/"),
              let statusText = statusLine.split(separator: " ").dropFirst().first,
              let status = Int(statusText), (100...599).contains(status) else {
            throw ManagerError.invalid("gh returned an invalid HTTP status")
        }
        // gh exits nonzero for HTTP failures; preserve their status and retry headers.
        if result.exitCode != 0 && (200...299).contains(status) { throw GitHubError.cli(exitCode: result.exitCode) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = headers[key].map { $0 + ", " + value } ?? value
        }
        return HTTPResponse(data: Data(result.stdout[separator.upperBound...]), status: status, headers: headers)
    }
}
