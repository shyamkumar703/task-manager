import Foundation
import TaskManagerCore
import TaskManagerRuntime
import Testing

@Test func slackConnectionAcceptsUserIdentityAndMetadataContainsNoToken() throws {
    let data = Data(#"{"ok":true,"team_id":"T1","team":"Test workspace","user_id":"U1","access_token":"xoxp-never-persist-this"}"#.utf8)
    let connection = try SlackConnection.validateAuthentication(data: data, status: 200)
    #expect(connection.workspaceID == "T1")
    #expect(connection.userID == "U1")
    #expect(connection.credentialAccount == "T1:U1")
    let metadata = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
    #expect(!metadata.contains("xoxp-"))
    #expect(!metadata.contains("access_token"))
}

@Test func slackConnectionRejectsBotMalformedAndRejectedAuthenticationWithoutLeakingPayload() {
    for token in ["", "xoxb-secret", "xapp-secret", "xoxp-secret\nInjected", "xoxp-secret with space"] {
        #expect(throws: ManagerError.self) { try SlackConnection.validateToken(token) }
    }
    for body in [#"{"ok":false,"error":"xoxp-private"}"#, #"{"ok":true,"team_id":"T1","team":"Test","user_id":"U1","bot_id":"B1"}"#, #"{"ok":true}"#, "invalid xoxp-private"] {
        do {
            _ = try SlackConnection.validateAuthentication(data: Data(body.utf8), status: 200)
            Issue.record("Expected invalid authentication")
        } catch { #expect(!String(describing: error).contains("xoxp-private")) }
    }
    #expect(throws: ManagerError.self) { try SlackConnection.validateAuthentication(data: Data(), status: 401) }
}
