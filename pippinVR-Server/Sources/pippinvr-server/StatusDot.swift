import AppKit

extension NSStatusBarButton {
    func setStatusDot(_ color: NSColor) {
        attributedTitle = NSAttributedString(
            string: " \u{25CF}",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 11)]
        )
    }
}
