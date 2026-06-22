import XCTest
@testable import JiraAPI

final class APITokenAuthTests: XCTestCase {
    func testBasicAuthHeader() async throws {
        let auth = APITokenAuth(email: "user@example.com", token: "abc123")
        var request = URLRequest(url: URL(string: "https://example.atlassian.net")!)
        try await auth.authorize(&request)
        let header = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertNotNil(header)
        XCTAssertTrue(header!.hasPrefix("Basic "))
        let raw = header!.replacingOccurrences(of: "Basic ", with: "")
        let decoded = String(data: Data(base64Encoded: raw)!, encoding: .utf8)
        XCTAssertEqual(decoded, "user@example.com:abc123")
    }
}

final class PATAuthTests: XCTestCase {
    func testBearer() async throws {
        let auth = PATAuth(token: "tok")
        var request = URLRequest(url: URL(string: "https://example.com")!)
        try await auth.authorize(&request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }
}

final class NoneAuthTests: XCTestCase {
    func testDoesNotSetAuthorizationHeader() async throws {
        let auth = NoneAuth()
        var request = URLRequest(url: URL(string: "https://example.atlassian.net")!)
        try await auth.authorize(&request)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPreservesExistingHeaders() async throws {
        let auth = NoneAuth()
        var request = URLRequest(url: URL(string: "https://example.atlassian.net")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await auth.authorize(&request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
