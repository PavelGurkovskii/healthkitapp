import Foundation

struct StepSampleDTO: Codable, Hashable {
  let uuid: String
  let startDate: String
  let endDate: String
  let count: Double
  let sourceBundleId: String?
}
