import AppKit
import SwiftUI

/// "Just throw stuff at them": as soon as files start being dragged anywhere on screen, a
/// glass drop zone drops down under the menu bar avatars. The zone is split left to right in
/// the same order as the avatars. Moving across it picks a person, lights up their face in the
/// menu bar and shows *Drop to <name>* beside the pointer. Letting go hands the files to that
/// person's composer.
///
/// No special permission is needed to notice the drag. A global mouse-down monitor (mouse
/// monitors don't need Accessibility access) starts a light poll that runs only while the
/// button is held. The poll watches the system drag pasteboard: if its change count moves
/// and it holds file URLs, a drag of files has started.
@MainActor
final class DropShelfController {
    struct Target: Equatable {
        let guid: String
        let name: String
        let image: NSImage?
    }

    /// The pinned people, left to right as they sit in the menu bar.
    var targets: () -> [Target] = { [] }
    /// Screen rect of the avatar row the zone hangs from.
    var anchor: () -> NSRect? = { nil }
    var isEnabled: () -> Bool = { true }
    /// The person under the pointer changed (nil once it leaves the zone).
    var onTargetChange: ((String?) -> Void)?
    /// The zone opened or closed.
    var onVisibilityChange: ((Bool) -> Void)?
    var onDrop: ((String, [URL]) -> Void)?

    private(set) var isVisible = false
    private let model = DropShelfModel()
    private var panel: NSPanel?
    private var dropView: DropShelfDropView?
    private var mouseDownMonitor: Any?
    private var poll: Timer?
    private var dragChangeCount = 0
    private var hideWork: DispatchWorkItem?

    static let zoneSize = NSSize(width: 380, height: 136)
    /// Room beside and below the zone inside the window for its shadow. None above, so the
    /// window never covers the menu bar (where the avatars take drops of their own).
    static let margin: CGFloat = 24

    init() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseWentDown() }
        }
    }

    // MARK: Watching for a drag

    private func mouseWentDown() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            // Button released: the drag (if any) is over.
            poll?.invalidate()
            poll = nil
            hide()
            return
        }
        guard !isVisible else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragChangeCount else { return }
        // Only checks the types, never reads the contents, so no paste-privacy prompt.
        guard pasteboard.types?.contains(.fileURL) == true else {
            // Something else (text, a tab…) is being dragged; ignore the rest of this drag.
            dragChangeCount = pasteboard.changeCount
            return
        }
        dragChangeCount = pasteboard.changeCount
        #if DEBUG
        NSLog("DROPSHELF file drag detected")
        #endif
        show()
    }

    // MARK: Showing

    func show() {
        guard isEnabled() else { return }
        let people = targets()
        guard !people.isEmpty, let anchor = anchor() else { return }
        hideWork?.cancel()
        hideWork = nil

        let panel = self.panel ?? makePanel()
        let zone = Self.zoneSize
        let margin = Self.margin
        let size = NSSize(width: zone.width + margin * 2, height: zone.height + margin)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 6 - margin), visible.maxX - 6 + margin - size.width)
        }
        // Hang just below the menu bar.
        let top = anchor.minY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)

        model.targets = people
        model.target = nil
        model.pointer = nil
        isVisible = true
        onVisibilityChange?(true)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [model] in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { model.open = true }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        setTarget(nil)
        onVisibilityChange?(false)
        withAnimation(.easeIn(duration: 0.16)) { model.open = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        let container = NSView()
        let hosting = NSHostingView(rootView: DropShelfView(model: model))
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        // On top of the SwiftUI content so it alone receives the drag.
        let drop = DropShelfDropView()
        drop.autoresizingMask = [.width, .height]
        drop.zoneInset = Self.margin
        drop.onUpdate = { [weak self] point, zone in self?.dragMoved(to: point, in: zone) }
        drop.onExit = { [weak self] in self?.dragLeft() }
        drop.onDrop = { [weak self] urls in self?.dropped(urls) ?? false }
        container.addSubview(drop)
        panel.contentView = container
        hosting.frame = container.bounds
        drop.frame = container.bounds
        self.panel = panel
        self.dropView = drop
        return panel
    }

    // MARK: Dragging over the zone

    /// `point` is in the zone's own coordinates (origin top left, as SwiftUI sees it).
    private func dragMoved(to point: CGPoint, in zone: CGSize) {
        let people = model.targets
        guard !people.isEmpty, zone.width > 0 else { return }
        let index = Self.index(forX: point.x, width: zone.width, count: people.count)
        model.pointer = point
        setTarget(people[index])
    }

    private func dragLeft() {
        model.pointer = nil
        setTarget(nil)
    }

    private func setTarget(_ target: Target?) {
        guard model.target != target else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { model.target = target }
        onTargetChange?(target?.guid)
    }

    private func dropped(_ urls: [URL]) -> Bool {
        guard let guid = model.target?.guid, !urls.isEmpty else { return false }
        #if DEBUG
        NSLog("DROPSHELF dropped %d file(s) on %@ (%@)", urls.count, model.target?.name ?? "", guid)
        #endif
        hide()
        onDrop?(guid, urls)
        return true
    }

    /// Which of `count` equal slices of the zone, left to right, holds `x`.
    nonisolated static func index(forX x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0, width > 0 else { return 0 }
        let slice = Int((x / width) * CGFloat(count))
        return min(count - 1, max(0, slice))
    }

    #if DEBUG
    /// Development aid: opens the zone and walks a fake drag across it.
    func debugWalk(snapshot url: URL?) {
        show()
        let zone = Self.zoneSize
        let steps: [CGFloat] = [0.1, 0.4, 0.7, 0.95]
        for (i, f) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(i) * 0.5) { [weak self] in
                guard let self else { return }
                self.dragMoved(to: CGPoint(x: zone.width * f, y: zone.height * 0.5), in: zone)
                NSLog("DROPSHELF x=%.2f → %@", f, self.model.target?.name ?? "nil")
                if i == steps.count - 1, let url, let view = self.panel?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(steps.count) * 0.5 + 0.3) { [weak self] in self?.hide() }
    }
    #endif
}

// MARK: - Drop target

/// Transparent view over the whole shelf window that takes the drag.
final class DropShelfDropView: NSView {
    var zoneInset: CGFloat = 0
    var onUpdate: ((CGPoint, CGSize) -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The zone itself: inset by the margin on the sides and bottom, flush with the top.
    private var zone: NSRect {
        NSRect(x: zoneInset, y: zoneInset, width: max(0, bounds.width - zoneInset * 2), height: max(0, bounds.height - zoneInset))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let zone = self.zone
        // The margin around the zone is only for its shadow; it doesn't take drops.
        guard zone.contains(p) else { onExit?(); return [] }
        // Flip to top-left origin for SwiftUI.
        onUpdate?(CGPoint(x: p.x - zone.minX, y: zone.maxY - p.y), zone.size)
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        zone.contains(convert(sender.draggingLocation, from: nil))
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return onDrop?(urls) ?? false
    }
}

// MARK: - Look

@MainActor
final class DropShelfModel: ObservableObject {
    @Published var open = false
    @Published var targets: [DropShelfController.Target] = []
    @Published var target: DropShelfController.Target?
    /// Pointer in the zone (top-left origin), nil while it's outside.
    @Published var pointer: CGPoint?
}

struct DropShelfView: View {
    @ObservedObject var model: DropShelfModel
    @Environment(\.colorScheme) private var scheme

    private let radius: CGFloat = 30

    var body: some View {
        let zone = DropShelfController.zoneSize
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            DotField(pointer: model.pointer, dark: scheme == .dark)
                .clipShape(shape)
            label
        }
        .frame(width: zone.width, height: zone.height)
        .cardSurface(radius: radius)
        .overlay(shape.strokeBorder(Theme.accent.opacity(model.target == nil ? 0 : 0.55), lineWidth: 1.5))
        .scaleEffect(model.open ? 1 : 0.55, anchor: .top)
        .opacity(model.open ? 1 : 0)
        .offset(y: model.open ? 0 : -14)
        .padding([.horizontal, .bottom], DropShelfController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var label: some View {
        let zone = DropShelfController.zoneSize
        if let target = model.target, let p = model.pointer {
            // Beside the pointer, on whichever side has room, clear of the dragged icon.
            let onRight = p.x < zone.width / 2
            let gap: CGFloat = 46
            let y = min(max(p.y, 26), zone.height - 26)
            TargetLabel(target: target)
                .fixedSize()
                .frame(width: 0, alignment: onRight ? .leading : .trailing)
                .position(x: onRight ? p.x + gap : p.x - gap, y: y)
                .animation(.spring(response: 0.22, dampingFraction: 0.85), value: p)
        } else {
            VStack(spacing: 6) {
                HStack(spacing: -6) {
                    ForEach(model.targets.prefix(6), id: \.guid) { t in
                        Face(target: t, size: 22)
                    }
                }
                Text("Drop on someone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TargetLabel: View {
    let target: DropShelfController.Target

    var body: some View {
        HStack(spacing: 6) {
            Face(target: target, size: 20)
            Text("Drop to \(target.name)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.interpolate)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(0.07)))
        .id(target.guid)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

private struct Face: View {
    let target: DropShelfController.Target
    let size: CGFloat

    var body: some View {
        Group {
            if let image = target.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.secondary.opacity(0.35))
                    Text(String(target.name.prefix(1)))
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
    }
}

/// A grid of faint dots that light up around the pointer.
private struct DotField: View {
    let pointer: CGPoint?
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 11
            let dot: CGFloat = 1.6
            let reach: CGFloat = 120
            let base = dark ? Color.white : Color.black
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    var alpha = 0.07
                    if let p = pointer {
                        let d = hypot(x - p.x, y - p.y)
                        alpha += 0.38 * max(0, 1 - d / reach)
                    }
                    context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                                 with: .color(base.opacity(alpha)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
