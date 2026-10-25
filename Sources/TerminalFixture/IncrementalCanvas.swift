#if os(macOS)
import AppKit
import SwiftTerm

/// A terminal view that records every region it invalidates, so the fixture
/// can replay AppKit's partial redraws.
final class RecordingTerminalView: LocalProcessTerminalView {
    private(set) var pendingDirtyRects: [CGRect] = []

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        pendingDirtyRects.append(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }

    override var needsDisplay: Bool {
        didSet {
            if needsDisplay {
                pendingDirtyRects.append(bounds)
            }
        }
    }

    func takeDirtyRects() -> [CGRect] {
        defer { pendingDirtyRects.removeAll() }
        return pendingDirtyRects.map { $0.intersection(bounds) }.filter { !$0.isEmpty }
    }
}

/// A transparent bitmap the view draws into the way AppKit drives a layer's
/// backing store: each redraw clears the dirty region, then runs `draw(_:)` once
/// with the region's bounding box, clipped to the dirty rects. The result is
/// composited over whatever is behind the view, like Core Animation does.
final class TerminalBackingStore {
    let context: CGContext
    private let view: NSView

    init?(view: NSView, scale: CGFloat) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        self.context = context
        self.view = view
    }

    func redraw(_ rects: [CGRect]) {
        guard let first = rects.first else {
            return
        }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        context.saveGState()
        context.clip(to: rects)
        context.clear(union)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(union)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    func redrawAll() {
        redraw([view.bounds])
    }

    func image() -> CGImage? {
        context.makeImage()
    }
}

/// A backing store that is only repainted where the terminal invalidated.
/// Comparing it with a full redraw exposes stale pixels left behind by missing
/// invalidations.
final class IncrementalCanvas {
    private let view: RecordingTerminalView
    private let scale: CGFloat
    private let store: TerminalBackingStore

    init?(view: RecordingTerminalView, scale: CGFloat) {
        guard let store = TerminalBackingStore(view: view, scale: scale) else {
            return nil
        }
        self.view = view
        self.scale = scale
        self.store = store
        _ = view.takeDirtyRects()
        store.redrawAll()
    }

    /// Repaints the regions the view invalidated since the last call.
    func update() {
        store.redraw(view.takeDirtyRects())
    }

    /// Pixels that differ from a full redraw of the current state, with the
    /// incremental image and a diff image (mismatches in red).
    func compareWithFullRender() -> (mismatchedPixels: Int, incremental: CGImage?, diff: CGImage?) {
        update()
        guard let fresh = TerminalBackingStore(view: view, scale: scale),
              let diff = TerminalBackingStore(view: view, scale: scale) else {
            return (0, nil, nil)
        }
        fresh.redrawAll()
        guard let freshPixels = fresh.context.data?.assumingMemoryBound(to: UInt8.self),
              let incrementalPixels = store.context.data?.assumingMemoryBound(to: UInt8.self),
              let diffPixels = diff.context.data?.assumingMemoryBound(to: UInt8.self) else {
            return (0, store.image(), nil)
        }
        let context = store.context
        var mismatched = 0
        for y in 0..<context.height {
            for x in 0..<context.width {
                let offset = y * context.bytesPerRow + x * 4
                var delta = 0
                for channel in 0..<4 {
                    delta = max(delta, abs(Int(freshPixels[offset + channel]) - Int(incrementalPixels[offset + channel])))
                }
                let isDifferent = delta > 8
                if isDifferent {
                    mismatched += 1
                }
                // Dimmed full render on black, with mismatches in solid red
                diffPixels[offset] = isDifferent ? 255 : freshPixels[offset] / 3
                diffPixels[offset + 1] = isDifferent ? 0 : freshPixels[offset + 1] / 3
                diffPixels[offset + 2] = isDifferent ? 0 : freshPixels[offset + 2] / 3
                diffPixels[offset + 3] = 255
            }
        }
        return (mismatched, store.image(), diff.image())
    }
}
#endif
