import Combine
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        ChatPanelController.shared.hide()
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView().environmentObject(AppState.shared))
            let window = NSWindow(contentViewController: controller)
            window.title = "OpenHoy"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 540, height: 700))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Development aid.
    func snapshot(to url: URL) {
        window?.setContentSize(NSSize(width: 540, height: 1400))   // capture everything, not just the visible part
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ViewState private var tick = 0
    @ViewState private var search = ""
    @ViewState private var draggingGUID: String?
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let refresher = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                permissions
                pinned
                appearance
                options
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 600)
        .onReceive(refresher) { _ in
            tick += 1
            let current = Permissions.messagesAutomation
            if current != .unknown { messagesStatus = current }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenHoy").font(.system(size: 22, weight: .semibold))
                Text("Your favourite people in the menu bar. Drop texts, voice notes, files and screen recordings — sent over your own iMessage.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }

    private var permissions: some View {
        let _ = tick
        return SettingsSection(title: "Permissions") {
            let fda: PermissionStatus = state.access == .granted ? .granted : (state.access == .unknown ? .unknown : .denied)
            PermissionRow(title: "Full Disk Access",
                          detail: fda == .granted
                            ? "Reads your conversations from Messages."
                            : "Required. Click Open Settings, then switch on OpenHoy, or click + and choose OpenHoy.app. If OpenHoy is already listed, remove it with – and add it again.",
                          status: fda,
                          buttons: [
                            .init("Open Settings", prominent: true) { Permissions.openFullDiskAccessSettings() },
                            .init("Show App in Finder") { Permissions.revealApp() },
                            .init("Check Again") { state.retryAccess() },
                          ])
            PermissionRow(title: "Messages", detail: messagesDetail, status: messagesStatus,
                          buttons: messagesStatus == .denied
                            ? [.init("Ask Again", prominent: true) { Task { await Permissions.resetMessagesAutomation(); requestMessages() } },
                               .init("Open Settings") { Permissions.open("Privacy_Automation") }]
                            : [.init("Allow", prominent: true) { requestMessages() },
                               .init("Open Settings") { Permissions.open("Privacy_Automation") }])
            PermissionRow(title: "Contacts", detail: "Names and photos for your people.", status: Permissions.contacts,
                          buttons: Self.standardButtons(Permissions.contacts, anchor: "Privacy_Contacts") { state.reloadContacts() })
            PermissionRow(title: "Microphone", detail: "Voice notes and narrated recordings.", status: Permissions.capture(.audio),
                          buttons: Self.standardButtons(Permissions.capture(.audio), anchor: "Privacy_Microphone") {
                              Task { _ = await MediaPermission.microphone(); tick += 1 } })
            PermissionRow(title: "Speech Recognition", detail: "Live transcripts of voice notes (on-device when available).",
                          status: Permissions.speech,
                          buttons: Self.standardButtons(Permissions.speech, anchor: "Privacy_SpeechRecognition") {
                              Task { _ = await MediaPermission.speech(); tick += 1 } })
            PermissionRow(title: "Camera", detail: "Video notes and the face bubble.", status: Permissions.capture(.video),
                          buttons: Self.standardButtons(Permissions.capture(.video), anchor: "Privacy_Camera") {
                              Task { _ = await MediaPermission.camera(); tick += 1 } })
            PermissionRow(title: "Screen Recording", detail: "Record a window or an area of your screen.",
                          status: Permissions.screenRecording,
                          buttons: Self.standardButtons(Permissions.screenRecording, anchor: "Privacy_ScreenCapture") {
                              CGRequestScreenCaptureAccess(); tick += 1 })
        }
    }

    /// "Allow" (asks macOS) plus a way into System Settings; once denied, macOS won't ask
    /// again, so only the settings button makes sense.
    static func standardButtons(_ status: PermissionStatus, anchor: String, allow: @escaping () -> Void) -> [PermissionButton] {
        let settings = PermissionButton("Open Settings", prominent: status == .denied) { Permissions.open(anchor) }
        return status == .denied ? [settings] : [PermissionButton("Allow", prominent: true, action: allow), settings]
    }

    @ViewState private var messagesStatus: PermissionStatus = Permissions.messagesAutomation

    private var messagesDetail: String {
        switch messagesStatus {
        case .denied: return "Blocked — click “Ask Again”, then choose OK in the prompt."
        default: return "Required — sends through the Messages app."
        }
    }

    private func requestMessages() {
        Task {
            messagesStatus = await Permissions.requestMessagesAutomation()
            tick += 1
        }
    }

    private var pinned: some View {
        SettingsSection(title: "People in your menu bar (\(state.pinnedGUIDs.count))") {
            if state.pinnedChats.isEmpty {
                Text("Pin conversations below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Drag to change the order. The top person is left-most in the menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(state.pinnedChats, id: \.guid) { chat in
                        PinnedRow(chat: chat, isDragging: draggingGUID == chat.guid)
                            .onDrag {
                                draggingGUID = chat.guid
                                return NSItemProvider(object: chat.guid as NSString)
                            }
                            .onDrop(of: [.text], delegate: PinReorderDropDelegate(target: chat.guid,
                                                                                  dragging: $draggingGUID, state: state))
                    }
                }
                // Dropping anywhere else in the list just ends the drag.
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    draggingGUID = nil
                    return true
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.pinnedGUIDs)
            }

            Divider().padding(.vertical, 4)

            TextField("Search recent conversations", text: $search)
                .textFieldStyle(.roundedBorder)
            let candidates = state.recentChats.filter { chat in
                !state.pinnedGUIDs.contains(chat.guid) &&
                (search.isEmpty || state.person(for: chat).name.localizedCaseInsensitiveContains(search) ||
                 chat.participants.contains { $0.localizedCaseInsensitiveContains(search) })
            }
            if state.access != .granted {
                Text("Grant Full Disk Access to see your conversations.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if candidates.isEmpty {
                Text("No matching conversations.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(candidates.prefix(12)) { chat in
                HStack(spacing: 10) {
                    AvatarView(person: state.person(for: chat), size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.person(for: chat).name)
                        Text(chat.isGroup ? "\(chat.participants.count) people · \(chat.service)" : "\(chat.primaryHandle) · \(chat.service)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pin") { state.togglePin(chat) }
                }
            }
        }
    }

    private var appearance: some View {
        SettingsSection(title: "Appearance") {
            HStack(spacing: 10) {
                ForEach(ThemeChoice.allCases) { choice in
                    ThemeSwatch(choice: choice, selected: state.theme == choice) {
                        withAnimation(.easeOut(duration: 0.15)) { state.theme = choice }
                    }
                }
            }
            Text(state.theme == .messages
                 ? "Matches Messages: blue for iMessage, green for SMS."
                 : state.theme == .systemAccent
                    ? "Follows the accent colour in System Settings › Appearance."
                    : "Colours your messages, the send button, the unread dot and the open chat's ring.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        SettingsSection(title: "Options") {
            Toggle("Send the transcript as text with voice notes", isOn: $state.sendTranscripts)
            Toggle("Show a drop zone under the menu bar while dragging files", isOn: $state.dropShelf)
            Toggle("Open OpenHoy at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                Text("Tip: start dragging files and throw them at someone in the drop zone, or onto their avatar.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit OpenHoy") { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: - Components

/// A theme preview: an incoming and a sent bubble in that theme's colours.
private struct ThemeSwatch: View {
    let choice: ThemeChoice
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let palette = choice.palette
        let sent = palette.sent.map { Color(nsColor: $0) }
        Button(action: action) {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 34, height: 12)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(LinearGradient(colors: sent.count == 1 ? [sent[0], sent[0]] : sent,
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 42, height: 12)
                    }
                    if let sms = palette.sms?.first {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Capsule().fill(Color(nsColor: sms)).frame(width: 28, height: 12)
                        }
                    }
                }
                .padding(8)
                .frame(height: 62)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.25 : 0.1),
                                  lineWidth: selected ? 2 : 1))
                Text(choice.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(choice.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PinnedRow: View {
    let chat: ChatSummary
    let isDragging: Bool
    @EnvironmentObject private var state: AppState
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .help("Drag to reorder")
            AvatarView(person: state.person(for: chat), size: 28)
            Text(state.person(for: chat).name)
            Spacer()
            Button { state.togglePin(chat) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Unpin")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(isDragging ? 0.1 : (hovering ? 0.05 : 0))))
        .opacity(isDragging ? 0.55 : 1)
        .contentShape(Rectangle())
        .pointerStyle(.grabIdle)
        .onHover { hovering = $0 }
    }
}

/// Live reordering: as a dragged row passes over another, they swap places.
private struct PinReorderDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let state: AppState

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = state.pinnedGUIDs.firstIndex(of: dragging),
              let to = state.pinnedGUIDs.firstIndex(of: target) else { return }
        state.movePinned(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
    }
}

struct PermissionButton: Identifiable {
    let id = UUID()
    let title: String
    let prominent: Bool
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionStatus
    let buttons: [PermissionButton]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.symbol)
                .foregroundStyle(status == .granted ? .green : (status == .denied ? .red : .secondary))
                .font(.system(size: 15))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status != .granted {
                    HStack(spacing: 8) {
                        ForEach(buttons) { button in
                            if button.prominent {
                                Button(button.title, action: button.action)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            } else {
                                Button(button.title, action: button.action)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct AvatarView: View {
    let person: Person
    let size: CGFloat

    var body: some View {
        Group {
            if let image = person.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(hue: person.hue, saturation: 0.45, brightness: 0.85),
                                            Color(hue: person.hue, saturation: 0.6, brightness: 0.6)],
                                   startPoint: .top, endPoint: .bottom)
                    if person.initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                    } else {
                        Text(person.initials.prefix(2))
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
