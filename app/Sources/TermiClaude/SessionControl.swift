import Foundation

/// Fermeture d'une session Claude Code : arret du process `claude`, puis fermeture de
/// l'onglet Terminal.app qui l'hebergeait.
///
/// Cette action est volontairement portee cote Swift et non par le coeur Python : le
/// collecteur (`termiclaude/collector.py`) est contractuellement en lecture seule
/// (aucune ecriture, aucun signal). Le widget reste donc la seule couche qui agisse.
enum SessionControl {

    /// Delai laisse a `claude` pour sortir proprement sur SIGTERM (il ferme sa session et
    /// nettoie son fichier d'etat) avant de passer a SIGKILL.
    private static let gracePeriod: TimeInterval = 3
    /// Delai d'attente apres SIGKILL (le noyau doit reaper le process).
    private static let killPeriod: TimeInterval = 1.5

    enum CloseError: Error {
        /// Le process n'existe plus : la session s'etait deja terminee.
        case gone
        /// Le pid ne correspond plus a une session Claude Code (pid recycle par le systeme).
        case notClaude(String)
        /// L'envoi du signal a echoue (permissions...).
        case signalFailed(String)
        /// Le process a survecu a SIGTERM **et** SIGKILL.
        case stillAlive

        var message: String {
            switch self {
            case .gone:
                return "Le process n'existait plus : la session s'etait deja terminee."
            case .notClaude(let command):
                return "Le pid ne correspond plus a une session Claude Code (\(command)) : "
                     + "aucun signal n'a ete envoye."
            case .signalFailed(let reason):
                return "Impossible d'arreter le process : \(reason)."
            case .stillAlive:
                return "Le process ne s'est pas arrete, meme apres SIGKILL."
            }
        }
    }

    /// Arrete la session `pid` (SIGTERM, puis SIGKILL en repli) et ferme son onglet Terminal.
    ///
    /// Bloquant (jusqu'a ~4,5 s dans le pire cas) : a appeler depuis une file de fond.
    static func close(pid: Int, tty: String?) -> Result<Void, CloseError> {
        // pid 0/1 = groupe de process courant / launchd : jamais une session claude.
        guard pid > 1, isAlive(pid) else { return .failure(.gone) }

        // Garde-fou anti pid recycle : le fichier d'etat peut designer un pid deja reattribue
        // a un autre programme. On ne signale que ce qui ressemble vraiment a `claude`.
        guard let command = command(of: pid) else { return .failure(.gone) }
        guard command.lowercased().contains("claude") else {
            return .failure(.notClaude(String(command.prefix(60))))
        }

        if Darwin.kill(pid_t(pid), SIGTERM) != 0 {
            let code = errno
            // ESRCH : le process vient de sortir de lui-meme -> on enchaine sur l'onglet.
            guard code == ESRCH else {
                return .failure(.signalFailed(String(cString: strerror(code))))
            }
        }

        if !waitForExit(pid, timeout: gracePeriod) {
            Darwin.kill(pid_t(pid), SIGKILL)
            if !waitForExit(pid, timeout: killPeriod) { return .failure(.stillAlive) }
        }

        if let tty { closeTerminalTab(tty: tty) }
        return .success(())
    }

    // MARK: - Process

    /// Le process existe-t-il ? EPERM = existe mais pas a nous -> vivant.
    private static func isAlive(_ pid: Int) -> Bool {
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Attend la disparition du process, par sondages de 100 ms. `false` = toujours vivant.
    private static func waitForExit(_ pid: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(100_000)
        }
        return !isAlive(pid)
    }

    /// Ligne de commande complete du process (`ps -o command=`), ou nil s'il a disparu.
    private static func command(of pid: Int) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "command="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    // MARK: - Onglet Terminal.app

    /// Ferme l'onglet Terminal.app dont le tty correspond, une fois le process arrete.
    ///
    /// Deux cas, verifies sur Terminal.app (macOS 26) :
    ///   - **fenetre a onglet unique** (cas courant : une session = une fenetre) ->
    ///     `close window`, qui ferme sans confirmation des lors que le shell est revenu au
    ///     prompt (ce que garantit l'attente de sortie de `claude` faite juste avant) ;
    ///   - **fenetre multi-onglets** -> `exit` envoye au shell de l'onglet vise. Le
    ///     dictionnaire AppleScript de Terminal n'expose pas `close` sur la classe `tab`
    ///     (il l'accepte en pratique, mais rien ne garantit qu'il ne fermerait pas la
    ///     fenetre entiere - donc les onglets voisins, potentiellement d'autres sessions).
    ///     On s'en tient au geste sur, quitte a laisser un onglet « [Process completed] »
    ///     que l'utilisateur refermera d'un ⌘W.
    ///
    /// Lance sans attendre la fin : si Terminal affichait une confirmation (profil configure
    /// pour toujours demander), l'attente bloquerait la file de fond du widget.
    private static func closeTerminalTab(tty: String) {
        guard tty.range(of: "^ttys[0-9]+$", options: .regularExpression) != nil else { return }
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        if (count of tabs of w) is 1 then
                            close w
                        else
                            do script "exit" in t
                        end if
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
}
