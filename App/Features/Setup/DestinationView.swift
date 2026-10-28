import SwiftUI

/// Where backups go: a new private channel, or a chat the owner can already post in.
struct DestinationView: View {
    let telegram: TelegramService
    /// Called once the choice is saved.
    let onChosen: () -> Void

    @State private var chats: [ChatSummary]?
    @State private var loadFailed = false
    @State private var errorText: String?
    @State private var isWorking = false

    var body: some View {
        ScreenLayout(title: "Choose where backups go", subtitle: "A private channel works best.") {
            VStack(alignment: .leading, spacing: 16) {
                PrimaryButton(title: "Create backup channel", isWorking: isWorking, action: createChannel)
                if let errorText { ErrorLine(text: errorText) }
                Text("Or use an existing chat")
                    .font(.headline)
                    .padding(.top, 12)
                chatList
            }
        }
        .task { await loadChats() }
    }

    @ViewBuilder private var chatList: some View {
        if let chats {
            VStack(spacing: 0) {
                ForEach(chats) { chat in
                    if chat.id != chats.first?.id {
                        Divider().padding(.leading, 60)
                    }
                    ChatRow(chat: chat, action: { choose(chat) })
                        .disabled(isWorking)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else if loadFailed {
            QuietButton(title: "Couldn't load your chats. Try again", action: { Task { await loadChats() } })
                .frame(maxWidth: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }

    /// Saved Messages first, then the rest in Telegram's own order, each chat once.
    nonisolated static func pickerOrder(_ chats: [ChatSummary]) -> [ChatSummary] {
        let ordered = chats.filter { $0.kind == .savedMessages } + chats.filter { $0.kind != .savedMessages }
        var seen = Set<Int64>()
        return ordered.filter { seen.insert($0.id).inserted }
    }

    private func loadChats() async {
        loadFailed = false
        do {
            chats = Self.pickerOrder(try await telegram.listWritableChats())
        } catch {
            log.warning("Could not list chats: \(error)", category: "setup")
            loadFailed = true
        }
    }

    private func createChannel() {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        Task {
            do {
                let chat = try await telegram.createBackupChannel()
                log.info("Created the backup channel \(chat.id)", category: "setup")
                save(chat)
            } catch let error as TelegramError {
                errorText = error.message
            } catch {
                log.warning("Could not create the backup channel: \(error)", category: "setup")
                errorText = "Couldn't create the channel. Try again."
            }
            isWorking = false
        }
    }

    private func choose(_ chat: ChatSummary) {
        guard !isWorking else { return }
        save(chat)
    }

    private func save(_ chat: ChatSummary) {
        telegram.setDestination(chat)
        log.info("Destination set: \(chat.id) (\(chat.kind))", category: "setup")
        onChosen()
    }
}

/// One tappable chat in the list.
private struct ChatRow: View {
    let chat: ChatSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(chat.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch chat.kind {
        case .savedMessages: return "bookmark.fill"
        case .channel: return "megaphone"
        case .group: return "person.2"
        }
    }
}
