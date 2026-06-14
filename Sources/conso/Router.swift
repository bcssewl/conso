import SwiftUI
import Observation

/// Shared navigation state so the menu-bar HUD can drive the main window.
@MainActor
@Observable
final class Router {
    var pillar: Pillar = .status
}
