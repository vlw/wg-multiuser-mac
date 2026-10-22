import AppKit
import SwiftUI

/// Моноширинный текстовый редактор на NSTextView с подсветкой конфига WireGuard.
/// С `editable: false` используется и для просмотра журнала.
struct ConfigEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var highlight = true
    var scrollToEnd = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isEditable = editable
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.string = text
        context.coordinator.apply(tv)
        if scrollToEnd { tv.scrollToEndOfDocument(nil) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = editable
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            if editable { tv.selectedRanges = sel }
            context.coordinator.apply(tv)
            if scrollToEnd { tv.scrollToEndOfDocument(nil) }
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConfigEditor
        init(_ p: ConfigEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            apply(tv)
        }

        func apply(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: ConfigEditor.font, .foregroundColor: NSColor.textColor], range: full)
            if parent.highlight { highlight(storage) }
            storage.endEditing()
            tv.typingAttributes = [.font: ConfigEditor.font, .foregroundColor: NSColor.textColor]
        }

        private static let section = try! NSRegularExpression(pattern: "^\\s*\\[[^\\]]*\\]", options: .anchorsMatchLines)
        private static let key = try! NSRegularExpression(pattern: "^\\s*([A-Za-z]+)\\s*=", options: .anchorsMatchLines)
        private static let comment = try! NSRegularExpression(pattern: "#.*$", options: .anchorsMatchLines)
        private static let hidden = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: hiddenSecret))

        private func highlight(_ s: NSTextStorage) {
            let text = s.string
            let full = NSRange(location: 0, length: s.length)
            for m in Self.section.matches(in: text, range: full) {
                s.addAttributes([.foregroundColor: NSColor.systemPurple, .font: ConfigEditor.bold], range: m.range)
            }
            for m in Self.key.matches(in: text, range: full) {
                let k = (text as NSString).substring(with: m.range(at: 1)).lowercased()
                let known = WGConfig.interfaceKeys.contains(k) || WGConfig.peerKeys.contains(k)
                let color: NSColor = !known ? .systemRed : WGConfig.privilegedKeys.contains(k) ? .systemOrange : .systemBlue
                s.addAttribute(.foregroundColor, value: color, range: m.range(at: 1))
            }
            for m in Self.hidden.matches(in: text, range: full) {
                s.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            }
            for m in Self.comment.matches(in: text, range: full) {
                s.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: m.range)
            }
        }
    }
}
