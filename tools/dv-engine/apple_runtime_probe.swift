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
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    parent.wantsLayer = true
    let controls = CALayer()
    parent.layer?.addSublayer(controls)
    backend.attach(to: parent)
    guard let surface = parent.subviews.first, let layer = surface.layer else {
      fatalError("Experimental video view did not attach")
    }
    precondition(layer.zPosition < controls.zPosition)
    precondition(parent.layer?.sublayers?.first === layer)
    backend.setVisible(false)
    precondition(surface.isHidden)
    backend.close()
    precondition(parent.subviews.isEmpty)
    backend.close()
    print("PASS: bundled runtime loads, shares the app API, initializes dual-layer support, and closes")
  }
}
