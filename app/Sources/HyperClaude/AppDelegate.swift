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
    private let workQueue = DispatchQueue(label: "com.julienchateau.hyperclaude.work", qos: .utility)

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

    /// Glyphe monochrome Hyper x Claude (image template : s'inverse selon le theme de la barre).
    private static let glyph: NSImage = {
        if let url = Bundle.module.url(forResource: "menubar-template", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "HyperClaude") ?? NSImage()
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

    private func rebuildMenu() {
        menu.removeAllItems()
        let waiting = sessions.filter { $0.status == "waiting" }.count

        menu.addItem(disabled("\(sessions.count) session(s) · \(waiting) en attente"))
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
                var info: [String: Any] = [:]
                if let sp = session.shellPid { info["shellPid"] = sp }
                if let t = session.tty { info["tty"] = t }
                item.representedObject = info
                item.attributedTitle = Self.attributedRow(session)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if let usage, usage.available {
            menu.addItem(usageItem("Session", usage.sessionPercent, usage.sessionSeverity))
            menu.addItem(usageItem("Semaine", usage.weeklyPercent, usage.weeklySeverity))
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
        let quit = NSMenuItem(title: "Quitter HyperClaude", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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

    /// Ligne d'usage : libelle + mini barre + pourcentage.
    private func usageItem(_ label: String, _ percent: Double?, _ severity: String?) -> NSMenuItem {
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
        item.attributedTitle = out
        return item
    }

    // MARK: - Actions

    /// Focus (L3) : ecrit un ordre de focus (shellPid + tty) lu par le plugin Hyper qui
    /// met la bonne fenetre au premier plan, puis active Hyper (repli si plugin absent).
    @objc private func focusSession(_ sender: NSMenuItem) {
        if let info = sender.representedObject as? [String: Any] {
            Self.writeFocusRequest(shellPid: info["shellPid"] as? Int, tty: info["tty"] as? String)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Hyper\" to activate"]
        try? proc.run()
    }

    /// Canal IPC vers le plugin Hyper : ecrit ~/.hyperclaude/focus.json (ecriture atomique).
    private static func writeFocusRequest(shellPid: Int?, tty: String?) {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".hyperclaude")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = ["ts": Int(Date().timeIntervalSince1970 * 1000)]
        if let shellPid { obj["shellPid"] = shellPid }
        if let tty { obj["tty"] = tty }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let dst = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("focus.json"))
        try? data.write(to: dst, options: .atomic)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supporte") }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            // Meme inset/rayon que le surlignage natif des items de menu (macOS moderne).
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            .font: NSFont.menuFont(ofSize: 13),
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attrs)
        // Alignement horizontal sur le texte des items natifs (~ 21 px de marge gauche).
        text.draw(at: NSPoint(x: 21, y: (bounds.height - size.height) / 2), withAttributes: attrs)
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
