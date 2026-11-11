import AppKit
import CoreImage
import Combine
import SwiftUI

/// Shows every pinned person as a row of avatars in **one** status item.
///
/// Which avatar was clicked is resolved from the real cursor position on screen
/// (`NSEvent.mouseLocation`) against each avatar's on-screen rect. Event-relative
/// coordinates are only a fallback, because on recent macOS releases clicks on status
/// items can arrive forwarded/synthesized with coordinates that don't match the avatar
/// under the pointer. Clicks are accepted both as raw mouse events on the strip and via
/// the status button's action, whichever path macOS uses.
@MainActor
final class StatusBarController: NSObject {
    static private(set) var shared: StatusBarController?

    private let item: NSStatusItem
    private let strip = AvatarStripView()
    private var cancellables = Set<AnyCancellable>()
    private let tooltip = AvatarTooltip()
    private let dropShelf = DropShelfController()

    var onOpenSettings: (() -> Void)?
    var onStopScreenRecording: (() -> Void)?

    private var state: AppState { .shared }

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        Self.shared = self
        item.autosaveName = "OpenHoyAvatars"
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.imagePosition = .noImage
            // Fallback path: if macOS delivers the click to the button rather than our view.
            button.target = self
            button.action = #selector(buttonAction(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            strip.frame = button.bounds
            strip.autoresizingMask = [.width, .height]
            button.addSubview(strip)
        }
        strip.onActivate = { [weak self] hit, rightClick in self?.activate(hit, rightClick: rightClick) }
        strip.onDropFiles = { [weak self] guid, urls in self?.dropped(urls, on: guid) }
        strip.onHover = { [weak self] guid in self?.hover(guid) }
        strip.onWidthChange = { [weak self] width in
            guard let self, abs(self.item.length - width) > 0.25 else { return }
            self.item.length = width
        }

        dropShelf.targets = { [weak self] in
            guard let self else { return [] }
            return self.strip.entries.map { DropShelfController.Target(guid: $0.guid, name: $0.person.firstName, image: $0.person.image) }
        }
        dropShelf.anchor = { [weak self] in self?.strip.window == nil ? nil : self?.strip.screenBounds }
        dropShelf.isEnabled = { AppState.shared.dropShelf }
        dropShelf.onVisibilityChange = { [weak self] open in
            self?.tooltip.hide()
            self?.strip.setShelfOpen(open)
        }
        dropShelf.onTargetChange = { [weak self] guid in self?.strip.setShelfTarget(guid) }
        dropShelf.onDrop = { [weak self] guid, urls in self?.dropped(urls, on: guid) }

        Publishers.MergeMany(
            state.$pinnedGUIDs.map { _ in () }.eraseToAnyPublisher(),
            state.$unread.map { _ in () }.eraseToAnyPublisher(),
            state.$drafts.map { _ in () }.eraseToAnyPublisher(),
            state.$openChatGUID.map { _ in () }.eraseToAnyPublisher(),
            state.$contactsVersion.map { _ in () }.eraseToAnyPublisher(),
            state.$recentChats.map { _ in () }.eraseToAnyPublisher(),
            state.$theme.map { _ in () }.eraseToAnyPublisher(),
            ScreenRecordCoordinator.shared.$isRecording.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        strip.entries = state.pinnedChats.map { chat in
            AvatarEntry(guid: chat.guid, person: state.person(for: chat),
                        unread: state.unread.contains(chat.guid),
                        draft: state.hasDraft(chat.guid) && state.openChatGUID != chat.guid,
                        active: state.openChatGUID == chat.guid)
        }
        strip.isRecording = ScreenRecordCoordinator.shared.isRecording
        item.length = strip.preferredWidth
        strip.needsDisplay = true
    }

    /// Screen rect of a pinned person's avatar, used to anchor the panel.
    func anchorRect(for guid: String) -> NSRect? {
        strip.screenRect(for: guid)
    }

    /// True when the pointer is over our status item (so the panel shouldn't treat the
    /// click as "outside").
    func containsMouse() -> Bool {
        strip.screenBounds.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: - Actions

    /// Debounces the two delivery paths (view mouse event + button action) for one click.
    private var lastActivation: TimeInterval = 0
    private var lastHit: AvatarStripView.Hit?

    @objc private func buttonAction(_ sender: Any?) {
        let event = NSApp.currentEvent
        let right = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        activate(strip.hit(event: event), rightClick: right)
    }

    private func activate(_ hit: AvatarStripView.Hit, rightClick: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if hit == lastHit, now - lastActivation < 0.2 { return }
        lastActivation = now
        lastHit = hit
        tooltip.hide()

        if rightClick {
            showMenu()
            return
        }
        switch hit {
        case .avatar(let guid):
            let anchor = strip.screenRect(for: guid) ?? strip.screenBounds
            ChatPanelController.shared.toggle(chatGUID: guid, anchor: anchor)
        case .stopRecording:
            onStopScreenRecording?()
        case .empty:
            if strip.entries.isEmpty { onOpenSettings?() }
        }
    }

    private func dropped(_ urls: [URL], on guid: String) {
        tooltip.hide()
        state.composer(for: guid).addFiles(urls)
        ChatPanelController.shared.show(chatGUID: guid, anchor: strip.screenRect(for: guid) ?? strip.screenBounds)
    }

    private func hover(_ guid: String?) {
        // While the drop zone is open it names the person itself.
        guard !dropShelf.isVisible, let guid, let chat = state.chat(guid: guid), state.openChatGUID != guid,
              let rect = strip.screenRect(for: guid) else {
            tooltip.hide()
            return
        }
        tooltip.show(text: state.person(for: chat).name, below: rect)
    }

    private func showMenu() {
        guard let button = item.button else { return }
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let pinMenu = NSMenu()
        for chat in state.recentChats.prefix(30) {
            let entry = NSMenuItem(title: state.person(for: chat).name, action: #selector(togglePin(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = chat.guid
            let pinned = state.pinnedGUIDs.contains(chat.guid)
            entry.state = pinned ? .on : .off
            pinMenu.addItem(entry)
        }
        if pinMenu.items.isEmpty {
            pinMenu.addItem(NSMenuItem(title: "No conversations found", action: nil, keyEquivalent: ""))
        }
        let pinItem = NSMenuItem(title: "Pinned People (\(state.pinnedGUIDs.count))", action: nil, keyEquivalent: "")
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenHoy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let guid = sender.representedObject as? String, let chat = state.chat(guid: guid) else { return }
        state.togglePin(chat)
    }

    @objc private func openSettings() { onOpenSettings?() }

    // MARK: - Debug

    #if DEBUG
    func dropShelfTest(snapshot url: URL?) { dropShelf.debugWalk(snapshot: url) }
    #endif

    func snapshot(to url: URL) {
        guard let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { return }
        strip.cacheDisplay(in: strip.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Development aid: clicks every avatar through both delivery paths and logs what opens.
    func selfTest() {
        guard let window = strip.window else { NSLog("SELFTEST no window"); return }
        NSLog("SELFTEST window=%@ strip=%@ entries=%d", NSStringFromRect(window.frame), NSStringFromRect(strip.frame), strip.entries.count)
        for (index, entry) in strip.entries.enumerated() {
            guard let rect = strip.screenRect(for: entry.guid) else { continue }
            let center = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            lastActivation = 0
            lastHit = nil
            if ProcessInfo.processInfo.environment["OPENHOY_SELFTEST"] == "pointer" {
                // Simulates macOS routing the click to the button action with no usable
                // coordinates: only the real pointer position can identify the avatar.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: primaryHeight - rect.midY))
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                buttonAction(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                NSLog("SELFTEST pointer %@ → open=%@", entry.guid, state.openChatGUID ?? "nil")
                continue
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            NSLog("SELFTEST clicked %@ → open=%@", entry.guid, state.openChatGUID ?? "nil")
            ChatPanelController.shared.snapshot(to: URL(fileURLWithPath: "/tmp/openhoy-scratch/selftest-\(index).png"))
        }
    }
}

// MARK: - Avatar strip

struct AvatarEntry: Equatable {
    let guid: String
    let person: Person
    let unread: Bool
    let draft: Bool
    let active: Bool
}

final class AvatarStripView: NSView {
    enum Hit: Equatable { case avatar(String), stopRecording, empty }

    var entries: [AvatarEntry] = [] {
        didSet {
            guard entries != oldValue else { return }
            if entries.map(\.guid) != oldValue.map(\.guid) { onWidthChange?(preferredWidth) }
            syncMotion()
            animate()
        }
    }
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            onWidthChange?(preferredWidth)
        }
    }

    var onActivate: ((Hit, Bool) -> Void)?
    var onDropFiles: ((String, [URL]) -> Void)?
    var onHover: ((String?) -> Void)?
    /// The status item must follow the strip's width when people are added or removed.
    var onWidthChange: ((CGFloat) -> Void)?

    // Geometry (points). At rest the faces overlap in a clump at the right end; with the
    // pointer over the row (or a chat open) they fan out into the room reserved for them,
    // so the status item never changes width and nothing else in the menu bar moves.
    static let avatarSize: CGFloat = 20
    private let restGap: CGFloat = 20 * 0.58
    private let openGap: CGFloat = 20 + 5
    /// Extra room opened on the hovered face's left. Space only ever opens leftward (the right
    /// end is pinned), so the face under the pointer never slides out from under it.
    private let extraGap: CGFloat = 5
    private let padding: CGFloat = 4
    /// Room for a hovered face's 1.1× scale at the right end.
    private let edgeRoom: CGFloat = 2
    private var recordWidth: CGFloat { isRecording ? 30 : 0 }

    private struct Motion {
        var x: CGFloat = 0, vx: CGFloat = 0
        var scale: CGFloat = 1, vScale: CGFloat = 0
        var focus: CGFloat = 0, vFocus: CGFloat = 0
        var ring: CGFloat = 0, vRing: CGFloat = 0
    }
    private var motion: [String: Motion] = [:]
    /// Local x of the pointer (or a drag) while it is over the strip.
    private var pointerX: CGFloat?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    private var hovered: String? {
        didSet {
            guard hovered != oldValue else { return }
            onHover?(hovered)
        }
    }
    private var dragTarget: String?
    /// The drop zone under the menu bar is open: fan out so each face can be told apart.
    private var shelfOpen = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    var preferredWidth: CGFloat {
        if entries.isEmpty { return 26 + recordWidth }
        let spread = CGFloat(entries.count - 1) * openGap + (entries.count > 1 ? extraGap * 1.7 : 0)
        return padding * 2 + recordWidth + edgeRoom + Self.avatarSize + spread
    }

    private var isFanned: Bool { pointerX != nil || dragTarget != nil || shelfOpen || entries.contains(where: \.active) }

    /// Where each face's centre is heading.
    private func targetCenters(hovered: Int?, fanned: Bool? = nil) -> [CGFloat] {
        let n = entries.count
        guard n > 0 else { return [] }
        let fanned = fanned ?? isFanned
        var xs = Array(repeating: CGFloat(0), count: n)
        xs[n - 1] = bounds.width - padding - edgeRoom - Self.avatarSize / 2
        for i in stride(from: n - 2, through: 0, by: -1) {
            var gap = fanned ? openGap : restGap
            if let h = hovered, h > 0, i < h { gap += extraGap * exp(-pow(CGFloat(h - 1 - i) / 1.2, 2)) }
            xs[i] = xs[i + 1] - gap
        }
        return xs
    }

    private func currentCenters() -> [CGFloat] { entries.map { motion[$0.guid]?.x ?? 0 } }

    /// Index of the face under local x, judged against where the faces are drawn right now
    /// (or against the given centres).
    private func index(atX x: CGFloat, centers: [CGFloat]? = nil) -> Int? {
        let xs = centers ?? currentCenters()
        let n = xs.count
        guard n > 0 else { return nil }
        let d = Self.avatarSize
        var u: CGFloat
        if x <= xs[0] {
            u = (x - xs[0]) / d
        } else if x >= xs[n - 1] {
            u = CGFloat(n - 1) + (x - xs[n - 1]) / d
        } else {
            u = 0
            for i in 0..<(n - 1) where x <= xs[i + 1] {
                u = CGFloat(i) + (x - xs[i]) / max(1, xs[i + 1] - xs[i])
                break
            }
        }
        guard u >= -0.5, u <= CGFloat(n) - 0.5 else { return nil }
        return min(n - 1, max(0, Int(u.rounded())))
    }

    private func hoveredIndex() -> Int? {
        if let dragTarget { return entries.firstIndex { $0.guid == dragTarget } }
        guard let pointerX else { return nil }
        return index(atX: pointerX)
    }

    private func circleRect(center x: CGFloat, scale: CGFloat = 1) -> NSRect {
        let d = min(Self.avatarSize, bounds.height) * scale
        return NSRect(x: x - d / 2, y: (bounds.height - d) / 2, width: d, height: d)
    }

    var screenBounds: NSRect { toScreen(bounds) }

    /// Where a face sits once the row has fanned out (what the chat panel anchors to).
    func screenRect(for guid: String) -> NSRect? {
        guard let i = entries.firstIndex(where: { $0.guid == guid }) else { return nil }
        return toScreen(circleRect(center: targetCenters(hovered: nil, fanned: true)[i]))
    }

    private func toScreen(_ rect: NSRect) -> NSRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func hit(local point: NSPoint) -> Hit {
        if isRecording, point.x < padding + recordWidth { return .stopRecording }
        if let i = index(atX: point.x) { return .avatar(entries[i].guid) }
        // A click while the faces are still spreading out: judge it against where they're
        // heading (fanned, with room opened around the face under the pointer).
        let settled = targetCenters(hovered: nil, fanned: true)
        if let rough = index(atX: point.x, centers: settled),
           let i = index(atX: point.x, centers: targetCenters(hovered: rough, fanned: true)) {
            return .avatar(entries[i].guid)
        }
        return .empty
    }

    /// The pointer in local coordinates. Status item events can arrive with coordinates
    /// that don't match the pointer, so the real cursor position is preferred.
    private func localPointer() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    /// What the user clicked: trust the real pointer position when it's over us; fall back
    /// to the event's own coordinates (e.g. for synthesized events).
    func hit(event: NSEvent?) -> Hit {
        if let pointer = localPointer(), bounds.insetBy(dx: -2, dy: -4).contains(pointer) {
            let h = hit(local: pointer)
            if h != .empty { return h }
        }
        if let event, event.window === window {
            return hit(local: convert(event.locationInWindow, from: nil))
        }
        return .empty
    }

    // MARK: Motion

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// New faces start where they belong; removed ones are forgotten.
    private func syncMotion() {
        let targets = targetCenters(hovered: hoveredIndex())
        var next: [String: Motion] = [:]
        for (i, entry) in entries.enumerated() {
            var m = motion[entry.guid] ?? Motion(x: targets[i])
            if motion[entry.guid] == nil, entry.active { m.ring = 1; m.focus = 1 }
            next[entry.guid] = m
        }
        motion = next
    }

    private func animate() {
        needsDisplay = true
        if link == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = 0
        }
        link?.isPaused = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { link?.invalidate(); link = nil } else { syncMotion(); animate() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard changed else { return }
        // Width changes (people added or removed) re-anchor the row: snap instead of sliding.
        let targets = targetCenters(hovered: hoveredIndex())
        for (i, entry) in entries.enumerated() { motion[entry.guid]?.x = targets[i] }
        needsDisplay = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(1.0 / 30, max(1.0 / 240, now - lastTick))
        lastTick = now
        if !step(CGFloat(dt)) {
            link.isPaused = true
            lastTick = 0
        }
        needsDisplay = true
    }

    /// Advances every spring one frame. Returns false once everything has settled.
    private func step(_ dt: CGFloat) -> Bool {
        let hoveredIdx = hoveredIndex()
        hovered = hoveredIdx.map { entries[$0].guid }
        let targets = targetCenters(hovered: hoveredIdx)
        let snap = reduceMotion
        var moving = false

        func spring(_ value: inout CGFloat, _ velocity: inout CGFloat, to target: CGFloat, k: CGFloat, zeta: CGFloat) {
            if snap { value = target; velocity = 0; return }
            let c = 2 * sqrt(k) * zeta
            velocity += (-k * (value - target) - c * velocity) * dt
            value += velocity * dt
            if abs(value - target) < 0.002 && abs(velocity) < 0.02 {
                value = target
                velocity = 0
            } else {
                moving = true
            }
        }

        for (i, entry) in entries.enumerated() {
            guard var m = motion[entry.guid] else { continue }
            let near: CGFloat = hoveredIdx.map { exp(-pow(CGFloat(i - $0) / 1.2, 2)) } ?? 0
            let isHover = i == hoveredIdx
            spring(&m.x, &m.vx, to: targets[i], k: 260, zeta: 0.82)
            spring(&m.scale, &m.vScale, to: isHover ? 1.1 : entry.active ? 1.05 : 1 + 0.04 * near, k: 420, zeta: 0.62)
            spring(&m.focus, &m.vFocus, to: isHover || entry.active ? 1 : 0.3 * near, k: 300, zeta: 0.95)
            spring(&m.ring, &m.vRing, to: entry.active || dragTarget == entry.guid ? 1 : 0, k: 300, zeta: 0.9)
            motion[entry.guid] = m
        }
        return moving
    }

    // MARK: Drawing

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isRecording {
                AvatarRenderer.drawRecordingBadge(in: NSRect(x: padding, y: 0, width: 26, height: bounds.height))
            }
            if entries.isEmpty {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                if let image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "OpenHoy")?
                    .withSymbolConfiguration(config) {
                    let tinted = image.tinted(.labelColor)
                    let s = tinted.size
                    tinted.draw(in: NSRect(x: recordWidth + (26 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
                }
                return
            }
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            // Back to front: earlier people sit on top of later ones; the open chat above
            // them, and the face under the pointer above everything.
            let hoveredGUID = hovered
            let order = entries.indices.sorted { a, b in
                func z(_ i: Int) -> Int {
                    if entries[i].guid == hoveredGUID { return 1000 }
                    if entries[i].active { return 900 }
                    return entries.count - i
                }
                return z(a) < z(b)
            }
            for i in order {
                let entry = entries[i]
                guard let m = motion[entry.guid] else { continue }
                AvatarRenderer.drawGlass(entry, focus: max(0, min(1, m.focus)), ring: max(0, min(1, m.ring)),
                                         in: circleRect(center: m.x, scale: m.scale), context: ctx)
            }
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updatePointer() }
    override func mouseEntered(with event: NSEvent) { updatePointer() }
    override func mouseExited(with event: NSEvent) {
        pointerX = nil
        hovered = nil
        animate()
    }

    private func updatePointer() {
        guard let pointer = localPointer(), bounds.insetBy(dx: -2, dy: -4).contains(pointer) else {
            pointerX = nil
            hovered = nil
            animate()
            return
        }
        pointerX = pointer.x
        hovered = hoveredIndex().map { entries[$0].guid }
        animate()
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?(hit(event: event), event.modifierFlags.contains(.control))
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate?(hit(event: event), true)
    }

    // MARK: Drag & drop

    func setShelfOpen(_ open: Bool) {
        guard shelfOpen != open else { return }
        shelfOpen = open
        if !open { dragTarget = nil }
        animate()
    }

    /// Lights up the face picked in the drop zone, as if a drag were over it.
    func setShelfTarget(_ guid: String?) {
        guard dragTarget != guid else { return }
        dragTarget = guid
        animate()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }

    private func dragTargetGUID(_ sender: NSDraggingInfo) -> String? {
        if case .avatar(let guid) = hit(event: nil) { return guid }
        if case .avatar(let guid) = hit(local: convert(sender.draggingLocation, from: nil)) { return guid }
        return nil
    }

    private func dragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pointerX = convert(sender.draggingLocation, from: nil).x
        dragTarget = dragTargetGUID(sender) ?? (entries.count == 1 ? entries[0].guid : nil)
        animate()
        return dragTarget == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragTarget = nil
        pointerX = nil
        hovered = nil
        animate()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            // AppKit doesn't send draggingExited after a drop, so leave the hover state here.
            dragTarget = nil
            pointerX = nil
            hovered = nil
            animate()
        }
        guard let guid = dragTarget ?? dragTargetGUID(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(guid, urls)
        return true
    }
}

#if DEBUG
/// Test hooks for driving the strip without a real pointer (debug builds only).
extension AvatarStripView {
    func debugPointer(_ x: CGFloat?) { pointerX = x }
    func debugSettle(frames: Int = 180) { for _ in 0..<frames { _ = step(1.0 / 60) } }
    func debugHit(_ x: CGFloat) -> Hit { hit(local: NSPoint(x: x, y: bounds.midY)) }
    func debugCenters() -> [CGFloat] { currentCenters() }
    var debugHovered: String? { hovered }
}
#endif

// MARK: - Drawing

enum AvatarRenderer {
    /// Ring around the open conversation, in the current theme.
    static var ringGradient: NSGradient {
        let colors = Theme.palette.ringColors
        return NSGradient(colors: colors.count == 1 ? [colors[0], colors[0]] : colors)!
    }
    static var unreadColor: NSColor { Theme.palette.unread }

    static func drawRecordingBadge(in bounds: NSRect) {
        let r = NSRect(x: bounds.minX + 1, y: (bounds.height - 18) / 2, width: 24, height: 18)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.midX - 3.5, y: r.midY - 3.5, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// One face as a glass lens. Out of focus (`focus` 0) the full-colour photo is softened
    /// behind a light frost; in focus (1) it is sharp. `ring` fades in the sunset ring that
    /// marks the open conversation.
    @MainActor
    static func drawGlass(_ entry: AvatarEntry, focus f: CGFloat, ring: CGFloat, in rect: NSRect, context ctx: CGContext) {
        let images = AvatarImages.shared.images(for: entry.person)

        // Soft contact shadow so overlapping faces read as stacked.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.6, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: rect.insetBy(dx: 0.4, dy: 0.4))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        if let sharp = images.sharp { ctx.draw(sharp, in: rect) }
        if f < 1, let soft = images.soft {
            ctx.setAlpha(1 - f)
            ctx.draw(soft, in: rect)
            ctx.setAlpha(1)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        // Frost: a faint white wash, brighter at the top, gone once in focus.
        if f < 1, let frost = CGGradient(colorsSpace: space, colors: [
            NSColor.white.withAlphaComponent(0.16 * (1 - f)).cgColor,
            NSColor.white.withAlphaComponent(0.04 * (1 - f)).cgColor,
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(frost, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        // Lens: a specular highlight across the top and light caught in the bottom rim.
        let lens = 1 - 0.3 * f
        func glow(at center: CGPoint, radius: CGFloat, squash: CGFloat, alpha: CGFloat) {
            guard let g = CGGradient(colorsSpace: space, colors: [
                NSColor.white.withAlphaComponent(alpha).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray, locations: [0, 1]) else { return }
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: 1, y: squash)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
            ctx.restoreGState()
        }
        glow(at: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.14), radius: rect.width * 0.5, squash: 0.62, alpha: 0.6 * lens)
        glow(at: CGPoint(x: rect.midX, y: rect.minY), radius: rect.width * 0.5, squash: 0.5, alpha: 0.22 * lens)
        ctx.restoreGState()

        // Crisp glass edge, with a faint dark hairline so it holds on light wallpapers.
        ctx.setLineWidth(0.75)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55 * lens).cgColor)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.4, dy: 0.4))
        ctx.setLineWidth(0.5)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.strokeEllipse(in: rect.insetBy(dx: -0.25, dy: -0.25))

        if ring > 0.01 {
            // A ring in the theme's colour marks the open conversation.
            ctx.saveGState()
            ctx.setAlpha(ring)
            // Just inside the edge, so it never clips against the menu bar's height.
            let path = CGPath(ellipseIn: rect.insetBy(dx: 0.9, dy: 0.9), transform: nil)
                .copy(strokingWithWidth: 1.8, lineCap: .round, lineJoin: .round, miterLimit: 1)
            ctx.addPath(path)
            ctx.clip()
            ringGradient.draw(in: rect, angle: -45)
            ctx.restoreGState()
        }

        if entry.unread {
            let dot = NSRect(x: rect.maxX - 5.5, y: rect.maxY - 6.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.fillEllipse(in: dot.insetBy(dx: -1.2, dy: -1.2))
            ctx.setFillColor(unreadColor.cgColor)
            ctx.fillEllipse(in: dot)
        }

        if entry.draft {
            let badge = NSRect(x: rect.maxX - 8, y: rect.minY - 0.5, width: 10, height: 10)
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: badge).fill()
            if let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 6, weight: .bold)) {
                let tinted = pencil.tinted(NSColor.windowBackgroundColor)
                let s = tinted.size
                tinted.draw(in: NSRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
    }

    static func drawInitials(_ person: Person, in rect: NSRect) {
        let top = NSColor(hue: person.hue, saturation: 0.45, brightness: 0.85, alpha: 1)
        let bottom = NSColor(hue: person.hue, saturation: 0.6, brightness: 0.6, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
        if person.initials.isEmpty {
            if let glyph = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: rect.height * 0.5, weight: .semibold)) {
                let tinted = glyph.tinted(.white)
                let s = tinted.size
                tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return
        }
        let font = NSFont.systemFont(ofSize: rect.height * 0.4, weight: .semibold)
        let text = NSAttributedString(string: String(person.initials.prefix(2)),
                                      attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

// MARK: - Avatar images

/// Each face rasterized once, plus a softened copy for the out-of-focus glass look.
@MainActor
final class AvatarImages {
    static let shared = AvatarImages()
    private final class Pair {
        let sharp: CGImage?, soft: CGImage?
        init(sharp: CGImage?, soft: CGImage?) { self.sharp = sharp; self.soft = soft }
    }
    /// Photos are keyed by the image object itself (weakly), so a freed image can never be
    /// mistaken for a new one that happens to reuse its address.
    private let photos = NSMapTable<NSImage, Pair>.weakToStrongObjects()
    private var initials: [String: Pair] = [:]
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func images(for person: Person) -> (sharp: CGImage?, soft: CGImage?) {
        let key = "\(person.initials)|\(person.hue)"
        if let image = person.image {
            if let hit = photos.object(forKey: image) { return (hit.sharp, hit.soft) }
        } else if let hit = initials[key] {
            return (hit.sharp, hit.soft)
        }
        let sharp = Self.rasterize(person)
        let pair = Pair(sharp: sharp, soft: sharp.flatMap(soften))
        if let image = person.image {
            photos.setObject(pair, forKey: image)
        } else {
            if initials.count > 64 { initials.removeAll() }
            initials[key] = pair
        }
        return (pair.sharp, pair.soft)
    }

    /// Square, unclipped, so the blur doesn't pull in transparent edges.
    private static func rasterize(_ person: Person, points: CGFloat = 48, scale: CGFloat = 2) -> CGImage? {
        let pixels = Int(points * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: points, height: points)
        if let image = person.image {
            image.draw(in: rect.aspectFill(image.size), from: .zero, operation: .copy, fraction: 1)
        } else {
            AvatarRenderer.drawInitials(person, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private func soften(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(image.width) / 96 * 5)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15])
            .cropped(to: input.extent)
        return context.createCGImage(blurred, from: input.extent)
    }
}

// MARK: - Tooltip

@MainActor
final class AvatarTooltip {
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var currentText: String?

    func show(text: String, below rect: NSRect) {
        if currentText == text, panel?.isVisible == true { position(below: rect); return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.present(text: text, below: rect) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel?.isVisible == true ? 0 : 0.25), execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        currentText = nil
        panel?.orderOut(nil)
    }

    private func present(text: String, below rect: NSRect) {
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = p
            return p
        }()
        let view = NSHostingView(rootView: TooltipView(text: text))
        view.layoutSubtreeIfNeeded()
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        currentText = text
        position(below: rect)
        panel.orderFrontRegardless()
    }

    private func position(below rect: NSRect) {
        guard let panel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 3))
    }
}

private struct TooltipView: View {
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(0.6)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(white: 0.16).opacity(0.92)))
        .padding(4)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Helpers

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

extension NSRect {
    /// Rect that fills `self` with content of `size`, centered (for drawing photos into circles).
    func aspectFill(_ size: NSSize) -> NSRect {
        guard size.width > 0, size.height > 0 else { return self }
        let scale = max(width / size.width, height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}
