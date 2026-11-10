// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin
import ExtensionFoundation
import XPC

@_silgen_name("plezy_retro_apple_configure")
private func configureWorker(_ core: UnsafePointer<CChar>, _ names: UnsafePointer<UnsafePointer<CChar>?>?,
                             _ files: UnsafePointer<Int32>?, _ count: Int32) -> Int32
@_silgen_name("plezy_retro_apple_run")
private func runWorker(_ descriptor: Int32)

private final class WorkerHandler: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false

  init() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [self] in
      lock.lock()
      let waiting = !started
      lock.unlock()
      if waiting { _exit(2) }
    }
  }

  func receive(_ message: XPCDictionary) -> XPCDictionary? {
    let operation: String? = message["operation"]
    if operation == "stop" { _exit(0) }
    lock.lock()
    let duplicate = started
    started = true
    lock.unlock()
    guard !duplicate, operation == "start",
          let name: String = message["core"],
          ["gambatte_libretro", "mgba_libretro", "fceumm_libretro"].contains(name),
          let count: Int64 = message["count"], count >= 0, count <= 65,
          Bundle.main.bundleIdentifier == "org.snapetech.pleazyng.RommWorker",
          let frameworks = Bundle.main.privateFrameworksURL else { _exit(2) }
    let path = frameworks.appendingPathComponent(name + ".framework").appendingPathComponent(name).path
    var names: [UnsafePointer<CChar>?] = []
    var files: [Int32] = []
    var pipe: Int32 = -1
    message.withUnsafeUnderlyingDictionary { dictionary in
      pipe = xpc_dictionary_dup_fd(dictionary, "pipe")
      for index in 0..<Int(count) {
        guard let value = xpc_dictionary_get_string(dictionary, "name_" + String(index)),
              strlen(value) <= 4096 else { _exit(2) }
        names.append(UnsafePointer(strdup(value)))
        files.append(xpc_dictionary_dup_fd(dictionary, "file_" + String(index)))
      }
    }
    defer { names.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    guard pipe >= 0, files.allSatisfy({ $0 >= 0 }) else { _exit(2) }
    var type: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(pipe, SOL_SOCKET, SO_TYPE, &type, &length) == 0, type == SOCK_STREAM else { _exit(2) }
    let accepted = path.withCString { core in
      names.withUnsafeBufferPointer { names in
        files.withUnsafeBufferPointer { files in
          configureWorker(core, names.baseAddress, files.baseAddress, Int32(count))
        }
      }
    }
    guard accepted == 1 else { _exit(2) }
    DispatchQueue.global(qos: .userInitiated).async { runWorker(pipe) }
    let reply = XPCDictionary()
    reply["accepted"] = Int64(1)
    return reply
  }
}

@main
struct RommWorkerExtension: AppExtension {
  @AppExtensionPoint.Bind var boundExtensionPoint: AppExtensionPoint {
    AppExtensionPoint.Identifier(host: "org.snapetech.pleazyng", name: "RommWorker")
  }

  var configuration: some AppExtensionConfiguration {
    let handler = WorkerHandler()
    return ConnectionHandler(onSessionRequest: { request in
      request.accept(incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
        handler.receive(message)
      }, cancellationHandler: { _ in _exit(0) })
    })
  }
}
