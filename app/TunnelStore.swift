import Foundation

let helperPath = "/Library/PrivilegedHelperTools/wgmenu-helper"
let wgPath = "/opt/homebrew/bin/wg"

struct CommandResult {
    let ok: Bool
    let out: String
    let err: String
    var message: String { (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Запуск без shell; блокирующий, поэтому вызывать не с главного потока (кроме быстрых `list`/`caps`).
func runCommand(_ path: String, _ args: [String], input: String? = nil) -> CommandResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = input == nil ? FileHandle.nullDevice : inp
    do { try p.run() } catch { return CommandResult(ok: false, out: "", err: error.localizedDescription) }
    if let input {
        inp.fileHandleForWriting.write(Data(input.utf8))
        try? inp.fileHandleForWriting.close()
    }
    var errData = Data()
    let errThread = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
    errThread.start()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    while errThread.isExecuting { usleep(1000) }
    return CommandResult(ok: p.terminationStatus == 0,
                         out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
}

func helper(_ args: [String], input: String? = nil) -> CommandResult {
    runCommand("/usr/bin/sudo", ["-n", helperPath] + args, input: input)
}

func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

struct Tunnel: Identifiable, Hashable {
    let name: String
    var up: Bool
    var setsDNS = false
    var routesAllTraffic = false
    var id: String { name }
}

struct PeerStats {
    let publicKey: String
    let endpoint: String?
    let allowedIPs: String
    let handshake: Date?
    let rx: Int64
    let tx: Int64
    let keepalive: String
}

struct TunnelStats {
    var publicKey: String?
    var iface: String?
    var listenPort: String?
    var peers: [String: PeerStats] = [:]

    init(_ text: String) {
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "pubkey" where f.count > 1: publicKey = f[1]
            case "iface" where f.count > 1: iface = f[1]
            case "port" where f.count > 1: listenPort = f[1]
            case "peer" where f.count >= 8:
                // peer, public-key, endpoint, allowed-ips, latest-handshake, rx, tx, keepalive
                let hs = TimeInterval(f[4]) ?? 0
                peers[f[1]] = PeerStats(publicKey: f[1],
                                        endpoint: f[2] == "(none)" ? nil : f[2],
                                        allowedIPs: f[3],
                                        handshake: hs > 0 ? Date(timeIntervalSince1970: hs) : nil,
                                        rx: Int64(f[5]) ?? 0, tx: Int64(f[6]) ?? 0,
                                        keepalive: f[7])
            default: break
            }
        }
    }
}

/// Общее состояние: список туннелей, их статусы и операции через помощника.
@MainActor
final class TunnelStore: ObservableObject {
    @Published private(set) var tunnels: [Tunnel] = []
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var listError: String?
    @Published private(set) var isAdmin = false
    /// Увеличивается после каждого изменения конфигов — по нему окна перечитывают данные.
    @Published private(set) var revision = 0

    var onChange: (() -> Void)?
    var openLog: ((String) -> Void)?

    init() {
        isAdmin = helper(["caps"]).out.hasPrefix("admin")
        reload()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var anyUp: Bool { tunnels.contains { $0.up } }

    /// Полный список через помощника (видит /etc/wireguard). Быстро, можно с главного потока.
    func reload() {
        let r = helper(["list"])
        if r.ok {
            listError = nil
            let fresh = r.out.split(separator: "\n").compactMap { line -> Tunnel? in
                let f = line.split(separator: "\t")
                guard f.count >= 2 else { return nil }
                let flags = f.count > 2 ? f[2].split(separator: ",") : []
                return Tunnel(name: String(f[0]), up: f[1] == "up",
                              setsDNS: flags.contains("dns"), routesAllTraffic: flags.contains("inet"))
            }
            if fresh != tunnels { tunnels = fresh }
        } else {
            listError = r.message.isEmpty ? "Помощник недоступен" : r.message
        }
        onChange?()
    }

    /// Состояние без sudo: /var/run/wireguard доступен на чтение всем. Так видно действия других пользователей.
    func refreshStatus() {
        let active = activeTunnelNames()
        var changed = tunnels
        for i in changed.indices { changed[i].up = active.contains(changed[i].name) }
        if changed != tunnels {
            tunnels = changed
            onChange?()
        }
    }

    func isUp(_ name: String) -> Bool { tunnels.first { $0.name == name }?.up ?? false }

    @discardableResult
    func setActive(_ name: String, _ up: Bool) async -> String? {
        busy.insert(name)
        onChange?()
        let r = await offMain { helper([up ? "up" : "down", name]) }
        busy.remove(name)
        refreshStatus()
        onChange?()
        return r.ok ? nil : (r.message.isEmpty ? "Ошибка wg-quick" : r.message)
    }

    func config(_ name: String) async -> Result<String, HelperError> {
        let r = await offMain { helper(["get", name]) }
        return r.ok ? .success(r.out) : .failure(HelperError(r.message))
    }

    func stats(_ name: String) async -> TunnelStats? {
        let r = await offMain { helper(["stats", name]) }
        return r.ok ? TunnelStats(r.out) : nil
    }

    /// oldName == nil — создание нового туннеля.
    func save(name: String, oldName: String?, text: String) async -> String? {
        let args = oldName.map { ["save", name, $0] } ?? ["create", name]
        busy.insert(oldName ?? name)
        let r = await offMain { helper(args, input: text) }
        busy.remove(oldName ?? name)
        reload()
        revision += 1
        return r.ok ? nil : r.message
    }

    func delete(_ name: String) async -> String? {
        busy.insert(name)
        let r = await offMain { helper(["delete", name]) }
        busy.remove(name)
        reload()
        revision += 1
        return r.ok ? nil : r.message
    }

    func log() async -> String {
        await offMain { helper(["log"]).out }
    }
}

struct HelperError: Error {
    let message: String
    init(_ m: String) { message = m }
}

func activeTunnelNames() -> Set<String> {
    let dir = "/var/run/wireguard"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var result = Set<String>()
    for f in files where f.hasSuffix(".name") {
        guard let iface = try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !iface.isEmpty else { continue }
        if FileManager.default.fileExists(atPath: "\(dir)/\(iface).sock") { result.insert(String(f.dropLast(5))) }
    }
    return result
}

/// Публичный ключ из приватного — `wg pubkey` работает без root.
func publicKey(fromPrivate key: String) -> String? {
    guard WGConfig.isKey(key) else { return nil }
    let r = runCommand(wgPath, ["pubkey"], input: key)
    return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

func generatePrivateKey() -> String? {
    let r = runCommand(wgPath, ["genkey"])
    return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}
