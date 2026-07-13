import Foundation

enum AppLayoutMode {
    case wide
    case medium
    case narrow
    case compact
}

enum SidebarMode {
    case full
    case iconOnly
    case hidden
}

enum InspectorMode {
    case hidden
    case docked
    case overlay
    case sheet
}

enum BrowserMode {
    case dualPane
    case singlePane
}

enum ActiveBrowserPane: String, CaseIterable, Identifiable {
    case local = "Local"
    case remote = "Remote"

    var id: String { rawValue }
}

enum ToolbarDensity {
    case expanded
    case compact
    case minimal
}
