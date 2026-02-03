import Foundation

struct OutboxChunk: Codable, Hashable {
  var chunkId: String
  var createdAt: String
  var attemptCount: Int
  var samples: [StepSampleDTO]
}
