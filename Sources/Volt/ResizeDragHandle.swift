import AppKit
import SwiftUI

enum ResizeDragAxis {
    case horizontal
    case vertical
}

struct ResizeDragHandleView: NSViewRepresentable {
    var axis: ResizeDragAxis
    var cursor: NSCursor
    var currentValue: CGFloat
    var minValue: CGFloat
    var maxValue: CGFloat
    var direction: CGFloat = 1
    var onResize: (CGFloat) -> Void
    var onResizeEnd: (() -> Void)? = nil

    func makeNSView(context: Context) -> ResizeDragTrackingView {
        let view = ResizeDragTrackingView()
        view.axis = axis
        view.cursor = cursor
        view.currentValue = currentValue
        view.minValue = minValue
        view.maxValue = maxValue
        view.direction = direction
        view.onResize = onResize
        view.onResizeEnd = onResizeEnd
        return view
    }

    func updateNSView(_ nsView: ResizeDragTrackingView, context: Context) {
        nsView.axis = axis
        nsView.cursor = cursor
        nsView.currentValue = currentValue
        nsView.minValue = minValue
        nsView.maxValue = maxValue
        nsView.direction = direction
        nsView.onResize = onResize
        nsView.onResizeEnd = onResizeEnd
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class ResizeDragTrackingView: NSView {
    var axis: ResizeDragAxis = .horizontal
    var cursor: NSCursor = .arrow
    var currentValue: CGFloat = 0
    var minValue: CGFloat = 0
    var maxValue: CGFloat = .greatestFiniteMagnitude
    var direction: CGFloat = 1
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?

    private var startLocation: NSPoint?
    private var startValue: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        startLocation = event.locationInWindow
        startValue = currentValue
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation else { return }
        let delta: CGFloat = switch axis {
        case .horizontal:
            event.locationInWindow.x - startLocation.x
        case .vertical:
            event.locationInWindow.y - startLocation.y
        }
        let value = min(maxValue, max(minValue, startValue + delta * direction))
        onResize?(value)
    }

    override func mouseUp(with event: NSEvent) {
        startLocation = nil
        onResizeEnd?()
    }
}
