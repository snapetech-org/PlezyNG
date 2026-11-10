import XCTest
@testable import PlezyNGDVRuntimeAPI

private final class RuntimeCandidate: DVRuntimeBackend {
  var available = true
  var preparations = 0
  var closes = 0

  override func prepare() -> Bool {
    preparations += 1
    return available
  }

  override func close() { closes += 1 }
}

final class RuntimeFallbackTests: XCTestCase {
  func testAbsentRuntimeLeavesCompatibilityPlaybackAvailable() {
    XCTAssertNil(DVRuntimeBackend.preparedForPlayback(make: { nil }))
  }

  func testRejectedRuntimeIsClosedBeforeCompatibilityPlayback() {
    let candidate = RuntimeCandidate()
    candidate.available = false
    XCTAssertNil(DVRuntimeBackend.preparedForPlayback(make: { candidate }))
    XCTAssertEqual(candidate.preparations, 1)
    XCTAssertEqual(candidate.closes, 1)
  }

  func testPreparedRuntimeIsRetainedForPlayback() {
    let candidate = RuntimeCandidate()
    XCTAssertTrue(DVRuntimeBackend.preparedForPlayback(make: { candidate }) === candidate)
    XCTAssertEqual(candidate.preparations, 1)
    XCTAssertEqual(candidate.closes, 0)
  }
}
