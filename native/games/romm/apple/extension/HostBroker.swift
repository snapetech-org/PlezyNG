// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin
import ExtensionFoundation
import XPC

private typealias RommLaunch = @convention(c) (
  UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
  UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32
private typealias RommStop = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias RommDead = @convention(c) (UnsafeMutableRawPointer?) -> Int32

@_silgen_name("plezy_retro_apple_initialize")
private func initializeRommApple(_ launch: RommLaunch, _ stop: RommStop,
                                 _ dead: RommDead, _ release: RommStop)

enum RommAppleBroker {
  static func install() {
    if #available(iOS 26.0, *) {
      initializeRommApple(rommAppleLaunch, rommAppleStop, rommAppleDead, rommAppleRelease)
    }
  }
}

@available(iOS 26.0, *)
extension AppExtensionPoint {
  @Definition static var rommWorker: AppExtensionPoint {
    Name("RommWorker")
    EnhancedSecurity()
    // The default application scope excludes third-party extensions.
  }
}

@available(iOS 26.0, *)
private final class RommExtensionLease: @unchecked Sendable {
  private let lock = NSLock()
  private let finished = DispatchSemaphore(value: 0)
  private var process: AppExtensionProcess?
  private var session: XPCSession?
  private var descriptor: Int32 = -1
  private var cancelled = false
  private var exited = false

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  var dead: Bool { locked { exited } }

  func stop() {
    let state: (XPCSession?, Int32) = locked {
      cancelled = true
      let fd = descriptor
      descriptor = -1
      return (session, fd)
    }
    if state.1 >= 0 { Darwin.close(state.1) }
    if let session = state.0 {
      var message = XPCDictionary()
      message["operation"] = "stop"
      try? session.send(message: message)
    }
    // invalidate() only disconnects. Only onInterruption proves process exit.
  }

  private func didExit() {
    let fd = locked {
      exited = true
      let fd = descriptor
      descriptor = -1
      session = nil
      process = nil
      return fd
    }
    if fd >= 0 { Darwin.close(fd) }
    finished.signal()
  }

  private static func input(_ path: String) throws -> Int32 {
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size > 0, info.st_size <= 256 * 1024 * 1024 else {
      Darwin.close(fd)
      throw CocoaError(.fileReadCorruptFile)
    }
    return fd
  }

  private static func bootstrap(core: String, rom: String, system: String, pipe: Int32) throws -> XPCDictionary {
    let name = URL(fileURLWithPath: core).lastPathComponent
    guard ["gambatte_libretro", "mgba_libretro", "fceumm_libretro"].contains(name) else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    var inputs: [(String, Int32)] = []
    defer { inputs.forEach { Darwin.close($0.1) } }
    var bytes: Int64 = 0
    func add(_ virtual: String, _ path: String) throws {
      guard inputs.count < 65, virtual.utf8.count <= 4096 else { throw CocoaError(.fileReadTooLarge) }
      let fd = try input(path)
      inputs.append((virtual, fd))
      var info = stat()
      guard fstat(fd, &info) == 0 else { throw CocoaError(.fileReadCorruptFile) }
      bytes += info.st_size
      guard bytes <= 384 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
    }
    if !rom.isEmpty {
      try add("/rom/" + URL(fileURLWithPath: rom).lastPathComponent, rom)
      let base = URL(fileURLWithPath: system, isDirectory: true)
      let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
      guard let enumeration = FileManager.default.enumerator(at: base,
          includingPropertiesForKeys: Array(keys), options: []) else {
        throw CocoaError(.fileReadNoPermission)
      }
      var visited = 0
      for case let file as URL in enumeration {
        visited += 1
        guard visited <= 256 else { throw CocoaError(.fileReadTooLarge) }
        let values = try file.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        if values.isRegularFile == true {
          let prefix = base.path + "/"
          guard file.path.hasPrefix(prefix) else { throw CocoaError(.fileReadNoPermission) }
          try add("/system/" + file.path.dropFirst(prefix.count), file.path)
        }
      }
    }
    var message = XPCDictionary()
    message["operation"] = "start"
    message["core"] = name
    message["count"] = Int64(inputs.count)
    message.withUnsafeUnderlyingDictionary { dictionary in
      xpc_dictionary_set_fd(dictionary, "pipe", pipe)
      for (index, input) in inputs.enumerated() {
        xpc_dictionary_set_string(dictionary, "name_" + String(index), input.0)
        xpc_dictionary_set_fd(dictionary, "file_" + String(index), input.1)
      }
    }
    return message
  }

  func start(core: String, rom: String, system: String) -> Int32 {
    guard !Thread.isMainThread else {
      locked { exited = true }
      return -1
    }
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      locked { exited = true }
      return -1
    }
    for fd in pair {
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      var noSignal: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }
    let message: XPCDictionary
    do {
      message = try Self.bootstrap(core: core, rom: rom, system: system, pipe: pair[1])
    } catch {
      pair.forEach { Darwin.close($0) }
      locked { exited = true }
      return -1
    }
    Darwin.close(pair[1])
    locked { descriptor = pair[0] }
    Task {
      var launched = false
      do {
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .rommWorker)
        guard let identity = monitor.identities.first(where: {
          $0.bundleIdentifier == "org.snapetech.pleazyng.RommWorker"
        }) else { throw CocoaError(.executableNotLoadable) }
        let process = try await AppExtensionProcess(configuration: .init(
          appExtensionIdentity: identity, onInterruption: { [self] in didExit() }))
        launched = true
        let attached = locked {
          guard !exited else { return false }
          self.process = process
          return true
        }
        guard attached else {
          process.invalidate()
          finished.signal()
          return
        }
        let session = try process.makeXPCSession()
        session.setTargetQueue(DispatchQueue.global(qos: .userInitiated))
        try session.activate()
        let shouldStop = locked {
          guard !exited else { return true }
          self.session = session
          return cancelled
        }
        if shouldStop {
          stop()
          return
        }
        session.send(message: message) { [self] result in
          switch result {
          case .success(let reply):
            let accepted: Int64? = reply["accepted"]
            if accepted != 1 { stop() }
          case .failure:
            stop()
          }
          finished.signal()
        }
      } catch {
        stop()
        if !launched { locked { exited = true } }
        finished.signal()
      }
    }
    if finished.wait(timeout: .now() + 10) == .timedOut {
      stop()
      return -1
    }
    return locked {
      guard !cancelled && !exited, descriptor >= 0 else { return -1 }
      let fd = descriptor
      descriptor = -1
      return fd
    }
  }
}

@available(iOS 26.0, *)
private func rommAppleLaunch(_ core: UnsafePointer<CChar>?, _ rom: UnsafePointer<CChar>?,
                            _ system: UnsafePointer<CChar>?,
                            _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
  guard let core, let rom, let system, let out,
        let a = String(validatingUTF8: core), let b = String(validatingUTF8: rom),
        let c = String(validatingUTF8: system), a.utf8.count <= 32768,
        b.utf8.count <= 32768, c.utf8.count <= 32768 else { return -1 }
  let lease = RommExtensionLease()
  out.pointee = Unmanaged.passRetained(lease).toOpaque()
  return lease.start(core: a, rom: b, system: c)
}

@available(iOS 26.0, *)
private func rommAppleStop(_ pointer: UnsafeMutableRawPointer?) {
  guard let pointer else { return }
  Unmanaged<RommExtensionLease>.fromOpaque(pointer).takeUnretainedValue().stop()
}

@available(iOS 26.0, *)
private func rommAppleDead(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
  guard let pointer else { return 1 }
  return Unmanaged<RommExtensionLease>.fromOpaque(pointer).takeUnretainedValue().dead ? 1 : 0
}

@available(iOS 26.0, *)
private func rommAppleRelease(_ pointer: UnsafeMutableRawPointer?) {
  guard let pointer else { return }
  Unmanaged<RommExtensionLease>.fromOpaque(pointer).release()
}
