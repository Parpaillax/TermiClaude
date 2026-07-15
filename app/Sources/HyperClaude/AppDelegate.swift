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

    // Presentation par statut : (puce, libelle).
    private static let styles: [String: (String, String)] = [
        "waiting": ("🟠", "attend une action"),
        "busy":    ("🔵", "travaille"),
        "idle":    ("⚪️", "au repos"),
        "unknown": ("⚫️", "etat inconnu"),
    ]

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
        usageTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
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
                self.usage = fetched
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Icone / badge

    /// Logo Hyper x Claude embarque (rendu couleur, non template).
    private static let logo: NSImage = {
        if let url = Bundle.module.url(forResource: "menubar-icon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "HyperClaude") ?? NSImage()
    }()

    /// Compose le logo avec une pastille (badge) portant le nombre de sessions en attente.
    private static func statusImage(waiting: Int) -> NSImage {
        let h: CGFloat = 18
        let size = NSSize(width: waiting > 0 ? h + 4 : h, height: h)
        let img = NSImage(size: size)
        img.lockFocus()
        logo.draw(in: NSRect(x: 0, y: 0, width: h, height: h),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        if waiting > 0 {
            let d: CGFloat = 11
            let rect = NSRect(x: size.width - d, y: size.height - d, width: d, height: d)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let text = "\(min(waiting, 9))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2),
                      withAttributes: attrs)
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let waiting = sessions.filter { $0.status == "waiting" }.count
        button.image = Self.statusImage(waiting: waiting)
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
                let (dot, label) = Self.styles[session.status] ?? Self.styles["unknown"]!
                let title = "\(dot) \(session.name ?? "pid \(session.pid)")"
                let item = NSMenuItem(
                    title: title,
                    action: session.focusable ? #selector(focusSession(_:)) : nil,
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.tty
                var tip = "\(label)\ndossier : \(session.cwd ?? "-")\nterminal : \(session.tty ?? "non resolu")"
                if let waitingFor = session.waitingFor { tip += "\nattend : \(waitingFor)" }
                if session.stale { tip += "\n(inactive)" }
                item.toolTip = tip
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if let usage, usage.available {
            menu.addItem(disabled("Session : \(Self.pct(usage.sessionPercent))"))
            menu.addItem(disabled("Semaine (all models) : \(Self.pct(usage.weeklyPercent))"))
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
