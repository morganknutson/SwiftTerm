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
        return true
    }

    override open func accessibilityRole() -> NSAccessibility.Role? {
        return .textArea
    }

    override open func accessibilityValue() -> Any? {
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return nil }
        return terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: cols, row: rows - 1)
        )
    }

    override open func setAccessibilityValue(_ value: Any?) {
        guard let text = value as? String else { return }
        send(txt: text)
    }

    override open func accessibilitySelectedTextRange() -> NSRange {
        return selectedRange()
    }

    override open func accessibilitySelectedText() -> String? {
        guard let sel = selection, sel.active else { return nil }
        return sel.getSelectedText()
    }
}
#endif
