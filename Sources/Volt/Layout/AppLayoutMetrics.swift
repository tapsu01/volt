import Foundation
import SwiftUI

enum AppLayoutMetrics {
    static let wideBreakpoint: CGFloat = 1350
    static let mediumBreakpoint: CGFloat = 1100
    static let narrowBreakpoint: CGFloat = 850

    static let inspectorSinglePaneBreakpoint: CGFloat = 1250
    static let disconnectedRemoteSinglePaneBreakpoint: CGFloat = 1250

    static let fullSidebarWidth: CGFloat = 240
    static let iconSidebarWidth: CGFloat = 64
    static let dockedInspectorWidth: CGFloat = 280

    static func overlayInspectorWidth(for width: CGFloat) -> CGFloat {
        min(320, max(260, width * 0.28))
    }
}
