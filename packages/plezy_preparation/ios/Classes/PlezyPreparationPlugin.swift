import Flutter
import UIKit
import BackgroundTasks

public class PlezyPreparationPlugin: NSObject, FlutterPlugin {
    private static let identifier = "org.plezy.preparation"
    private static let subtitleIdentifier = "org.plezy.subtitle.jobs"
    private static var registrant: ((FlutterPluginRegistry) -> Void)?
    private static var registered = false
    public static func registerBackgroundTasks(_ callback: @escaping (FlutterPluginRegistry) -> Void) {
        registrant = callback
        guard !registered else { return }
        registered = true
        for name in [identifier, subtitleIdentifier] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: name, using: .main) { task in
                guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                run(processing, subtitles: name == subtitleIdentifier)
            }
        }
    }
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PlezyPreparationPlugin()
        let channel = FlutterMethodChannel(name: "org.plezy/preparation", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let subtitles = (call.arguments as? [String: Any])?["subtitles"] as? Bool == true
        switch call.method {
        case "schedule":
            do { try Self.schedule(subtitles: subtitles); result(nil) }
            catch { result(FlutterError(code: "scheduler_unavailable", message: nil, details: nil)) }
        case "cancel":
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: subtitles ? Self.subtitleIdentifier : Self.identifier)
            result(nil)
        case "subtitlesMayRun": result(UIApplication.shared.applicationState == .background)
        default: result(FlutterMethodNotImplemented)
        }
    }
    private static func schedule(subtitles: Bool = false) throws {
        let request = BGProcessingTaskRequest(identifier: subtitles ? subtitleIdentifier : identifier)
        request.requiresNetworkConnectivity = !subtitles
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
        do { try BGTaskScheduler.shared.submit(request) }
        catch let error as BGTaskScheduler.Error where error.code == .tooManyPendingTaskRequests { /* already queued */ }
    }
    private static func run(_ task: BGProcessingTask, subtitles: Bool) {
        // Re-enqueue before starting so expiration/process death cannot strand work.
        try? schedule(subtitles: subtitles)
        let engine = FlutterEngine(name: subtitles ? "plezy.subtitle.jobs" : "plezy.preparation", project: nil, allowHeadlessExecution: true)
        var finished = false
        let channel = FlutterMethodChannel(name: subtitles ? "org.plezy/subtitle.worker" : "org.plezy/preparation.worker", binaryMessenger: engine.binaryMessenger)
        func finish(_ success: Bool) {
            guard !finished else { return }
            finished = true
            channel.setMethodCallHandler(nil)
            task.setTaskCompleted(success: success)
            engine.destroyContext()
        }
        task.expirationHandler = { DispatchQueue.main.async {
            if subtitles { channel.invokeMethod("stop", arguments: nil) }
            finish(false)
        } }
        channel.setMethodCallHandler { call, result in
            guard call.method == "complete" else { result(FlutterMethodNotImplemented); return }
            result(nil)
            DispatchQueue.main.async { finish(call.arguments as? Bool == true) }
        }
        guard engine.run(withEntrypoint: subtitles ? "subtitleBackgroundEntrypoint" : "remotePreparationEntrypoint", libraryURI:
            subtitles ? "package:plezy/services/subtitle_background_worker.dart" :
            "package:plezy/services/remote_streams/remote_preparation_worker.dart") else { finish(false); return }
        registrant?(engine)
    }
}
