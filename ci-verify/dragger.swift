// Drives a real file drag (an NSDraggingSession from this helper) across OpenHoy's drop
// zone with synthesized mouse events, taking screenshots along the way.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = CommandLine.arguments[2]

func log(_ s: String) { print("DRAGGER", s) }

final class Source: NSView, NSDraggingSource {
    var started = false
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDown(with event: NSEvent) { log("mouseDown in source") }
    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }
        started = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 48, height: 48), contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
        log("drag session started")
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        log("drag ended operation=\(operation.rawValue)")
    }
    override func draw(_ r: NSRect) { NSColor.systemOrange.setFill(); bounds.fill() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = Source()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

func shot(_ name: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "\(outDir)/\(name).png"]
    try? p.run(); p.waitUntilExit()
}

func windows(owner: String) -> [(CGRect, Int)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard w[kCGWindowOwnerName as String] as? String == owner,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return (CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!), w[kCGWindowLayer as String] as? Int ?? 0)
    }
}

func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func glide(from a: CGPoint, to b: CGPoint, steps: Int = 25) {
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

DispatchQueue.global().async {
    Thread.sleep(forTimeInterval: 2)
    log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
    let ws = windows(owner: "OpenHoy")
    log("OpenHoy windows before: \(ws)")
    // Source window centre in CG (top-left) coordinates.
    let primaryH = NSScreen.screens[0].frame.height
    let start = CGPoint(x: 300, y: primaryH - 300)
    DispatchQueue.main.sync {
        post(.mouseMoved, start)
    }
    Thread.sleep(forTimeInterval: 0.3)
    post(.leftMouseDown, start)
    Thread.sleep(forTimeInterval: 0.2)
    var p = start
    for i in 1...8 { p = CGPoint(x: start.x + CGFloat(i) * 4, y: start.y - CGFloat(i) * 4); post(.leftMouseDragged, p); Thread.sleep(forTimeInterval: 0.03) }
    Thread.sleep(forTimeInterval: 0.8)
    let after = windows(owner: "OpenHoy")
    log("OpenHoy windows during drag: \(after)")
    shot("1-drag-started")
    guard let shelf = after.first(where: { $0.1 >= 100 && $0.0.width > 300 })?.0 else {
        log("NO SHELF WINDOW FOUND")
        post(.leftMouseUp, p)
        Thread.sleep(forTimeInterval: 1)
        exit(2)
    }
    // Zone is inset 24pt on the sides and bottom, flush at the top.
    let zone = CGRect(x: shelf.minX + 24, y: shelf.minY, width: shelf.width - 48, height: shelf.height - 24)
    log("zone \(zone)")
    var points: [CGPoint] = []
    for f in [0.12, 0.38, 0.62, 0.88] { points.append(CGPoint(x: zone.minX + zone.width * f, y: zone.midY)) }
    for (i, q) in points.enumerated() {
        glide(from: p, to: q)
        p = q
        Thread.sleep(forTimeInterval: 0.5)
        shot("2-over-\(i)")
    }
    // Drop on the second slice.
    glide(from: p, to: points[1]); p = points[1]
    Thread.sleep(forTimeInterval: 0.5)
    post(.leftMouseUp, p)
    Thread.sleep(forTimeInterval: 1.5)
    shot("3-after-drop")
    log("OpenHoy windows after drop: \(windows(owner: "OpenHoy"))")
    exit(0)
}
app.run()
