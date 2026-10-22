import Foundation

/// Подставляется вместо секретов (PrivateKey, PresharedKey), когда их показывают не администратору.
/// Помощник при сохранении заменяет его обратно на настоящее значение.
let hiddenSecret = "<hidden>"

struct WGEntry {
    let key: String     // как написано в файле
    let value: String
    let line: Int       // номер строки, с 1
    var lkey: String { key.lowercased() }
}

struct WGSection {
    let name: String
    let line: Int
    var entries: [WGEntry] = []

    func values(_ key: String) -> [String] {
        entries.filter { $0.lkey == key.lowercased() }.map(\.value)
    }
    func value(_ key: String) -> String? { values(key).first }
    /// Значения через запятую из всех одноимённых строк (Address, AllowedIPs, DNS).
    func list(_ key: String) -> [String] {
        values(key).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Разбор и проверка конфига в формате wg-quick.
struct WGConfig {
    static let interfaceKeys: Set<String> = ["privatekey", "listenport", "fwmark", "address", "dns", "mtu", "table",
                                             "preup", "postup", "predown", "postdown", "saveconfig"]
    static let peerKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"]
    /// Параметры, которые выполняют команды от root или пишут файлы — менять может только администратор.
    static let privilegedKeys: Set<String> = ["preup", "postup", "predown", "postdown", "saveconfig"]
    static let secretKeys: Set<String> = ["privatekey", "presharedkey"]

    private(set) var sections: [WGSection] = []
    private(set) var errors: [String] = []

    var interface: WGSection? { sections.first { $0.name.lowercased() == "interface" } }
    var peers: [WGSection] { sections.filter { $0.name.lowercased() == "peer" } }

    /// wg-quick заменит системный DNS.
    var setsDNS: Bool { !(interface?.list("DNS").isEmpty ?? true) }

    /// Через туннель идёт весь трафик: 0.0.0.0/0 (или ::/0), в том числе в виде пары половинок /1.
    var routesAllTraffic: Bool {
        let ips = Set(peers.flatMap { $0.list("AllowedIPs") })
        return ips.contains("0.0.0.0/0") || ips.contains("::/0")
            || ips.isSuperset(of: ["0.0.0.0/1", "128.0.0.0/1"]) || ips.isSuperset(of: ["::/1", "8000::/1"])
    }

    init(_ text: String) {
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            var line = raw
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if !["interface", "peer"].contains(name.lowercased()) {
                    errors.append("Строка \(n): неизвестная секция [\(name)]")
                }
                sections.append(WGSection(name: name, line: n))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                errors.append("Строка \(n): ожидается «Параметр = значение»")
                continue
            }
            guard !sections.isEmpty else {
                errors.append("Строка \(n): параметр вне секции [Interface] или [Peer]")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[sections.count - 1].entries.append(WGEntry(key: key, value: value, line: n))
        }
        validate()
    }

    private mutating func validate() {
        let ifaces = sections.filter { $0.name.lowercased() == "interface" }
        if ifaces.isEmpty { errors.append("Нет секции [Interface]") }
        if ifaces.count > 1 { errors.append("Секция [Interface] должна быть одна") }

        var seenPeers = Set<String>()
        for s in sections {
            let isIface = s.name.lowercased() == "interface"
            let allowed = isIface ? Self.interfaceKeys : Self.peerKeys
            for e in s.entries {
                guard allowed.contains(e.lkey) else {
                    errors.append("Строка \(e.line): неизвестный параметр «\(e.key)» в [\(s.name)]")
                    continue
                }
                if let err = Self.check(e) { errors.append("Строка \(e.line): \(err)") }
            }
            if isIface {
                if s.value("PrivateKey") == nil { errors.append("В [Interface] нет PrivateKey") }
            } else if s.name.lowercased() == "peer" {
                if let pk = s.value("PublicKey") {
                    if !seenPeers.insert(pk).inserted { errors.append("Строка \(s.line): пир с таким PublicKey уже есть") }
                } else {
                    errors.append("Строка \(s.line): в [Peer] нет PublicKey")
                }
            }
        }
    }

    private static func check(_ e: WGEntry) -> String? {
        let v = e.value
        switch e.lkey {
        case "privatekey", "presharedkey":
            return v == hiddenSecret || isKey(v) ? nil : "\(e.key) — неверный ключ (нужен base64, 44 символа)"
        case "publickey":
            return isKey(v) ? nil : "PublicKey — неверный ключ (нужен base64, 44 символа)"
        case "listenport":
            return UInt16(v) != nil ? nil : "ListenPort — нужно число 0–65535"
        case "mtu":
            return Int(v).map { (576...65535).contains($0) } == true ? nil : "MTU — нужно число 576–65535"
        case "persistentkeepalive":
            return v == "off" || UInt16(v) != nil ? nil : "PersistentKeepalive — нужно число секунд или off"
        case "address", "allowedips":
            let bad = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !isCIDR($0) }
            return bad.isEmpty ? nil : "\(e.key) — неверный адрес: \(bad.joined(separator: ", "))"
        case "endpoint":
            return isEndpoint(v) ? nil : "Endpoint — нужно «хост:порт»"
        default:
            return v.isEmpty && !privilegedKeys.contains(e.lkey) ? "\(e.key) — пустое значение" : nil
        }
    }

    static func isKey(_ s: String) -> Bool {
        s.count == 44 && Data(base64Encoded: s)?.count == 32
    }

    static func isIP(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    static func isCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, isIP(String(parts[0])) else { return false }
        guard parts.count == 2 else { return true }
        let max = parts[0].contains(":") ? 128 : 32
        return Int(parts[1]).map { (0...max).contains($0) } ?? false
    }

    static func isEndpoint(_ s: String) -> Bool {
        guard let colon = s.lastIndex(of: ":"), UInt16(s[s.index(after: colon)...]) != nil else { return false }
        var host = String(s[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return !host.isEmpty && !host.contains(" ")
    }
}

/// Делает из произвольного названия допустимое имя интерфейса wg-quick: [a-zA-Z0-9_=+.-], не длиннее 15.
func sanitizeTunnelName(_ s: String) -> String {
    let ru: [Character: String] = ["а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh",
        "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"]
    var translit = ""
    for ch in s {
        let low = Character(ch.lowercased())
        if let t = ru[low] { translit += ch == low ? t : t.capitalized } else { translit.append(ch) }
    }
    let latin = translit.applyingTransform(.toLatin, reverse: false)?
        .applyingTransform(.stripDiacritics, reverse: false) ?? translit
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.")
    var out = ""
    for ch in latin {
        if allowed.contains(ch) { out.append(ch) } else if out.last != "-" { out.append("-") }
    }
    out = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(15))
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

func isValidTunnelName(_ s: String) -> Bool {
    s.range(of: "^[a-zA-Z0-9_=+.-]{1,15}$", options: .regularExpression) != nil
}
