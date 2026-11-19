import AppKit
import Combine
import ServiceManagement

enum PillSize: String, CaseIterable {
    case small, medium, large

    /// Facteur appliqué aux mesures du design Paper (777 × 208).
    var scale: CGFloat {
        switch self {
        case .small: return 0.20
        case .medium: return 0.25
        case .large: return 0.31
        }
    }

    var label: String {
        switch self {
        case .small: return "Petite"
        case .medium: return "Moyenne"
        case .large: return "Grande"
        }
    }
}

enum PillAppearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "Comme le système"
        case .light: return "Clair"
        case .dark: return "Sombre"
        }
    }
}

final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var size: PillSize {
        didSet { defaults.set(size.rawValue, forKey: "size") }
    }

    /// Échelle de la pilule.
    var scale: CGFloat { size.scale }

    @Published var appearance: PillAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    init() {
        size = PillSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium
        appearance = PillAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossible de modifier l'ouverture au démarrage"
            alert.informativeText = "Place PillMusic dans le dossier Applications puis réessaie.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
}
