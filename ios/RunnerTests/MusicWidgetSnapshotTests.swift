import Foundation
import XCTest

#if !os(Linux)
  @testable import Pleazyng
#endif

final class MusicWidgetSnapshotTests: XCTestCase {
  private let scope = "0ef608a2-1000-4000-8000-000000000001"
  private let date = Date(timeIntervalSince1970: 1_800_000_000)
  private var message: [String: Any] {
    [
      "scope": scope, "revision": 4, "playing": true, "title": "Track", "artist": "Artist",
      "labels": ["play": "Play", "pause": "Pause", "previous": "Previous", "next": "Next"],
    ]
  }

  func testPortablePresentationDropsCredentialsAndBoundsMetadata() throws {
    var input = message
    input["streamUrl"] = "https://server.test/audio?token=secret"
    input["token"] = "secret"
    input["artist"] = String(repeating: "é", count: 600)
    input["labels"] = ["play": "Play", "pause": "Pause", "previous": "Previous", "next": "Next", "token": "secret"]
    let snapshot = try XCTUnwrap(MusicWidgetSnapshot(message: input, now: date))
    XCTAssertEqual(snapshot.content.artist.count, 256)
    XCTAssertEqual(snapshot.content.labels.count, 4)
    let encoded = try JSONEncoder().encode(snapshot)
    let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    XCTAssertFalse(json.contains("secret"))
    XCTAssertEqual(try JSONDecoder().decode(MusicWidgetSnapshot.self, from: encoded), snapshot)
  }

  func testRejectsMissingAndMalformedPresentation() {
    for key in ["title", "scope", "revision", "playing", "labels"] {
      var input = message
      input.removeValue(forKey: key)
      XCTAssertNil(MusicWidgetSnapshot(message: input, now: date))
    }
    var input = message
    input["scope"] = "server-session"
    XCTAssertNil(MusicWidgetSnapshot(message: input, now: date))
    input = message
    input["revision"] = -1
    XCTAssertNil(MusicWidgetSnapshot(message: input, now: date))
  }

  func testTransportRejectsStaleExpiredAndForeignSnapshots() throws {
    let snapshot = try XCTUnwrap(MusicWidgetSnapshot(message: message, now: date))
    XCTAssertTrue(snapshot.authorizes("next", scope: scope, revision: 4, now: date))
    XCTAssertFalse(snapshot.authorizes("stop", scope: scope, revision: 4, now: date))
    XCTAssertFalse(snapshot.authorizes("next", scope: UUID().uuidString, revision: 4, now: date))
    XCTAssertFalse(snapshot.authorizes("next", scope: scope, revision: 5, now: date))
    XCTAssertFalse(snapshot.authorizes("next", scope: scope, revision: 4, now: snapshot.expiresAt))
    XCTAssertFalse(snapshot.authorizes("next", scope: scope, revision: 4, now: date.addingTimeInterval(-1)))
  }
}

#if os(Linux)
  @main
  enum PortableMusicWidgetTests {
    static func main() {
      XCTMain([
        testCase([
          (
            "testPortablePresentationDropsCredentialsAndBoundsMetadata",
            MusicWidgetSnapshotTests.testPortablePresentationDropsCredentialsAndBoundsMetadata
          ),
          (
            "testRejectsMissingAndMalformedPresentation",
            MusicWidgetSnapshotTests.testRejectsMissingAndMalformedPresentation
          ),
          (
            "testTransportRejectsStaleExpiredAndForeignSnapshots",
            MusicWidgetSnapshotTests.testTransportRejectsStaleExpiredAndForeignSnapshots
          ),
        ])
      ])
    }
  }
#endif
