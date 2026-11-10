import CoreNFC
import Flutter
import Foundation

final class MusicNfcBridge: NSObject, NFCTagReaderSessionDelegate {
  private enum Operation {
    case read
    case write(NFCNDEFMessage)
  }

  private struct Scan {
    let reader: NFCTagReaderSession
    let operation: Operation
    let result: FlutterResult
  }

  private var channel: FlutterMethodChannel?
  private var scan: Scan?
  private var processing = false

  private var available: Bool {
    Bundle.main.object(forInfoDictionaryKey: "PleazyngMusicNFCEnabled") as? String == "YES"
      && NFCTagReaderSession.readingAvailable
  }

  func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.pleazyng/music_nfc", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  private static func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  static func musicURL(_ text: String) -> URL? {
    guard text.utf8.count <= 2048,
      let components = URLComponents(string: text),
      components.scheme == "pleazyng", components.host == "play",
      components.path.isEmpty, components.fragment == nil,
      components.user == nil, components.password == nil, components.port == nil,
      let items = components.queryItems, items.count == 2,
      Set(items.map(\.name)) == Set(["server", "id"]),
      items.allSatisfy({ !($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { return nil }
    return components.url
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "available", "readAvailable":
      result(available)
    case "cancel":
      if let reader = scan?.reader { complete(reader, value: Self.error("cancelled")) }
      result(nil)
    case "read":
      begin(.read, prompt: arguments?["prompt"] as? String, result: result)
    case "write":
      guard let text = arguments?["uri"] as? String,
        let url = Self.musicURL(text),
        let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url)
      else {
        result(Self.error("invalid_link"))
        return
      }
      begin(.write(NFCNDEFMessage(records: [payload])), prompt: arguments?["prompt"] as? String, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func begin(_ operation: Operation, prompt: String?, result: @escaping FlutterResult) {
    guard available else {
      result(Self.error("unavailable"))
      return
    }
    guard scan == nil else {
      result(Self.error("busy"))
      return
    }
    guard let reader = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: .main) else {
      result(Self.error("unavailable"))
      return
    }
    scan = Scan(reader: reader, operation: operation, result: result)
    processing = false
    if let prompt, !prompt.isEmpty { reader.alertMessage = prompt }
    reader.begin()
  }

  private func complete(_ reader: NFCTagReaderSession, value: Any?, invalidate: Bool = true) {
    guard let scan, scan.reader === reader else { return }
    self.scan = nil
    processing = false
    if invalidate { reader.invalidate() }
    scan.result(value)
  }

  func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

  func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    let cancelled = (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorUserCanceled
    complete(session, value: Self.error(cancelled ? "cancelled" : "scan_failed"), invalidate: false)
  }

  func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard scan?.reader === session, !processing else { return }
    guard tags.count == 1, let detected = tags.first else {
      session.restartPolling()
      return
    }
    let tag: NFCNDEFTag
    switch detected {
    case .miFare(let value): tag = value
    case .iso7816(let value): tag = value
    case .iso15693(let value): tag = value
    case .feliCa(let value): tag = value
    @unknown default:
      complete(session, value: Self.error("unsupported_tag"))
      return
    }
    processing = true
    session.connect(to: detected) { [weak self] error in
      guard let self, self.scan?.reader === session else { return }
      guard error == nil else {
        self.complete(session, value: Self.error("connect_failed"))
        return
      }
      self.access(tag, reader: session)
    }
  }

  private func access(_ tag: NFCNDEFTag, reader: NFCTagReaderSession) {
    tag.queryNDEFStatus { [weak self] status, capacity, error in
      guard let self, let scan = self.scan, scan.reader === reader else { return }
      guard error == nil, status != .notSupported else {
        self.complete(reader, value: Self.error("unsupported_tag"))
        return
      }
      switch scan.operation {
      case .read:
        tag.readNDEF { [weak self] message, error in
          let url = message?.records.lazy.compactMap { record in
            record.wellKnownTypeURIPayload().flatMap { Self.musicURL($0.absoluteString) }
          }.first
          guard error == nil, let url else {
            self?.complete(reader, value: Self.error("invalid_link"))
            return
          }
          self?.complete(reader, value: url.absoluteString)
        }
      case .write(let message):
        guard status == .readWrite, message.length <= capacity else {
          self.complete(reader, value: Self.error(status == .readWrite ? "capacity" : "read_only"))
          return
        }
        tag.writeNDEF(message) { [weak self] error in
          let value: Any = error == nil ? true : Self.error("write_failed") as Any
          self?.complete(reader, value: value)
        }
      }
    }
  }
}
