import SwiftUI
import SafariServices
import StripePaymentSheet
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
    @State private var showEditListingSheet = false
    @State private var listingOverride: APIListing?
    @State private var isAcceptingTask = false
    @State private var isCheckingOnboarding = false
    @State private var didAcceptSafePayment = false
    @State private var showOnboarding = false
    @State private var onboardingUrl: URL?
    @State private var shouldRetryAcceptAfterOnboarding = false
    @State private var paymentSheet: PaymentSheet?
    @State private var showPaymentSheet = false
    @State private var isStartingPayment = false
    @State private var showCompleteSheet = false
    @State private var isCompletingListing = false
    @State private var isCancelingPayment = false
    @State private var isDeclining = false
    @State private var showDeleteConfirm = false
    @State private var isDeletingListing = false
    @State private var showStripeOnboardingExplanation = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
                .ignoresSafeArea(.keyboard, edges: .bottom)

            VStack(spacing: 0) {
                ChatHeader(
                    title: currentListing.title,
                    isModalStyle: isModalStyle,
                    trailingView: headerTrailingView
                ) {
                    dismiss()
                }

                ListingRow(listing: currentListing, userLocation: nil) {
                    if isOwner {
                        showEditListingSheet = true
                    } else {
                        showListingSheet = true
                    }
                }

                if shouldShowSafePaymentAction {
                    acceptActionSection
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                } else if shouldShowSafePaymentAcceptedInfo {
                    acceptedInfoSection
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                // Vis fullfør-knappen når begge har godtatt
                if currentListing.offersSafePayment == true && isOwner && listingStatus == "ACCEPTED_BOTH" {
                    completePaymentButton
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
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
                                    MessageBubble(
                                        message: row.message,
                                        bodyText: row.bodyText,
                                        isSystem: row.isSystem,
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

        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await startConversation()
        }
        .onAppear {
            socketClient.onMessage = { message in
                Task { @MainActor in
                    appendMessage(message)
                    // Refresh listing when a system message arrives
                    if message.body.hasPrefix("SYSTEM:") {
                        await refreshListing()
                    }
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
                listing: currentListing,
                sheetDetent: $listingSheetDetent,
                userLocation: nil,
                showsMessageAction: false
            )
            .environmentObject(authManager)
            .presentationDetents([.large], selection: $listingSheetDetent)
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showEditListingSheet) {
            EditListingSheet(
                listing: currentListing,
                onUpdated: { updated in
                    listingOverride = updated
                },
                onDeleted: { _ in }
            )
            .environmentObject(authManager)
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showUserReviews) {
            UserReviewsSheet(userId: currentListing.userId, userName: displayUserName)
        }
        .sheet(isPresented: $showOnboarding) {
            if let url = onboardingUrl {
                SafariView(url: url) {
                    Task { await retryAcceptAfterOnboarding() }
                }
            }
        }
        .sheet(isPresented: $showPaymentSheet) {
            if let paymentSheet {
                PaymentSheetPresenter(paymentSheet: paymentSheet, onCompletion: handlePaymentSheetResult)
            }
        }
        .sheet(isPresented: $showCompleteSheet) {
            CompleteListingSheet(
                listing: currentListing,
                onCompleted: { updatedListing in
                    if let updatedListing {
                        listingOverride = updatedListing
                    }
                }
            )
            .environmentObject(authManager)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showStripeOnboardingExplanation) {
            StripeOnboardingSheet(
                onContinue: {
                    startStripeOnboarding()
                },
                onCancel: {
                    showStripeOnboardingExplanation = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .confirmationDialog("Slett annonse?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Slett annonse", role: .destructive) {
                Task { await deleteListing() }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Dette kan ikke angres.")
        }
    }

    private var currentListing: APIListing {
        listingOverride ?? listing
    }

    private var isOwner: Bool {
        guard let userId = authManager.userIdentifier else { return false }
        return currentListing.userId == userId
    }

    private var headerTrailingView: AnyView? {
        guard isOwner else { return nil }
        return AnyView(listingActionsButton)
    }

    private var displayUserName: String {
        let name = currentListing.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Bruker" : name
    }

    private var isSafePayment: Bool {
        currentListing.offersSafePayment == true
    }

    /// Current listing status (from listing or local override)
    private var listingStatus: String {
        currentListing.status ?? "INITIATED"
    }

    /// Check if the current user has already accepted
    private var hasCurrentUserAccepted: Bool {
        if isOwner {
            return listingStatus == "ACCEPTED_OWNER" || listingStatus == "ACCEPTED_BOTH"
        } else {
            return listingStatus == "ACCEPTED_CONTRACTOR" || listingStatus == "ACCEPTED_BOTH"
        }
    }

    /// Check if the other party has accepted
    private var hasOtherPartyAccepted: Bool {
        if isOwner {
            return listingStatus == "ACCEPTED_CONTRACTOR" || listingStatus == "ACCEPTED_BOTH"
        } else {
            return listingStatus == "ACCEPTED_OWNER" || listingStatus == "ACCEPTED_BOTH"
        }
    }

    /// Check if both parties have accepted
    private var hasBothAccepted: Bool {
        listingStatus == "ACCEPTED_BOTH"
    }

    private var hasExecutorAccepted: Bool {
        // Executor (contractor) has accepted when status is ACCEPTED_CONTRACTOR or ACCEPTED_BOTH
        if didAcceptSafePayment {
            return true
        }
        return listingStatus == "ACCEPTED_CONTRACTOR" || listingStatus == "ACCEPTED_BOTH"
    }

    private var safePaymentStatus: String? {
        conversation?.safePaymentStatus
    }

    private var isPaymentStarted: Bool {
        // Check both listing status AND safePaymentStatus for robustness
        listingStatus == "ACCEPTED_BOTH" || safePaymentStatus == "held" || safePaymentStatus == "released"
    }

    private var isPaymentHeld: Bool {
        listingStatus == "ACCEPTED_BOTH" || safePaymentStatus == "held"
    }

    private var shouldShowSafePaymentAction: Bool {
        guard authManager.isAuthenticated, isSafePayment else { return false }
        guard listingStatus != "COMPLETED" else { return false }
        
        // Show accept button when:
        // - Owner: contractor has accepted but owner hasn't paid yet
        // - Contractor: hasn't accepted yet (regardless of owner status)
        if isOwner {
            // Owner sees accept/pay button when contractor has accepted and payment not started
            return hasExecutorAccepted && !isPaymentStarted
        } else {
            // Contractor sees accept button when they haven't accepted yet
            return !hasCurrentUserAccepted
        }
    }

    private var shouldShowSafePaymentAcceptedInfo: Bool {
        guard authManager.isAuthenticated, isSafePayment else { return false }
        guard listingStatus != "COMPLETED" else { return false }
        
        if isOwner {
            // Owner sees info when payment is started (held or released)
            return isPaymentStarted
        } else {
            // Contractor sees info when they have accepted
            return hasCurrentUserAccepted
        }
    }

    private var otherUserLabel: String {
        guard let currentUserId = authManager.userIdentifier else { return "Bruker" }
        guard let conversation else { return "Bruker" }
        let otherUserId = currentUserId == conversation.buyerId ? conversation.sellerId : conversation.buyerId
        return "Bruker \(otherUserId.suffix(4))"
    }

    private var acceptActionTitle: String {
        "Godta"
    }

    private var acceptActionPrimaryMessage: String {
        if isOwner {
            return "Når du godtar, betaler du inn beløpet til Trygg betaling. Pengene holdes trygt til jobben er godkjent."
        }
        return "Når du godtar, betaler oppdragsgiver inn beløpet til Trygg betaling. Du får utbetaling når jobben er godkjent."
    }

    private var acceptActionSecondaryMessage: String {
        "Trygg betaling er en valgfri tjeneste som gir ekstra sikkerhet for begge parter. Det er helt opp til dere om dere ønsker å bruke denne når dere inngår avtale."
    }

    private var acceptActionFeeMessage: String {
        if isOwner {
            return "For Trygg betaling og utbetaling tar boenklere et plattformgebyr på 10 % av prisen du har satt for jobben."
        }
        return "Dette koster ikke noe for deg. Det er oppdragsgiver som dekker gebyret for Trygg betaling."
    }

    private var acceptActionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(acceptActionPrimaryMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(acceptActionSecondaryMessage)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(acceptActionFeeMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    if isOwner {
                        Task { await handleOwnerPaymentAction() }
                    } else {
                        Task { await checkOnboardingAndProceed() }
                    }
                } label: {
                    BoenklereActionButtonLabel(
                        title: acceptActionTitle,
                        systemImage: "checkmark.seal.fill",
                        isLoading: isAcceptActionDisabled && !isDeclining
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAcceptActionDisabled)

                if isOwner {
                    Button {
                        Task { await declineSafePayment() }
                    } label: {
                        BoenklereActionButtonLabel(
                            title: "Avslå",
                            systemImage: "xmark.circle.fill",
                            isLoading: isDeclining,
                            textColor: .red,
                            fillColor: Color.red.opacity(0.15)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isAcceptActionDisabled)
                }
            }
        }
    }

    private var acceptedInfoSection: some View {
        safePaymentInfoBox {
            if isPaymentStarted {
                if isOwner {
                    ownerSafePaymentInfoText
                } else {
                    executorSafePaymentInfoText
                }
            } else {
                Text("Du har godtatt oppdraget, venter på godkjenning av \(ownerDisplayName)")
            }
        }
    }

    private var shouldShowCompletePaymentButton: Bool {
        guard authManager.isAuthenticated, isSafePayment, isOwner else { return false }
        guard listingStatus != "COMPLETED" else { return false }
        return true
    }

    private var isSafePaymentActionEnabled: Bool {
        isSafePayment && isPaymentHeld
    }

    private var listingActionsButton: some View {
        let isCompleted = listingStatus == "COMPLETED"
        return Menu {
            if isSafePaymentActionEnabled || isCompleted {
                Button("Fullfør og utbetal \(safePaymentPriceText)") {
                    Task { await completeListingAndReview() }
                }
                .disabled(isCompletingListing || isCompleted)

                Button("Kanseller og refunder", role: .destructive) {
                    Task { await cancelSafePayment() }
                }
                .disabled(isCancelingPayment || isCompleted)
            } else {
                Button("Merk som utført") {
                    Task { await completeListingAndReview() }
                }
                .disabled(isCompletingListing || listingStatus == "COMPLETED")

                Button("Slett annonse", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.gray, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Flere valg")
    }

    private var completePaymentButton: some View {
        HStack(spacing: 8) {
            Button {
                Task { await completeListingAndReview() }
            } label: {
                HStack(spacing: 6) {
                    if isCompletingListing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text("Fullfør - oppdraget er utført")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 0.11, green: 0.56, blue: 0.24))
                .cornerRadius(24)
            }
            .buttonStyle(.plain)
            .disabled(isCompletingListing)

            SafePaymentInfoTooltipButton(
                text: "Trykk «Fullfør» når jobben er ferdig for å utbetale til utføreren.\nUtbetaling skjer automatisk etter 6 dager hvis du ikke gjør noe. Du kan kansellere før det via menyen."
            )
        }
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

        guard let listingId = currentListing.id else {
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
    private func refreshListing() async {
        guard let listingId = currentListing.id else { return }
        do {
            let updatedListing = try await APIService.shared.getListing(id: listingId)
            listingOverride = updatedListing
            // Also refresh conversation to get updated safePaymentStatus
            if let conv = conversation {
                let updatedConversation = try await APIService.shared.getConversation(id: conv.id)
                self.conversation = updatedConversation
            }
        } catch {
            // Ignore refresh errors
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

    @MainActor
    private func checkOnboardingAndProceed() async {
        guard !isCheckingOnboarding else { return }
        guard authManager.isAuthenticated else { return }
        if isOwner { return }
        guard let conversation else { return }
        guard let userId = authManager.userIdentifier else { return }

        isCheckingOnboarding = true
        defer { isCheckingOnboarding = false }

        do {
            let response = try await APIService.shared.checkSafePaymentOnboarding(
                conversationId: conversation.id,
                userId: userId
            )
            if response.requiresOnboarding {
                guard let urlString = response.onboardingUrl,
                      let url = URL(string: urlString) else {
                    errorMessage = "Kunne ikke starte Stripe onboarding"
                    return
                }
                onboardingUrl = url
                showStripeOnboardingExplanation = true
                return
            }
        } catch {
            errorMessage = "Kunne ikke sjekke Stripe-tilkobling"
            return
        }

        await handleAcceptAction()
    }

    @MainActor
    private func startStripeOnboarding() {
        showStripeOnboardingExplanation = false
        guard let url = onboardingUrl else {
            errorMessage = "Kunne ikke starte Stripe onboarding"
            return
        }
        shouldRetryAcceptAfterOnboarding = true
        showOnboarding = true
    }

    @MainActor
    private func handleAcceptAction() async {
        guard !isAcceptingTask else { return }
        guard authManager.isAuthenticated else { return }
        if isOwner {
            return
        }
        guard let listingId = currentListing.id else { return }
        guard let userId = authManager.userIdentifier else { return }

        isAcceptingTask = true
        print("Accept: start listingId=\(listingId) userId=\(userId)")
        do {
            // First accept the listing status
            let updatedListing = try await APIService.shared.acceptListing(
                listingId: listingId,
                userId: userId
            )
            listingOverride = updatedListing
            didAcceptSafePayment = true
            print("Accept: listing status updated to \(updatedListing.status ?? "nil")")
            
            // Also call the old conversation-based accept for Stripe onboarding check
            if let conversation {
                let response = try await APIService.shared.acceptSafePayment(
                    conversationId: conversation.id,
                    userId: userId
                )
                if response.requiresOnboarding {
                    if let urlString = response.onboardingUrl,
                       let url = URL(string: urlString) {
                        print("Stripe: onboarding required")
                        onboardingUrl = url
                        shouldRetryAcceptAfterOnboarding = true
                        showOnboarding = true
                    } else {
                        errorMessage = "Kunne ikke starte Stripe onboarding"
                    }
                } else {
                    self.conversation = response.conversation
                }
            }
        } catch {
            errorMessage = "Kunne ikke oppdatere oppdraget"
            print("Accept: failed listingId=\(listingId) error=\(error)")
        }
        isAcceptingTask = false
    }

    @MainActor
    private func declineSafePayment() async {
        guard !isDeclining else { return }
        guard authManager.isAuthenticated else { return }
        guard let listingId = currentListing.id else { return }
        guard let userId = authManager.userIdentifier else { return }

        isDeclining = true
        do {
            if let conversation {
                // Reset conversation safe payment state FIRST (this also resets listing status to INITIATED)
                // Must happen before sending system message to avoid race condition
                let updated = try await APIService.shared.declineSafePayment(
                    conversationId: conversation.id,
                    userId: userId
                )
                self.conversation = updated
                
                // Refresh listing to get updated status
                let updatedListing = try await APIService.shared.getListing(id: listingId)
                listingOverride = updatedListing
                didAcceptSafePayment = false
                
                // Send system message AFTER database is updated
                // This ensures other clients get correct data when they refresh
                let declineName = otherUserLabel
                let message = try await APIService.shared.sendMessage(
                    conversationId: conversation.id,
                    senderId: userId,
                    body: "SYSTEM:\(declineName) har avslått oppdraget."
                )
                appendMessage(message)
            } else {
                // No conversation, just refresh listing
                let updatedListing = try await APIService.shared.getListing(id: listingId)
                listingOverride = updatedListing
                didAcceptSafePayment = false
            }
        } catch {
            errorMessage = "Kunne ikke avslå oppdraget"
        }
        isDeclining = false
    }

    @MainActor
    private func retryAcceptAfterOnboarding() async {
        guard shouldRetryAcceptAfterOnboarding else { return }
        shouldRetryAcceptAfterOnboarding = false
        await handleAcceptAction()
    }

    @MainActor
    private func handleOwnerPaymentAction() async {
        guard authManager.isAuthenticated else { return }
        guard let conversation else { return }
        guard let userId = authManager.userIdentifier else { return }

        isStartingPayment = true
        print("Stripe: payment start conversationId=\(conversation.id) userId=\(userId)")
        do {
            let response = try await APIService.shared.createSafePaymentIntent(
                conversationId: conversation.id,
                userId: userId
            )
            self.conversation = response.conversation
            StripeAPI.defaultPublishableKey = response.publishableKey
            print("Stripe: payment sheet ready conversationId=\(conversation.id)")
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = "Boenklere"
            paymentSheet = PaymentSheet(
                paymentIntentClientSecret: response.clientSecret,
                configuration: configuration
            )
            showPaymentSheet = true
        } catch {
            errorMessage = "Kunne ikke starte betaling"
            print("Stripe: payment start failed conversationId=\(conversation.id) error=\(error)")
        }
        isStartingPayment = false
    }

    private func handlePaymentSheetResult(_ result: PaymentSheetResult) {
        switch result {
        case .completed:
            print("Stripe: payment sheet completed")
            Task { await confirmSafePayment() }
        case .failed:
            errorMessage = "Betaling feilet"
            print("Stripe: payment sheet failed")
        case .canceled:
            print("Stripe: payment sheet canceled")
            break
        }
        showPaymentSheet = false
        paymentSheet = nil
    }

    @MainActor
    private func confirmSafePayment() async {
        guard let conversation else { return }
        guard let userId = authManager.userIdentifier else { return }
        do {
            let updated = try await APIService.shared.confirmSafePayment(
                conversationId: conversation.id,
                userId: userId
            )
            self.conversation = updated
            print("Stripe: payment confirmed conversationId=\(conversation.id) status=\(updated.safePaymentStatus ?? "nil")")
        } catch {
            errorMessage = "Kunne ikke bekrefte betalingen"
            print("Stripe: payment confirm failed conversationId=\(conversation.id) error=\(error)")
        }
    }

    private var isAcceptActionDisabled: Bool {
        isAcceptingTask || isCheckingOnboarding || isStartingPayment || isDeclining || (!isOwner && conversation == nil)
    }

    private var ownerDisplayName: String {
        let name = currentListing.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "oppdragseier" : name
    }

    private var executorDisplayName: String {
        let name = otherUserLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "oppdragstaker" : name
    }

    private var executorSafePaymentInfoText: some View {
        Text(
            "Dere har begge godtatt å utføre oppdraget med Trygg betaling. Du mottar utbetaling når \(ownerDisplayName) markerer oppdraget som utført"
        )
    }

    private var ownerSafePaymentInfoText: some View {
        let info = ownerSafePaymentInfoAttributedString(executorName: executorDisplayName)
        return Text(info)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "boenklere", url.host == "my-listings" {
                    openMyListings()
                    return .handled
                }
                return .systemAction
            })
    }

    private var safePaymentPriceText: String {
        if let amountMinor = conversation?.safePaymentAmount {
            let amountValue = Double(amountMinor) / 100.0
            let formatted = amountValue.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(amountValue))
                : String(format: "%.2f", amountValue)
            return "\(formatted) kr"
        }
        let priceValue = max(0, Int(currentListing.price))
        return "\(priceValue) kr"
    }

    private func ownerSafePaymentInfoAttributedString(executorName: String) -> AttributedString {
        let linkToken = "[[MY_LISTINGS]]"
        let raw = "Dere har begge godtatt å utføre oppdraget med Trygg betaling. For å utbetalt pengene til \(executorName) må du etter endt oppdrag markere oppdrag som utført i \(linkToken). Ønsker du å kansellere, vil vi refundere pengene til din konto. Det kan du enten gjøre i Mine annonser eller trykke på knappen oppe til høyre."
        var info = AttributedString(raw)
        if let range = info.range(of: linkToken) {
            var link = AttributedString("Mine annonser")
            link.font = .caption.bold()
            link.foregroundColor = .secondary
            link.link = URL(string: "boenklere://my-listings")
            info.replaceSubrange(range, with: link)
        }
        return info
    }

    private func safePaymentInfoBox(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func openMyListings() {
        NotificationCenter.default.post(name: .openMyListings, object: nil)
    }

    @MainActor
    private func completeListingAndReview() async {
        guard let userId = authManager.userIdentifier else { return }
        guard let listingId = currentListing.id else { return }

        isCompletingListing = true
        errorMessage = nil

        do {
            let updated = try await APIService.shared.updateListing(
                listingId: listingId,
                title: currentListing.title,
                description: currentListing.description,
                address: currentListing.address,
                latitude: currentListing.latitude,
                longitude: currentListing.longitude,
                price: currentListing.price,
                offersSafePayment: currentListing.offersSafePayment ?? false,
                status: "COMPLETED",
                userId: userId,
                imageData: nil
            )
            listingOverride = updated
            showCompleteSheet = true
        } catch {
            errorMessage = "Kunne ikke fullføre oppdraget"
        }

        isCompletingListing = false
    }

    @MainActor
    private func cancelSafePayment() async {
        guard let conversation else { return }
        guard let userId = authManager.userIdentifier else { return }
        guard !isCancelingPayment else { return }

        isCancelingPayment = true
        errorMessage = nil

        do {
            let updated = try await APIService.shared.cancelSafePayment(
                conversationId: conversation.id,
                userId: userId
            )
            self.conversation = updated
            didAcceptSafePayment = false
        } catch {
            errorMessage = "Kunne ikke kansellere oppdraget"
        }

        isCancelingPayment = false
    }

    @MainActor
    private func deleteListing() async {
        guard let listingId = currentListing.id else { return }
        guard !isDeletingListing else { return }

        isDeletingListing = true
        errorMessage = nil

        do {
            try await APIService.shared.deleteListing(id: listingId)
            dismiss()
        } catch {
            errorMessage = "Kunne ikke slette annonsen"
        }

        isDeletingListing = false
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
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray, in: Circle())
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
        let lastMessage = stripSystemMessage(sorted.first?.lastMessage)
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
        guard let lastMessage = stripSystemMessage(conversation.lastMessage) else {
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
            print("Failed to load conversations: \(error)")
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

                if let lastMessage = stripSystemMessage(conversation.lastMessage),
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

                if let lastMessage = stripSystemMessage(conversation.lastMessage),
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
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray, in: Circle())
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
    @State private var sheetDetent: PresentationDetent = .large
    @State private var listing: APIListing?
    @State private var isLoadingListing = false
    @State private var showListingSheet = false
    @State private var showEditListingSheet = false
    @State private var listingSheetDetent: PresentationDetent = .large
    @State private var showUserReviews = false
    @State private var otherUserName: String?
    @State private var firstUnreadMessageId: Int64?
    @State private var didMarkRead = false
    @State private var isAcceptingTask = false
    @State private var isCheckingOnboarding = false
    @State private var didAcceptSafePayment = false
    @State private var safePaymentStatusOverride: String?
    @State private var showStripeOnboardingExplanation = false
    @State private var showOnboarding = false
    @State private var onboardingUrl: URL?
    @State private var shouldRetryAcceptAfterOnboarding = false
    @State private var paymentSheet: PaymentSheet?
    @State private var showPaymentSheet = false
    @State private var isStartingPayment = false
    @State private var showCompleteSheet = false
    @State private var isCompletingListing = false
    @State private var showReviewOwnerSheet = false
    @State private var showReviewContractorSheet = false
    @State private var hasReviewedOwner = false
    @State private var hasReviewedContractor = false
    @State private var isCheckingReview = false
    @State private var reviewRating: Int = 0
    @State private var reviewComment: String = ""
    @State private var isSubmittingReview = false
    @State private var isCancelingPayment = false
    @State private var isDeclining = false
    @State private var showDeleteConfirm = false
    @State private var isDeletingListing = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
                .ignoresSafeArea(.keyboard, edges: .bottom)

            VStack(spacing: 0) {
                collapsedHeader

                if !isCollapsed {
                    if let listing {
                        ListingRow(listing: listing, userLocation: nil) {
                            if isOwner {
                                showEditListingSheet = true
                            } else {
                                showListingSheet = true
                            }
                        }

                        if shouldShowSafePaymentAction {
                            acceptActionSection
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        } else if shouldShowSafePaymentAcceptedInfo {
                            acceptedInfoSection
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }

                        // Vis fullfør-knappen når begge har godtatt
                        if listing.offersSafePayment == true && isOwner && listing.status == "ACCEPTED_BOTH" {
                            completePaymentButton
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }
                        
                        // Show review buttons when listing is COMPLETED (outside of safe payment info section)
                        if shouldShowReviewOwnerButton {
                            reviewOwnerButton
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }
                        
                        if shouldShowReviewContractorButton {
                            reviewContractorButton
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }

                    } else if isLoadingListing {
                        ProgressView()
                            .padding(.vertical, 8)
                    }
                }

                if !isCollapsed {
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
                                            bodyText: row.bodyText,
                                            isSystem: row.isSystem,
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
            }

        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadMessages()
            await loadListing()
            await loadOtherUser()
            await checkIfAlreadyReviewedOwner()
            await checkIfAlreadyReviewedContractor()
        }
        .onAppear {
            socketClient.onMessage = { message in
                Task { @MainActor in
                    appendMessage(message)
                    // Refresh listing when a system message arrives
                    if message.body.hasPrefix("SYSTEM:") {
                        await refreshListing()
                    }
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
                    userLocation: nil,
                    showsMessageAction: false
                )
                .environmentObject(authManager)
                .presentationDetents([.large], selection: $listingSheetDetent)
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $showEditListingSheet) {
            if let listing {
                EditListingSheet(
                    listing: listing,
                    onUpdated: { updated in
                        self.listing = updated
                    },
                    onDeleted: { _ in }
                )
                .environmentObject(authManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $showUserReviews) {
            if let otherUserId {
                UserReviewsSheet(userId: otherUserId, userName: displayOtherName)
            }
        }
        .sheet(isPresented: $showOnboarding) {
            if let url = onboardingUrl {
                SafariView(url: url) {
                    Task { await retryAcceptAfterOnboarding() }
                }
            }
        }
        .sheet(isPresented: $showPaymentSheet) {
            if let paymentSheet {
                PaymentSheetPresenter(paymentSheet: paymentSheet, onCompletion: handlePaymentSheetResult)
            }
        }
        .sheet(isPresented: $showCompleteSheet) {
            if let listing {
                CompleteListingSheet(
                    listing: listing,
                    onCompleted: { updatedListing in
                        if let updatedListing {
                            self.listing = updatedListing
                        }
                    }
                )
                .environmentObject(authManager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $showReviewOwnerSheet) {
            ReviewOwnerSheet(
                ownerName: ownerDisplayName,
                rating: $reviewRating,
                comment: $reviewComment,
                isSubmitting: isSubmittingReview,
                onSubmit: {
                    Task { await submitOwnerReview() }
                },
                onCancel: {
                    showReviewOwnerSheet = false
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showReviewContractorSheet) {
            ReviewOwnerSheet(
                ownerName: contractorDisplayName,
                rating: $reviewRating,
                comment: $reviewComment,
                isSubmitting: isSubmittingReview,
                onSubmit: {
                    Task { await submitContractorReview() }
                },
                onCancel: {
                    showReviewContractorSheet = false
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showStripeOnboardingExplanation) {
            StripeOnboardingSheet(
                onContinue: {
                    startStripeOnboarding()
                },
                onCancel: {
                    showStripeOnboardingExplanation = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .confirmationDialog("Slett annonse?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Slett annonse", role: .destructive) {
                Task { await deleteListing() }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Dette kan ikke angres.")
        }
        .onChange(of: listing?.id) { _, _ in
            Task { 
                await checkIfAlreadyReviewedOwner()
                await checkIfAlreadyReviewedContractor()
            }
        }
        .presentationDetents([.height(70), .large], selection: $sheetDetent)
        .presentationDragIndicator(.hidden)
    }

    private var inputBar: some View {
        ChatInputBar(
            text: $messageText,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onSend: { Task { await sendMessage() } }
        )
    }

    private var collapsedHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 5)
                .padding(.bottom, 3)

            HStack {
                if !isModalStyle {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray, in: Circle())
                    }
                }

                if isCollapsed {
                    collapsedContent
                } else {
                    Text(conversation.listingTitle)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                Spacer()

                if shouldShowListingActionsButton {
                    listingActionsButton
                }

                if isModalStyle {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.gray, in: Circle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if shouldShowSafePaymentAction {
            collapsedActionButton(title: "Godta oppdraget", icon: "checkmark.circle.fill") {
                if isOwner {
                    Task { await handleOwnerPaymentAction() }
                } else {
                    Task { await checkOnboardingAndProceed() }
                }
            }
        } else if shouldShowCompletePaymentButton {
            collapsedActionButton(title: "Fullfør og utbetal", icon: "checkmark.seal.fill") {
                Task { await completeListingAndReview() }
            }
        } else if shouldShowReviewOwnerButton {
            collapsedActionButton(title: "Gi vurdering", icon: "star.fill") {
                showReviewOwnerSheet = true
            }
        } else if shouldShowReviewContractorButton {
            collapsedActionButton(title: "Gi vurdering", icon: "star.fill") {
                showReviewContractorSheet = true
            }
        } else {
            Text(conversation.listingTitle)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    private func collapsedActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue, in: Capsule())
        }
    }

    private var isCollapsed: Bool {
        sheetDetent == .height(70)
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

    private var isOwner: Bool {
        guard let userId = authManager.userIdentifier else { return false }
        return listing?.userId == userId
    }

    private var isSafePayment: Bool {
        listing?.offersSafePayment == true
    }

    private var shouldShowListingActionsButton: Bool {
        isOwner
    }

    private var isSafePaymentActionEnabled: Bool {
        isSafePayment && isPaymentHeld
    }

    private var listingActionsButton: some View {
        let isCompleted = listing?.status == "COMPLETED"
        return Menu {
            if isSafePaymentActionEnabled || isCompleted {
                Button("Fullfør og utbetal \(safePaymentPriceText)") {
                    Task { await completeListingAndReview() }
                }
                .disabled(isCompletingListing || isCompleted)

                Button("Kanseller og refunder", role: .destructive) {
                    Task { await cancelSafePayment() }
                }
                .disabled(isCancelingPayment || isCompleted)
            } else {
                Button("Merk som utført") {
                    Task { await completeListingAndReview() }
                }
                .disabled(isCompletingListing || listing?.status == "COMPLETED")

                Button("Slett annonse", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.gray, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Flere valg")
    }

    /// Current listing status
    private var listingStatus: String {
        listing?.status ?? "INITIATED"
    }

    /// Check if the current user has already accepted
    private var hasCurrentUserAccepted: Bool {
        if isOwner {
            return listingStatus == "ACCEPTED_OWNER" || listingStatus == "ACCEPTED_BOTH"
        } else {
            return listingStatus == "ACCEPTED_CONTRACTOR" || listingStatus == "ACCEPTED_BOTH"
        }
    }

    /// Check if the other party has accepted
    private var hasOtherPartyAccepted: Bool {
        if isOwner {
            return listingStatus == "ACCEPTED_CONTRACTOR" || listingStatus == "ACCEPTED_BOTH"
        } else {
            return listingStatus == "ACCEPTED_OWNER" || listingStatus == "ACCEPTED_BOTH"
        }
    }

    /// Check if both parties have accepted
    private var hasBothAccepted: Bool {
        listingStatus == "ACCEPTED_BOTH"
    }

    private var hasExecutorAccepted: Bool {
        // Executor (contractor) has accepted when status is ACCEPTED_CONTRACTOR or ACCEPTED_BOTH
        if didAcceptSafePayment {
            return true
        }
        return listingStatus == "ACCEPTED_CONTRACTOR" || listingStatus == "ACCEPTED_BOTH"
    }

    private var safePaymentStatus: String? {
        safePaymentStatusOverride ?? conversation.safePaymentStatus
    }

    private var isPaymentStarted: Bool {
        // Check both listing status AND safePaymentStatus for robustness
        listingStatus == "ACCEPTED_BOTH" || safePaymentStatus == "held" || safePaymentStatus == "released"
    }

    private var isPaymentHeld: Bool {
        listingStatus == "ACCEPTED_BOTH" || safePaymentStatus == "held"
    }

    private var shouldShowSafePaymentAction: Bool {
        guard authManager.isAuthenticated, isSafePayment else { return false }
        guard listingStatus != "COMPLETED" else { return false }
        
        // Show accept button when:
        // - Owner: contractor has accepted but owner hasn't paid yet
        // - Contractor: hasn't accepted yet (regardless of owner status)
        if isOwner {
            // Owner sees accept/pay button when contractor has accepted and payment not started
            return hasExecutorAccepted && !isPaymentStarted
        } else {
            // Contractor sees accept button when they haven't accepted yet
            return !hasCurrentUserAccepted
        }
    }

    private var shouldShowSafePaymentAcceptedInfo: Bool {
        guard authManager.isAuthenticated, isSafePayment else { return false }
        guard listingStatus != "COMPLETED" else { return false }
        
        if isOwner {
            // Owner sees info when payment is started (held or released)
            return isPaymentStarted
        } else {
            // Contractor sees info when they have accepted
            return hasCurrentUserAccepted
        }
    }

    private var acceptActionTitle: String? {
        guard let listing else { return nil }
        if isOwner {
            return "Godta og betal"
        }
        let priceValue = max(0, Int(listing.price))
        return "Godta oppdraget for \(priceValue) kr"
    }

    private var acceptActionPrimaryMessage: String {
        if isOwner {
            return "Når du godtar, betaler du inn beløpet til Trygg betaling. Pengene holdes trygt til jobben er godkjent."
        }
        return "Når du godtar, betaler oppdragsgiver inn beløpet til Trygg betaling. Du får utbetaling når jobben er godkjent."
    }

    private var acceptActionSecondaryMessage: String {
        "Trygg betaling er en valgfri tjeneste som gir ekstra sikkerhet for begge parter. Det er helt opp til dere om dere ønsker å bruke denne når dere inngår avtale."
    }

    private var acceptActionFeeMessage: String {
        if isOwner {
            return "For Trygg betaling og utbetaling tar boenklere et plattformgebyr på 10 % av prisen du har satt for jobben."
        }
        return "Dette koster ikke noe for deg. Det er oppdragsgiver som dekker gebyret for Trygg betaling."
    }

    private var acceptActionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(acceptActionPrimaryMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(acceptActionSecondaryMessage)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(acceptActionFeeMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    if isOwner {
                        Task { await handleOwnerPaymentAction() }
                    } else {
                        Task { await checkOnboardingAndProceed() }
                    }
                } label: {
                    BoenklereActionButtonLabel(
                        title: acceptActionTitle ?? "Godta",
                        systemImage: "checkmark.seal.fill",
                        isLoading: (isAcceptingTask || isCheckingOnboarding || isStartingPayment) && !isDeclining
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAcceptingTask || isCheckingOnboarding || isStartingPayment || isDeclining)

                if isOwner {
                    Button {
                        Task { await declineSafePayment() }
                    } label: {
                        BoenklereActionButtonLabel(
                            title: "Avslå",
                            systemImage: "xmark.circle.fill",
                            isLoading: isDeclining,
                            textColor: .red,
                            fillColor: Color.red.opacity(0.15)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isAcceptingTask || isCheckingOnboarding || isStartingPayment || isDeclining)
                }
            }
        }
    }

    private var acceptedInfoSection: some View {
        safePaymentInfoBox {
            if isPaymentStarted {
                if isOwner {
                    ownerSafePaymentInfoText
                } else {
                    executorSafePaymentInfoText
                }
            } else {
                Text("Du har godtatt oppdraget, venter på godkjenning av \(ownerDisplayName)")
            }
        }
    }

    private var shouldShowCompletePaymentButton: Bool {
        guard authManager.isAuthenticated, isSafePayment, isOwner else { return false }
        guard listing?.status != "COMPLETED" else { return false }
        return true
    }

    private var completePaymentButton: some View {
        HStack(spacing: 8) {
            Button {
                Task { await completeListingAndReview() }
            } label: {
                HStack(spacing: 6) {
                    if isCompletingListing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text("Fullfør - oppdraget er utført")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 0.11, green: 0.56, blue: 0.24))
                .cornerRadius(24)
            }
            .buttonStyle(.plain)
            .disabled(isCompletingListing)

            SafePaymentInfoTooltipButton(
                text: "Trykk «Fullfør» når jobben er ferdig for å utbetale til utføreren.\nUtbetaling skjer automatisk etter 6 dager hvis du ikke gjør noe. Du kan kansellere før det via menyen."
            )
        }
    }

    private var shouldShowReviewOwnerButton: Bool {
        guard authManager.isAuthenticated else { return false }
        guard !isOwner else { return false }
        guard listing?.status == "COMPLETED" else { return false }
        guard !hasReviewedOwner else { return false }
        return true
    }
    
    private var shouldShowReviewContractorButton: Bool {
        guard authManager.isAuthenticated else { return false }
        guard isOwner else { return false }
        guard listing?.status == "COMPLETED" else { return false }
        guard listing?.acceptedContractorId != nil else { return false }
        guard !hasReviewedContractor else { return false }
        return true
    }

    private var reviewOwnerButton: some View {
        Button {
            showReviewOwnerSheet = true
        } label: {
            BoenklereActionButtonLabel(
                title: "Gi vurdering av \(ownerDisplayName)",
                systemImage: "star.fill"
            )
        }
        .buttonStyle(.plain)
    }
    
    private var reviewContractorButton: some View {
        Button {
            showReviewContractorSheet = true
        } label: {
            BoenklereActionButtonLabel(
                title: "Gi vurdering av \(contractorDisplayName)",
                systemImage: "star.fill"
            )
        }
        .buttonStyle(.plain)
    }

    private var messageRows: [MessageRow] {
        makeMessageRows(messages: messages, currentUserId: authManager.userIdentifier)
    }

    private var ownerDisplayName: String {
        let name = displayOtherName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "oppdragseier" : name
    }

    private var executorDisplayName: String {
        let name = displayOtherName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "oppdragstaker" : name
    }
    
    private var contractorDisplayName: String {
        let name = displayOtherName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "oppdragstaker" : name
    }

    private var executorSafePaymentInfoText: some View {
        Text(
            "Dere har begge godtatt å utføre oppdraget med Trygg betaling. Du mottar utbetaling når \(ownerDisplayName) markerer oppdraget som utført"
        )
    }

    private var ownerSafePaymentInfoText: some View {
        let info = ownerSafePaymentInfoAttributedString(executorName: executorDisplayName)
        return Text(info)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "boenklere", url.host == "my-listings" {
                    openMyListings()
                    return .handled
                }
                return .systemAction
            })
    }

    private var safePaymentPriceText: String {
        if let amountMinor = conversation.safePaymentAmount {
            let amountValue = Double(amountMinor) / 100.0
            let formatted = amountValue.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(amountValue))
                : String(format: "%.2f", amountValue)
            return "\(formatted) kr"
        }
        if let listing {
            let priceValue = max(0, Int(listing.price))
            return "\(priceValue) kr"
        }
        return "0 kr"
    }

    private func ownerSafePaymentInfoAttributedString(executorName: String) -> AttributedString {
        let linkToken = "[[MY_LISTINGS]]"
        let raw = "Dere har begge godtatt å utføre oppdraget med Trygg betaling. For å utbetalt pengene til \(executorName) må du etter endt oppdrag markere oppdrag som utført i \(linkToken). Ønsker du å kansellere, vil vi refundere pengene til din konto. Det kan du enten gjøre i Mine annonser eller trykke på knappen oppe til høyre."
        var info = AttributedString(raw)
        if let range = info.range(of: linkToken) {
            var link = AttributedString("Mine annonser")
            link.font = .caption.bold()
            link.foregroundColor = .secondary
            link.link = URL(string: "boenklere://my-listings")
            info.replaceSubrange(range, with: link)
        }
        return info
    }

    private func safePaymentInfoBox(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func openMyListings() {
        NotificationCenter.default.post(name: .openMyListings, object: nil)
    }

    @MainActor
    private func completeListingAndReview() async {
        guard let listing else { return }
        guard let userId = authManager.userIdentifier else { return }
        guard let listingId = listing.id else { return }

        isCompletingListing = true
        errorMessage = nil

        do {
            let updated = try await APIService.shared.updateListing(
                listingId: listingId,
                title: listing.title,
                description: listing.description,
                address: listing.address,
                latitude: listing.latitude,
                longitude: listing.longitude,
                price: listing.price,
                offersSafePayment: listing.offersSafePayment ?? false,
                status: "COMPLETED",
                userId: userId,
                imageData: nil
            )
            self.listing = updated
            showCompleteSheet = true
        } catch {
            errorMessage = "Kunne ikke fullføre oppdraget"
        }

        isCompletingListing = false
    }

    @MainActor
    private func cancelSafePayment() async {
        guard let userId = authManager.userIdentifier else { return }
        guard !isCancelingPayment else { return }

        isCancelingPayment = true
        errorMessage = nil

        do {
            let updated = try await APIService.shared.cancelSafePayment(
                conversationId: conversation.id,
                userId: userId
            )
            safePaymentStatusOverride = updated.safePaymentStatus
            didAcceptSafePayment = false
        } catch {
            errorMessage = "Kunne ikke kansellere oppdraget"
        }

        isCancelingPayment = false
    }

    @MainActor
    private func deleteListing() async {
        guard let listingId = listing?.id else { return }
        guard !isDeletingListing else { return }

        isDeletingListing = true
        errorMessage = nil

        do {
            try await APIService.shared.deleteListing(id: listingId)
            dismiss()
        } catch {
            errorMessage = "Kunne ikke slette annonsen"
        }

        isDeletingListing = false
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
    private func refreshListing() async {
        do {
            let updatedListing = try await APIService.shared.getListing(id: conversation.listingId)
            listing = updatedListing
            // Also refresh conversation to get updated safePaymentStatus
            let updatedConversation = try await APIService.shared.getConversation(id: conversation.id)
            safePaymentStatusOverride = updatedConversation.safePaymentStatus
        } catch {
            // Ignore refresh errors
        }
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

    @MainActor
    private func checkOnboardingAndProceed() async {
        guard !isCheckingOnboarding else { return }
        guard authManager.isAuthenticated else { return }
        if isOwner { return }
        guard let userId = authManager.userIdentifier else { return }

        isCheckingOnboarding = true
        defer { isCheckingOnboarding = false }

        do {
            let response = try await APIService.shared.checkSafePaymentOnboarding(
                conversationId: conversation.id,
                userId: userId
            )
            if response.requiresOnboarding {
                guard let urlString = response.onboardingUrl,
                      let url = URL(string: urlString) else {
                    errorMessage = "Kunne ikke starte Stripe onboarding"
                    return
                }
                onboardingUrl = url
                showStripeOnboardingExplanation = true
                return
            }
        } catch {
            errorMessage = "Kunne ikke sjekke Stripe-tilkobling"
            return
        }

        await handleAcceptAction()
    }

    @MainActor
    private func startStripeOnboarding() {
        showStripeOnboardingExplanation = false
        guard let url = onboardingUrl else {
            errorMessage = "Kunne ikke starte Stripe onboarding"
            return
        }
        shouldRetryAcceptAfterOnboarding = true
        showOnboarding = true
    }

    @MainActor
    private func handleAcceptAction() async {
        guard !isAcceptingTask else { return }
        guard authManager.isAuthenticated else { return }
        if isOwner { return }
        guard let listingId = listing?.id else { return }
        guard let userId = authManager.userIdentifier else { return }

        isAcceptingTask = true
        print("Accept: start listingId=\(listingId) userId=\(userId)")
        do {
            // First accept the listing status
            let updatedListing = try await APIService.shared.acceptListing(
                listingId: listingId,
                userId: userId
            )
            listing = updatedListing
            didAcceptSafePayment = true
            print("Accept: listing status updated to \(updatedListing.status ?? "nil")")
            
            // Also call the old conversation-based accept for Stripe onboarding check
            let response = try await APIService.shared.acceptSafePayment(
                conversationId: conversation.id,
                userId: userId
            )
            if response.requiresOnboarding {
                if let urlString = response.onboardingUrl,
                   let url = URL(string: urlString) {
                    print("Stripe: onboarding required")
                    onboardingUrl = url
                    shouldRetryAcceptAfterOnboarding = true
                    showOnboarding = true
                } else {
                    errorMessage = "Kunne ikke starte Stripe onboarding"
                }
            } else {
                safePaymentStatusOverride = response.conversation.safePaymentStatus
            }
        } catch {
            errorMessage = "Kunne ikke oppdatere oppdraget"
            print("Accept: failed listingId=\(listingId) error=\(error)")
        }
        isAcceptingTask = false
    }

    @MainActor
    private func retryAcceptAfterOnboarding() async {
        guard shouldRetryAcceptAfterOnboarding else { return }
        shouldRetryAcceptAfterOnboarding = false
        await handleAcceptAction()
    }

    @MainActor
    private func fetchAndOpenOnboarding() async {
        guard let userId = authManager.userIdentifier else { return }

        do {
            let response = try await APIService.shared.acceptSafePayment(
                conversationId: conversation.id,
                userId: userId
            )
            if let urlString = response.onboardingUrl,
               let url = URL(string: urlString) {
                onboardingUrl = url
                shouldRetryAcceptAfterOnboarding = true
                showOnboarding = true
            } else {
                errorMessage = "Kunne ikke starte Stripe onboarding"
            }
        } catch {
            errorMessage = "Kunne ikke starte Stripe onboarding"
        }
    }

    @MainActor
    private func handleOwnerPaymentAction() async {
        guard authManager.isAuthenticated else { return }
        guard let userId = authManager.userIdentifier else { return }

        isStartingPayment = true
        print("Stripe: payment start conversationId=\(conversation.id) userId=\(userId)")
        do {
            let response = try await APIService.shared.createSafePaymentIntent(
                conversationId: conversation.id,
                userId: userId
            )
            StripeAPI.defaultPublishableKey = response.publishableKey
            safePaymentStatusOverride = response.conversation.safePaymentStatus
            print("Stripe: payment sheet ready conversationId=\(conversation.id)")
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = "Boenklere"
            paymentSheet = PaymentSheet(
                paymentIntentClientSecret: response.clientSecret,
                configuration: configuration
            )
            showPaymentSheet = true
        } catch {
            errorMessage = "Kunne ikke starte betaling"
            print("Stripe: payment start failed conversationId=\(conversation.id) error=\(error)")
        }
        isStartingPayment = false
    }

    private func handlePaymentSheetResult(_ result: PaymentSheetResult) {
        switch result {
        case .completed:
            print("Stripe: payment sheet completed")
            Task { await confirmSafePayment() }
        case .failed:
            errorMessage = "Betaling feilet"
            print("Stripe: payment sheet failed")
        case .canceled:
            print("Stripe: payment sheet canceled")
            break
        }
        showPaymentSheet = false
        paymentSheet = nil
    }

    @MainActor
    private func confirmSafePayment() async {
        guard let userId = authManager.userIdentifier else { return }
        do {
            let updated = try await APIService.shared.confirmSafePayment(
                conversationId: conversation.id,
                userId: userId
            )
            safePaymentStatusOverride = updated.safePaymentStatus
            print("Stripe: payment confirmed conversationId=\(conversation.id) status=\(updated.safePaymentStatus ?? "nil")")
        } catch {
            errorMessage = "Kunne ikke bekrefte betalingen"
            print("Stripe: payment confirm failed conversationId=\(conversation.id) error=\(error)")
        }
    }

    @MainActor
    private func checkIfAlreadyReviewedOwner() async {
        guard let userId = authManager.userIdentifier else { return }
        guard !isOwner else { return }
        guard let listingId = listing?.id else { return }
        guard let ownerId = listing?.userId else { return }

        isCheckingReview = true
        do {
            let reviews = try await APIService.shared.getReviewsByReviewer(userId: userId)
            hasReviewedOwner = reviews.contains { review in
                review.listingId == listingId && review.revieweeId == ownerId
            }
        } catch {
            hasReviewedOwner = false
        }
        isCheckingReview = false
    }
    
    @MainActor
    private func checkIfAlreadyReviewedContractor() async {
        guard let userId = authManager.userIdentifier else { return }
        guard isOwner else { return }
        guard let listingId = listing?.id else { return }
        guard let contractorId = listing?.acceptedContractorId else { return }

        isCheckingReview = true
        do {
            let reviews = try await APIService.shared.getReviewsByReviewer(userId: userId)
            hasReviewedContractor = reviews.contains { review in
                review.listingId == listingId && review.revieweeId == contractorId
            }
        } catch {
            hasReviewedContractor = false
        }
        isCheckingReview = false
    }

    @MainActor
    private func submitOwnerReview() async {
        print("submitOwnerReview: started")
        guard let userId = authManager.userIdentifier else {
            print("submitOwnerReview: no userId")
            return
        }
        guard let listingId = listing?.id else {
            print("submitOwnerReview: no listingId")
            return
        }
        guard let ownerId = listing?.userId else {
            print("submitOwnerReview: no ownerId")
            return
        }
        guard reviewRating > 0 else {
            print("submitOwnerReview: rating is 0")
            errorMessage = "Du må velge en vurdering"
            return
        }

        print("submitOwnerReview: calling API with listingId=\(listingId) reviewerId=\(userId) revieweeId=\(ownerId) rating=\(reviewRating)")
        isSubmittingReview = true
        do {
            _ = try await APIService.shared.createReview(
                listingId: listingId,
                reviewerId: userId,
                revieweeId: ownerId,
                rating: reviewRating,
                comment: reviewComment.isEmpty ? nil : reviewComment
            )
            print("submitOwnerReview: success")
            hasReviewedOwner = true
            showReviewOwnerSheet = false
            reviewRating = 0
            reviewComment = ""
        } catch {
            print("submitOwnerReview: error \(error)")
            errorMessage = "Kunne ikke lagre vurderingen"
        }
        isSubmittingReview = false
    }
    
    @MainActor
    private func submitContractorReview() async {
        guard let userId = authManager.userIdentifier else { return }
        guard let listingId = listing?.id else { return }
        guard let contractorId = listing?.acceptedContractorId else { return }
        guard reviewRating > 0 else {
            errorMessage = "Du må velge en vurdering"
            return
        }

        isSubmittingReview = true
        do {
            _ = try await APIService.shared.createReview(
                listingId: listingId,
                reviewerId: userId,
                revieweeId: contractorId,
                rating: reviewRating,
                comment: reviewComment.isEmpty ? nil : reviewComment
            )
            hasReviewedContractor = true
            showReviewContractorSheet = false
            reviewRating = 0
            reviewComment = ""
        } catch {
            errorMessage = "Kunne ikke lagre vurderingen"
        }
        isSubmittingReview = false
    }

    @MainActor
    private func declineSafePayment() async {
        guard !isDeclining else { return }
        guard authManager.isAuthenticated else { return }
        guard let listingId = listing?.id else { return }
        guard let userId = authManager.userIdentifier else { return }

        isDeclining = true
        do {
            // Reset conversation safe payment state FIRST (this also resets listing status to INITIATED)
            // Must happen before sending system message to avoid race condition
            let updated = try await APIService.shared.declineSafePayment(
                conversationId: conversation.id,
                userId: userId
            )
            safePaymentStatusOverride = updated.safePaymentStatus
            
            // Refresh listing to get updated status
            let updatedListing = try await APIService.shared.getListing(id: listingId)
            listing = updatedListing
            didAcceptSafePayment = false
            
            // Send system message AFTER database is updated
            // This ensures other clients get correct data when they refresh
            let declineName = displayOtherName
            let message = try await APIService.shared.sendMessage(
                conversationId: conversation.id,
                senderId: userId,
                body: "SYSTEM:\(declineName) har avslått oppdraget."
            )
            appendMessage(message)
        } catch {
            errorMessage = "Kunne ikke avslå oppdraget"
        }
        isDeclining = false
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

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onDismiss: (() -> Void)?

        init(onDismiss: (() -> Void)?) {
            self.onDismiss = onDismiss
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDismiss?()
        }
    }
}

struct PaymentSheetPresenter: UIViewControllerRepresentable {
    let paymentSheet: PaymentSheet
    let onCompletion: (PaymentSheetResult) -> Void

    func makeUIViewController(context: Context) -> PresentationController {
        PresentationController(paymentSheet: paymentSheet, onCompletion: onCompletion)
    }

    func updateUIViewController(_ uiViewController: PresentationController, context: Context) {
        uiViewController.paymentSheet = paymentSheet
        uiViewController.onCompletion = onCompletion
        uiViewController.presentIfNeeded()
    }

    final class PresentationController: UIViewController {
        var paymentSheet: PaymentSheet
        var onCompletion: (PaymentSheetResult) -> Void
        private var didPresent = false

        init(paymentSheet: PaymentSheet, onCompletion: @escaping (PaymentSheetResult) -> Void) {
            self.paymentSheet = paymentSheet
            self.onCompletion = onCompletion
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentIfNeeded()
        }

        func presentIfNeeded() {
            guard !didPresent else { return }
            guard view.window != nil else { return }
            didPresent = true
            paymentSheet.present(from: self) { [weak self] result in
                self?.didPresent = false
                self?.onCompletion(result)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: APIMessage
    let bodyText: String
    let isSystem: Bool
    let isOutgoing: Bool
    let avatarName: String?
    let showsAvatar: Bool
    let showsTimestamp: Bool
    let isGroupedWithPrevious: Bool
    let isGroupedWithNext: Bool
    let topSpacing: CGFloat
    let onAvatarTap: (() -> Void)?

    var body: some View {
        if isSystem {
            HStack {
                Spacer(minLength: 40)
                Text(bodyText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5), in: Capsule())
                Spacer(minLength: 40)
            }
            .padding(.top, topSpacing)
        } else {
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
        Text(bodyText)
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
    let bodyText: String
    let isSystem: Bool
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

        let systemState = parseSystemMessage(message.body)
        let prevIsSystem = prev.map { parseSystemMessage($0.body).isSystem } ?? false
        let nextIsSystem = next.map { parseSystemMessage($0.body).isSystem } ?? false
        let isOutgoing = !systemState.isSystem && currentUserId != nil && message.senderId == currentUserId
        let groupedWithPrev = !systemState.isSystem && !prevIsSystem && prev?.senderId == message.senderId
        let groupedWithNext = !systemState.isSystem && !nextIsSystem && next?.senderId == message.senderId
        let showAvatar = !systemState.isSystem && !isOutgoing && !groupedWithNext
        let showTimestamp = !systemState.isSystem && !groupedWithNext
        let topSpacing: CGFloat = systemState.isSystem ? 12 : (groupedWithPrev ? 2 : 10)

        rows.append(
            MessageRow(
                message: message,
                bodyText: systemState.text,
                isSystem: systemState.isSystem,
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

private let systemMessagePrefix = "SYSTEM:"
private let executorAcceptanceMarker = "har godtatt oppdraget for"
private let safePaymentCancellationMarker = "har kansellert oppdraget"
private let safePaymentDeclineMarker = "har avslått oppdraget"

private func parseSystemMessage(_ body: String) -> (isSystem: Bool, text: String) {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix(systemMessagePrefix) {
        let stripped = trimmed.dropFirst(systemMessagePrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, stripped)
    }
    return (false, trimmed)
}

private func stripSystemMessage(_ body: String?) -> String? {
    guard let body else { return nil }
    return parseSystemMessage(body).text
}

private func isExecutorAcceptanceMessage(_ body: String) -> Bool {
    let parsed = parseSystemMessage(body)
    guard parsed.isSystem else { return false }
    return parsed.text.localizedCaseInsensitiveContains(executorAcceptanceMarker)
}

private func isSafePaymentCancellationMessage(_ body: String) -> Bool {
    let parsed = parseSystemMessage(body)
    guard parsed.isSystem else { return false }
    return parsed.text.localizedCaseInsensitiveContains(safePaymentCancellationMarker) ||
           parsed.text.localizedCaseInsensitiveContains(safePaymentDeclineMarker)
}

private func latestMessageId(
    in messages: [APIMessage],
    matching predicate: (String) -> Bool
) -> Int64? {
    messages.filter { predicate($0.body) }.map(\.id).max()
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

private struct ReviewOwnerSheet: View {
    let ownerName: String
    @Binding var rating: Int
    @Binding var comment: String
    let isSubmitting: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(spacing: 20) {
                    Text("Hvordan var din opplevelse med oppdraget?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                rating = star
                            } label: {
                                Image(systemName: star <= rating ? "star.fill" : "star")
                                    .font(.system(size: 32))
                                    .foregroundColor(star <= rating ? .yellow : .gray.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kommentar (valgfritt)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Skriv en kommentar...", text: $comment, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }

                    Button {
                        onSubmit()
                    } label: {
                        if isSubmitting {
                            BoenklereActionButtonLabel(title: "Send vurdering", systemImage: "star.fill")
                                .overlay(ProgressView())
                        } else {
                            BoenklereActionButtonLabel(title: "Send vurdering", systemImage: "star.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(rating == 0 || isSubmitting)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var sheetHeader: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 5)
                .padding(.bottom, 3)

            HStack {
                Text("Vurder \(ownerName)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: onCancel) {
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
    }
}

private struct SafePaymentInfoTooltipButton: View {
    let text: String
    @State private var showInfo = false
    @State private var isPulsing = false

    var body: some View {
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(Color.blue)
                .scaleEffect(isPulsing ? 1.15 : 1.0)
                .opacity(isPulsing ? 0.7 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .onAppear { isPulsing = true }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo) {
            ScrollView {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            .frame(width: 300)
            .frame(maxHeight: 300)
            .presentationCompactAdaptation(.popover)
        }
    }
}
