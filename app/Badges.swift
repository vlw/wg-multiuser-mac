import AppKit
import SwiftUI

// Значки туннеля справа от имени: [DNS] — конфиг задаёт DNS, 🌐 — через туннель идёт весь трафик (0.0.0.0/0).
// Обе позиции всегда занимают место, чтобы значки разных туннелей стояли ровными колонками.

let dnsBadgeHelp = "Задаёт DNS: wg-quick заменит системный DNS"
let internetBadgeHelp = "Весь трафик через туннель (0.0.0.0/0)"

struct TunnelBadges: View {
    let dns: Bool
    let internet: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("DNS")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1))
                .opacity(dns ? 1 : 0)
                .help(dns ? dnsBadgeHelp : "")
            Image(systemName: "globe")
                .font(.system(size: 12))
                .opacity(internet ? 1 : 0)
                .help(internet ? internetBadgeHelp : "")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([dns ? "DNS" : nil, internet ? "весь трафик" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Для меню в трее (NSMenuItem.attributedTitle)

enum MenuBadges {
    static let menuFont = NSFont.menuFont(ofSize: 0)

    /// «DNS» в скруглённом прямоугольнике. Рисуется при каждом показе, поэтому цвет следует теме.
    static let dns: NSImage = {
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let text = "DNS" as NSString
        let textSize = text.size(withAttributes: [.font: font])
        let size = NSSize(width: ceil(textSize.width) + 8, height: 13)
        return NSImage(size: size, flipped: false) { rect in
            let color = NSColor.secondaryLabelColor
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            color.setStroke()
            path.stroke()
            text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                      withAttributes: [.font: font, .foregroundColor: color])
            return true
        }
    }()

    static let globe: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        return NSImage(systemSymbolName: "globe", accessibilityDescription: "весь трафик")?
            .withSymbolConfiguration(config) ?? NSImage()
    }()

    /// Заголовок пункта меню: имя, затем колонка DNS и колонка планетки.
    static func title(_ name: String, dns: Bool, internet: Bool, nameColumnWidth: CGFloat) -> NSAttributedString {
        let dnsColumn = nameColumnWidth + 14
        let globeColumn = dnsColumn + self.dns.size.width + 6
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: dnsColumn),
                          NSTextTab(textAlignment: .left, location: globeColumn)]

        let result = NSMutableAttributedString(string: name, attributes: [.font: menuFont])
        if dns || internet {
            result.append(NSAttributedString(string: "\t", attributes: [.font: menuFont]))
            if dns { result.append(attachment(self.dns)) }
            if internet {
                result.append(NSAttributedString(string: "\t", attributes: [.font: menuFont]))
                result.append(attachment(globe))
            }
        }
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func nameWidth(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: menuFont]).width)
    }

    private static func attachment(_ image: NSImage) -> NSAttributedString {
        let a = NSTextAttachment()
        a.image = image
        // Выравниваем по центру строчных букв меню.
        let y = (menuFont.capHeight - image.size.height) / 2
        a.bounds = CGRect(x: 0, y: y.rounded(), width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: a)
    }
}
