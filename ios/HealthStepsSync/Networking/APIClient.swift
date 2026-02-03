import Foundation

final class APIClient {
  struct Config {
    var baseURL: URL
  }

  struct UploadChunkResponse: Decodable {
    let ok: Bool
    let duplicate: Bool?
    let written: Int?
    let skippedSeenSamples: Int?
    let receivedSamples: Int?
    let tookMs: Int?
  }

  private struct UploadChunkRequest: Encodable {
    let chunkId: String
    let samples: [StepSampleDTO]
  }

  enum APIError: Error {
    case invalidResponse
    case httpError(statusCode: Int)
  }

  private let config: Config
  private let session: URLSession

  init(config: Config, session: URLSession = .shared) {
    self.config = config
    self.session = session
  }

  func ping() async throws {
    var request = URLRequest(url: config.baseURL.appendingPathComponent("ping"))
    request.httpMethod = "GET"

    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else { throw APIError.httpError(statusCode: http.statusCode) }
  }

  func upload(chunk: OutboxChunk) async throws -> UploadChunkResponse {
    var request = URLRequest(url: config.baseURL.appendingPathComponent("steps/chunk"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let payload = UploadChunkRequest(chunkId: chunk.chunkId, samples: chunk.samples)
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else { throw APIError.httpError(statusCode: http.statusCode) }

    if let decoded = try? JSONDecoder().decode(UploadChunkResponse.self, from: data) {
      return decoded
    }

    return UploadChunkResponse(ok: true, duplicate: nil, written: nil, skippedSeenSamples: nil, receivedSamples: nil, tookMs: nil)
  }
}
