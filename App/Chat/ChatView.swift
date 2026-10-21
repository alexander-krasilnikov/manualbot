import Ports
import SwiftUI

struct ChatView: View {
    let chat: ChatViewModel
    let models: ModelSetupViewModel
    /// A photo to ask with when there is no nameplate at hand.
    var samplePhoto: Data?
    let onOpenCitation: (Citation) -> Void

    /// A matched photo opens like a citation of the page or section it is on.
    private func onOpenMatch(_ match: ImageMatch) {
        onOpenCitation(Citation(
            n: 0, chunkId: "", docId: match.docId, docTitle: match.docTitle, page: match.page, heading: match.heading,
            snippet: "", imageId: match.imageId))
    }

    @State private var renaming = false
    @State private var newTitle = ""
    @State private var showChats = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !models.canChat { LanguageModelBanner(models: models) }
            ScopeBar(chat: chat)
            Divider()
            transcript
            Divider()
            inputBar
        }
        .navigationTitle(chat.current?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Chats", systemImage: "list.bullet") { showChats = true }.accessibilityIdentifier("chatsButton")
                Button("New chat", systemImage: "square.and.pencil") { Task { await chat.newChat() } }
                    .disabled(chat.isGenerating).accessibilityIdentifier("newChatButton")
            }
        }
        .sheet(isPresented: $showChats) { ChatListSheet(chat: chat) }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let id = chat.currentID { Task { await chat.rename(id, to: newTitle) } } }
        }
        .task { await chat.load() }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty && chat.streaming == nil { EmptyChatHint(availability: chat.availability) }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        MessageView(
                            message: message, previousQuestion: index > 0 ? chat.messages[index - 1].text : nil,
                            photos: chat.photos, onOpen: onOpenCitation, onOpenMatch: onOpenMatch)
                            .id(message.id)
                    }
                    if let streaming = chat.streaming {
                        StreamingBubble(text: streaming).id("streaming")
                    }
                }
                .padding()
            }
            .onChange(of: chat.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: chat.streaming) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if chat.streaming != nil { proxy.scrollTo("streaming", anchor: .bottom) }
            else if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = disabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("chatDisabledReason")
            }
            if let error = chat.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if let photo = chat.attachedPhoto {
                AttachedPhotoChip(data: photo) { chat.removePhoto() }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotoAttachButtons(chat: chat, samplePhoto: samplePhoto)
                TextField(placeholder, text: Bindable(chat).draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .disabled(chat.availability != .ready)
                    .onSubmit { send() }
                    .accessibilityIdentifier("chatInput")
                if chat.isGenerating {
                    Button("Stop", systemImage: "stop.circle.fill") { chat.stop() }
                        .labelStyle(.iconOnly).font(.title).accessibilityIdentifier("stopButton")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .labelStyle(.iconOnly).font(.title).disabled(!chat.canSend).accessibilityIdentifier("sendButton")
                }
            }
        }
        .padding()
    }

    private func send() {
        guard chat.canSend else { return }
        inputFocused = false  // the answer needs the room
        Task { await chat.send() }
    }

    private var placeholder: String {
        switch chat.availability {
        case .ready: chat.attachedPhoto == nil ? "Ask about your documents" : "Add a question, or send the photo"
        case .modelNotReady: "Chat is unavailable"
        case .noDocuments: "Import a document to start"
        }
    }

    private var disabledReason: String? {
        switch chat.availability {
        case .ready: nil
        case .modelNotReady: models.canChat ? "Loading the language model…" : "The language model is still being prepared."
        case .noDocuments: "Import a document first, then ask questions about it."
        }
    }
}

// MARK: - Pieces

struct EmptyChatHint: View {
    let availability: ChatViewModel.Availability

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle).foregroundStyle(.secondary)
            Text(availability == .ready ? "Ask a question about your documents" : "Nothing to ask yet").font(.headline)
            Text("Answers come only from your documents and always show where they came from. If the documents don't say, you'll be told.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

struct LanguageModelBanner: View {
    let models: ModelSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(models.pendingRows) { row in ModelRowView(row: row) { Task { await models.retry(row.id) } } }
            if !models.hasFailure && !models.isWorking {
                Button("Download remaining models") { Task { await models.start() } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("startDownload")
            }
        }
        .padding()
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("languageModelBanner")
    }
}

/// Shows what a chat searches: the whole library, or the documents pinned to it.
struct ScopeBar: View {
    let chat: ChatViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(.secondary)
                if chat.pinnedDocuments.isEmpty {
                    Text("All documents").font(.subheadline).accessibilityIdentifier("scopeAll")
                } else {
                    ForEach(chat.pinnedDocuments) { doc in
                        Button { Task { await chat.togglePin(doc.id) } } label: {
                            Label(doc.title, systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon).font(.subheadline)
                        }
                        .buttonStyle(.bordered).accessibilityIdentifier("scope-\(doc.title)")
                    }
                    Button("Clear") { Task { await chat.clearPins() } }.font(.subheadline)
                }
                Menu {
                    ForEach(chat.documents) { doc in
                        Button { Task { await chat.togglePin(doc.id) } } label: {
                            if chat.pinnedIDs.contains(doc.id) { Label(doc.title, systemImage: "checkmark") } else { Text(doc.title) }
                        }
                    }
                } label: { Label("Narrow to…", systemImage: "line.3.horizontal.decrease.circle").font(.subheadline) }
                    .disabled(chat.documents.isEmpty).accessibilityIdentifier("pinMenu")
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
    }
}

struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    HStack(spacing: 8) { ProgressView(); Text("Searching your documents…").foregroundStyle(.secondary) }
                        .accessibilityIdentifier("thinking")
                } else {
                    Text(text).textSelection(.enabled).accessibilityIdentifier("streamingText")
                }
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 40)
        }
    }
}

struct MessageView: View {
    let message: MessageRecord
    let previousQuestion: String?
    let photos: PhotoLoader
    let onOpen: (Citation) -> Void
    let onOpenMatch: (ImageMatch) -> Void

    @State private var userPhoto: Data?
    @State private var citedPhotos: [CitedPhoto] = []

    struct CitedPhoto: Identifiable, Equatable {
        let citation: Citation
        let photo: PhotoRef
        var id: String { photo.id }
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    if message.hasAttachment {
                        Group {
                            if let userPhoto, let image = UIImage(data: userPhoto) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: 120, height: 90)
                            }
                        }
                        .accessibilityIdentifier("userPhoto")
                    }
                    if !message.text.isEmpty {
                        Text(message.text).padding(12).foregroundStyle(.white)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("userMessage")
                    }
                }
            }
            .task(id: message.id) { if message.hasAttachment { userPhoto = await photos.attachment(message) } }
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if !message.fromDocuments {
                        // Open lists the closest chunks below its reply; Conversational lists nothing.
                        Label("Not from your documents", systemImage: message.citations.isEmpty ? "bubble.left" : "globe")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("notFromDocumentsLabel")
                    }
                    Text(Self.linked(message.text, citations: message.citations))
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "cite", let n = Int(url.host() ?? ""), let c = message.citations.first(where: { $0.n == n }) {
                                onOpen(c); return .handled
                            }
                            return .discarded
                        })
                        .accessibilityIdentifier(message.notFound ? "notFoundMessage" : message.matchesOnly ? "matchesMessage" : "assistantMessage")
                    if message.stopped {
                        Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("stoppedLabel")
                    }
                    // Photos that matched the question's photo, or its words by meaning, sit beside the answer.
                    if !message.notFound, !message.imageMatches.isEmpty {
                        Text("Matching photos").font(.caption.bold()).foregroundStyle(.secondary)
                        ImageMatchGrid(matches: message.imageMatches, photos: photos, onOpen: onOpenMatch)
                    }
                    if !message.citations.isEmpty {
                        Text(isSuggestion ? "Closest chunks" : message.matchesOnly ? "Chunks from those pages" : "Sources")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(message.citations, id: \.n) { citation in
                            CitationChip(citation: citation, isSuggestion: isSuggestion) { onOpen(citation) }
                        }
                    }
                    if !citedPhotos.isEmpty && !message.matchesOnly {
                        Text("Photos on the cited pages").font(.caption.bold()).foregroundStyle(.secondary)
                        CitedPhotoStrip(items: citedPhotos, onOpen: onOpen)
                    }
                    if let query = message.standaloneQuery, query != previousQuestion {
                        Text("Searched for: \(query)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("standaloneQuery")
                    }
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 40)
            }
            .task(id: message.id) { await loadCitedPhotos() }
        }
    }

    /// The chunks listed are suggestions, not sources: the reply did not come from them.
    private var isSuggestion: Bool { message.notFound || !message.fromDocuments }

    /// Each photo stored on a cited page or section, and each cited photo chunk, once, beside the sources.
    private func loadCitedPhotos() async {
        guard !isSuggestion, !message.matchesOnly else { return }
        var found: [CitedPhoto] = []
        for citation in message.citations {
            for photo in await photos.cited(citation) where !found.contains(where: { $0.id == photo.id }) {
                found.append(CitedPhoto(citation: citation, photo: photo))
            }
        }
        citedPhotos = found
    }

    /// The answer with each `[n]` marker turned into a tappable link.
    static func linked(_ text: String, citations: [Citation]) -> AttributedString {
        var result = AttributedString(text)
        let valid = Set(citations.map(\.n))
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let n = Int(ns.substring(with: match.range(at: 1))), valid.contains(n),
                let range = Range(match.range, in: text), let attributed = Range(range, in: result) else { continue }
            result[attributed].link = URL(string: "cite://\(n)")
            result[attributed].font = .body.bold()
        }
        return result
    }
}

struct CitationChip: View {
    let citation: Citation
    let isSuggestion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(citation.n)").font(.caption.bold()).frame(width: 22, height: 22)
                    .background(.tint.opacity(0.2), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(citation.docTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source \(citation.n): \(citation.docTitle), \(location)")
        .accessibilityIdentifier("citation-\(citation.n)")
    }

    private var location: String {
        [citation.page.map { "page \($0)" }, citation.heading.flatMap { $0.isEmpty ? nil : "“\($0)”" }]
            .compactMap { $0 }.joined(separator: " · ").ifEmpty("chunk")
    }
}

/// Thumbnails of the photos on the pages an answer cites. Tapping one opens the page it is on.
struct CitedPhotoStrip: View {
    let items: [MessageView.CitedPhoto]
    let onOpen: (Citation) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button { onOpen(item.citation) } label: {
                        if let image = UIImage(data: item.photo.data) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 96, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photo from source \(item.citation.n), \(item.citation.docTitle)")
                    .accessibilityIdentifier("citedPhoto-\(item.citation.n)")
                }
            }
        }
        .accessibilityIdentifier("citedPhotos")
    }
}

/// The library photos that matched a photo question, with the document and page each one is on.
struct ImageMatchGrid: View {
    let matches: [ImageMatch]
    let photos: PhotoLoader
    let onOpen: (ImageMatch) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                ImageMatchCard(match: match, photos: photos) { onOpen(match) }.accessibilityIdentifier("imageMatch-\(index + 1)")
            }
        }
    }
}

private struct ImageMatchCard: View {
    let match: ImageMatch
    let photos: PhotoLoader
    let action: () -> Void
    @State private var thumbnail: MatchThumbnail?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let data = thumbnail?.data, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: thumbnail?.documentDeleted == true ? "trash" : "photo").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(match.docTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if thumbnail?.documentDeleted == true {
                    Text("document deleted").font(.caption2).foregroundStyle(.orange).accessibilityIdentifier("matchDeleted")
                }
            }
            .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(thumbnail?.documentDeleted == true)
        .accessibilityElement(children: .combine)
        .task(id: match.id) { thumbnail = await photos.matched(match) }
    }

    private var location: String {
        [match.page.map { "page \($0)" }, match.heading.flatMap { $0.isEmpty ? nil : "“\($0)”" }].compactMap { $0 }.joined(separator: " · ")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct ChatListSheet: View {
    let chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: ChatRecord?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(chat.chats) { item in
                    Button {
                        Task { await chat.select(item.id); dismiss() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.title).font(.headline)
                                Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.id == chat.currentID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await chat.delete(item.id) } }
                        Button("Rename") { newTitle = item.title; renaming = item }.tint(.blue)
                    }
                }
            }
            .overlay { if chat.chats.isEmpty { ContentUnavailableView("No chats yet", systemImage: "bubble.left") } }
            .navigationTitle("Chats")
            .toolbar { Button("Done") { dismiss() } }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { if let item = renaming { Task { await chat.rename(item.id, to: newTitle) } } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
