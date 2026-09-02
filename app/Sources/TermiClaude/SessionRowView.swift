import AppKit

/// Ligne de session dans le menu : le titre sur deux niveaux, et un bouton de fermeture
/// (croix) revele au survol, a droite.
///
/// Vue custom plutot que `NSMenuItem.attributedTitle` : c'est le seul moyen d'avoir deux
/// zones cliquables distinctes sur une meme ligne (corps = focus de l'onglet, croix =
/// fermeture de la session). Un `NSMenuItem` n'expose qu'une seule action, et un sous-menu
/// aurait coute un clic de plus pour l'action principale (le focus).
///
/// Le titre est fourni par une closure prenant l'etat de surlignage : les couleurs du texte
/// doivent changer sur fond bleu, et AppKit ne recolore pas un titre attribue.
final class SessionRowView: NSView {

    private let title: (Bool) -> NSAttributedString
    private let onSelect: (() -> Void)?
    private let onClose: () -> Void
    private var closeHovered = false

    /// Retrait gauche du texte : aligne sur les items de menu natifs.
    private static let textInset: CGFloat = 18
    /// Cote de la zone cliquable de la croix, et sa marge droite.
    private static let closeSide: CGFloat = 24
    private static let closeMargin: CGFloat = 8
    /// Marge verticale autour du bloc de texte.
    private static let verticalPadding: CGFloat = 6

    /// Marqueur de la zone de survol dediee a la croix (cf. `updateTrackingAreas`).
    private static let closeAreaKey = "close"

    init(
        width: CGFloat,
        title: @escaping (Bool) -> NSAttributedString,
        onSelect: (() -> Void)?,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.onSelect = onSelect
        self.onClose = onClose
        let height = ceil(title(false).size().height) + Self.verticalPadding * 2
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // S'etire a la largeur reelle de l'item de menu (comme les lignes natives).
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supporte") }

    /// Repere haut-gauche : le texte multi-ligne se dessine vers le bas.
    override var isFlipped: Bool { true }

    /// Zone cliquable de la croix (bord droit de la ligne).
    private var closeRect: NSRect {
        NSRect(
            x: bounds.maxX - Self.closeSide - Self.closeMargin,
            y: (bounds.height - Self.closeSide) / 2,
            width: Self.closeSide,
            height: Self.closeSide
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            // Meme inset/rayon que le surlignage natif des items de menu (macOS moderne).
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 7, yRadius: 7).fill()
        }

        let text = title(highlighted)
        let textWidth = max(40, closeRect.minX - Self.textInset - 4)
        let textHeight = ceil(text.size().height)
        text.draw(with: NSRect(x: Self.textInset,
                               y: (bounds.height - textHeight) / 2,
                               width: textWidth,
                               height: textHeight),
                  options: [.usesLineFragmentOrigin])

        // Croix revelee au survol de la ligne seulement : le menu reste sobre au repos.
        if highlighted { drawCloseButton() }
    }

    /// Croix dessinee au trait (pas de SF Symbol : la teinte d'un symbole sur fond bleu
    /// demande une config palette, et deux segments suffisent ici).
    private func drawCloseButton() {
        let rect = closeRect
        if closeHovered {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
        }
        let cross = rect.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cross.minX, y: cross.minY))
        path.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
        path.move(to: NSPoint(x: cross.minX, y: cross.maxY))
        path.line(to: NSPoint(x: cross.maxX, y: cross.minY))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        let stroke = closeHovered
            ? NSColor.white
            : NSColor.selectedMenuItemTextColor.withAlphaComponent(0.7)
        stroke.setStroke()
        path.stroke()
    }

    // MARK: - Survol

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Ligne entiere : rafraichit le surlignage, et suit la souris pour la croix.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        // Zone de la croix : entree/sortie fiables meme si `mouseMoved` n'est pas delivre
        // pendant le tracking du menu.
        addTrackingArea(NSTrackingArea(
            rect: closeRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: [Self.closeAreaKey: true]
        ))
    }

    private static func isCloseArea(_ event: NSEvent) -> Bool {
        (event.trackingArea?.userInfo?[closeAreaKey] as? Bool) == true
    }

    override func mouseEntered(with event: NSEvent) {
        if Self.isCloseArea(event) { closeHovered = true }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        // Sortie de la ligne comme de la croix : dans les deux cas la croix n'est plus visee.
        closeHovered = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let inside = closeRect.contains(convert(event.locationInWindow, from: nil))
        if inside != closeHovered {
            closeHovered = inside
            needsDisplay = true
        }
    }

    // MARK: - Clic

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) {
            // Comme un item natif : le menu se referme, l'action se joue ensuite.
            enclosingMenuItem?.menu?.cancelTracking()
            onClose()
            return
        }
        // Session non ciblable (tmux / SSH / detache) : ligne inerte, menu conserve.
        guard let onSelect else {
            needsDisplay = true
            return
        }
        enclosingMenuItem?.menu?.cancelTracking()
        onSelect()
    }
}
