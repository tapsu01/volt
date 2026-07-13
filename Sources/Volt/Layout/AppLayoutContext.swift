import Foundation
import SwiftUI

struct AppLayoutContext {
    let mode: AppLayoutMode
    let width: CGFloat
    let sidebarMode: SidebarMode
    let inspectorMode: InspectorMode
    let browserMode: BrowserMode
    let toolbarDensity: ToolbarDensity
    let isQueueCompact: Bool

    var isDualPane: Bool { browserMode == .dualPane }
    var isInspectorDocked: Bool { inspectorMode == .docked }
    var isSidebarFull: Bool { sidebarMode == .full }
    var isSidebarIconOnly: Bool { sidebarMode == .iconOnly }

    var sidebarWidth: CGFloat {
        switch sidebarMode {
        case .full:
            AppLayoutMetrics.fullSidebarWidth
        case .iconOnly:
            AppLayoutMetrics.iconSidebarWidth
        case .hidden:
            0
        }
    }

    var inspectorWidth: CGFloat {
        switch inspectorMode {
        case .docked:
            AppLayoutMetrics.dockedInspectorWidth
        case .overlay, .sheet:
            AppLayoutMetrics.overlayInspectorWidth(for: width)
        case .hidden:
            0
        }
    }

    static func make(
        width: CGFloat,
        inspectorOpen: Bool,
        remoteConnected: Bool,
        queueExpanded: Bool,
        sidebarVisible: Bool
    ) -> AppLayoutContext {
        let mode: AppLayoutMode
        if width >= AppLayoutMetrics.wideBreakpoint {
            mode = .wide
        } else if width >= AppLayoutMetrics.mediumBreakpoint {
            mode = .medium
        } else if width >= AppLayoutMetrics.narrowBreakpoint {
            mode = .narrow
        } else {
            mode = .compact
        }

        let sidebarMode: SidebarMode
        if !sidebarVisible {
            sidebarMode = .hidden
        } else if width < AppLayoutMetrics.narrowBreakpoint {
            sidebarMode = .iconOnly
        } else {
            sidebarMode = .full
        }

        let shouldUseSinglePane =
            width < AppLayoutMetrics.mediumBreakpoint ||
            (inspectorOpen && width < AppLayoutMetrics.inspectorSinglePaneBreakpoint) ||
            (!remoteConnected && width < AppLayoutMetrics.disconnectedRemoteSinglePaneBreakpoint)

        let inspectorMode: InspectorMode
        if !inspectorOpen {
            inspectorMode = .hidden
        } else if width >= AppLayoutMetrics.wideBreakpoint {
            inspectorMode = .docked
        } else if width < AppLayoutMetrics.narrowBreakpoint {
            inspectorMode = .sheet
        } else {
            inspectorMode = .overlay
        }

        let toolbarDensity: ToolbarDensity
        switch mode {
        case .wide, .medium:
            toolbarDensity = .expanded
        case .narrow:
            toolbarDensity = .compact
        case .compact:
            toolbarDensity = .minimal
        }

        return AppLayoutContext(
            mode: mode,
            width: width,
            sidebarMode: sidebarMode,
            inspectorMode: inspectorMode,
            browserMode: shouldUseSinglePane ? .singlePane : .dualPane,
            toolbarDensity: toolbarDensity,
            isQueueCompact: width < 1000 || queueExpanded && width < AppLayoutMetrics.mediumBreakpoint
        )
    }
}
