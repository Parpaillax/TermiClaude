import AppKit
import CoreServices

/// App de barre de menus (palier L2). NSStatusItem + rafraichissement FSEvents,
/// donnees via le coeur Python, badge/compteur, menu detaille et footer d'usage.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
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
        updateButton()
        rebuildMenu()
        startWatching()
        refreshSessions()
        refreshUsage()
        // Filet de securite si FSEvents rate un evenement ; l'usage bouge lentement.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }
        // L'endpoint d'usage est fortement rate-limite : on l'interroge avec parcimonie.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    // MARK: - Rafraichissement

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
        let menu = NSMenu()
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
                item.representedObject = session.tty
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
        let refresh = NSMenuItem(title: "Rafraichir", action: #selector(manualRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quitter HyperClaude", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
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
        let value = percent ?? 0
        let filled = max(0, min(10, Int((value / 100 * 10).rounded())))
        let bar = String(repeating: "▮", count: filled) + String(repeating: "▯", count: 10 - filled)
        let barColor: NSColor = (severity == "critical") ? .systemRed
            : (severity == "warning") ? .systemOrange : .systemBlue

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: label.padding(toLength: 8, withPad: " ", startingAt: 0), attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        ]))
        out.append(NSAttributedString(string: bar + "  ", attributes: [
            .foregroundColor: barColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        ]))
        out.append(NSAttributedString(string: Self.pct(percent), attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
        ]))
        item.attributedTitle = out
        return item
    }

    // MARK: - Actions

    /// Focus best-effort (L2) : active Hyper au premier plan. Le focus *precis* de la
    /// bonne fenetre viendra du plugin Hyper (L3), qui recevra le `tty` (representedObject).
    @objc private func focusSession(_ sender: NSMenuItem) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Hyper\" to activate"]
        try? proc.run()
    }

    @objc private func manualRefresh() {
        refreshSessions()
        refreshUsage()
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
            me.refreshSessions()
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
