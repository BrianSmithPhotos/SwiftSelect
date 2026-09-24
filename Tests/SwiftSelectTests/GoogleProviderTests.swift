import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

/// Exercises `GoogleProvider` against a mocked `URLSession` — no network or real key needed.
/// Mirrors `OpenRouterProviderTests`, including pointing `APIKeyStore` at a throwaway service so a
/// real saved key can't leak into the missing-key test.
final class GoogleProviderTests: XCTestCase {
    private var realService: String!

    override func setUp() {
        super.setUp()
        realService = APIKeyStore.service
        APIKeyStore.service = "photos.briansmith.macphotomaster.tests"
        setenv("GEMINI_API_KEY", "test-key", 1)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        unsetenv("GEMINI_API_KEY")
        APIKeyStore.service = realService
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func jsonResponse(for request: URLRequest, statusCode: Int = 200, body: String) -> (
        HTTPURLResponse, Data
    ) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, body.data(using: .utf8)!)
    }

    private func chat(provider: GoogleProvider, think: Bool = true, images: [String] = []) async throws
        -> String
    {
        try await provider.chat(
            model: "gemini-3.5-flash-lite", systemPrompt: "sys", userPrompt: "user",
            imagePayloads: images, think: think)
    }

    // MARK: - chat

    func testChatPostsToOpenAICompatibleEndpointWithBearerKey() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return self.jsonResponse(
                for: request, body: #"{"choices": [{"message": {"content": "hello"}}]}"#)
        }

        let content = try await chat(provider: GoogleProvider(session: makeSession()))

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(content, "hello")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testChatSendsImageAsDataURLAndOmitsReasoningWhenThinking() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            return self.jsonResponse(
                for: request, body: #"{"choices": [{"message": {"content": "hello"}}]}"#)
        }

        _ = try await chat(provider: GoogleProvider(session: makeSession()), images: ["abc123"])

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gemini-3.5-flash-lite")
        XCTAssertNil(json["reasoning_effort"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "sys")
        let userParts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let imageURL = try XCTUnwrap(userParts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,abc123")
    }

    func testChatRequestsMinimalReasoningWhenThinkIsFalse() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            return self.jsonResponse(
                for: request, body: #"{"choices": [{"message": {"content": "hello"}}]}"#)
        }

        _ = try await chat(provider: GoogleProvider(session: makeSession()), think: false)

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["reasoning_effort"] as? String, "minimal")
    }

    func testChatThrowsEmptyResponseWhenContentIsBlank() async {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(for: request, body: #"{"choices": [{"message": {"content": "  "}}]}"#)
        }

        do {
            _ = try await chat(provider: GoogleProvider(session: makeSession()))
            XCTFail("Expected an emptyResponse error")
        } catch let error as AISuggestionError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testChatThrowsProviderErrorWhenAPIKeyMissing() async {
        unsetenv("GEMINI_API_KEY")

        do {
            _ = try await chat(provider: GoogleProvider(session: makeSession()))
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            XCTAssertEqual(error, .provider("GEMINI_API_KEY is not set"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testChatSurfacesErrorMessageFromArrayWrappedBody() async {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(
                for: request, statusCode: 400,
                body: #"[{"error": {"code": 400, "message": "API key not valid"}}]"#)
        }

        do {
            _ = try await chat(provider: GoogleProvider(session: makeSession()))
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider(let message) = error else {
                return XCTFail("Expected .provider, got \(error)")
            }
            XCTAssertTrue(message.contains("API key not valid"), "unexpected message: \(message)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - ensureVisionCapable

    func testEnsureVisionCapableAcceptsModelsPrefixedID() async throws {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(
                for: request, body: #"{"data": [{"id": "models/gemini-3.5-flash-lite"}]}"#)
        }

        try await GoogleProvider(session: makeSession()).ensureVisionCapable(model: "gemini-3.5-flash-lite")
    }

    func testEnsureVisionCapableThrowsWhenModelNotFound() async {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(for: request, body: #"{"data": [{"id": "models/gemini-2.5-flash"}]}"#)
        }

        do {
            try await GoogleProvider(session: makeSession()).ensureVisionCapable(model: "gemini-9-nope")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider = error else { return XCTFail("Expected .provider, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // `URLSession` delivers the body to a custom `URLProtocol` via `httpBodyStream` rather
        // than `httpBody`, even though the original `URLRequest` was built with `httpBody` set —
        // reconstitute it so the handler can inspect the JSON payload the same way either way.
        var effectiveRequest = request
        if effectiveRequest.httpBody == nil, let stream = request.httpBodyStream {
            effectiveRequest.httpBody = Self.readAllData(from: stream)
        }
        do {
            let (response, data) = try handler(effectiveRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAllData(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}
