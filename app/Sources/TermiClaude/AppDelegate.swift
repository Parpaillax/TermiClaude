import AppKit
import CoreServices

/// App de barre de menus (palier L2). NSStatusItem + rafraichissement FSEvents,
/// donnees via le coeur Python, badge/compteur, menu detaille et footer d'usage.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var menuOpen = false
    private var sessions: [Session] = []
    private var usage: Usage?
    private var eventStream: FSEventStreamRef?
    private var pollTimer: Timer?
    private var usageTimer: Timer?
    private let workQueue = DispatchQueue(label: "com.julienchateau.termiclaude.work", qos: .utility)

    // Libelle par statut.
    private static let labels: [String: String] = [
        "waiting": "attend une action",
        "busy":    "travaille",
        "idle":    "au repos",
        "unknown": "etat inconnu",
    ]

    /// Couleur adaptative : `light` en theme clair, `dark` en theme sombre.
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func color(for status: String) -> NSColor {
        switch status {
        case "waiting": return .systemOrange
        case "busy":    return .systemBlue
        case "idle":    return .systemGray
        default:        return .tertiaryLabelColor
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
        }
        menu.delegate = self
        statusItem.menu = menu
        updateButton()
        rebuildMenu()
        startWatching()
        refreshSessions()
        refreshUsage()
        // Filet de securite si FSEvents rate un evenement (sauf menu ouvert, pour ne pas le perturber).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.autoRefresh()
        }
        // L'endpoint d'usage est fortement rate-limite : on l'interroge avec parcimonie.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    // MARK: - Rafraichissement

    /// Rafraichissement automatique (timer / FSEvents) : ne perturbe pas un menu ouvert.
    private func autoRefresh() {
        if menuOpen { return }
        refreshSessions()
    }

    private func refreshSessions() {
        workQueue.async { [weak self] in
            let fetched = DataSource.sessions()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sessions = fetched
                self.updateButton()
                self.rebuildMenu()
            }
        }
    }

    private func refreshUsage() {
        workQueue.async { [weak self] in
            let fetched = DataSource.usage()
            DispatchQueue.main.async {
                guard let self else { return }
                // Garde le dernier usage fiable : un echec transitoire (429...) ne blanke pas
                // le footer. On ne remplace que par une valeur disponible, ou faute de cache.
                if let fetched, fetched.available {
                    self.usage = fetched
                } else if self.usage == nil {
                    self.usage = fetched
                }
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Icone / badge

    /// Glyphe monochrome Terminal x Claude (image template : s'inverse selon le theme de la barre).
    private static let glyph: NSImage = {
        if let url = Bundle.module.url(forResource: "menubar-template", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "TermiClaude") ?? NSImage()
    }()

    /// Icone de barre de menus. Sans attente : glyphe template (adaptatif natif).
    /// Avec attente : glyphe teinte selon le theme + pastille rouge dessinee avec compteur.
    private func statusImage(waiting: Int) -> NSImage {
        let h: CGFloat = 18
        if waiting == 0 {
            let img = (Self.glyph.copy() as? NSImage) ?? Self.glyph
            img.size = NSSize(width: h, height: h)
            img.isTemplate = true
            return img
        }
        let isDark = (statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let glyphColor = isDark ? NSColor.white : NSColor.black

        let size = NSSize(width: h + 4, height: h)
        let img = NSImage(size: size)
        img.lockFocus()
        let gRect = NSRect(x: 0, y: 0, width: h, height: h)
        Self.glyph.draw(in: gRect)
        // Recolore le glyphe (noir) vers la couleur adaptee au theme.
        glyphColor.set()
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSBezierPath(rect: gRect).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        // Pastille d'alerte.
        let d: CGFloat = 11
        let badge = NSRect(x: size.width - d, y: size.height - d, width: d, height: d)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let text = "\(min(waiting, 9))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
        ]
        let ts = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: badge.midX - ts.width / 2, y: badge.midY - ts.height / 2),
                  withAttributes: attrs)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let waiting = sessions.filter { $0.status == "waiting" }.count
        button.image = statusImage(waiting: waiting)
    }

    // MARK: - Menu

    /// Logo couleur pour le header du menu (inline).
    private static let headerLogo: NSImage? = {
        guard let url = Bundle.module.url(forResource: "menubar-icon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    private func rebuildMenu() {
        menu.removeAllItems()
        let waiting = sessions.filter { $0.status == "waiting" }.count

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let head = NSMutableAttributedString()
        if let logo = Self.headerLogo {
            let att = NSTextAttachment()
            att.image = logo
            att.bounds = CGRect(x: 0, y: -3, width: 15, height: 15)
            head.append(NSAttributedString(attachment: att))
            head.append(NSAttributedString(string: "  "))
        }
        head.append(NSAttributedString(string: "\(sessions.count) session(s) · \(waiting) en attente", attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        header.attributedTitle = head
        menu.addItem(header)
        menu.addItem(.separator())

        let newSessionItem = NSMenuItem(title: "Nouvelle session…", action: #selector(startNewSession), keyEquivalent: "n")
        newSessionItem.target = self
        menu.addItem(newSessionItem)
        menu.addItem(.separator())

        if sessions.isEmpty {
            menu.addItem(disabled("Aucune session Claude Code active"))
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: "",
                    action: session.focusable ? #selector(focusSession(_:)) : nil,
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.tty
                item.attributedTitle = Self.attributedRow(session)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if let usage, usage.available {
            menu.addItem(usageItem("Session", usage.sessionPercent, usage.sessionSeverity, usage.sessionResetsAt))
            menu.addItem(usageItem("Semaine", usage.weeklyPercent, usage.weeklySeverity, usage.weeklyResetsAt))
        } else {
            menu.addItem(disabled("Usage indisponible"))
        }

        menu.addItem(.separator())
        // Largeur de contenu du menu (mesuree sur les items deja ajoutes) pour que la vue
        // custom "Rafraichir" s'etende comme les autres lignes.
        let menuFont = NSFont.menuFont(ofSize: 13)
        var contentWidth: CGFloat = 180
        for it in menu.items {
            if let a = it.attributedTitle {
                contentWidth = max(contentWidth, a.size().width)
            } else if !it.title.isEmpty {
                contentWidth = max(contentWidth, (it.title as NSString).size(withAttributes: [.font: menuFont]).width)
            }
        }
        let rowWidth = contentWidth + 44

        // Rafraichir : vue custom -> ne ferme pas le menu au clic, mais style aligne sur le natif.
        let refresh = NSMenuItem(title: "Rafraichir", action: nil, keyEquivalent: "")
        refresh.view = MenuActionView(title: "Rafraichir maintenant", width: rowWidth) { [weak self] in
            self?.refreshSessions()
            self?.refreshUsage()
        }
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quitter TermiClaude", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Cale la vue custom sur la largeur reelle du menu (incluant "Quitter" + ⌘Q),
        // pour que le surlignage s'etende exactement comme les lignes natives.
        let fullWidth = menu.size.width
        if fullWidth > 1 {
            refresh.view?.setFrameSize(NSSize(width: fullWidth, height: 22))
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func pct(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(Int(value.rounded())) %"
    }

    /// Parseurs ISO8601 de l'API d'usage (avec et sans fraction de seconde).
    private static let isoParsers: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    /// Echeance de reset en heure locale : "reset 17h30" si c'est aujourd'hui,
    /// "reset 28/08 09h15" sinon. `nil` si la date est absente ou illisible.
    private static func resetLabel(_ iso: String?) -> String? {
        guard let iso,
              let date = isoParsers.lazy.compactMap({ $0.date(from: iso) }).first
        else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "fr_FR")
        fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH'h'mm" : "dd/MM HH'h'mm"
        return "reset " + fmt.string(from: date)
    }

    private static func shorten(_ path: String?) -> String {
        guard let path else { return "-" }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    /// Ligne de session sur deux niveaux : puce coloree + titre en gras, puis sous-ligne dim.
    private static func attributedRow(_ s: Session) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        para.lineBreakMode = .byTruncatingTail

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: color(for: s.status),
            .font: NSFont.systemFont(ofSize: 12),
        ]))
        let title = truncate(s.title ?? s.name ?? "pid \(s.pid)", 52)
        out.append(NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ]))

        let label = labels[s.status] ?? labels["unknown"]!
        var sub = "\(label) · \(shorten(s.cwd)) · \(s.tty ?? "—")"
        if let waitingFor = s.waitingFor { sub += " · \(waitingFor)" }
        if s.stale { sub += " · inactive" }
        out.append(NSAttributedString(string: "\n" + sub, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11),
        ]))

        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Ligne d'usage : libelle + mini barre + pourcentage, et sous-ligne d'echeance de reset.
    private func usageItem(_ label: String, _ percent: Double?, _ severity: String?, _ resetsAt: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        let slots = 12
        let value = percent ?? 0
        let filled = max(0, min(slots, Int((value / 100 * Double(slots)).rounded())))
        // Gris fonce (texte + piste) et bleu fonce, adaptatifs clair/sombre.
        let textColor = Self.dyn(NSColor(white: 0.22, alpha: 1), NSColor(white: 0.88, alpha: 1))
        let trackColor = Self.dyn(NSColor(white: 0.80, alpha: 1), NSColor(white: 0.35, alpha: 1))
        let darkBlue = Self.dyn(NSColor(srgbRed: 0.11, green: 0.29, blue: 0.63, alpha: 1),
                                NSColor(srgbRed: 0.42, green: 0.60, blue: 0.95, alpha: 1))
        let barColor: NSColor = (severity == "critical") ? .systemRed
            : (severity == "warning") ? .systemOrange : darkBlue
        let barFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: label.padding(toLength: 8, withPad: " ", startingAt: 0), attributes: [
            .foregroundColor: textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        ]))
        // Blocs pleins : partie remplie en couleur, piste en gris fonce solide.
        out.append(NSAttributedString(string: String(repeating: "█", count: filled), attributes: [
            .foregroundColor: barColor, .font: barFont,
        ]))
        out.append(NSAttributedString(string: String(repeating: "█", count: slots - filled), attributes: [
            .foregroundColor: trackColor, .font: barFont,
        ]))
        out.append(NSAttributedString(string: "  " + Self.pct(percent), attributes: [
            .foregroundColor: textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
        ]))
        // Sous-ligne dim, alignee sous la barre : quand le quota repart a zero.
        if let reset = Self.resetLabel(resetsAt) {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 2
            let indent = String(repeating: " ", count: 8)
            out.append(NSAttributedString(string: "\n" + indent + reset, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            ]))
            out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        }
        item.attributedTitle = out
        return item
    }

    // MARK: - Actions

    /// Focus (L3) : Terminal.app expose nativement le `tty` de chaque onglet en AppleScript
    /// (`tty of tab`), donc pas besoin de plugin compagnon. On selectionne
    /// directement l'onglet correspondant et on met sa fenetre au premier plan ; repli sur
    /// une simple activation de Terminal si le tty n'est pas resolu ou introuvable.
    @objc private func focusSession(_ sender: NSMenuItem) {
        if let tty = sender.representedObject as? String {
            Self.focusTerminalTab(tty: tty)
        } else {
            Self.activateTerminal()
        }
    }

    /// Selectionne l'onglet Terminal.app dont le tty correspond et avance sa fenetre au
    /// premier plan. `tty` doit etre au format produit par le collecteur (ex. "ttys016") ;
    /// on le valide avant de l'interpoler dans l'AppleScript.
    private static func focusTerminalTab(tty: String) {
        guard tty.range(of: "^ttys[0-9]+$", options: .regularExpression) != nil else {
            activateTerminal()
            return
        }
        let devTty = "/dev/\(tty)"
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(devTty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    private static func activateTerminal() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Terminal\" to activate"]
        try? proc.run()
    }

    /// Options exposees dans le formulaire "Nouvelle session" (flags CLI `claude --help`).
    private enum ClaudeModel: String, CaseIterable {
        case defaultValue = "", sonnet, opus, fable, haiku
        var label: String {
            switch self {
            case .defaultValue: return "Par defaut"
            case .sonnet: return "Sonnet"
            case .opus: return "Opus"
            case .fable: return "Fable"
            case .haiku: return "Haiku"
            }
        }
    }

    private enum ClaudeEffort: String, CaseIterable {
        case defaultValue = "", low, medium, high, xhigh, max
        var label: String {
            switch self {
            case .defaultValue: return "Par defaut"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .xhigh: return "Xhigh"
            case .max: return "Max"
            }
        }
    }

    private enum ClaudePermissionMode: String, CaseIterable {
        case defaultValue = "", manual, plan, auto, acceptEdits, dontAsk, bypassPermissions
        var label: String {
            switch self {
            case .defaultValue: return "Par defaut"
            case .manual: return "Manuel"
            case .plan: return "Plan"
            case .auto: return "Auto"
            case .acceptEdits: return "Accepter les edits"
            case .dontAsk: return "Ne jamais demander"
            case .bypassPermissions: return "Ignorer les permissions"
            }
        }
    }

    private static func makePopup(titles: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return popup
    }

    private static func makeFormRow(_ label: String, _ control: NSView) -> NSStackView {
        let text = NSTextField(labelWithString: label)
        text.font = NSFont.systemFont(ofSize: 12)
        text.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let row = NSStackView(views: [text, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// Construit le formulaire d'options (modele/effort/mode/Ultracode), affiche dans une
    /// NSAlert plutot que comme accessoryView de NSOpenPanel : depuis macOS 10.15, le panneau
    /// de choix de fichier tourne dans un processus systeme separe qui ignore silencieusement
    /// les accessory views personnalisees, alors qu'une NSAlert reste hebergee dans notre
    /// propre process et s'affiche de facon fiable.
    private static func makeSessionOptionsView(
        modelPopup: NSPopUpButton,
        effortPopup: NSPopUpButton,
        modePopup: NSPopUpButton,
        ultracodeCheckbox: NSButton
    ) -> NSView {
        let stack = NSStackView(views: [
            makeFormRow("Modele", modelPopup),
            makeFormRow("Effort", effortPopup),
            makeFormRow("Mode", modePopup),
            ultracodeCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }

    /// "Nouvelle session" : NSAlert de configuration (modele, effort, mode de permission,
    /// Ultracode), puis panneau natif de choix de dossier, puis ouverture d'une fenetre
    /// Terminal.app avec `claude` lance dans ce dossier (repo de code selectionne).
    @objc private func startNewSession() {
        let modelPopup = Self.makePopup(titles: ClaudeModel.allCases.map(\.label))
        let effortPopup = Self.makePopup(titles: ClaudeEffort.allCases.map(\.label))
        let modePopup = Self.makePopup(titles: ClaudePermissionMode.allCases.map(\.label))
        if let autoIndex = ClaudePermissionMode.allCases.firstIndex(of: .auto) {
            modePopup.selectItem(at: autoIndex)
        }
        let ultracodeCheckbox = NSButton(
            checkboxWithTitle: "Activer Ultracode (orchestration multi-agents)",
            target: nil, action: nil
        )

        let alert = NSAlert()
        alert.messageText = "Nouvelle session Claude"
        alert.informativeText = "Configurer la session, puis choisir le dossier du projet."
        alert.addButton(withTitle: "Choisir le dossier…")
        alert.addButton(withTitle: "Annuler")
        alert.accessoryView = Self.makeSessionOptionsView(
            modelPopup: modelPopup, effortPopup: effortPopup,
            modePopup: modePopup, ultracodeCheckbox: ultracodeCheckbox
        )

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.title = "Nouvelle session Claude"
        panel.message = "Choisir le dossier du projet (repo de code)"
        panel.prompt = "Ouvrir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Self.launchClaudeSession(
            at: url.path,
            model: ClaudeModel.allCases[modelPopup.indexOfSelectedItem],
            effort: ClaudeEffort.allCases[effortPopup.indexOfSelectedItem],
            permissionMode: ClaudePermissionMode.allCases[modePopup.indexOfSelectedItem],
            ultracode: ultracodeCheckbox.state == .on
        )
    }

    /// Ouvre une nouvelle fenetre Terminal.app positionnee sur `path` et y lance `claude`
    /// avec les flags correspondant aux options choisies. Le chemin est echappe pour le
    /// shell (quotes simples) puis pour l'AppleScript (guillemets/antislash) avant d'etre
    /// interpole dans le script.
    private static func launchClaudeSession(
        at path: String,
        model: ClaudeModel,
        effort: ClaudeEffort,
        permissionMode: ClaudePermissionMode,
        ultracode: Bool
    ) {
        let shellQuoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"

        var args = ["claude"]
        if !model.rawValue.isEmpty { args += ["--model", model.rawValue] }
        if !effort.rawValue.isEmpty { args += ["--effort", effort.rawValue] }
        if !permissionMode.rawValue.isEmpty { args += ["--permission-mode", permissionMode.rawValue] }
        if ultracode { args += ["ultracode"] }

        let command = "cd \(shellQuoted) && \(args.joined(separator: " "))"
        let appleScriptEscaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - FSEvents (reactivite quasi-instantanee)

    private func startWatching() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            me.autoRefresh()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}

// MARK: - Suivi de l'etat ouvert/ferme du menu

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refreshSessions()   // donnees fraiches a l'ouverture (local, peu couteux)
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }
}

// MARK: - Item de menu cliquable qui ne ferme PAS le menu

/// Vue custom pour un item de menu : declenche une action au clic sans dismisser le menu
/// (contrairement a un NSMenuItem standard). Gere le surlignage au survol.
final class MenuActionView: NSView {
    private let title: String
    private let onClick: () -> Void

    init(title: String, width: CGFloat, onClick: @escaping () -> Void) {
        self.title = title
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        // S'etire a la largeur reelle de l'item de menu (comme les lignes natives).
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supporte") }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            // Meme inset/rayon que le surlignage natif des items de menu (macOS moderne).
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 7, yRadius: 7).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            .font: NSFont.menuFont(ofSize: 13),
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attrs)
        // Alignement horizontal sur le texte des items natifs.
        text.draw(at: NSPoint(x: 18, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        onClick()
        // Volontairement : pas de cancelTracking -> le menu reste ouvert.
        needsDisplay = true
    }
}
