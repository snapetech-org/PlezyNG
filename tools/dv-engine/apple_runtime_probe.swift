import AppKit
import Foundation
import PlezyNGDVRuntimeAPI

@main struct AppleRuntimeProbe {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let path = CommandLine.arguments[1]
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      fatalError(String(cString: dlerror()))
    }
    typealias Version = @convention(c) () -> Int32
    typealias Create = @convention(c) () -> UnsafeMutableRawPointer
    let version = unsafeBitCast(dlsym(handle, "PlezyNGDVRuntimeVersion"), to: Version.self)
    precondition(version() == 1)
    let create = unsafeBitCast(dlsym(handle, "PlezyNGCreateDVBackend"), to: Create.self)
    let object = Unmanaged<AnyObject>.fromOpaque(create()).takeRetainedValue()
    guard let backend = object as? DVRuntimeBackend else { fatalError("API class identity mismatch") }
    precondition(backend.prepare(), "Bundled dual-layer runtime did not initialize")
    precondition(backend.property("plezyng-dv-engine") == "plezyng-apple-dv-runtime-v1")
    backend.close()
    backend.close()
    print("PASS: bundled runtime loads, shares the app API, initializes dual-layer support, and closes")
  }
}
