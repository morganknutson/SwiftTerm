#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum BlockAlpha: CGFloat {
    case full = 1.0
    case dark = 0.75
    case medium = 0.5
    case light = 0.25
}

/// A filled rectangle inside a cell, expressed as fractions of the cell size
/// measured from the top-left corner.
struct BlockElementRect {
    let x0: CGFloat
    let x1: CGFloat
    let y0: CGFloat
    let y1: CGFloat
    let alpha: BlockAlpha

    init(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat, alpha: BlockAlpha = .full) {
        self.x0 = x0
        self.x1 = x1
        self.y0 = y0
        self.y1 = y1
        self.alpha = alpha
    }

    /// Builds a rectangle from eighths of the cell, the unit of the block element range.
    init(eighthsX0 x0: Int, x1: Int, y0: Int, y1: Int, alpha: BlockAlpha = .full) {
        self.init(x0: CGFloat(x0) / 8, x1: CGFloat(x1) / 8, y0: CGFloat(y0) / 8, y1: CGFloat(y1) / 8, alpha: alpha)
    }

    func rect(in cellOrigin: CGPoint, cellSize: CGSize) -> CGRect {
        let left = cellOrigin.x + x0 * cellSize.width
        let right = cellOrigin.x + x1 * cellSize.width
        let top = cellOrigin.y + cellSize.height - y0 * cellSize.height
        let bottom = cellOrigin.y + cellSize.height - y1 * cellSize.height
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

/// Characters that are drawn as a set of filled rectangles instead of font glyphs:
/// block elements (U+2580-U+259F), braille patterns (U+2800-U+28FF), sextants
/// (U+1FB00-U+1FB3B) and the eighth blocks of Symbols for Legacy Computing.
/// Drawing them from the cell geometry makes adjacent cells meet without seams,
/// which font glyphs rarely do.
struct BlockElementMapping {
    static func rects(for codePoint: UInt32) -> [BlockElementRect]? {
        switch codePoint {
        case 0x2580...0x259F:
            return blockElements[codePoint]
        case 0x2800...0x28FF:
            return braille(UInt8(codePoint - 0x2800))
        case 0x1FB00...0x1FB3B:
            return sextant(Int(codePoint - 0x1FB00))
        case 0x1FB70...0x1FB8B:
            return legacyEighths[codePoint]
        default:
            return nil
        }
    }

    private static let fullBlock = BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: 8)
    private static let quadrantUL = BlockElementRect(eighthsX0: 0, x1: 4, y0: 0, y1: 4)
    private static let quadrantUR = BlockElementRect(eighthsX0: 4, x1: 8, y0: 0, y1: 4)
    private static let quadrantLL = BlockElementRect(eighthsX0: 0, x1: 4, y0: 4, y1: 8)
    private static let quadrantLR = BlockElementRect(eighthsX0: 4, x1: 8, y0: 4, y1: 8)

    private static func upperBlock(_ num: Int) -> [BlockElementRect] {
        [BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: num)]
    }

    private static func lowerBlock(_ num: Int) -> [BlockElementRect] {
        [BlockElementRect(eighthsX0: 0, x1: 8, y0: 8 - num, y1: 8)]
    }

    private static func leftBlock(_ num: Int) -> [BlockElementRect] {
        [BlockElementRect(eighthsX0: 0, x1: num, y0: 0, y1: 8)]
    }

    private static func rightBlock(_ num: Int) -> [BlockElementRect] {
        [BlockElementRect(eighthsX0: 8 - num, x1: 8, y0: 0, y1: 8)]
    }

    private static let blockElements: [UInt32: [BlockElementRect]] = [
        0x2580: upperBlock(4),
        0x2581: lowerBlock(1),
        0x2582: lowerBlock(2),
        0x2583: lowerBlock(3),
        0x2584: lowerBlock(4),
        0x2585: lowerBlock(5),
        0x2586: lowerBlock(6),
        0x2587: lowerBlock(7),
        0x2588: [fullBlock],
        0x2589: leftBlock(7),
        0x258A: leftBlock(6),
        0x258B: leftBlock(5),
        0x258C: leftBlock(4),
        0x258D: leftBlock(3),
        0x258E: leftBlock(2),
        0x258F: leftBlock(1),
        0x2590: rightBlock(4),
        0x2591: [BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: 8, alpha: .light)],
        0x2592: [BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: 8, alpha: .medium)],
        0x2593: [BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: 8, alpha: .dark)],
        0x2594: upperBlock(1),
        0x2595: rightBlock(1),
        0x2596: [quadrantLL],
        0x2597: [quadrantLR],
        0x2598: [quadrantUL],
        0x2599: [quadrantUL, quadrantLL, quadrantLR],
        0x259A: [quadrantUL, quadrantLR],
        0x259B: [quadrantUL, quadrantUR, quadrantLL],
        0x259C: [quadrantUL, quadrantUR, quadrantLR],
        0x259D: [quadrantUR],
        0x259E: [quadrantUR, quadrantLL],
        0x259F: [quadrantUR, quadrantLL, quadrantLR]
    ]

    /// U+1FB70-U+1FB8B: one-eighth bars at each position and the upper/right partial blocks.
    private static let legacyEighths: [UInt32: [BlockElementRect]] = {
        var table: [UInt32: [BlockElementRect]] = [:]
        for n in 1...6 {
            table[0x1FB70 + UInt32(n - 1)] = [BlockElementRect(eighthsX0: n, x1: n + 1, y0: 0, y1: 8)]
            table[0x1FB76 + UInt32(n - 1)] = [BlockElementRect(eighthsX0: 0, x1: 8, y0: n, y1: n + 1)]
        }
        table[0x1FB7C] = [BlockElementRect(eighthsX0: 0, x1: 1, y0: 0, y1: 8), BlockElementRect(eighthsX0: 0, x1: 8, y0: 7, y1: 8)]
        table[0x1FB7D] = [BlockElementRect(eighthsX0: 0, x1: 1, y0: 0, y1: 8), BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: 1)]
        table[0x1FB7E] = [BlockElementRect(eighthsX0: 7, x1: 8, y0: 0, y1: 8), BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: 1)]
        table[0x1FB7F] = [BlockElementRect(eighthsX0: 7, x1: 8, y0: 0, y1: 8), BlockElementRect(eighthsX0: 0, x1: 8, y0: 7, y1: 8)]
        table[0x1FB80] = [BlockElementRect(eighthsX0: 0, x1: 8, y0: 0, y1: 1), BlockElementRect(eighthsX0: 0, x1: 8, y0: 7, y1: 8)]
        table[0x1FB81] = [0, 2, 4, 7].map { BlockElementRect(eighthsX0: 0, x1: 8, y0: $0, y1: $0 + 1) }
        for (offset, eighths) in [2, 3, 5, 6, 7].enumerated() {
            table[0x1FB82 + UInt32(offset)] = upperBlock(eighths)
            table[0x1FB87 + UInt32(offset)] = rightBlock(eighths)
        }
        return table
    }()

    /// Braille dots are numbered 1-2-3-7 down the left column and 4-5-6-8 down
    /// the right; bit n-1 of the offset from U+2800 raises dot n.
    private static func braille(_ bits: UInt8) -> [BlockElementRect] {
        let dots: [(bit: UInt8, column: Int, row: Int)] = [
            (0, 0, 0), (1, 0, 1), (2, 0, 2), (3, 1, 0), (4, 1, 1), (5, 1, 2), (6, 0, 3), (7, 1, 3)
        ]
        return dots.compactMap { dot in
            guard bits & (1 << dot.bit) != 0 else {
                return nil
            }
            let x0 = (CGFloat(dot.column) * 4 + 1) / 8
            let y0 = (CGFloat(dot.row) * 4 + 1) / 16
            return BlockElementRect(x0: x0, x1: x0 + 2 / 8, y0: y0, y1: y0 + 2 / 16)
        }
    }

    /// Sextants cover a 2x3 grid; the code points enumerate every pattern except
    /// empty, full, and the left/right halves that already exist as U+258C/U+2590.
    private static func sextant(_ index: Int) -> [BlockElementRect] {
        var pattern = index + 1
        if pattern >= 21 { pattern += 1 }
        if pattern >= 42 { pattern += 1 }
        var rects: [BlockElementRect] = []
        for cell in 0..<6 where pattern & (1 << cell) != 0 {
            let column = CGFloat(cell % 2)
            let row = CGFloat(cell / 2)
            rects.append(BlockElementRect(x0: column / 2, x1: (column + 1) / 2, y0: row / 3, y1: (row + 1) / 3))
        }
        return rects
    }
}
#endif
