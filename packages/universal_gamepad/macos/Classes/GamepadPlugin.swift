import FlutterMacOS

/// Entry point for the gamepad macOS plugin.
///
/// Registers a `MethodChannel` (`dev.universal_gamepad/methods`) and an
/// `EventChannel` (`dev.universal_gamepad/events`) with the Flutter engine.
/// The EventChannel streams gamepad connection, button, and axis events.
/// The MethodChannel supports `listGamepads` and `dispose`.
public class GamepadPlugin: NSObject, FlutterPlugin {

    private let controllerManager: GCControllerManager
    private let streamHandler: GamepadStreamHandler

    init(controllerManager: GCControllerManager, streamHandler: GamepadStreamHandler) {
        self.controllerManager = controllerManager
        self.streamHandler = streamHandler
        super.init()
    }

    // MARK: - FlutterPlugin registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let streamHandler = GamepadStreamHandler()
        let controllerManager = GCControllerManager(streamHandler: streamHandler)

        // Method channel
        let methodChannel = FlutterMethodChannel(
            name: "dev.universal_gamepad/methods",
            binaryMessenger: registrar.messenger
        )

        // Event channel
        let eventChannel = FlutterEventChannel(
            name: "dev.universal_gamepad/events",
            binaryMessenger: registrar.messenger
        )
        eventChannel.setStreamHandler(streamHandler)

        let instance = GamepadPlugin(
            controllerManager: controllerManager,
            streamHandler: streamHandler
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        // Start observing controllers immediately so we capture connections
        // that happen before the Dart side listens.
        controllerManager.start()
    }

    // MARK: - FlutterPlugin method handling

    public func handle(_ call: FlutterMethodCall,
                       result: @escaping FlutterResult) {
        if call.method.hasPrefix("plezy") {
            let arguments = call.arguments as? [String: Any] ?? [:]
            let owner = arguments["owner"] as? String ?? ""
            let id = arguments["deviceId"] as? Int ?? -1
            switch call.method {
            case "plezyClaimEffects": result(controllerManager.effects.claim(owner))
            case "plezyReleaseEffects": controllerManager.effects.release(owner); result(nil)
            case "plezyControllerState": result(controllerManager.effects.state(owner, id, controller: controllerManager.controller(for: id)))
            case "plezyControllerEffects": result(controllerManager.effects.apply(arguments, controller: controllerManager.controller(for: id)))
            default: result(FlutterMethodNotImplemented)
            }
            return
        }
        switch call.method {
        case "pause": controllerManager.effects.stop(); result(nil)
        case "resume": result(nil)
        case "listGamepads":
            result(controllerManager.listGamepads())
        case "dispose":
            controllerManager.stop()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
