import Foundation

/// Stable boundary between the app and its bundled optional-OS runtime.
/// The interface keeps the app's existing deployment floor. The implementation
/// is included in every Apple build and loaded on a compatible OS at runtime.
open class DVRuntimeBackend: NSObject {
  /// A missing or unusable optional runtime leaves the compatibility player
  /// available. Close a failed candidate before the caller creates that player.
  public static func preparedForPlayback(make: () -> DVRuntimeBackend?) -> DVRuntimeBackend? {
    guard let candidate = make() else { return nil }
    guard candidate.prepare() else {
      candidate.close()
      return nil
    }
    return candidate
  }

  public var onProperty: ((String, Any?, Int64?) -> Void)?
  public var onEvent: ((String, [String: Any]?, Int64?) -> Void)?

  open func prepare() -> Bool { false }
  open func attach(to parent: NSObject) {}
  open func setFrame(_ frame: CGRect) {}
  open func setVisible(_ visible: Bool) {}
  open func setProperty(_ name: String, value: String) {}
  open func property(_ name: String) -> String? { nil }
  open func observe(_ name: String) {}
  open func command(_ arguments: [String], completion: @escaping (Int64?, NSError?) -> Void) {
    completion(nil, NSError(domain: "PlezyNGDVRuntime", code: 1))
  }
  open func close() {}
}
