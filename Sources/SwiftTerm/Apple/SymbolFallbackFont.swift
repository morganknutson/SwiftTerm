#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import CoreText
import Foundation

/// Draws the icons that prompts, file listers and editors print from the
/// Private Use Area (Nerd Font icons) when the terminal font has no glyph for
/// them, using the bundled Symbols Nerd Font Mono (MIT, see
/// Resources/SymbolsNerdFont-LICENSE.txt), the same font Ghostty bundles.
///
/// CoreText cannot be relied on to reach the font through a cascade list: the
/// system monospaced font resolves private-use characters to LastResort before
/// consulting it. The icons are therefore placed explicitly, scaled to fill the
/// cells they occupy and centered vertically on the text.
final class SymbolFallbackFont {
    static let shared = SymbolFallbackFont()

    private let descriptor: CTFontDescriptor?
    private let lock = NSLock()
    private var fonts: [FontKey: CTFont] = [:]

    private struct FontKey: Hashable {
        let size: CGFloat
        let verticalShift: CGFloat
    }

    private init() {
        let url = Bundle.module.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
        let descriptors = url.flatMap { CTFontManagerCreateFontDescriptorsFromURL($0 as CFURL) as? [CTFontDescriptor] }
        descriptor = descriptors?.first
    }

    static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
            return true
        default:
            return false
        }
    }

    static func font(_ font: CTFont, hasGlyphFor scalar: Unicode.Scalar) -> Bool {
        var characters = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }

    /// The symbol font sized so an icon spans `width` points (its glyphs are one
    /// em wide) without growing past the text, and shifted so the icons are
    /// centered on the text of `textFont`. Nil when the font could not be loaded.
    func font(width: CGFloat, textFont: CTFont) -> CTFont? {
        guard let descriptor else {
            return nil
        }
        let size = min(width, CTFontGetSize(textFont))
        let textCenter = (CTFontGetAscent(textFont) - CTFontGetDescent(textFont)) / 2
        let key = FontKey(size: size, verticalShift: textCenter)

        lock.lock()
        defer { lock.unlock() }
        if let cached = fonts[key] {
            return cached
        }
        let unshifted = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let symbolCenter = (CTFontGetAscent(unshifted) - CTFontGetDescent(unshifted)) / 2
        var matrix = CGAffineTransform(translationX: 0, y: textCenter - symbolCenter)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, &matrix)
        fonts[key] = font
        return font
    }
}
#endif
