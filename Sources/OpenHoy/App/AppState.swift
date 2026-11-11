import AppKit
import Combine
import Contacts

/// Display info for a chat (contact name + photo, or group name).
struct Person: Equatable {
    let name: String
    let firstName: String
    let image: NSImage?
    let initials: String
    /// Stable hue used for initials avatars.
    let hue: Double
}

enum DatabaseAccess: Equatable {
    case unknown
    case granted
    case denied(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let database = ChatDatabase()

    @Published private(set) var access: DatabaseAccess = .unknown
    @Published private(set) var recentChats: [ChatSummary] = []
    @Published private(set) var messages: [String: [ChatMessage]] = [:]
    @Published private(set) var pending: [String: [ChatMessage]] = [:]
    @Published private(set) var unread: Set<String> = []
    @Published private(set) var drafts: Set<String> = []
    @Published var openChatGUID: String?
    @Published private(set) var contactsVersion = 0
    @Published var pinnedGUIDs: [String] {
        didSet {
            UserDefaults.standard.set(pinnedGUIDs, forKey: Keys.pinned)
            // Reordering needs no reload; only adding/removing people does.
            if Set(pinnedGUIDs) != Set(oldValue) { Task { await refresh(force: true) } }
        }
    }
    /// The panel's expand button: a wider card with more history visible.
    @Published var panelExpanded: Bool {
        didSet { UserDefaults.standard.set(panelExpanded, forKey: "panelExpanded") }
    }
    /// Colour theme (Settings › Appearance).
    @Published var theme: ThemeChoice {
        didSet {
            Theme.choice = theme
            UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
        }
    }
    @Published var sendTranscripts: Bool {
        didSet { UserDefaults.standard.set(sendTranscripts, forKey: Keys.sendTranscripts) }
    }
    /// Open a drop zone under the avatars whenever files are being dragged.
    @Published var dropShelf: Bool {
        didSet { UserDefaults.standard.set(dropShelf, forKey: Keys.dropShelf) }
    }

    private var knownChats: [String: ChatSummary] = [:]
    /// Merged-away chat guid → the conversation guid it now belongs to.
    private var guidAliases: [String: String] = [:]
    private var composers: [String: ComposerModel] = [:]
    private var lastSeenRowID: [String: Int64]
    private var dataVersion: Int64 = -1
    private var isRefreshing = false
    /// A refresh was requested while one was running; run again when it finishes.
    private var refreshQueued = false
    private var queuedRefreshForced = false
    private var watcher: DatabaseWatcher?
    /// Safety net in case a file event is missed (e.g. the database is replaced).
    private var fallbackTimer: Timer?
    private var personCache: [String: Person] = [:]
    private var sentTranscripts: [String]

    private enum Keys {
        static let pinned = "pinnedChatGUIDs"
        static let knownChats = "knownChats"
        static let lastSeen = "lastSeenRowIDs"
        static let sendTranscripts = "sendTranscripts"
        static let transcripts = "sentTranscripts"
        static let theme = "theme"
        static let dropShelf = "dropShelf"
    }

    private init() {
        let defaults = UserDefaults.standard
        pinnedGUIDs = defaults.stringArray(forKey: Keys.pinned) ?? []
        sendTranscripts = defaults.object(forKey: Keys.sendTranscripts) as? Bool ?? true
        dropShelf = defaults.object(forKey: Keys.dropShelf) as? Bool ?? true
        let savedTheme = defaults.string(forKey: Keys.theme).flatMap(ThemeChoice.init(rawValue:)) ?? .messages
        theme = savedTheme
        Theme.choice = savedTheme
        panelExpanded = defaults.bool(forKey: "panelExpanded")
        lastSeenRowID = (defaults.dictionary(forKey: Keys.lastSeen) as? [String: Int64]) ?? [:]
        sentTranscripts = defaults.stringArray(forKey: Keys.transcripts) ?? []
        if let data = defaults.data(forKey: Keys.knownChats),
           let chats = try? JSONDecoder().decode([ChatSummary].self, from: data) {
            knownChats = Dictionary(chats.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: - Lifecycle

    func start() {
        Task.detached(priority: .utility) {
            ContactResolver.shared.reload()
            await MainActor.run {
                self.personCache.removeAll()
                self.contactsVersion += 1
            }
            await self.refresh(force: true)
        }
        MessageSender.pruneOutbox()
        Task { await refresh(force: true) }
        watcher = DatabaseWatcher(directory: database.url.deletingLastPathComponent()) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func retryAccess() {
        Task {
            await database.close()
            await refresh(force: true)
        }
    }

    func reloadContacts() {
        Task.detached(priority: .userInitiated) {
            _ = await ContactResolver.shared.requestAccess()
            ContactResolver.shared.reload()
            await MainActor.run {
                self.personCache.removeAll()
                self.contactsVersion += 1
            }
        }
    }

    // MARK: - Data

    var pinnedChats: [ChatSummary] {
        pinnedGUIDs.compactMap { knownChats[$0] }
    }

    func chat(guid: String) -> ChatSummary? { knownChats[guid] }

    func visibleMessages(for guid: String) -> [ChatMessage] {
        (messages[guid] ?? []) + (pending[guid] ?? [])
    }

    func composer(for guid: String) -> ComposerModel {
        if let existing = composers[guid] { return existing }
        let model = ComposerModel(chatGUID: guid)
        // Only the "has a draft" bit matters outside the panel (pencil badge in the menu bar).
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self, weak model] _ in
            guard let self, let model else { return }
            let hasDraft = model.hasContent
            if hasDraft != self.drafts.contains(guid) {
                if hasDraft { self.drafts.insert(guid) } else { self.drafts.remove(guid) }
            }
        }.store(in: &model.subscriptions)
        composers[guid] = model
        return model
    }

    func hasDraft(_ guid: String) -> Bool { drafts.contains(guid) }

    func togglePin(_ chat: ChatSummary) {
        if let index = pinnedGUIDs.firstIndex(of: chat.guid) {
            pinnedGUIDs.remove(at: index)
        } else {
            knownChats[chat.guid] = chat
            pinnedGUIDs.append(chat.guid)
        }
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        pinnedGUIDs.move(fromOffsets: source, toOffset: destination)
    }

    func markSeen(_ guid: String) {
        let newest = messages[guid]?.last?.rowID ?? 0
        lastSeenRowID[guid] = max(lastSeenRowID[guid] ?? 0, newest)
        UserDefaults.standard.set(lastSeenRowID, forKey: Keys.lastSeen)
        unread.remove(guid)
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else {
            // Replay once afterwards; only force a full reload if a caller asked for one.
            refreshQueued = true
            queuedRefreshForced = queuedRefreshForced || force
            return
        }
        isRefreshing = true
        await performRefresh(force: force)
        while refreshQueued {
            let forced = queuedRefreshForced
            refreshQueued = false
            queuedRefreshForced = false
            await performRefresh(force: forced)
        }
        isRefreshing = false
    }

    private func performRefresh(force: Bool) async {
        do {
            let version = try await database.dataVersion()
            let changed = version != dataVersion
            if changed || force {
                dataVersion = version
                let chats = mergeConversations(try await database.recentChats(limit: 150))
                recentChats = chats
                for chat in chats { knownChats[chat.guid] = chat }
                // Two pins that turn out to be the same person collapse into one.
                var seen = Set<String>()
                let remapped = pinnedGUIDs.map { guidAliases[$0] ?? $0 }.filter { seen.insert($0).inserted }
                if remapped != pinnedGUIDs { pinnedGUIDs = remapped }
                persistKnownChats()
                if pinnedGUIDs.isEmpty && !UserDefaults.standard.bool(forKey: "didAutoPin") {
                    UserDefaults.standard.set(true, forKey: "didAutoPin")
                    pinnedGUIDs = Array(chats.prefix(4).map(\.guid))
                }
                for chat in pinnedChats {
                    let loaded = try await database.messages(chatRowIDs: chat.allRowIDs, limit: 40)
                    let merged = mergeTranscripts(loaded)
                    if messages[chat.guid] != merged { messages[chat.guid] = merged }
                    reconcilePending(chat.guid, with: merged)
                }
            }
            if access != .granted { access = .granted }
            // Unread state only changes with the data (markSeen clears it directly).
            guard changed || force else { return }
            let newestUnread = try await database.newestUnreadRowIDs(chatRowIDs: pinnedChats.flatMap(\.allRowIDs))
            var nextUnread: Set<String> = []
            for chat in pinnedChats {
                guard chat.guid != openChatGUID,
                      let rowID = chat.allRowIDs.compactMap({ newestUnread[$0] }).max() else { continue }
                if rowID > (lastSeenRowID[chat.guid] ?? 0) { nextUnread.insert(chat.guid) }
            }
            if openChatGUID != nil, let guid = openChatGUID, changed { markSeen(guid) }
            if nextUnread != unread { unread = nextUnread }
        } catch let error as ChatDatabaseError {
            if case .noAccess = error {
                access = .denied(error.localizedDescription)
                await database.close()
            } else {
                NSLog("OpenHoy refresh failed: \(error.localizedDescription)")
            }
        } catch {
            NSLog("OpenHoy refresh failed: \(error.localizedDescription)")
        }
    }

    /// Folds the several `chat` rows Messages keeps for one person (or one group) into a
    /// single conversation. The conversation keeps the guid that's pinned (so pins stay
    /// stable) or else the most recent one, and sends to the most recently active row.
    private func mergeConversations(_ chats: [ChatSummary]) -> [ChatSummary] {
        let resolver = ContactResolver.shared
        func handleKey(_ handle: String) -> String {
            if let info = resolver.info(for: handle) { return "c:" + info.fullName.lowercased() }
            return ContactResolver.key(for: handle) ?? handle.lowercased()
        }
        func key(_ chat: ChatSummary) -> String {
            if chat.isGroup {
                // Named groups are distinct even with the same members.
                return "g:" + (chat.displayName ?? "") + "|" + chat.participants.map(handleKey).sorted().joined(separator: ",")
            }
            return "p:" + handleKey(chat.primaryHandle)
        }

        var order: [String] = []
        var groups: [String: [ChatSummary]] = [:]
        for chat in chats {   // already newest first
            let k = key(chat)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(chat)
        }
        let pinned = Set(pinnedGUIDs)
        var aliases: [String: String] = [:]
        defer { guidAliases = aliases }
        return order.compactMap { k -> ChatSummary? in
            guard let members = groups[k], let latest = members.first else { return nil }
            let primary = members.first { pinned.contains($0.guid) } ?? latest
            for m in members where m.guid != primary.guid { aliases[m.guid] = primary.guid }
            var participants: [String] = []
            for m in members { for p in m.participants where !participants.contains(p) { participants.append(p) } }
            if !latest.isGroup { participants = [latest.primaryHandle] + participants.filter { $0 != latest.primaryHandle } }
            return ChatSummary(rowID: primary.rowID, guid: primary.guid, identifier: primary.identifier,
                               displayName: primary.displayName ?? latest.displayName, service: latest.service,
                               participants: latest.isGroup ? latest.participants : [participants[0]],
                               lastMessageDate: latest.lastMessageDate,
                               mergedRowIDs: members.map(\.rowID), latestGUID: latest.guid,
                               groupPhotoPath: primary.groupPhotoPath ?? latest.groupPhotoPath)
        }
    }

    private func persistKnownChats() {
        // Keep pinned chats plus the recent list so pins survive scrolling out of "recent".
        let keep = Set(pinnedGUIDs).union(recentChats.map(\.guid))
        knownChats = knownChats.filter { keep.contains($0.key) }
        if let data = try? JSONEncoder().encode(Array(knownChats.values)) {
            UserDefaults.standard.set(data, forKey: Keys.knownChats)
        }
    }

    // MARK: - People

    func person(for chat: ChatSummary) -> Person {
        // Keyed by the group photo too, so a new photo set in Messages shows up.
        let cacheKey = chat.guid + "|" + (chat.groupPhotoPath ?? "")
        if let cached = personCache[cacheKey] { return cached }
        let resolver = ContactResolver.shared
        let infos = chat.participants.map { resolver.info(for: $0) }
        let name: String
        let firstName: String
        var image: NSImage?
        if chat.isGroup {
            let firsts = zip(chat.participants, infos).map { handle, info in info?.firstName ?? ContactResolver.prettyHandle(handle) }
            name = chat.displayName ?? firsts.prefix(3).joined(separator: ", ") + (firsts.count > 3 ? " +\(firsts.count - 3)" : "")
            firstName = chat.displayName ?? (firsts.count == 2 ? firsts.joined(separator: " & ") : "the group")
            // The group photo set in Messages, else the members' own contact photos.
            image = chat.groupPhotoPath.flatMap { NSImage(contentsOfFile: $0) }
                ?? Self.groupComposite(infos.compactMap { $0?.imageData.flatMap(NSImage.init(data:)) })
        } else {
            let info = infos.first ?? nil
            name = info?.fullName ?? ContactResolver.prettyHandle(chat.primaryHandle)
            firstName = info?.firstName ?? Self.fallbackFirstName(chat.primaryHandle)
            image = info?.imageData.flatMap(NSImage.init(data:))
        }
        // Initials only from words that start with a letter ("+1 (555)…" gets a person glyph instead).
        let initials = name.split(separator: " ").compactMap { $0.first(where: \.isLetter).map(String.init) }
            .prefix(2).joined().uppercased()
        let hue = Self.stableHue(chat.guid)
        let person = Person(name: name, firstName: firstName, image: image,
                            initials: initials, hue: hue)
        personCache[cacheKey] = person
        return person
    }

    /// Two member photos overlapping diagonally (like Messages); one photo as is.
    static func groupComposite(_ photos: [NSImage]) -> NSImage? {
        guard let first = photos.first else { return nil }
        guard photos.count > 1 else { return first }
        let side: CGFloat = 128, small = side * 0.64
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            func draw(_ image: NSImage, in rect: NSRect, ring: Bool) {
                NSGraphicsContext.saveGraphicsState()
                let circle = NSBezierPath(ovalIn: rect)
                circle.addClip()
                let size = image.size
                let scale = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
                let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
                image.draw(in: NSRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
                                      width: drawSize.width, height: drawSize.height))
                NSGraphicsContext.restoreGraphicsState()
                if ring {
                    // Thin gap so the front photo reads as separate from the one behind it.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    let gap = NSBezierPath(ovalIn: rect.insetBy(dx: -4, dy: -4))
                    gap.append(NSBezierPath(ovalIn: rect).reversed)
                    NSColor.black.setFill()
                    gap.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            draw(photos[0], in: NSRect(x: 0, y: side - small, width: small, height: small), ring: false)
            draw(photos[1], in: NSRect(x: side - small, y: 0, width: small, height: small), ring: true)
            return true
        }
    }

    /// Same colour for the same person on every launch (`hashValue` is randomised per process).
    static func stableHue(_ key: String) -> Double {
        var hash: UInt32 = 2166136261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }   // FNV-1a
        return Double(hash % 360) / 360
    }

    /// `tanya.k@icloud.com` → `Tanya`; phone numbers stay as they are.
    static func fallbackFirstName(_ handle: String) -> String {
        guard let at = handle.firstIndex(of: "@") else { return ContactResolver.prettyHandle(handle) }
        let local = handle[..<at].split(whereSeparator: { ".-_+".contains($0) }).first.map(String.init) ?? String(handle[..<at])
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    func mePerson() -> Person {
        if let cached = personCache["__me__"] { return cached }
        let info = ContactResolver.shared.meInfo
        let name = info?.fullName ?? "Me"
        let initials = info == nil ? "ME" : name.split(separator: " ").compactMap { $0.first(where: \.isLetter).map(String.init) }.prefix(2).joined().uppercased()
        let person = Person(name: name, firstName: info?.firstName ?? "Me",
                            image: info?.imageData.flatMap(NSImage.init(data:)), initials: initials, hue: 0.58)
        personCache["__me__"] = person
        return person
    }

    /// Avatar for an incoming message: the chat's person, or the specific sender in a group.
    func person(forHandle handle: String?, in chat: ChatSummary) -> Person {
        guard chat.isGroup, let handle else { return person(for: chat) }
        let key = "h:" + handle
        if let cached = personCache[key] { return cached }
        let info = ContactResolver.shared.info(for: handle)
        let name = info?.fullName ?? ContactResolver.prettyHandle(handle)
        let initials = name.split(separator: " ").compactMap { $0.first(where: \.isLetter).map(String.init) }.prefix(2).joined().uppercased()
        let person = Person(name: name, firstName: info?.firstName ?? Self.fallbackFirstName(handle),
                            image: info?.imageData.flatMap(NSImage.init(data:)), initials: initials,
                            hue: Self.stableHue(handle))
        personCache[key] = person
        return person
    }

    func senderName(_ handle: String?) -> String {
        guard let handle else { return "" }
        return ContactResolver.shared.info(for: handle)?.firstName ?? ContactResolver.prettyHandle(handle)
    }

    // MARK: - Sending

    func send(from composer: ComposerModel) {
        guard let chat = chat(guid: composer.chatGUID), composer.canSend else { return }
        let draft = composer.takeDraft()
        let now = Date()
        var queue: [(MessageSender.Payload, String)] = []   // payload, pending message id
        var optimistic: [ChatMessage] = []

        func pendingMessage(text: String?, files: [URL], audio: Bool = false, transcript: String? = nil) -> ChatMessage {
            let atts = files.map { url in
                MessageAttachment(id: UUID().uuidString, url: url, mimeType: nil, transferName: url.lastPathComponent,
                                  kind: AttachmentKind.classify(mimeType: nil, uti: nil, filename: url.lastPathComponent))
            }
            return ChatMessage(id: "local-" + UUID().uuidString, rowID: .max, text: text, isFromMe: true,
                               date: now.addingTimeInterval(Double(optimistic.count) * 0.001), sender: nil,
                               attachments: atts, isAudioMessage: audio, delivery: .sending, transcript: transcript)
        }

        if let voice = draft.voiceNote {
            let transcript = draft.voiceTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = pendingMessage(text: nil, files: [voice], audio: true, transcript: transcript)
            optimistic.append(message)
            queue.append((.file(voice), message.id))
            if sendTranscripts, let transcript, !transcript.isEmpty {
                rememberTranscript(transcript)
                queue.append((.text(transcript), message.id))
            }
        }
        if !draft.files.isEmpty {
            let message = pendingMessage(text: nil, files: draft.files)
            optimistic.append(message)
            for file in draft.files { queue.append((.file(file), message.id)) }
        }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let message = pendingMessage(text: text, files: [])
            optimistic.append(message)
            queue.append((.text(text), message.id))
        }

        pending[chat.guid, default: []].append(contentsOf: optimistic)

        Task {
            if !MessageSender.isDryRun, Permissions.messagesAutomation != .granted {
                _ = await Permissions.requestMessagesAutomation()
            }
            var failed: [String: String] = [:]
            for (payload, id) in queue where failed[id] == nil {
                do {
                    try await MessageSender.send(payload, to: chat)
                } catch {
                    failed[id] = error.localizedDescription
                }
            }
            updatePending(chat.guid) { message in
                guard optimistic.contains(where: { $0.id == message.id }) else { return }
                // Accepted by Messages is all we know here; chat.db reports delivery and reads.
                message.delivery = failed[message.id].map { .failed($0) } ?? .sent
            }
            if MessageSender.isDryRun {
                // No real Messages round-trip in dry-run mode — keep the bubbles as if sent.
                return
            }
            await refresh(force: true)
        }
    }

    func dismissFailed(_ message: ChatMessage, in guid: String) {
        pending[guid]?.removeAll { $0.id == message.id }
    }

    private func updatePending(_ guid: String, _ body: (inout ChatMessage) -> Void) {
        guard var list = pending[guid] else { return }
        for i in list.indices { body(&list[i]) }
        pending[guid] = list
    }

    /// Drop optimistic bubbles once Messages has recorded the real ones.
    private func reconcilePending(_ guid: String, with loaded: [ChatMessage]) {
        guard var list = pending[guid], !list.isEmpty, !MessageSender.isDryRun else { return }
        let mine = loaded.filter(\.isFromMe)
        list.removeAll { local in
            guard local.delivery == .sent else { return false }
            if Date().timeIntervalSince(local.date) > 90 { return true }
            return mine.contains { real in
                real.date > local.date.addingTimeInterval(-15) &&
                ((local.trimmedText != nil && real.trimmedText == local.trimmedText) ||
                 (!local.attachments.isEmpty && real.attachments.count >= 1 &&
                  real.attachments.contains { a in local.attachments.contains { $0.displayName == a.displayName } }))
            }
        }
        pending[guid] = list
    }

    private func rememberTranscript(_ text: String) {
        sentTranscripts.append(text)
        if sentTranscripts.count > 100 { sentTranscripts.removeFirst(sentTranscripts.count - 100) }
        UserDefaults.standard.set(sentTranscripts, forKey: Keys.transcripts)
    }

    /// Voice notes we sent are followed by their transcript as a text message.
    /// Fold that text back under the audio bubble.
    private func mergeTranscripts(_ list: [ChatMessage]) -> [ChatMessage] {
        guard !sentTranscripts.isEmpty else { return list }
        let known = Set(sentTranscripts)
        var result: [ChatMessage] = []
        for message in list {
            if message.isFromMe, let text = message.trimmedText, known.contains(text), message.attachments.isEmpty,
               let last = result.last, last.isFromMe, last.voiceAttachment != nil, last.transcript == nil,
               message.date.timeIntervalSince(last.date) < 60 {
                result[result.count - 1].transcript = text
                continue
            }
            result.append(message)
        }
        return result
    }
}
