import Foundation

/// Passerelle vers le coeur Python `hyperclaude` (une seule source de verite).
///
/// L'app reste une couche de presentation : elle invoque `python3 -m hyperclaude`
/// (collecte des sessions) et `python3 -m hyperclaude.usage` (quota) et decode leur JSON.
enum DataSource {

    /// Racine du depot (contenant le paquet `hyperclaude`).
    /// Resolue en remontant depuis l'executable, avec repli sur $HYPERCLAUDE_REPO.
    static func repoRoot() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["HYPERCLAUDE_REPO"],
           fm.fileExists(atPath: env + "/hyperclaude/__init__.py") {
            return env
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("hyperclaude/__init__.py").path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// Lance `python3 <args>` avec PYTHONPATH sur la racine du depot ; renvoie stdout.
    private static func run(_ moduleArgs: [String]) -> Data? {
        guard let root = repoRoot() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3"] + moduleArgs
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = root
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return data
    }

    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return dec
    }

    static func sessions() -> [Session] {
        guard let data = run(["-m", "hyperclaude"]) else { return [] }
        return (try? decoder().decode([Session].self, from: data)) ?? []
    }

    /// L'usage peut etre indisponible (sortie code 1) mais le JSON est toujours emis.
    static func usage() -> Usage? {
        guard let data = run(["-m", "hyperclaude.usage"]) else { return nil }
        return try? decoder().decode(Usage.self, from: data)
    }
}
