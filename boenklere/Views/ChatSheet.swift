import SwiftUI
import UIKit

struct ChatSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let listing: APIListing
    var isModalStyle: Bool = true
    @StateObject private var socketClient = ChatSocketClient()
    @State private var conversation: APIConversation?
    @State private var messages: [APIMessage] = []
    @State private var messageText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showListingSheet = false
    @State private var listingSheetDetent: PresentationDetent = .large
    @State private var showUserReviews = false
    @State private var didMarkRead = false

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(
                title: listing.title,
                isModalStyle: isModalStyle
            ) {
                dismiss()
            }

            ListingRow(listing: listing, userLocation: nil) {
                showListingSheet = true
            }

            Divider()
                .padding(.leading, 76)

            if !authManager.isAuthenticated {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Logg inn for å sende meldinger")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messageRows) { row in
                                MessageBubble(
                                    message: row.message,
                                    isOutgoing: row.isOutgoing,
                                    avatarName: row.isOutgoing ? nil : displayUserName,
                                    showsAvatar: row.showAvatar,
                                    showsTimestamp: row.showTimestamp,
                                    isGroupedWithPrevious: row.isGroupedWithPrevious,
                                    isGroupedWithNext: row.isGroupedWithNext,
                                    topSpacing: row.topSpacing,
                                    onAvatarTap: row.isOutgoing ? nil : { showUserReviews = true }
                                )
                                .id(row.message.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .background(Color(.systemGroupedBackground))
                    .onChange(of: messages.count) { _, _ in
                        if let lastId = messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if authManager.isAuthenticated {
                inputBar
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea(.keyboard, edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await startConversation()
        }
        .onAppear {
            socketClient.onMessage = { message in
                Task { @MainActor in
                    appendMessage(message)
                }
            }
        }
        .onDisappear {
            socketClient.disconnect()
            Task { await markListingConversationReadIfNeeded() }
        }
        .onChange(of: conversation?.id) { _, _ in
            connectIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                connectIfNeeded()
            case .background, .inactive:
                socketClient.disconnect()
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showListingSheet) {
            ListingDetailSheet(
                listing: listing,
                sheetDetent: $listingSheetDetent,
                userLocation: nil
            )
            .environmentObject(authManager)
            .presentationDetents([.large], selection: $listingSheetDetent)
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showUserReviews) {
            UserReviewsSheet(userId: listing.userId, userName: displayUserName)
        }
    }

    private var displayUserName: String {
        let name = listing.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Bruker" : name
    }

    private var messageRows: [MessageRow] {
        makeMessageRows(messages: messages, currentUserId: authManager.userIdentifier)
    }

    private var inputBar: some View {
        ChatInputBar(
            text: $messageText,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onSend: { Task { await sendMessage() } },
            isSendDisabled: conversation == nil
        )
    }

    @MainActor
    private func startConversation() async {
        guard authManager.isAuthenticated else { return }
        guard let userId = authManager.userIdentifier else { return }

        isLoading = true
        errorMessage = nil

        guard let listingId = listing.id else {
            errorMessage = "Kunne ikke starte chat"
            isLoading = false
            return
        }

        do {
            let convo = try await APIService.shared.createConversation(
                listingId: listingId,
                buyerId: userId
            )
            conversation = convo
            messages = try await APIService.shared.getMessages(conversationId: convo.id)
        } catch {
            errorMessage = "Kunne ikke starte chat"
        }

        isLoading = false
    }

    @MainActor
    private func sendMessage() async {
        guard let conversation else { return }
        guard let userId = authManager.userIdentifier else { return }

        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let message = try await APIService.shared.sendMessage(
                conversationId: conversation.id,
                senderId: userId,
                body: trimmed
            )
            appendMessage(message)
            messageText = ""
        } catch {
            errorMessage = "Kunne ikke sende melding"
        }

        isLoading = false
    }

    @MainActor
    private func appendMessage(_ message: APIMessage) {
        if messages.contains(where: { $0.id == message.id }) {
            return
        }
        messages.append(message)
        if message.senderId != authManager.userIdentifier {
            didMarkRead = false
        }
    }

    @MainActor
    private func markListingConversationReadIfNeeded() async {
        guard !didMarkRead else { return }
        guard let conversation else { return }
        guard let userId = authManager.userIdentifier else { return }
        do {
            try await APIService.shared.markConversationRead(conversationId: conversation.id, userId: userId)
            didMarkRead = true
            await authManager.refreshUnreadMessageCount()
            NotificationCenter.default.post(name: .didMarkConversationRead, object: conversation.id)
        } catch {
            return
        }
    }

    private func connectIfNeeded() {
        guard scenePhase == .active else { return }
        guard let conversationId = conversation?.id else { return }
        guard let userId = authManager.userIdentifier else { return }
        guard let url = APIService.shared.webSocketURL(conversationId: conversationId, userId: userId) else { return }
        socketClient.connect(conversationId: conversationId, userId: userId, url: url)
    }
}

struct ConversationsSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @State private var conversations: [APIConversationSummary] = []
    @State private var listingDetails: [Int64: APIListing] = [:]
    @State private var userNames: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    let showsBackButton: Bool
    let showsCloseButton: Bool

    init(showsBackButton: Bool = false, showsCloseButton: Bool = true) {
        self.showsBackButton = showsBackButton
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            if !authManager.isAuthenticated {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Logg inn for å se meldinger")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        if isLoading && conversations.isEmpty {
                            ProgressView()
                                .padding(.top, 12)
                        } else if listingGroups.isEmpty {
                            Text("Ingen meldinger enda")
                                .foregroundColor(.secondary)
                                .padding(.top, 12)
                        } else {
                            ForEach(listingGroups) { group in
                                NavigationLink {
                                    ListingConversationsView(group: group, userNames: userNames)
                                        .environmentObject(authManager)
                                } label: {
                                    ListingConversationRow(
                                        group: group,
                                        listing: listingDetails[group.listingId]
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
                .refreshable {
                    await loadConversations()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadConversations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didMarkConversationRead)) { _ in
            Task { await loadConversations() }
        }
    }

    private var sheetHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 5)
                .padding(.bottom, 3)

            HStack {
                if showsBackButton {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                    }
                }

                Text("Meldinger")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                if showsCloseButton {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray, in: Circle())
                    }
                } else if showsBackButton {
                    Color.clear
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var listingGroups: [ListingConversationGroup] {
        let withMessages = conversations.filter { hasMessages($0) }
        let grouped = Dictionary(grouping: withMessages, by: { $0.listingId })

        let groups = grouped.map { listingId, groupConversations in
            let sorted = groupConversations.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            let listingTitle = sorted.first?.listingTitle ?? "Annonse"
            let listingImageUrl = sorted.first?.listingImageUrl
            let lastMessage = sorted.first?.lastMessage
            let updatedAt = sorted.first?.updatedAt
            let hasUnread = sorted.contains { ($0.unreadCount ?? 0) > 0 }
            return ListingConversationGroup(
                listingId: listingId,
                listingTitle: listingTitle,
                listingImageUrl: listingImageUrl,
                lastMessage: lastMessage,
                updatedAt: updatedAt,
                conversations: sorted,
                hasUnread: hasUnread
            )
        }

        return groups.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    private func hasMessages(_ conversation: APIConversationSummary) -> Bool {
        guard let lastMessage = conversation.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !lastMessage.isEmpty
    }

    @MainActor
    private func loadConversations() async {
        guard let userId = authManager.userIdentifier else { return }

        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await APIService.shared.getConversations(userId: userId)
            conversations = fetched
            authManager.updateUnreadCount(with: fetched)
            let withMessages = fetched.filter { hasMessages($0) }
            Task {
                await hydrateMetadata(for: withMessages)
            }
        } catch is CancellationError {
            return
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            errorMessage = "Kunne ikke hente meldinger"
        }
        isLoading = false
    }

    @MainActor
    private func hydrateMetadata(for conversations: [APIConversationSummary]) async {
        if Task.isCancelled { return }

        let listingIds = Set(conversations.map { $0.listingId })
        let missingListingIds = listingIds.filter { listingDetails[$0] == nil }

        if !missingListingIds.isEmpty {
            var fetchedListings: [Int64: APIListing] = [:]
            await withTaskGroup(of: (Int64, APIListing?).self) { group in
                for listingId in missingListingIds {
                    group.addTask {
                        let listing = try? await APIService.shared.getListing(id: listingId)
                        return (listingId, listing)
                    }
                }

                for await (listingId, listing) in group {
                    if let listing {
                        fetchedListings[listingId] = listing
                    }
                }
            }

            if !fetchedListings.isEmpty {
                await MainActor.run {
                    listingDetails.merge(fetchedListings) { _, new in new }
                }
            }
        }

        let participantIds = Set(conversations.flatMap { [$0.buyerId, $0.sellerId] })
        let missingParticipantIds = participantIds.filter { userNames[$0] == nil }

        if !missingParticipantIds.isEmpty {
            var fetchedNames: [String: String] = [:]
            await withTaskGroup(of: (String, String?).self) { group in
                for participantId in missingParticipantIds {
                    group.addTask {
                        let user = try? await APIService.shared.getUser(userId: participantId)
                        let name = user?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (participantId, name?.isEmpty == false ? name : nil)
                    }
                }

                for await (participantId, name) in group {
                    if let name {
                        fetchedNames[participantId] = name
                    }
                }
            }

            if !fetchedNames.isEmpty {
                await MainActor.run {
                    userNames.merge(fetchedNames) { _, new in new }
                }
            }
        }
    }
}

private struct ListingConversationGroup: Identifiable {
    let listingId: Int64
    let listingTitle: String
    let listingImageUrl: String?
    let lastMessage: String?
    let updatedAt: String?
    let conversations: [APIConversationSummary]
    let hasUnread: Bool

    var id: Int64 { listingId }
}

private struct ListingConversationRow: View {
    let group: ListingConversationGroup
    let listing: APIListing?

    var body: some View {
        HStack(spacing: 12) {
            ListingThumbnail(imageUrl: listing?.imageUrl ?? group.listingImageUrl)

            VStack(alignment: .leading, spacing: 4) {
                Text(listing?.title ?? group.listingTitle)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(listing?.description ?? " ")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if group.hasUnread {
                Text("1")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue, in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ListingConversationsView: View {
    let group: ListingConversationGroup
    let userNames: [String: String]
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let currentUserId = authManager.userIdentifier

        VStack(spacing: 0) {
            ChatHeader(title: group.listingTitle, isModalStyle: false) {
                dismiss()
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(group.conversations) { conversation in
                        let otherId = currentUserId == conversation.buyerId
                            ? conversation.sellerId
                            : conversation.buyerId
                        let otherName = userNames[otherId]

                        NavigationLink {
                            ConversationChatSheet(conversation: conversation, isModalStyle: false)
                                .environmentObject(authManager)
                        } label: {
                            ListingConversationDetailRow(
                                conversation: conversation,
                                participantName: otherName
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ListingConversationDetailRow: View {
    let conversation: APIConversationSummary
    let participantName: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 44, height: 44)

                Text(initials)
                    .font(.headline)
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let lastMessage = conversation.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !lastMessage.isEmpty {
                    Text(lastMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Ingen meldinger")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if (conversation.unreadCount ?? 0) > 0 {
                Text("Ny melding")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.blue, in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var displayName: String {
        let name = participantName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Interessent" : name
    }

    private var initials: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = name.first {
            return String(first).uppercased()
        }
        return "?"
    }
}

private struct ListingThumbnail: View {
    let imageUrl: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemGray5))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let imageUrl,
              let url = URL(string: imageUrl) else { return }

        if let cached = ImageCache.shared.image(for: imageUrl) {
            await MainActor.run {
                self.image = cached
            }
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let uiImage = UIImage(data: data) {
                await MainActor.run {
                    self.image = uiImage
                }
                ImageCache.shared.insert(uiImage, for: imageUrl)
            }
        } catch {
            print("Failed to load listing thumbnail: \(error)")
        }
    }
}

private struct UserAvatarButton: View {
    let name: String
    let size: CGFloat
    let action: (() -> Void)?

    init(name: String, size: CGFloat = 36, action: (() -> Void)? = nil) {
        self.name = name
        self.size = size
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) {
                avatarView
            }
            .buttonStyle(.plain)
        } else {
            avatarView
        }
    }

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.15))
            Text(initials)
                .font(.system(size: max(size * 0.4, 12), weight: .semibold))
                .foregroundColor(.blue)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        if let first = parts.first?.first {
            if parts.count > 1, let last = parts.last?.first {
                return "\(first)\(last)".uppercased()
            }
            return String(first).uppercased()
        }
        return "?"
    }
}

private struct UserReviewsSheet: View {
    let userId: String
    let userName: String
    @Environment(\.dismiss) var dismiss
    @State private var reviews: [UserReviewItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(.systemGray3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 5)
                    .padding(.bottom, 3)

                HStack {
                    Text("Vurderinger")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray, in: Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            ScrollView {
                VStack(spacing: 12) {
                    Text("For \(userName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if isLoading {
                        ProgressView()
                            .padding(.top, 12)
                    } else if reviews.isEmpty {
                        Text("Ingen vurderinger enda")
                            .foregroundColor(.secondary)
                            .padding(.top, 12)
                    } else {
                        ForEach(reviews) { review in
                            UserReviewRow(item: review)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .refreshable {
                await loadReviews()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadReviews()
        }
    }

    @MainActor
    private func loadReviews() async {
        isLoading = true
        errorMessage = nil
        do {
            let raw = try await APIService.shared.getReviewsByReviewee(userId: userId)
            let items = await buildReviewItems(reviews: raw)
            reviews = items
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Kunne ikke hente vurderinger"
        }
        isLoading = false
    }

    private func buildReviewItems(reviews: [APIReview]) async -> [UserReviewItem] {
        guard !reviews.isEmpty else { return [] }

        let listingIds = Set(reviews.map { $0.listingId })
        let reviewerIds = Set(reviews.map { $0.reviewerId })

        var listingMap: [Int64: APIListing] = [:]
        var reviewerMap: [String: String] = [:]

        await withTaskGroup(of: (Int64, APIListing?).self) { group in
            for listingId in listingIds {
                group.addTask {
                    let listing = try? await APIService.shared.getListing(id: listingId)
                    return (listingId, listing)
                }
            }

            for await (listingId, listing) in group {
                if let listing {
                    listingMap[listingId] = listing
                }
            }
        }

        await withTaskGroup(of: (String, String?).self) { group in
            for reviewerId in reviewerIds {
                group.addTask {
                    let user = try? await APIService.shared.getUser(userId: reviewerId)
                    let name = user?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (reviewerId, name?.isEmpty == false ? name : nil)
                }
            }

            for await (reviewerId, name) in group {
                if let name {
                    reviewerMap[reviewerId] = name
                }
            }
        }

        let sorted = reviews.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        return sorted.map { review in
            let listingTitle = listingMap[review.listingId]?.title ?? "Oppdrag"
            let reviewerName = reviewerMap[review.reviewerId] ?? "Bruker \(review.reviewerId.suffix(4))"
            return UserReviewItem(
                id: "\(review.id ?? 0)-\(review.reviewerId)",
                listingTitle: listingTitle,
                reviewerName: reviewerName,
                rating: review.rating,
                comment: review.comment,
                createdAt: review.createdAt
            )
        }
    }
}

private struct UserReviewItem: Identifiable {
    let id: String
    let listingTitle: String
    let reviewerName: String
    let rating: Int
    let comment: String?
    let createdAt: String?
}

private struct UserReviewRow: View {
    let item: UserReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.listingTitle)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                ReviewStars(rating: item.rating)
            }

            Text("Fra \(item.reviewerName)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let comment = item.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
               !comment.isEmpty {
                Text(comment)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            if let dateText = ReviewDateFormatter.shared.format(item.createdAt) {
                Text(dateText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReviewStars: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundColor(star <= rating ? .yellow : .secondary)
            }
        }
    }
}

private final class ReviewDateFormatter {
    static let shared = ReviewDateFormatter()
    private let outputFormatter: DateFormatter
    private let inputFormatters: [DateFormatter]

    private init() {
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = .current
        output.dateFormat = "dd.MM.yyyy"
        outputFormatter = output

        let inputWithMillis = DateFormatter()
        inputWithMillis.locale = Locale(identifier: "en_US_POSIX")
        inputWithMillis.timeZone = .current
        inputWithMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"

        let inputWithoutMillis = DateFormatter()
        inputWithoutMillis.locale = Locale(identifier: "en_US_POSIX")
        inputWithoutMillis.timeZone = .current
        inputWithoutMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        inputFormatters = [inputWithMillis, inputWithoutMillis]
    }

    func format(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: " ", with: "T")

        var base = normalized
        var fraction: String?

        if let dotIndex = normalized.firstIndex(of: ".") {
            base = String(normalized[..<dotIndex])
            let afterDot = normalized[normalized.index(after: dotIndex)...]
            let digits = afterDot.prefix { $0.isNumber }
            if !digits.isEmpty {
                fraction = String(digits)
            }
        }

        var candidates: [String] = []
        if let fraction {
            let padded = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            candidates.append("\(base).\(padded)")
        }
        candidates.append(base)

        for candidate in candidates {
            for formatter in inputFormatters {
                if let date = formatter.date(from: candidate) {
                    return outputFormatter.string(from: date)
                }
            }
        }
        return nil
    }
}

private struct ConversationRow: View {
    let conversation: APIConversationSummary

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 44, height: 44)

                Text(initials)
                    .font(.headline)
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.listingTitle)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let lastMessage = conversation.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !lastMessage.isEmpty {
                    Text(lastMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Start samtale")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var initials: String {
        let trimmed = conversation.listingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first {
            return String(first).uppercased()
        }
        return "?"
    }
}

private struct ChatHeader: View {
    let title: String
    let isModalStyle: Bool
    let trailingView: AnyView?
    let onBack: () -> Void

    init(
        title: String,
        isModalStyle: Bool,
        trailingView: AnyView? = nil,
        onBack: @escaping () -> Void
    ) {
        self.title = title
        self.isModalStyle = isModalStyle
        self.trailingView = trailingView
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 5)
                .padding(.bottom, 3)
                .opacity(isModalStyle ? 1 : 0)

            HStack(spacing: 8) {
                if !isModalStyle {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                    }
                }

                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let trailingView {
                    trailingView
                }

                if isModalStyle {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray, in: Circle())
                    }
                } else if trailingView == nil {
                    Color.clear
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

struct ConversationChatSheet: View {
    let conversation: APIConversationSummary
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var socketClient = ChatSocketClient()
    @State private var messages: [APIMessage] = []
    @State private var messageText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    var isModalStyle: Bool = true
    @State private var listing: APIListing?
    @State private var isLoadingListing = false
    @State private var showListingSheet = false
    @State private var listingSheetDetent: PresentationDetent = .large
    @State private var showUserReviews = false
    @State private var otherUserName: String?
    @State private var firstUnreadMessageId: Int64?
    @State private var didMarkRead = false

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(
                title: conversation.listingTitle,
                isModalStyle: isModalStyle
            ) {
                dismiss()
            }

            if let listing {
                ListingRow(listing: listing, userLocation: nil) {
                    showListingSheet = true
                }

                Divider()
                    .padding(.leading, 76)
            } else if isLoadingListing {
                ProgressView()
                    .padding(.vertical, 8)
            }

            if !authManager.isAuthenticated {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Logg inn for å sende meldinger")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messageRows) { row in
                                if row.message.id == firstUnreadMessageId {
                                    NewMessagePill()
                                }
                                MessageBubble(
                                    message: row.message,
                                    isOutgoing: row.isOutgoing,
                                    avatarName: row.isOutgoing ? nil : displayOtherName,
                                    showsAvatar: row.showAvatar,
                                    showsTimestamp: row.showTimestamp,
                                    isGroupedWithPrevious: row.isGroupedWithPrevious,
                                    isGroupedWithNext: row.isGroupedWithNext,
                                    topSpacing: row.topSpacing,
                                    onAvatarTap: row.isOutgoing ? nil : { showUserReviews = true }
                                )
                                .id(row.message.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .background(Color(.systemGroupedBackground))
                    .onChange(of: messages.count) { _, _ in
                        if let lastId = messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if authManager.isAuthenticated {
                inputBar
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea(.keyboard, edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadMessages()
            await loadListing()
            await loadOtherUser()
        }
        .onAppear {
            socketClient.onMessage = { message in
                Task { @MainActor in
                    appendMessage(message)
                }
            }
        }
        .onDisappear {
            socketClient.disconnect()
            Task { await markConversationReadIfNeeded() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                connectIfNeeded()
            case .background, .inactive:
                socketClient.disconnect()
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showListingSheet) {
            if let listing {
                ListingDetailSheet(
                    listing: listing,
                    sheetDetent: $listingSheetDetent,
                    userLocation: nil
                )
                .environmentObject(authManager)
                .presentationDetents([.large], selection: $listingSheetDetent)
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $showUserReviews) {
            if let otherUserId {
                UserReviewsSheet(userId: otherUserId, userName: displayOtherName)
            }
        }
    }

    private var inputBar: some View {
        ChatInputBar(
            text: $messageText,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onSend: { Task { await sendMessage() } }
        )
    }

    private var otherUserId: String? {
        guard let currentUserId = authManager.userIdentifier else { return conversation.buyerId }
        return currentUserId == conversation.buyerId ? conversation.sellerId : conversation.buyerId
    }

    private var displayOtherName: String {
        let name = otherUserName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            return name
        }
        guard let otherUserId else { return "Bruker" }
        return "Bruker \(otherUserId.suffix(4))"
    }

    private var messageRows: [MessageRow] {
        makeMessageRows(messages: messages, currentUserId: authManager.userIdentifier)
    }

    @MainActor
    private func loadMessages() async {
        guard authManager.isAuthenticated else { return }

        isLoading = true
        errorMessage = nil
        do {
            messages = try await APIService.shared.getMessages(conversationId: conversation.id)
            connectIfNeeded()
            updateUnreadMarker()
        } catch {
            errorMessage = "Kunne ikke hente meldinger"
        }
        isLoading = false
    }

    @MainActor
    private func loadListing() async {
        guard listing == nil else { return }

        isLoadingListing = true
        do {
            listing = try await APIService.shared.getListing(id: conversation.listingId)
        } catch {
            listing = nil
        }
        isLoadingListing = false
    }

    @MainActor
    private func loadOtherUser() async {
        guard let otherUserId else { return }

        if let listing, listing.userId == otherUserId {
            let listingName = listing.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !listingName.isEmpty {
                otherUserName = listingName
                return
            }
        }

        do {
            let user = try await APIService.shared.getUser(userId: otherUserId)
            otherUserName = user.name
        } catch {
            otherUserName = nil
        }
    }

    @MainActor
    private func sendMessage() async {
        guard let userId = authManager.userIdentifier else { return }

        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let message = try await APIService.shared.sendMessage(
                conversationId: conversation.id,
                senderId: userId,
                body: trimmed
            )
            appendMessage(message)
            messageText = ""
        } catch {
            errorMessage = "Kunne ikke sende melding"
        }

        isLoading = false
    }

    @MainActor
    private func appendMessage(_ message: APIMessage) {
        if messages.contains(where: { $0.id == message.id }) {
            return
        }
        messages.append(message)
        if message.senderId != authManager.userIdentifier {
            didMarkRead = false
        }
    }

    @MainActor
    private func markConversationReadIfNeeded() async {
        guard !didMarkRead else { return }
        guard let userId = authManager.userIdentifier else { return }
        do {
            try await APIService.shared.markConversationRead(conversationId: conversation.id, userId: userId)
            didMarkRead = true
            await authManager.refreshUnreadMessageCount()
            NotificationCenter.default.post(name: .didMarkConversationRead, object: conversation.id)
        } catch {
            return
        }
    }

    @MainActor
    private func updateUnreadMarker() {
        guard let userId = authManager.userIdentifier else { return }
        let lastReadAt = MessageDateParser.shared.date(from: conversation.lastReadAt)
        firstUnreadMessageId = messages.first(where: { message in
            guard message.senderId != userId else { return false }
            guard let createdAt = message.createdAt else { return lastReadAt == nil }
            guard let createdDate = MessageDateParser.shared.date(from: createdAt) else { return true }
            guard let lastReadAt else { return true }
            return createdDate > lastReadAt
        })?.id
    }

    private func connectIfNeeded() {
        guard scenePhase == .active else { return }
        guard let userId = authManager.userIdentifier else { return }
        guard let url = APIService.shared.webSocketURL(conversationId: conversation.id, userId: userId) else { return }
        socketClient.connect(conversationId: conversation.id, userId: userId, url: url)
    }
}

private struct ChatInputBar: View {
    @Binding var text: String
    let isLoading: Bool
    let errorMessage: String?
    let onSend: () -> Void
    var isSendDisabled = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedText.isEmpty && !isLoading && !isSendDisabled
    }

    var body: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                TextField("Skriv en melding", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSend ? Color(red: 0, green: 0.52, blue: 1) : .secondary)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MessageBubble: View {
    let message: APIMessage
    let isOutgoing: Bool
    let avatarName: String?
    let showsAvatar: Bool
    let showsTimestamp: Bool
    let isGroupedWithPrevious: Bool
    let isGroupedWithNext: Bool
    let topSpacing: CGFloat
    let onAvatarTap: (() -> Void)?

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 8) {
                if isOutgoing {
                    Spacer(minLength: 40)
                }

                if !isOutgoing {
                    if showsAvatar, let avatarName = trimmedAvatarName {
                        UserAvatarButton(name: avatarName, size: 32, action: onAvatarTap)
                    } else {
                        Color.clear
                            .frame(width: 32, height: 32)
                    }
                }

                bubbleView
                    .frame(maxWidth: bubbleMaxWidth, alignment: isOutgoing ? .trailing : .leading)

                if !isOutgoing {
                    Spacer(minLength: 40)
                }
            }

            if showsTimestamp, let timestampText {
                HStack(spacing: 0) {
                    if isOutgoing {
                        Spacer()
                    }

                    Text(timestampText)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if !isOutgoing {
                        Spacer()
                    }
                }
                .padding(.leading, isOutgoing ? 0 : 40)
                .padding(.top, 4)
            }
        }
        .padding(.top, topSpacing)
    }

    private var bubbleColor: Color {
        isOutgoing ? Color(red: 0, green: 0.52, blue: 1) : Color(.systemGray5)
    }

    private var bubbleBackground: some View {
        let large: CGFloat = 20
        let small: CGFloat = 6
        let topLeading = isOutgoing ? large : (isGroupedWithPrevious ? small : large)
        let topTrailing = isOutgoing ? (isGroupedWithPrevious ? small : large) : large
        let bottomLeading = isOutgoing ? large : (isGroupedWithNext ? small : large)
        let bottomTrailing = isOutgoing ? (isGroupedWithNext ? small : large) : large

        return UnevenRoundedRectangle(
            topLeadingRadius: topLeading,
            bottomLeadingRadius: bottomLeading,
            bottomTrailingRadius: bottomTrailing,
            topTrailingRadius: topTrailing
        )
        .fill(bubbleColor)
    }

    private var bubbleView: some View {
        Text(message.body)
            .font(.body)
            .foregroundColor(isOutgoing ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleBackground)
    }

    private var bubbleMaxWidth: CGFloat {
        UIScreen.main.bounds.width * 0.68
    }

    private var timestampText: String? {
        guard let createdAt = message.createdAt else { return nil }
        return MessageTimestampFormatter.shared.format(createdAt)
    }

    private var trimmedAvatarName: String? {
        let name = avatarName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
}

private final class MessageTimestampFormatter {
    static let shared = MessageTimestampFormatter()
    private let outputFormatter: DateFormatter
    private let inputFormatters: [DateFormatter]

    private init() {
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = .current
        output.dateFormat = "HH:mm"
        outputFormatter = output

        let inputWithMillis = DateFormatter()
        inputWithMillis.locale = Locale(identifier: "en_US_POSIX")
        inputWithMillis.timeZone = .current
        inputWithMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"

        let inputWithoutMillis = DateFormatter()
        inputWithoutMillis.locale = Locale(identifier: "en_US_POSIX")
        inputWithoutMillis.timeZone = .current
        inputWithoutMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        inputFormatters = [inputWithMillis, inputWithoutMillis]
    }

    func format(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: " ", with: "T")

        var base = normalized
        var fraction: String?

        if let dotIndex = normalized.firstIndex(of: ".") {
            base = String(normalized[..<dotIndex])
            let afterDot = normalized[normalized.index(after: dotIndex)...]
            let digits = afterDot.prefix { $0.isNumber }
            if !digits.isEmpty {
                fraction = String(digits)
            }
        }

        if let fraction {
            var padded = String(fraction.prefix(3))
            if padded.count == 1 {
                padded.append("00")
            } else if padded.count == 2 {
                padded.append("0")
            }
            if let date = inputFormatters[0].date(from: "\(base).\(padded)") {
                return outputFormatter.string(from: date)
            }
        }

        if let date = inputFormatters[1].date(from: base) {
            return outputFormatter.string(from: date)
        }

        return nil
    }
}

private final class MessageDateParser {
    static let shared = MessageDateParser()
    private let inputFormatters: [DateFormatter]

    private init() {
        let inputWithMillis = DateFormatter()
        inputWithMillis.locale = Locale(identifier: "en_US_POSIX")
        inputWithMillis.timeZone = .current
        inputWithMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"

        let inputWithoutMillis = DateFormatter()
        inputWithoutMillis.locale = Locale(identifier: "en_US_POSIX")
        inputWithoutMillis.timeZone = .current
        inputWithoutMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        inputFormatters = [inputWithMillis, inputWithoutMillis]
    }

    func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: " ", with: "T")

        var base = normalized
        var fraction: String?

        if let dotIndex = normalized.firstIndex(of: ".") {
            base = String(normalized[..<dotIndex])
            let afterDot = normalized[normalized.index(after: dotIndex)...]
            let digits = afterDot.prefix { $0.isNumber }
            if !digits.isEmpty {
                fraction = String(digits)
            }
        }

        if let fraction {
            var padded = String(fraction.prefix(3))
            if padded.count == 1 {
                padded.append("00")
            } else if padded.count == 2 {
                padded.append("0")
            }
            if let date = inputFormatters[0].date(from: "\(base).\(padded)") {
                return date
            }
        }

        return inputFormatters[1].date(from: base)
    }
}

private struct NewMessagePill: View {
    var body: some View {
        Text("Ny melding")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}

private struct MessageRow: Identifiable {
    let message: APIMessage
    let isOutgoing: Bool
    let showAvatar: Bool
    let showTimestamp: Bool
    let isGroupedWithPrevious: Bool
    let isGroupedWithNext: Bool
    let topSpacing: CGFloat

    var id: Int64 { message.id }
}

private func makeMessageRows(messages: [APIMessage], currentUserId: String?) -> [MessageRow] {
    guard !messages.isEmpty else { return [] }

    var rows: [MessageRow] = []
    rows.reserveCapacity(messages.count)

    for index in messages.indices {
        let message = messages[index]
        let prev = index > messages.startIndex ? messages[index - 1] : nil
        let next = index < messages.index(before: messages.endIndex) ? messages[index + 1] : nil

        let isOutgoing = currentUserId != nil && message.senderId == currentUserId
        let groupedWithPrev = prev?.senderId == message.senderId
        let groupedWithNext = next?.senderId == message.senderId
        let showAvatar = !isOutgoing && !groupedWithNext
        let showTimestamp = !groupedWithNext
        let topSpacing: CGFloat = groupedWithPrev ? 2 : 10

        rows.append(
            MessageRow(
                message: message,
                isOutgoing: isOutgoing,
                showAvatar: showAvatar,
                showTimestamp: showTimestamp,
                isGroupedWithPrevious: groupedWithPrev,
                isGroupedWithNext: groupedWithNext,
                topSpacing: topSpacing
            )
        )
    }

    return rows
}

private struct APIMessageEvent: Codable {
    let message: APIMessage
}

private final class ChatSocketClient: ObservableObject {
    var onMessage: ((APIMessage) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var conversationId: Int64?
    private var userId: String?
    private var reconnectTask: Task<Void, Never>?
    private var isManuallyClosed = false
    private var reconnectAttempts = 0

    func connect(conversationId: Int64, userId: String, url: URL) {
        if self.conversationId == conversationId, task != nil {
            return
        }

        disconnect()
        self.conversationId = conversationId
        self.userId = userId
        isManuallyClosed = false
        reconnectAttempts = 0

        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()

        Task {
            await receiveLoop()
        }
    }

    func disconnect() {
        isManuallyClosed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        conversationId = nil
        userId = nil
    }


    private func scheduleReconnect() {
        guard !isManuallyClosed, let conversationId, let userId else { return }

        reconnectAttempts += 1
        let delay = min(Double(1 << min(reconnectAttempts, 4)), 12)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            guard let url = APIService.shared.webSocketURL(conversationId: conversationId, userId: userId) else { return }
            self.connect(conversationId: conversationId, userId: userId, url: url)
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        do {
            while true {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleIncoming(text.data(using: .utf8))
                case .data(let data):
                    handleIncoming(data)
                @unknown default:
                    break
                }
            }
        } catch {
            if !isManuallyClosed {
                scheduleReconnect()
            }
        }
    }

    private func handleIncoming(_ data: Data?) {
        guard let data else { return }
        let decoder = JSONDecoder()
        if let event = try? decoder.decode(APIMessageEvent.self, from: data) {
            onMessage?(event.message)
        }
    }
}
