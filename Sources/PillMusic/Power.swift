import Combine
import Foundation
import IOKit.ps

/// Suit la source d'alimentation pour économiser la batterie :
/// secteur → 60 i/s, batterie → 30 i/s, mode économie d'énergie → 20 i/s.
final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()

    @Published private(set) var onBattery = false
    @Published private(set) var lowPower = false

    var saving: Bool { onBattery || lowPower }
    var shaderFPS: Double {
        if let v = ProcessInfo.processInfo.environment["PILL_FPS"].flatMap(Double.init) { return v }
        return lowPower ? 20 : (onBattery ? 30 : 60)
    }

    private var source: CFRunLoopSource?

    private init() {
        update()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().update()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?
        let battery = type == "Battery Power"
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if battery != onBattery { onBattery = battery }
        if low != lowPower { lowPower = low }
    }
}
