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
        dictLog("isAccessibilityElement — returning true")
        return true
    }

    override open func accessibilityRole() -> NSAccessibility.Role? {
        dictLog("accessibilityRole — returning .textArea")
        return .textArea
    }

    override open func accessibilityValue() -> Any? {
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else {
            dictLog("accessibilityValue — returning nil (rows:\(rows) cols:\(cols))")
            return nil
        }
        let text = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: cols, row: rows - 1)
        )
        dictLog("accessibilityValue — returning \(text.count) chars")
        return text
    }

    override open func setAccessibilityValue(_ value: Any?) {
        dictLog("setAccessibilityValue — value type: \(type(of: value))")
        guard let text = value as? String else { return }
        dictLog("setAccessibilityValue sending — text: \"\(text)\"")
        send(txt: text)
    }

    override open func accessibilitySelectedTextRange() -> NSRange {
        let range = selectedRange()
        dictLog("accessibilitySelectedTextRange — returning \(NSStringFromRange(range))")
        return range
    }

    override open func accessibilitySelectedText() -> String? {
        guard let sel = selection, sel.active else {
            dictLog("accessibilitySelectedText — no active selection")
            return nil
        }
        let text = sel.getSelectedText()
        dictLog("accessibilitySelectedText — returning \"\(text)\"")
        return text
    }
}
#endif
