// SPDX-License-Identifier: MIT
import Foundation
import GameController
import CoreHaptics

/// Optional PlezyNG effects extension. Called on the plugin's main queue.
final class GamepadEffects {
    private final class Device {
        let controller: GCController
        var sensors = false
        private let motionLock = NSLock()
        private var motionEnabled = false
        private var generation: UInt64 = 0
        private var updated: TimeInterval = 0
        private var samples = [Double](repeating: 0, count: 6)
        func setSensors(_ enabled: Bool) {
            if sensors == enabled { return }
            sensors = enabled
            motionLock.lock()
            motionEnabled = enabled
            generation &+= 1
            let currentGeneration = generation
            samples = [Double](repeating: 0, count: 6)
            updated = 0
            motionLock.unlock()
            if enabled {
                controller.motion?.valueChangedHandler = { [weak self] motion in self?.sample(motion, generation: currentGeneration) }
            } else {
                controller.motion?.valueChangedHandler = nil
            }
            if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) {
                if controller.motion?.sensorsRequireManualActivation == true { controller.motion?.sensorsActive = enabled }
            }
        }
        private func sample(_ motion: GCMotion, generation: UInt64) {
            var values = [Double](repeating: 0, count: 6)
            if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) {
                if motion.hasRotationRate { values[0] = motion.rotationRate.x; values[1] = motion.rotationRate.y; values[2] = motion.rotationRate.z }
                if motion.hasGravityAndUserAcceleration {
                    values[3] = (motion.gravity.x + motion.userAcceleration.x) * 9.80665
                    values[4] = (motion.gravity.y + motion.userAcceleration.y) * 9.80665
                    values[5] = (motion.gravity.z + motion.userAcceleration.z) * 9.80665
                }
            }
            motionLock.lock()
            defer { motionLock.unlock() }
            if motionEnabled && self.generation == generation && values.allSatisfy({ $0.isFinite }) {
                samples = values
                updated = ProcessInfo.processInfo.systemUptime
            }
        }
        func motionValues() -> [Double] {
            motionLock.lock()
            defer { motionLock.unlock() }
            return motionEnabled && updated > 0 && ProcessInfo.processInfo.systemUptime - updated < 0.25 ? samples : [Double](repeating: 0, count: 6)
        }
        var engines: [String: CHHapticEngine] = [:]
        var players: [String: CHHapticAdvancedPatternPlayer] = [:]
        init(_ controller: GCController) { self.controller = controller }
        func stop() {
            setSensors(false)
            for player in players.values { try? player.stop(atTime: CHHapticTimeImmediate) }
            for engine in engines.values { engine.stop(completionHandler: nil) }
            players.removeAll()
            engines.removeAll()
        }
    }
    private var owner = ""
    private var devices: [Int: Device] = [:]
    func claim(_ token: String) -> Bool {
        guard token.range(of: "^[0-9a-f]{32}-[0-9]{1,10}-[0-9]{1,10}$", options: .regularExpression) != nil else { return false }
        if token != owner { stop(); owner = token }
        return true
    }
    func release(_ token: String) { if token == owner { stop() } }
    func stop() {
        owner = ""
        for device in devices.values { device.stop() }
        devices.removeAll()
    }
    func remove(_ id: Int) { devices.removeValue(forKey: id)?.stop() }
    private func device(_ token: String, _ id: Int, _ controller: GCController?) -> Device? {
        guard !owner.isEmpty, token == owner, let controller = controller else { return nil }
        if let previous = devices[id], previous.controller !== controller { remove(id) }
        if devices[id] == nil && devices.count < 4 { devices[id] = Device(controller) }
        return devices[id]
    }
    @available(macOS 11.0, iOS 14.0, tvOS 14.0, *)
    private func pulse(_ device: Device, _ locality: GCHapticsLocality, _ magnitude: Int, _ duration: Int) throws {
        let key = locality.rawValue
        try? device.players.removeValue(forKey: key)?.stop(atTime: CHHapticTimeImmediate)
        guard magnitude > 0, duration > 0 else { return }
        if device.engines[key] == nil {
            device.engines[key] = device.controller.haptics?.createEngine(withLocality: locality)
        }
        guard let engine = device.engines[key] else { return }
        engine.isAutoShutdownEnabled = true
        try engine.start()
        let event = CHHapticEvent(eventType: .hapticContinuous,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(magnitude) / 65535),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
            relativeTime: 0, duration: Double(duration) / 1000)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        device.players[key] = player
        try player.start(atTime: CHHapticTimeImmediate)
    }
    func apply(_ arguments: [String: Any], controller: GCController?) -> Bool {
        guard let token = arguments["owner"] as? String, let id = arguments["deviceId"] as? Int,
              let flags = arguments["flags"] as? Int, (0...7).contains(flags),
              let low = arguments["low"] as? Int, let high = arguments["high"] as? Int,
              let left = arguments["leftTrigger"] as? Int, let right = arguments["rightTrigger"] as? Int,
              let duration = arguments["duration"] as? Int, let triggerDuration = arguments["triggerDuration"] as? Int,
              [low, high, left, right].allSatisfy({ (0...65535).contains($0) }),
              (0...1000).contains(duration), (0...1000).contains(triggerDuration),
              let device = device(token, id, controller) else { return false }
        if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) {
            do {
                let localities = device.controller.haptics?.supportedLocalities ?? []
                if flags & 1 != 0 {
                    if localities.contains(.leftHandle) && localities.contains(.rightHandle) {
                        try pulse(device, .leftHandle, low, duration)
                        try pulse(device, .rightHandle, high, duration)
                    } else if localities.contains(.default) {
                        try pulse(device, .default, max(low, high), duration)
                    }
                }
                if flags & 2 != 0 {
                    if localities.contains(.leftTrigger) { try pulse(device, .leftTrigger, left, triggerDuration) }
                    if localities.contains(.rightTrigger) { try pulse(device, .rightTrigger, right, triggerDuration) }
                }
                if flags & 4 != 0 {
                    device.setSensors(arguments["sensors"] as? Bool == true)
                }
                return true
            } catch { remove(id); return false }
        }
        return false
    }
    func state(_ token: String, _ id: Int, controller: GCController?) -> [Double]? {
        guard let device = device(token, id, controller) else { return nil }
        var result = [Double](repeating: 0, count: 7)
        if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) {
            let localities = device.controller.haptics?.supportedLocalities ?? []
            var capabilities = localities.contains(.default) || (localities.contains(.leftHandle) && localities.contains(.rightHandle)) ? 1 : 0
            if localities.contains(.leftTrigger) && localities.contains(.rightTrigger) { capabilities |= 2 }
            if let motion = device.controller.motion {
                if motion.hasRotationRate { capabilities |= 4 }
                if motion.hasGravityAndUserAcceleration { capabilities |= 8 }
                let values = device.motionValues()
                for i in 0..<6 { result[i + 1] = values[i] }
            }
            result[0] = Double(capabilities)
        }
        return result.allSatisfy({ $0.isFinite }) ? result : nil
    }
}
