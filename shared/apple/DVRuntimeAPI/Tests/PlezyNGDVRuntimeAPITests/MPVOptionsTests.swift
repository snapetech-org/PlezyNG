import XCTest
@testable import PlezyNGDVRuntimeAPI

final class MPVOptionsTests: XCTestCase {
  func testPlexHeaderByteQuotingAndCommasSurvive() throws {
    let headers = "X-Plex-Device: Mac17\\,9,X-Plex-Client-Identifier: façade=client"
    let input = "http-header-fields=%\(headers.utf8.count)%\(headers),start=123.5"
    let decoded = try MPVOptions.parse(input)
    let actual = try MPVOptions.headers(decoded["http-header-fields"]!)
    XCTAssertEqual(actual["X-Plex-Device"], "Mac17,9")
    XCTAssertEqual(actual["X-Plex-Client-Identifier"], "façade=client")
    XCTAssertEqual(decoded["start"], "123.5")
  }

  func testEmptyMediaHeaderListIsAnExplicitClear() throws {
    let decoded = try MPVOptions.parse("http-header-fields-clr=")
    XCTAssertEqual(decoded["http-header-fields-clr"], "")
    XCTAssertNil(decoded["http-header-fields"])
    XCTAssertEqual(try MPVOptions.headers(""), [:])
  }

  func testChangeListItemsDoNotSplitEmbeddedCommas() throws {
    let decoded = try MPVOptions.headers(fromItems: ["User-Agent: Example/1,2", "X-Value: end\\ "])
    XCTAssertEqual(decoded["User-Agent"], "Example/1,2")
    XCTAssertEqual(decoded["X-Value"], "end\\")
  }

  func testMalformedLengthsAndHeaderInjectionAreRejected() {
    for input in ["header=%999%x", "header=%-1%x", "header=%1%é", "header=%1%ab", "missing-separator"] {
      XCTAssertThrowsError(try MPVOptions.parse(input))
    }
    for input in ["X-Test: value\r\nInjected: value", "X: value\r", "X: value\n", "Bad Name: value", "X: value\0"] {
      XCTAssertThrowsError(try MPVOptions.headers(input), input.debugDescription)
      XCTAssertThrowsError(try MPVOptions.headers(fromItems: [input]), input.debugDescription)
    }
  }
}
