//
//  MacAccessibilityService.swift
//
//
//  Created by Miguel de Icaza on 3/5/20.
//

#if os(macOS)
import Foundation
import AppKit

class AccessibilityService {
    func invalidate ()
    {

    }
}

// MARK: - Accessibility for dictation and Voice Control

extension TerminalView {
    override open func isAccessibilityElement() -> Bool {
        NSLog("[Dictation] isAccessibilityElement called — returning true")
        return true
    }

    override open func accessibilityRole() -> NSAccessibility.Role? {
        NSLog("[Dictation] accessibilityRole called — returning .textArea")
        return .textArea
    }

    override open func accessibilityValue() -> Any? {
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else {
            NSLog("[Dictation] accessibilityValue called — returning nil (rows:%d cols:%d)", rows, cols)
            return nil
        }
        let text = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: cols, row: rows - 1)
        )
        NSLog("[Dictation] accessibilityValue called — returning %d chars", text.count)
        return text
    }

    override open func setAccessibilityValue(_ value: Any?) {
        NSLog("[Dictation] setAccessibilityValue called — value type: %@", String(describing: type(of: value)))
        guard let text = value as? String else { return }
        NSLog("[Dictation] setAccessibilityValue sending to terminal — text: \"%@\"", text)
        send(txt: text)
    }

    override open func accessibilitySelectedTextRange() -> NSRange {
        let range = selectedRange()
        NSLog("[Dictation] accessibilitySelectedTextRange called — returning %@", NSStringFromRange(range))
        return range
    }

    override open func accessibilitySelectedText() -> String? {
        guard let sel = selection, sel.active else {
            NSLog("[Dictation] accessibilitySelectedText called — no active selection")
            return nil
        }
        let text = sel.getSelectedText()
        NSLog("[Dictation] accessibilitySelectedText called — returning \"%@\"", text)
        return text
    }
}
#endif
