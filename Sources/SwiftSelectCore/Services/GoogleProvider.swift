import Foundation
import os

/// Cloud backend for `AIProvider`, calling the Gemini API directly (billed against the user's own
/// Google account and credits, not OpenRouter's). Uses Google's OpenAI-compatible endpoint rather
/// than the native `generateContent` API, so the request/response shape matches `OpenRouterProvider`
/// and the rest of the pipeline sees no difference.
public struct GoogleProvider: AIProvider {
    private static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
    private static let timeoutSeconds: TimeInterval = 120
    private static let logger = Logger(subsystem: "SwiftSelect", category: "AISuggestion")

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// `GEMINI_API_KEY` env var wins if set, else the value saved in Settings' API Keys section.
    private static var apiKey: String? {
        APIKeyStore.resolve(envVar: "GEMINI_API_KEY", account: "GEMINI_API_KEY")
    }

    /// Every Gemini chat model accepts images, so this only confirms the id exists — the listing
    /// carries no modality field to check, unlike OpenRouter's. Ids come back as `models/<name>`,
    /// so both spellings are matched.
    public func ensureVisionCapable(model: String) async throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw AISuggestionError.provider("No Google model selected")
        }

        let request = try authorizedRequest(path: "models")
        let (data, response) = try await performRequest(request, label: "models")
        try Self.validate(response, data: data)

        let decoded = try JSONDecoder().decode(GoogleModelsResponse.self, from: data)
        let ids = (decoded.data ?? []).compactMap(\.id)
        guard ids.contains(trimmedModel) || ids.contains("models/\(trimmedModel)") else {
            throw AISuggestionError.provider(
                "Google model \"\(trimmedModel)\" was not found. Confirm the model id.")
        }
    }

    public func chat(
        model: String, systemPrompt: String, userPrompt: String, imagePayloads: [String], think: Bool
    ) async throws -> String {
        var userContent: [GoogleContentPart] = [.init(type: "text", text: userPrompt, imageURL: nil)]
        for payload in imagePayloads {
            userContent.append(
                .init(type: "image_url", text: nil, imageURL: .init(url: "data:image/jpeg;base64,\(payload)")))
        }
        let payload = GoogleChatRequest(
            model: model,
            messages: [
                GoogleMessage(role: "system", content: .text(systemPrompt)),
                GoogleMessage(role: "user", content: .parts(userContent)),
            ],
            temperature: 0.2,
            // Gemini 3 models reject "none" (thinking can't be turned off), so "minimal" is the
            // lowest effort available for the fallback retry.
            reasoningEffort: think ? nil : "minimal")

        var request = try authorizedRequest(path: "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let start = Date()
        let (data, response) = try await performRequest(request, label: "chat")
        let elapsedSeconds = Date().timeIntervalSince(start)
        Self.logger.log(
            "Google chat: model=\(model, privacy: .public) think=\(think, privacy: .public) elapsed=\(elapsedSeconds, privacy: .public)s"
        )
        try Self.validate(response, data: data)

        let decoded = try JSONDecoder().decode(GoogleChatResponse.self, from: data)
        let content =
            (decoded.choices?.first?.message?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AISuggestionError.emptyResponse }
        return content
    }

    private func authorizedRequest(path: String) throws -> URLRequest {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else {
            throw AISuggestionError.provider("GEMINI_API_KEY is not set")
        }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.timeoutSeconds
        return request
    }

    private func performRequest(_ request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AISuggestionError.timeout
        } catch {
            throw AISuggestionError.provider(
                "Could not reach the Google API (\(label)): \(error.localizedDescription)")
        }
    }

    /// Google puts the reason (bad key, quota exhausted) in the JSON body. It usually arrives as
    /// `{"error": {...}}` but sometimes wrapped in a one-element array, so both are tried.
    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = errorMessage(from: data) ?? "Google returned status \(status)"
            if message.lowercased().contains("deadline") { throw AISuggestionError.timeout }
            throw AISuggestionError.provider("Google request failed: \(message)")
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        let decoder = JSONDecoder()
        let body =
            (try? decoder.decode(GoogleErrorBody.self, from: data))
            ?? (try? decoder.decode([GoogleErrorBody].self, from: data))?.first
        guard let message = body?.error?.message, !message.isEmpty else { return nil }
        return message
    }
}

/// A system message is a plain string, a user message an array of parts; `Codable` has no union.
private enum GoogleMessageContent: Encodable {
    case text(String)
    case parts([GoogleContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .parts(let value): try container.encode(value)
        }
    }
}

private struct GoogleContentPart: Encodable {
    var type: String
    var text: String?
    var imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    struct ImageURL: Encodable {
        var url: String
    }
}

private struct GoogleMessage: Encodable {
    var role: String
    var content: GoogleMessageContent
}

private struct GoogleChatRequest: Encodable {
    var model: String
    var messages: [GoogleMessage]
    var temperature: Double
    var reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case reasoningEffort = "reasoning_effort"
    }
}

private struct GoogleChatResponse: Decodable {
    var choices: [Choice]?

    struct Choice: Decodable {
        var message: Message?
    }
    struct Message: Decodable {
        var content: String?
    }
}

private struct GoogleErrorBody: Decodable {
    var error: APIError?

    struct APIError: Decodable {
        var message: String?
    }
}

private struct GoogleModelsResponse: Decodable {
    var data: [Model]?

    struct Model: Decodable {
        var id: String?
    }
}
