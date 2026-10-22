import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Окно управления

struct ManagerView: View {
    @EnvironmentObject var store: TunnelStore
    @State private var selection: String?
    @State private var draft: String?          // текст нового туннеля, пока он создаётся
    @State private var message: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.tunnels) { t in
                    HStack(spacing: 8) {
                        StatusDot(up: t.up, busy: store.busy.contains(t.name))
                        Text(t.name)
                    }
                    .tag(t.name)
                    .contextMenu {
                        Button(t.up ? "Деактивировать" : "Активировать") { toggle(t) }
                        Button("Журнал") { store.openLog?(t.name) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("Новый пустой туннель") { newTunnel() }
                        Button("Импорт из файла (.conf или .zip)…") { importFiles() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Добавить туннель")
                    Spacer()
                    Button { store.openLog?("") } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Журнал")
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let text = draft {
                TunnelEditor(oldName: nil, name: "", text: text, isUp: false, knownPublicKey: nil) { saved in
                    draft = nil
                    if let saved { selection = saved }
                }
            } else if let name = selection, store.tunnels.contains(where: { $0.name == name }) {
                TunnelDetail(name: name) { selection = $0 }
                    .id(name)
            } else {
                ContentUnavailableView(store.listError ?? (store.tunnels.isEmpty ? "Туннелей нет" : "Выберите туннель"),
                                       systemImage: "network")
            }
        }
        .onChange(of: selection) { _, new in if new != nil { draft = nil } }
        .onAppear { if selection == nil { selection = store.tunnels.first?.name } }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func toggle(_ t: Tunnel) {
        Task { if let err = await store.setActive(t.name, !t.up) { message = err } }
    }

    private func newTunnel() {
        selection = nil
        draft = "[Interface]\nPrivateKey = \(generatePrivateKey() ?? "")\nAddress = \n\n[Peer]\nPublicKey = \nAllowedIPs = \nEndpoint = \n"
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText, .zip]
        panel.message = "Выберите файлы .conf или zip, выгруженный из WireGuard"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            var report: [String] = []
            var taken = Set(store.tunnels.map(\.name))
            for (fileName, text) in await offMain({ readConfigs(urls) }) {
                var name = sanitizeTunnelName(fileName)
                if name.isEmpty { name = "tunnel" }
                let base = String(name.prefix(12))
                var i = 2
                while taken.contains(name) { name = "\(base)-\(i)"; i += 1 }
                if let err = await store.save(name: name, oldName: nil, text: text) {
                    report.append("✗ \(fileName): \(err)")
                } else {
                    taken.insert(name)
                    report.append(name == fileName ? "✓ \(name)" : "✓ \(name) (было: \(fileName))")
                }
            }
            message = report.isEmpty ? "В выбранных файлах нет конфигов .conf" : report.joined(separator: "\n")
        }
    }
}

/// Читает .conf и .conf из zip. Возвращает (имя файла без расширения, текст).
private func readConfigs(_ urls: [URL]) -> [(String, String)] {
    var result: [(String, String)] = []
    for url in urls {
        if url.pathExtension.lowercased() == "zip" {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: tmp) }
            _ = runCommand("/usr/bin/unzip", ["-q", "-j", url.path, "*.conf", "-d", tmp.path])
            let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            for f in files.sorted(by: { $0.path < $1.path }) where f.pathExtension == "conf" {
                if let t = try? String(contentsOf: f, encoding: .utf8) { result.append((f.deletingPathExtension().lastPathComponent, t)) }
            }
        } else if let t = try? String(contentsOf: url, encoding: .utf8) {
            result.append((url.deletingPathExtension().lastPathComponent, t))
        }
    }
    return result
}

struct StatusDot: View {
    let up: Bool
    var busy = false
    var body: some View {
        Circle()
            .fill(busy ? Color.yellow : up ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 9, height: 9)
    }
}

// MARK: - Карточка туннеля

struct TunnelDetail: View {
    let name: String
    let onRenamed: (String) -> Void
    @EnvironmentObject var store: TunnelStore
    @State private var configText: String?
    @State private var loadError: String?
    @State private var stats: TunnelStats?
    @State private var editing = false
    @State private var actionError: String?
    @State private var confirmDelete = false

    init(name: String, onRenamed: @escaping (String) -> Void) {
        self.name = name
        self.onRenamed = onRenamed
    }

    private var up: Bool { store.isUp(name) }
    private var busy: Bool { store.busy.contains(name) }
    private var cfg: WGConfig? { configText.map(WGConfig.init) }

    var body: some View {
        Group {
            if editing, let text = configText {
                TunnelEditor(oldName: name, name: name, text: text, isUp: up, knownPublicKey: stats?.publicKey) { saved in
                    editing = false
                    if let saved, saved != name { onRenamed(saved) } else { Task { await load() } }
                }
            } else {
                details
            }
        }
        .task { await load() }
        .task(id: up) {
            // Статистика раз в секунду, пока карточка открыта; для выключенного туннеля — один раз (ради ключа).
            repeat {
                stats = await store.stats(name)
                if !up { break }
                try? await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled
        }
        .onChange(of: store.revision) { Task { await load() } }
    }

    private func load() async {
        switch await store.config(name) {
        case .success(let t): configText = t; loadError = nil
        case .failure(let e): loadError = e.message
        }
    }

    @ViewBuilder private var details: some View {
        VStack(spacing: 0) {
            Form {
                if let loadError {
                    Section { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                interfaceSection
                if let cfg {
                    ForEach(Array(cfg.peers.enumerated()), id: \.offset) { i, peer in
                        peerSection(peer, index: i, total: cfg.peers.count)
                    }
                    warningsSection(cfg)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Изменить") { editing = true }
                    .disabled(configText == nil || busy)
                Button("Журнал") { store.openLog?(name) }
                Spacer()
                Button("Удалить…", role: .destructive) { confirmDelete = true }
                    .disabled(busy)
            }
            .padding(12)
        }
        .confirmationDialog("Удалить туннель «\(name)»?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) {
                Task { if let err = await store.delete(name) { actionError = err } }
            }
        } message: {
            Text("Конфиг будет перемещён в /etc/wireguard/.deleted — его можно восстановить вручную.")
        }
        .alert(actionError ?? "", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        }
    }

    private var interfaceSection: some View {
        let iface = cfg?.interface
        return Section {
            LabeledContent("Статус") {
                HStack(spacing: 10) {
                    StatusDot(up: up, busy: busy)
                    Text(busy ? (up ? "Отключается…" : "Подключается…") : up ? "Активен" : "Неактивен")
                    Button(up ? "Деактивировать" : "Активировать") {
                        Task { if let err = await store.setActive(name, !up) { actionError = err } }
                    }
                    .disabled(busy)
                }
            }
            if let pk = stats?.publicKey { row("Публичный ключ", pk, mono: true) }
            if let port = stats?.listenPort ?? iface?.value("ListenPort") { row("Порт", port) }
            if let a = iface?.list("Address"), !a.isEmpty { row("Адреса", a.joined(separator: ", ")) }
            if let d = iface?.list("DNS"), !d.isEmpty { row("DNS-серверы", d.joined(separator: ", ")) }
            if let mtu = iface?.value("MTU") { row("MTU", mtu) }
            if up, let i = stats?.iface { row("Интерфейс", i) }
        } header: {
            Text("Интерфейс: \(name)").font(.headline)
        }
    }

    private func peerSection(_ peer: WGSection, index: Int, total: Int) -> some View {
        let key = peer.value("PublicKey") ?? ""
        let live = up ? stats?.peers[key] : nil
        return Section(total > 1 ? "Пир \(index + 1)" : "Пир") {
            row("Публичный ключ", key, mono: true)
            if peer.value("PresharedKey") != nil { row("Общий ключ", "включён") }
            if let ep = live?.endpoint ?? peer.value("Endpoint") { row("Endpoint", ep) }
            row("Разрешённые IP", peer.list("AllowedIPs").joined(separator: ", "))
            if let ka = peer.value("PersistentKeepalive"), ka != "off", ka != "0" { row("Keepalive", "каждые \(ka) с") }
            if up {
                row("Последнее рукопожатие", live?.handshake.map(relative) ?? "не было")
                if let live { row("Трафик", "↓ \(bytes(live.rx))   ↑ \(bytes(live.tx))") }
                diagnosis(live, keepalive: peer.value("PersistentKeepalive"))
            }
        }
    }

    @ViewBuilder
    private func diagnosis(_ live: PeerStats?, keepalive: String?) -> some View {
        let age = live?.handshake.map { Date().timeIntervalSince($0) }
        if let age, age < 180 {
            Label("Соединение установлено", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if age == nil {
            Label("Нет рукопожатия. Проверьте, что Endpoint доступен, UDP-порт открыт, а ключи совпадают с сервером. "
                  + "Если трафика в эту сеть ещё не было — откройте любой адрес из «Разрешённых IP».",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if keepalive == nil || keepalive == "off" || keepalive == "0" {
            Label("Рукопожатие было давно: трафика нет, это нормально без PersistentKeepalive.",
                  systemImage: "moon.zzz").foregroundStyle(.secondary)
        } else {
            Label("Рукопожатие было давно, хотя включён Keepalive — связь с сервером потеряна.",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func warningsSection(_ cfg: WGConfig) -> some View {
        let notes = configNotes(cfg)
        if !notes.isEmpty {
            Section("Проверка конфига") {
                ForEach(notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
    }

    private func configNotes(_ cfg: WGConfig) -> [String] {
        var notes = cfg.errors
        if !(cfg.interface?.list("DNS").isEmpty ?? true) {
            notes.append("Задан DNS: wg-quick заменит системный DNS, и при нескольких активных туннелях они будут мешать друг другу.")
        }
        let all = cfg.peers.flatMap { $0.list("AllowedIPs") }
        if all.contains("0.0.0.0/0") || all.contains("::/0") {
            notes.append("AllowedIPs содержит 0.0.0.0/0 — через этот туннель пойдёт весь трафик.")
        }
        return notes
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

private func relative(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "\(s) с назад" }
    if s < 3600 { return "\(s / 60) мин \(s % 60) с назад" }
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "ru_RU")
    return f.localizedString(for: d, relativeTo: Date())
}

private func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}

// MARK: - Редактор

struct TunnelEditor: View {
    let oldName: String?
    let isUp: Bool
    let knownPublicKey: String?
    let onDone: (String?) -> Void
    @EnvironmentObject var store: TunnelStore
    @State private var name: String
    @State private var text: String
    @State private var saving = false
    @State private var error: String?
    @State private var pubkey: String?

    init(oldName: String?, name: String, text: String, isUp: Bool, knownPublicKey: String?, onDone: @escaping (String?) -> Void) {
        self.oldName = oldName
        self.isUp = isUp
        self.knownPublicKey = knownPublicKey
        self.onDone = onDone
        _name = State(initialValue: name)
        _text = State(initialValue: text)
    }

    private var cfg: WGConfig { WGConfig(text) }
    private var privateKey: String? { cfg.interface?.value("PrivateKey") }
    private var nameError: String? {
        if !isValidTunnelName(name) { return "Имя: латиница, цифры и _=+.- , до 15 символов" }
        if name != oldName && store.tunnels.contains(where: { $0.name == name }) { return "Туннель с таким именем уже есть" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(oldName == nil ? "Новый туннель" : "Изменение туннеля").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Имя:").foregroundStyle(.secondary)
                    TextField("например, work1", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
                GridRow {
                    Text("Публичный ключ:").foregroundStyle(.secondary)
                    Text(pubkey ?? "—").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }

            ConfigEditor(text: $text)
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            VStack(alignment: .leading, spacing: 4) {
                if let nameError { problem(nameError) }
                ForEach(cfg.errors.prefix(6), id: \.self) { problem($0) }
                if let error { problem(error) }
                if !store.isAdmin {
                    note("Секретные ключи скрыты как \(hiddenSecret) и сохранятся без изменений. "
                         + "Менять PreUp/PostUp/PreDown/PostDown может только администратор.")
                }
                if isUp { note("Туннель активен — после сохранения он будет перезапущен.") }
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Отменить") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Сохранение…" : "Сохранить") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || nameError != nil || !cfg.errors.isEmpty)
            }
        }
        .padding(16)
        .onAppear { updatePubkey() }
        .onChange(of: privateKey) { updatePubkey() }
    }

    private func updatePubkey() {
        if let pk = privateKey, pk != hiddenSecret { pubkey = publicKey(fromPrivate: pk) } else { pubkey = knownPublicKey }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            let err = await store.save(name: name, oldName: oldName, text: text)
            saving = false
            if let err { error = err } else { onDone(name) }
        }
    }

    private func problem(_ s: String) -> some View {
        Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
    }

    private func note(_ s: String) -> some View {
        Label(s, systemImage: "info.circle").foregroundStyle(.secondary)
    }
}

// MARK: - Журнал

struct LogView: View {
    @EnvironmentObject var store: TunnelStore
    @Binding var filter: String
    @State private var text = ""

    private var shown: String {
        guard !filter.isEmpty else { return text }
        // Записи начинаются со строки с датой; показываем целиком те, где встречается фильтр.
        var entries: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \["#, options: .regularExpression) != nil || entries.isEmpty {
                entries.append(line)
            } else {
                entries[entries.count - 1] += "\n" + line
            }
        }
        return entries.filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Фильтр (имя туннеля, пользователь, ОШИБКА…)", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button("Обновить") { Task { text = await store.log() } }
            }
            .padding(10)
            ConfigEditor(text: .constant(shown.isEmpty ? "Записей нет" : shown), editable: false, highlight: false, scrollToEnd: true)
        }
        .frame(minWidth: 640, minHeight: 400)
        .task {
            while !Task.isCancelled {
                text = await store.log()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
