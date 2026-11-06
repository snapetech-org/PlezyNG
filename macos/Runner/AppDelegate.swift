import Cocoa
import FlutterMacOS

/// Match path_provider's bundle-scoped Application Support directory. Never
/// mark the shared Application Support root, custom folders or recordings.
enum DownloadBackupPolicy {
  static func managedRoots(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> [URL] {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .flatMap { base in
        ["downloads", "artwork"].map {
          base.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent($0, isDirectory: true)
        }
      }
  }

  @discardableResult
  static func exclude(_ directory: URL, allowedRoots: [URL] = managedRoots()) throws -> Bool {
    guard directory.isFileURL else { return false }
    let target = directory.standardizedFileURL
    guard allowedRoots.contains(where: { $0.standardizedFileURL.path == target.path }) else { return false }
    // Reject a redirected managed root. Resolve system aliases in the parent
    // before comparing the actual root (for example /var -> /private/var).
    let expected = target.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(target.lastPathComponent, isDirectory: true)
    guard expected.path == target.resolvingSymlinksInPath().path else { return false }
    let attributes = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { return false }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var writableURL = target
    try writableURL.setResourceValues(values)
    return true
  }

  static func refreshExistingRoots() {
    for root in managedRoots() where FileManager.default.fileExists(atPath: root.path) {
      do {
        try exclude(root)
      } catch {
        NSLog("Could not update managed download backup policy: %@", String(describing: error))
      }
    }
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
