// Привилегированный помощник WGMenu. Запускается через sudo по правилу из /etc/sudoers.d/wgmenu.
//
//   list                  имя<TAB>up|down<TAB>флаги (dns,inet или -) для каждого /etc/wireguard/*.conf
//   caps                  admin | user — может ли вызывающий видеть ключи и менять PreUp/PostUp
//   get <имя>             текст конфига (секреты скрыты, если вызывающий не администратор)
//   stats <имя>           публичный ключ и, если туннель поднят, статистика `wg show dump`
//   up|down <имя>         поднять / опустить туннель
//   create <имя>          создать туннель из конфига в stdin
//   save <имя> <старое>   сохранить конфиг из stdin (переименовать, если имена разные)
//   delete <имя>          удалить конфиг (копия уходит в /etc/wireguard/.deleted)
//   log                   хвост журнала
import Foundation

let confDir = "/etc/wireguard"
let runDir = "/var/run/wireguard"
let logPath = "/var/log/wgmenu.log"
let caller = ProcessInfo.processInfo.environment["SUDO_USER"] ?? "root"
setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
umask(0o077)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func confPath(_ name: String) -> String { "\(confDir)/\(name).conf" }

func requireName(_ name: String?, mustExist: Bool = true) -> String {
    guard let name, isValidTunnelName(name) else {
        fail("Недопустимое имя туннеля. Разрешены латиница, цифры и _=+.-, не длиннее 15 символов.")
    }
    if mustExist && !FileManager.default.fileExists(atPath: confPath(name)) { fail("Неизвестный туннель: \(name)") }
    return name
}

/// Имя utun-интерфейса, если туннель поднят.
func activeInterface(_ name: String) -> String? {
    guard let iface = try? String(contentsOfFile: "\(runDir)/\(name).name", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !iface.isEmpty else { return nil }
    var st = stat()
    guard stat("\(runDir)/\(iface).sock", &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return nil }
    return iface
}

@discardableResult
func run(_ args: [String], input: String? = nil) -> (status: Int32, output: String) {
    // Вывод пишем во временный файл, а не в pipe: фоновые процессы wg-quick могут держать pipe открытым.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wgmenu-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let out = try? FileHandle(forWritingTo: tmp) else { return (1, "не удалось создать временный файл") }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = out
    p.standardError = out
    let inPipe = Pipe()
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    do { try p.run() } catch { return (1, error.localizedDescription) }
    if let input {
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
    }
    p.waitUntilExit()
    try? out.close()
    let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    return (p.terminationStatus, text)
}

func log(_ title: String, _ body: String = "") {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    var entry = "\(df.string(from: Date())) [\(caller)] \(title)\n"
    if !body.isEmpty { entry += body.hasSuffix("\n") ? body : body + "\n" }
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o644])
    }
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(Data(entry.utf8))
        try? h.close()
    }
}

/// wg-quick up/down с записью в журнал. При ошибке завершает процесс с хвостом вывода.
func wgQuick(_ action: String, _ name: String) {
    let r = run(["wg-quick", action, confPath(name)])
    if r.status == 0 {
        log("\(action) \(name)", r.output)
    } else {
        log("ОШИБКА \(action) \(name)", r.output)
        let tail = r.output.split(separator: "\n").suffix(6).joined(separator: "\n")
        fail(tail.isEmpty ? "wg-quick \(action) завершился с ошибкой" : tail)
    }
}

let isAdmin: Bool = {
    if caller == "root" { return true }
    return run(["dsmemberutil", "checkmembership", "-U", caller, "-G", "admin"]).output.contains("is a member")
}()

func readConf(_ name: String) -> String {
    guard let text = try? String(contentsOfFile: confPath(name), encoding: .utf8) else { fail("Не удалось прочитать \(name)") }
    return text
}

/// Заменяет значения секретов в тексте построчно.
func rewriteSecrets(_ text: String, _ replace: (_ entry: WGEntry, _ peerKey: String?) -> String?) -> String {
    let cfg = WGConfig(text)
    var byLine: [Int: (WGEntry, String?)] = [:]
    for s in cfg.sections {
        let peerKey = s.name.lowercased() == "peer" ? s.value("PublicKey") : nil
        for e in s.entries where WGConfig.secretKeys.contains(e.lkey) { byLine[e.line] = (e, peerKey) }
    }
    var lines = text.components(separatedBy: "\n")
    for (n, (e, peerKey)) in byLine {
        if let v = replace(e, peerKey) { lines[n - 1] = "\(e.key) = \(v)" }
    }
    return lines.joined(separator: "\n")
}

func masked(_ text: String) -> String {
    rewriteSecrets(text) { _, _ in hiddenSecret }
}

/// Возвращает скрытые секреты из старого конфига.
func unmasked(_ text: String, old: String?) -> String {
    let oldCfg = old.map(WGConfig.init)
    let oldPrivate = oldCfg?.interface?.value("PrivateKey")
    var oldPSK: [String: String] = [:]
    for p in oldCfg?.peers ?? [] {
        if let pk = p.value("PublicKey"), let psk = p.value("PresharedKey") { oldPSK[pk] = psk }
    }
    return rewriteSecrets(text) { e, peerKey in
        guard e.value == hiddenSecret else { return nil }
        let real = e.lkey == "privatekey" ? oldPrivate : peerKey.flatMap { oldPSK[$0] }
        guard let real else { fail("Строка \(e.line): укажите \(e.key) заново — прежнее значение не найдено") }
        return real
    }
}

func privilegedLines(_ text: String?) -> [String] {
    guard let text else { return [] }
    return WGConfig(text).sections.flatMap { s in
        s.entries.filter { WGConfig.privilegedKeys.contains($0.lkey) }.map { "\(s.name.lowercased()):\($0.lkey)=\($0.value)" }
    }.sorted()
}

func writeConf(_ name: String, _ text: String) {
    let tmp = "\(confDir)/.\(name).conf.tmp"
    let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
          chown(tmp, 0, 0) == 0, rename(tmp, confPath(name)) == 0 else {
        unlink(tmp)
        fail("Не удалось записать \(confPath(name))")
    }
}

func moveToDeleted(_ name: String) {
    let dir = "\(confDir)/.deleted"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stamp = Int(Date().timeIntervalSince1970)
    if rename(confPath(name), "\(dir)/\(name)-\(stamp).conf") != 0 { fail("Не удалось удалить \(name)") }
}

// MARK: - Команды

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? ""
let arg1 = args.count > 1 ? args[1] : nil
let arg2 = args.count > 2 ? args[2] : nil

switch cmd {
case "list":
    let files = (try? FileManager.default.contentsOfDirectory(atPath: confDir)) ?? []
    for f in files.sorted() where f.hasSuffix(".conf") {
        let name = String(f.dropLast(5))
        guard isValidTunnelName(name) else { continue }
        let cfg = WGConfig((try? String(contentsOfFile: confPath(name), encoding: .utf8)) ?? "")
        let flags = [cfg.setsDNS ? "dns" : nil, cfg.routesAllTraffic ? "inet" : nil].compactMap { $0 }
        print("\(name)\t\(activeInterface(name) == nil ? "down" : "up")\t\(flags.isEmpty ? "-" : flags.joined(separator: ","))")
    }

case "caps":
    print(isAdmin ? "admin" : "user")

case "get":
    let name = requireName(arg1)
    let text = readConf(name)
    print(isAdmin ? text : masked(text), terminator: "")

case "stats":
    let name = requireName(arg1)
    if let pk = WGConfig(readConf(name)).interface?.value("PrivateKey") {
        let r = run(["wg", "pubkey"], input: pk)
        if r.status == 0 { print("pubkey\t\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }
    if let iface = activeInterface(name) {
        print("iface\t\(iface)")
        let r = run(["wg", "show", iface, "dump"])
        for (i, line) in r.output.split(separator: "\n").enumerated() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if i == 0, f.count >= 3 {
                print("port\t\(f[2])")       // f[0] — приватный ключ, не выводим
            } else if f.count >= 8 {
                // public-key preshared-key endpoint allowed-ips latest-handshake rx tx keepalive
                print(["peer", f[0], f[2], f[3], f[4], f[5], f[6], f[7]].joined(separator: "\t"))
            }
        }
    }

case "up":
    let name = requireName(arg1)
    if activeInterface(name) == nil { wgQuick("up", name) }

case "down":
    let name = requireName(arg1)
    if activeInterface(name) != nil { wgQuick("down", name) }

case "save", "create":
    // create <имя>           — новый туннель, имя должно быть свободно
    // save <имя> <старое>    — изменение существующего, с переименованием, если имена разные
    let name = requireName(arg1, mustExist: false)
    let oldName = cmd == "save" ? requireName(arg2) : nil
    let renaming = oldName != nil && oldName != name
    if (cmd == "create" || renaming) && FileManager.default.fileExists(atPath: confPath(name)) {
        fail("Туннель «\(name)» уже существует")
    }
    let oldText = oldName.map(readConf)

    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let text = unmasked(input, old: oldText)
    let cfg = WGConfig(text)
    if !cfg.errors.isEmpty { fail(cfg.errors.joined(separator: "\n")) }
    if !isAdmin && privilegedLines(text) != privilegedLines(oldText) {
        fail("PreUp/PostUp/PreDown/PostDown/SaveConfig может менять только администратор")
    }

    let wasUp = oldName.map { activeInterface($0) != nil } ?? false
    if wasUp, let oldName { wgQuick("down", oldName) }
    writeConf(name, text)
    if renaming, let oldName { moveToDeleted(oldName) }
    log(renaming ? "save \(oldName!) -> \(name)" : "\(cmd) \(name)")
    if wasUp { wgQuick("up", name) }

case "delete":
    let name = requireName(arg1)
    if activeInterface(name) != nil { wgQuick("down", name) }
    moveToDeleted(name)
    log("delete \(name)")

case "log":
    if let h = FileHandle(forReadingAtPath: logPath) {
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 200_000 ? size - 200_000 : 0)
        print(String(decoding: h.readDataToEndOfFile(), as: UTF8.self), terminator: "")
    }

default:
    fail("Использование: list | caps | get | stats | up | down | create | save | delete | log")
}
