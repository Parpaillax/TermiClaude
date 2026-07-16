// Rasteriseur SVG -> PNG carre, fond transparent, plein cadre (via WKWebView).
// Remplace qlmanage (qui ajoute un fond blanc opaque et scale mal).
//
//   swiftc tools/svg2png.swift -o /tmp/svg2png -framework Cocoa -framework WebKit
//   /tmp/svg2png in.svg out.png 1024

import Cocoa
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]) else {
    FileHandle.standardError.write(Data("usage: svg2png <in.svg> <out.png> <size>\n".utf8))
    exit(2)
}
let svg = (try? String(contentsOf: URL(fileURLWithPath: args[1]), encoding: .utf8)) ?? ""
let outURL = URL(fileURLWithPath: args[2])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let size: Int
    let outURL: URL

    init(size: Int, outURL: URL) {
        self.size = size
        self.outURL = outURL
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size), configuration: cfg)
        super.init()
        webView.setValue(false, forKey: "drawsBackground") // fond transparent
        webView.navigationDelegate = self
    }

    func load(_ svg: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:0;background:transparent}
        svg{display:block;width:\(size)px;height:\(size)px}</style>
        </head><body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: size, height: size)
        cfg.afterScreenUpdates = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            webView.takeSnapshot(with: cfg) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write(Data("snapshot/encode failed: \(String(describing: error))\n".utf8))
                    exit(1)
                }
                do { try png.write(to: self.outURL) } catch {
                    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                    exit(1)
                }
                exit(0)
            }
        }
    }
}

let renderer = Renderer(size: size, outURL: outURL)
renderer.load(svg)
app.run()
