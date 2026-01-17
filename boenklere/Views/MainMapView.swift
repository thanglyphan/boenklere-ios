import SwiftUI
import MapKit
import CoreLocation
import AuthenticationServices
import PhotosUI
import UIKit

struct MainMapView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationManager = LocationManager()
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showProfileSheet = false
    @State private var showConversationsSheet = false
    @State private var showMessagesLoginAlert = false
    @State private var sheetDetent: PresentationDetent = .height(70)
    @State private var listings: [APIListing] = []
    @State private var selectedListing: APIListing?
    @State private var deepLinkConversation: APIConversationSummary?
    @State private var pendingConversationId: Int64?
    @State private var pendingListingNotificationId: Int64?
    @State private var isLoadingConversationFromNotification = false
    @State private var isLoadingListingFromNotification = false
    @State private var mapRegion: MKCoordinateRegion?
    @State private var clusteringEnabled = true
    @State private var listingsReloadTask: Task<Void, Never>?
    @State private var didLoadInitialListings = false
    @State private var didCenterOnUser = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $cameraPosition) {
                UserAnnotation()

                // Listing markers (clustered when zoomed out)
                ForEach(clusteredListings) { cluster in
                    if let listing = cluster.listings.first, cluster.listings.count == 1 {
                        Annotation("", coordinate: cluster.coordinate) {
                            Button {
                                selectedListing = listing
                            } label: {
                                ListingMapMarker(listing: listing)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Annotation("", coordinate: cluster.coordinate) {
                            Button {
                                zoomToCluster(cluster)
                            } label: {
                                ListingClusterMarker(count: cluster.listings.count)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .mapControls {
                MapCompass()
            }
            .mapStyle(.standard)
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .onEnd) { context in
                let region = context.region
                mapRegion = region
                updateClusteringState(for: region)
                if sheetDetent != .large {
                    scheduleListingsReload(for: region)
                }
            }
            .onAppear {
                locationManager.requestLocation()
            }
            .onChange(of: locationManager.location) { _, newLocation in
                if let location = newLocation, !didCenterOnUser {
                    let region = MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
                    )
                    cameraPosition = .region(region)
                    mapRegion = region
                    updateClusteringState(for: region)
                    scheduleListingsReload(for: region)
                    didCenterOnUser = true
                }
            }

            recenterButton
                .padding(.leading, 20)
                .padding(.bottom, sheetBottomPadding)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sheetDetent)
                .opacity(sheetDetent == .large ? 0 : 1)

            mapActionPill
                .padding(.trailing, 20)
                .padding(.bottom, sheetBottomPadding)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sheetDetent)
                .opacity(sheetDetent == .large ? 0 : 1)
        }
        .sheet(isPresented: .constant(true)) {
            SearchSheet(
                sheetDetent: $sheetDetent,
                showProfileSheet: $showProfileSheet,
                showMessagesLoginAlert: $showMessagesLoginAlert,
                listings: $listings,
                selectedListing: $selectedListing,
                deepLinkConversation: $deepLinkConversation,
                userLocation: locationManager.location,
                onListingCreated: loadListings
            )
                .environmentObject(authManager)
                .presentationDetents([.height(70), .medium, .large], selection: $sheetDetent)
                .presentationDragIndicator(.hidden)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
                .sheet(isPresented: $showProfileSheet) {
                    ProfileSheet()
                        .environmentObject(authManager)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.hidden)
                }
                .sheet(isPresented: $showConversationsSheet) {
                    NavigationStack {
                        ConversationsSheet()
                            .environmentObject(authManager)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.hidden)
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveChatNotification)) { notification in
            guard let payload = notification.object as? ChatNotificationPayload else { return }
            handleChatNotification(payload)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveListingNotification)) { notification in
            guard let payload = notification.object as? ListingNotificationPayload else { return }
            handleListingNotification(payload)
        }
        .onChange(of: authManager.isAuthenticated) { _, _ in
            Task {
                await openPendingConversationIfPossible()
                await authManager.refreshUnreadMessageCount()
            }
        }
        .onChange(of: authManager.userIdentifier) { _, _ in
            Task { await openPendingConversationIfPossible() }
        }
        .onChange(of: selectedListing) { _, newValue in
            if let listing = newValue {
                focusMap(on: listing)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await authManager.refreshUnreadMessageCount() }
            }
        }
        .task {
            if let payload = ChatNotificationStore.consume() {
                handleChatNotification(payload)
            }
            if let payload = ListingNotificationStore.consume() {
                handleListingNotification(payload)
            }
            guard !didLoadInitialListings else { return }
            didLoadInitialListings = true
            await authManager.refreshUnreadMessageCount()
            await loadListings()
        }
    }

    private struct ListingCluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let listings: [APIListing]
    }

    private var recenterButton: some View {
        Button {
            centerOnUser()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var mapActionPill: some View {
        VStack(spacing: 6) {
            Button {
                if authManager.isAuthenticated {
                    showConversationsSheet = true
                } else {
                    showMessagesLoginAlert = true
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(showConversationsSheet ? .white : .primary)
                        .frame(width: 40, height: 40)
                        .background(showConversationsSheet ? Color.blue : Color.clear, in: Circle())

                    if authManager.unreadMessageCount > 0 {
                        Text("\(min(authManager.unreadMessageCount, 99))")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.blue, in: Capsule())
                            .offset(x: 6, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)

            Divider()
                .frame(width: 26)
                .overlay(Color.white.opacity(0.3))

            Button {
                showProfileSheet = true
            } label: {
                Image(systemName: "person.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(showProfileSheet ? .white : .primary)
                    .frame(width: 40, height: 40)
                    .background(showProfileSheet ? Color.blue : Color.clear, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 6)
    }

    private func centerOnUser() {
        if locationManager.location == nil {
            locationManager.requestLocation()
            return
        }
        guard let location = locationManager.location else { return }
        let region = MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
        mapRegion = region
        updateClusteringState(for: region)
        if sheetDetent != .large {
            scheduleListingsReload(for: region)
        }
        didCenterOnUser = true
    }

    private var clusteredListings: [ListingCluster] {
        let items = listings.compactMap { listing -> APIListing? in
            guard listing.latitude != nil, listing.longitude != nil else { return nil }
            return listing
        }

        guard let region = mapRegion, !items.isEmpty else {
            return spreadListings(items)
        }

        if !clusteringEnabled {
            return spreadListings(items)
        }

        let latStep = max(region.span.latitudeDelta / 8, 0.002)
        let lonStep = max(region.span.longitudeDelta / 8, 0.002)

        var buckets: [String: [APIListing]] = [:]
        for listing in items {
            guard let lat = listing.latitude, let lon = listing.longitude else { continue }
            let latBucket = Int(floor(lat / latStep))
            let lonBucket = Int(floor(lon / lonStep))
            let key = "\(latBucket)_\(lonBucket)"
            buckets[key, default: []].append(listing)
        }

        return buckets.map { key, group in
            let latSum = group.compactMap { $0.latitude }.reduce(0, +)
            let lonSum = group.compactMap { $0.longitude }.reduce(0, +)
            let count = Double(group.count)
            let coordinate = CLLocationCoordinate2D(latitude: latSum / count, longitude: lonSum / count)
            return ListingCluster(id: key, coordinate: coordinate, listings: group)
        }
    }

    private func spreadListings(_ items: [APIListing]) -> [ListingCluster] {
        var groups: [String: [APIListing]] = [:]

        for listing in items {
            guard let lat = listing.latitude, let lon = listing.longitude else { continue }
            let key = coordinateKey(lat: lat, lon: lon)
            groups[key, default: []].append(listing)
        }

        var clusters: [ListingCluster] = []
        for (key, group) in groups {
            let sortedGroup = group.sorted { (left, right) in
                (left.id ?? 0) < (right.id ?? 0)
            }
            guard let baseLat = sortedGroup.first?.latitude,
                  let baseLon = sortedGroup.first?.longitude else {
                continue
            }
            let baseCoordinate = CLLocationCoordinate2D(latitude: baseLat, longitude: baseLon)

            if sortedGroup.count == 1, let listing = sortedGroup.first {
                clusters.append(
                    ListingCluster(
                        id: "\(listing.id ?? 0)",
                        coordinate: baseCoordinate,
                        listings: [listing]
                    )
                )
                continue
            }

            for (index, listing) in sortedGroup.enumerated() {
                let coordinate = offsetCoordinate(base: baseCoordinate, index: index, count: sortedGroup.count)
                let id = "\(listing.id ?? 0)_\(key)"
                clusters.append(
                    ListingCluster(
                        id: id,
                        coordinate: coordinate,
                        listings: [listing]
                    )
                )
            }
        }

        return clusters
    }

    private func coordinateKey(lat: Double, lon: Double) -> String {
        String(format: "%.5f_%.5f", lat, lon)
    }

    private func offsetCoordinate(
        base: CLLocationCoordinate2D,
        index: Int,
        count: Int
    ) -> CLLocationCoordinate2D {
        guard count > 1 else { return base }

        let radiusMeters = min(18.0 + (Double(count) - 2) * 4.0, 32.0)
        let angle = (2.0 * Double.pi / Double(count)) * Double(index)
        let metersPerDegreeLat = 111_000.0
        let latOffset = (radiusMeters / metersPerDegreeLat) * cos(angle)
        let latRadians = base.latitude * Double.pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * max(cos(latRadians), 0.1)
        let lonOffset = (radiusMeters / metersPerDegreeLon) * sin(angle)

        return CLLocationCoordinate2D(
            latitude: base.latitude + latOffset,
            longitude: base.longitude + lonOffset
        )
    }

    private func zoomToCluster(_ cluster: ListingCluster) {
        guard let region = mapRegion else { return }
        let newSpan = MKCoordinateSpan(
            latitudeDelta: max(region.span.latitudeDelta / 2, 0.002),
            longitudeDelta: max(region.span.longitudeDelta / 2, 0.002)
        )
        cameraPosition = .region(MKCoordinateRegion(center: cluster.coordinate, span: newSpan))
    }

    private func updateClusteringState(for region: MKCoordinateRegion) {
        let enableThreshold: CLLocationDegrees = 0.03
        let disableThreshold: CLLocationDegrees = 0.02

        if clusteringEnabled {
            if region.span.latitudeDelta <= disableThreshold && region.span.longitudeDelta <= disableThreshold {
                clusteringEnabled = false
            }
        } else {
            if region.span.latitudeDelta >= enableThreshold || region.span.longitudeDelta >= enableThreshold {
                clusteringEnabled = true
            }
        }
    }

    private var sheetBottomPadding: CGFloat {
        switch sheetDetent {
        case .height(70):
            return 70
        case .medium:
            return UIScreen.main.bounds.height * 0.5 + 20
        case .large:
            return UIScreen.main.bounds.height - 40
        default:
            return 70
        }
    }

    private func loadListings() async {
        do {
            if Task.isCancelled { return }
            let fetchedListings: [APIListing]
            if let region = mapRegion,
               region.span.latitudeDelta > 0,
               region.span.longitudeDelta > 0 {
                let bounds = bounds(for: region)
                fetchedListings = try await APIService.shared.getListings(
                    minLat: bounds.minLat,
                    maxLat: bounds.maxLat,
                    minLon: bounds.minLon,
                    maxLon: bounds.maxLon
                )
            } else {
                fetchedListings = try await APIService.shared.getListings()
            }
            if Task.isCancelled { return }
            let filteredListings = fetchedListings.filter { $0.isCompleted != true }
            await MainActor.run {
                listings = filteredListings
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("Failed to load listings: \(error)")
        }
    }

    private func handleChatNotification(_ payload: ChatNotificationPayload) {
        pendingConversationId = payload.conversationId
        ChatNotificationStore.clear()
        Task { await openPendingConversationIfPossible() }
    }

    private func handleListingNotification(_ payload: ListingNotificationPayload) {
        pendingListingNotificationId = payload.listingId
        ListingNotificationStore.clear()
        Task { await openPendingListingIfPossible() }
    }

    @MainActor
    private func openPendingConversationIfPossible() async {
        guard !isLoadingConversationFromNotification else { return }
        guard let conversationId = pendingConversationId else { return }
        guard authManager.isAuthenticated, let userId = authManager.userIdentifier else {
            showMessagesLoginAlert = true
            return
        }

        isLoadingConversationFromNotification = true
        defer { isLoadingConversationFromNotification = false }

        do {
            let conversations = try await APIService.shared.getConversations(userId: userId)
            if let conversation = conversations.first(where: { $0.id == conversationId }) {
                selectedListing = nil
                deepLinkConversation = conversation
                pendingConversationId = nil
            } else {
                showConversationsSheet = true
            }
        } catch {
            showConversationsSheet = true
        }
    }

    @MainActor
    private func openPendingListingIfPossible() async {
        guard !isLoadingListingFromNotification else { return }
        guard let listingId = pendingListingNotificationId else { return }

        isLoadingListingFromNotification = true
        defer { isLoadingListingFromNotification = false }

        do {
            let listing = try await APIService.shared.getListing(id: listingId)
            deepLinkConversation = nil
            selectedListing = listing
            pendingListingNotificationId = nil
        } catch {
            pendingListingNotificationId = nil
        }
    }

    private func scheduleListingsReload(for region: MKCoordinateRegion) {
        listingsReloadTask?.cancel()
        listingsReloadTask = Task {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await loadListings()
        }
    }

    private func bounds(for region: MKCoordinateRegion) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let expansionFactor = 5.0
        let halfLat = region.span.latitudeDelta / 2 * expansionFactor
        let halfLon = region.span.longitudeDelta / 2 * expansionFactor

        let minLat = max(region.center.latitude - halfLat, -90)
        let maxLat = min(region.center.latitude + halfLat, 90)
        let minLon = max(region.center.longitude - halfLon, -180)
        let maxLon = min(region.center.longitude + halfLon, 180)

        return (minLat, maxLat, minLon, maxLon)
    }

    private func focusMap(on listing: APIListing) {
        guard let lat = listing.latitude, let lon = listing.longitude else { return }
        let span = mapRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: span
        )
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
    }
}

// MARK: - Listing Map Marker (Apple Maps style circular image)
struct ListingMapMarker: View {
    let listing: APIListing
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 50, height: 50)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundColor(.blue)
                        }
                }
            }

            VStack(spacing: 4) {
                Text(truncatedTitle)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())

                Text(priceLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(listing.price > 0 ? .blue : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        }
        .task {
            await loadImage()
        }
    }

    private var truncatedTitle: String {
        if listing.title.count <= 25 {
            return listing.title
        }

        let endIndex = listing.title.index(listing.title.startIndex, offsetBy: 25)
        return String(listing.title[..<endIndex]) + "…"
    }

    private var priceLabel: String {
        if listing.price > 0 {
            return "\(Int(listing.price)) kr"
        }
        return "Ikke oppgitt"
    }

    private func loadImage() async {
        guard let urlString = listing.imageUrl,
              let url = URL(string: urlString) else { return }

        if let cached = ImageCache.shared.image(for: urlString) {
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
                ImageCache.shared.insert(uiImage, for: urlString)
            }
        } catch {
            print("Failed to load marker image: \(error)")
        }
    }
}

struct ListingClusterMarker: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.8), lineWidth: 2)
        )
    }
}

// MARK: - Listing Row (Apple-style list item)
struct ListingRow: View {
    let listing: APIListing
    let userLocation: CLLocation?
    let onTap: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
        HStack(spacing: 12) {
            // Round image on the left
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(.systemGray5))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    }
            }

            // Title and description
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(listing.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let distanceText {
                    Text(distanceText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Price on the right
                if listing.price > 0 {
                    Text("\(Int(listing.price)) kr")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                } else {
                    Text("Ikke oppgitt")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            await loadImage()
        }
    }

    private var distanceText: String? {
        guard let lat = listing.latitude,
              let lon = listing.longitude,
              let userLocation else {
            return nil
        }

        let listingLocation = CLLocation(latitude: lat, longitude: lon)
        let meters = listingLocation.distance(from: userLocation)

        if meters < 1000 {
            let rounded = Int(meters.rounded())
            return "\(rounded) m unna"
        }

        let km = meters / 1000
        if km < 10 {
            return String(format: "%.1f km unna", km)
        }

        let roundedKm = Int(km.rounded())
        return "\(roundedKm) km unna"
    }

    private func loadImage() async {
        guard let urlString = listing.imageUrl,
              let url = URL(string: urlString) else { return }

        if let cached = ImageCache.shared.image(for: urlString) {
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
                ImageCache.shared.insert(uiImage, for: urlString)
            }
        } catch {
            print("Failed to load row image: \(error)")
        }
    }
}

struct SearchSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Binding var sheetDetent: PresentationDetent
    @Binding var showProfileSheet: Bool
    @Binding var showMessagesLoginAlert: Bool
    @Binding var listings: [APIListing]
    @Binding var selectedListing: APIListing?
    @Binding var deepLinkConversation: APIConversationSummary?
    var userLocation: CLLocation?
    var onListingCreated: () async -> Void
    @StateObject private var addressSearch = AddressSearchCompleter()
    @State private var isCreatingListing = false

    // Create listing form fields
    @State private var newTitle = ""
    @State private var newDescription = ""
    @State private var newAddressQuery = ""
    @State private var newSelectedAddress = ""
    @State private var newLatitude: Double?
    @State private var newLongitude: Double?
    @State private var newPrice = ""
    @State private var showingAddressSuggestions = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImage: Image?
    @State private var selectedImageData: Data?
    @State private var detailSheetDetent: PresentationDetent = .medium
    @State private var useSavedAddress = false

    var isCollapsed: Bool {
        sheetDetent == .height(70)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header that's always visible
            VStack(spacing: 0) {
                // Drag indicator - Apple Maps style
                Capsule()
                    .fill(Color(.systemGray3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 5)
                    .padding(.bottom, 3)

                // Header with drag text and create button
                HStack {
                    Text("Fant \(listings.count) oppdrag")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Spacer()

                    Button {
                        if isCreatingListing {
                            isCreatingListing = false
                            withAnimation {
                                sheetDetent = .height(70)
                            }
                            clearForm()
                        } else {
                            isCreatingListing = true
                            withAnimation {
                                sheetDetent = .large
                            }
                        }
                    } label: {
                        Image(systemName: isCreatingListing ? "xmark" : "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(isCreatingListing ? Color.gray : Color.blue, in: Circle())
                    }
                }
                .padding(.horizontal, 16)
            }

            // Content below header (only shown when expanded)
            if isCreatingListing && !isCollapsed {
                createListingContent
                    .padding(.top, 16)
            } else if !isCollapsed {
                // Listings list
                listingsContent
            }

            Spacer(minLength: 0)
        }
        .confirmationDialog("Logg inn", isPresented: $showMessagesLoginAlert, titleVisibility: .visible) {
            Button("Logg inn med Apple") {
                authManager.signInWithApple()
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Du må være logget inn for å bruke meldinger.")
        }
        .sheet(item: $selectedListing) { listing in
            ListingDetailSheet(
                listing: listing,
                sheetDetent: $detailSheetDetent,
                userLocation: userLocation
            )
                .presentationDetents([.height(70), .medium, .large], selection: $detailSheetDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
        }
        .sheet(item: $deepLinkConversation) { conversation in
            ConversationChatSheet(conversation: conversation)
                .environmentObject(authManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .onChange(of: selectedListing) { _, newValue in
            if newValue != nil {
                detailSheetDetent = .medium
            }
        }
    }

    @ViewBuilder
    private var createListingContent: some View {
        VStack(spacing: 0) {
            if !authManager.isAuthenticated {
                VStack(spacing: 16) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text("Logg inn for å opprette annonser")
                        .foregroundColor(.secondary)

                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            handleAuthorization(authorization)
                        case .failure(let error):
                            print("Sign in failed: \(error)")
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 20)
                }
                .padding(.top, 40)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Photo picker
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            if let selectedImage {
                                selectedImage
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 150)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                    .cornerRadius(12)
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            self.selectedPhotoItem = nil
                                            self.selectedImage = nil
                                            self.selectedImageData = nil
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.title2)
                                                .foregroundColor(.white)
                                                .shadow(radius: 2)
                                        }
                                        .padding(8)
                                    }
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 32))
                                        .foregroundColor(.secondary)
                                    Text("Legg til bilde")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .frame(height: 150)
                                .frame(maxWidth: .infinity)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .onChange(of: selectedPhotoItem) { _, newItem in
                            guard let newItem else {
                                selectedImage = nil
                                selectedImageData = nil
                                return
                            }

                            newItem.loadTransferable(type: Data.self) { result in
                                DispatchQueue.main.async {
                                    switch result {
                                    case .success(let data):
                                        guard let data, let uiImage = UIImage(data: data) else { return }

                                        // Resize image to reduce memory usage
                                        let maxSize: CGFloat = 600
                                        let scale = min(maxSize / uiImage.size.width, maxSize / uiImage.size.height, 1.0)
                                        let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)

                                        let renderer = UIGraphicsImageRenderer(size: newSize)
                                        let resizedImage = renderer.image { _ in
                                            uiImage.draw(in: CGRect(origin: .zero, size: newSize))
                                        }

                                        selectedImageData = resizedImage.jpegData(compressionQuality: 0.6)
                                        selectedImage = Image(uiImage: resizedImage)

                                    case .failure(let error):
                                        print("Error loading image: \(error)")
                                    }
                                }
                            }
                        }

                        // Apple-style grouped text fields
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Tittel")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("", text: $newTitle)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            Divider()
                                .padding(.leading, 16)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Beskrivelse")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("", text: $newDescription, axis: .vertical)
                                    .lineLimit(2...4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            Divider()
                                .padding(.leading, 16)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Pris")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("kr", text: $newPrice)
                                    .keyboardType(.numberPad)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        if let savedAddress = authManager.userAddress,
                           let savedLatitude = authManager.userLatitude,
                           let savedLongitude = authManager.userLongitude {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Bruk lagret adresse", isOn: $useSavedAddress)
                                    .toggleStyle(.switch)

                                if useSavedAddress {
                                    HStack(spacing: 8) {
                                        Image(systemName: "mappin.circle.fill")
                                            .foregroundColor(.blue)
                                        Text(savedAddress)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .onChange(of: useSavedAddress) { _, newValue in
                                if newValue {
                                    newAddressQuery = savedAddress
                                    newSelectedAddress = savedAddress
                                    newLatitude = savedLatitude
                                    newLongitude = savedLongitude
                                    showingAddressSuggestions = false
                                } else {
                                    newAddressQuery = ""
                                    newSelectedAddress = ""
                                    newLatitude = nil
                                    newLongitude = nil
                                    showingAddressSuggestions = false
                                }
                            }
                        }

                        if !useSavedAddress {
                            // Address search
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                    TextField("Søk etter adresse", text: $newAddressQuery)
                                        .onChange(of: newAddressQuery) { _, newValue in
                                            addressSearch.search(query: newValue)
                                            showingAddressSuggestions = !newValue.isEmpty
                                        }
                                    if !newAddressQuery.isEmpty {
                                        Button { newAddressQuery = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            if !newSelectedAddress.isEmpty {
                                HStack {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.blue)
                                    Text(newSelectedAddress)
                                        .font(.subheadline)
                                    Spacer()
                                    Button {
                                        newSelectedAddress = ""
                                        newLatitude = nil
                                        newLongitude = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            if showingAddressSuggestions && !addressSearch.results.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(addressSearch.results.prefix(5), id: \.self) { result in
                                        Button {
                                            newAddressQuery = ""
                                            newSelectedAddress = result.title + ", " + result.subtitle
                                            showingAddressSuggestions = false
                                            Task {
                                                await getCoordinates(for: result)
                                            }
                                        } label: {
                                            HStack {
                                                Image(systemName: "mappin.and.ellipse")
                                                    .foregroundColor(.secondary)
                                                    .frame(width: 24)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(result.title)
                                                        .font(.subheadline)
                                                        .foregroundColor(.primary)
                                                    Text(result.subtitle)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                                Spacer()
                                            }
                                            .padding(.vertical, 10)
                                            .padding(.horizontal, 12)
                                        }
                                        if result != addressSearch.results.prefix(5).last {
                                            Divider()
                                                .padding(.leading, 48)
                                        }
                                    }
                                }
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }

                        if showSuccess {
                            Text("Annonse opprettet!")
                                .foregroundColor(.green)
                                .font(.caption)
                        }

                        Button {
                            Task {
                                await createListing()
                            }
                        } label: {
                            if isSubmitting {
                                BoenklereActionButtonLabel(title: "Opprett", systemImage: "plus")
                                    .overlay(ProgressView())
                            } else {
                                BoenklereActionButtonLabel(title: "Opprett", systemImage: "plus")
                            }
                        }
                        .disabled(isSubmitting || newTitle.isEmpty || newDescription.isEmpty)
                    }
                    .padding(.horizontal, 20)
                }
                .onAppear {
                    if !useSavedAddress,
                       let savedAddress = authManager.userAddress,
                       let savedLatitude = authManager.userLatitude,
                       let savedLongitude = authManager.userLongitude {
                        useSavedAddress = true
                        newAddressQuery = savedAddress
                        newSelectedAddress = savedAddress
                        newLatitude = savedLatitude
                        newLongitude = savedLongitude
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var listingsContent: some View {
        if listings.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "map")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)

                Text("Her var det tomt!")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text("Opprett det første oppdraget i dette område ved å trykke på + knappen, eller zoom ut for å sjekke nærområde")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            .padding(.horizontal, 20)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                ForEach(sortedListings, id: \.id) { listing in
                    ListingRow(listing: listing, userLocation: userLocation) {
                        selectedListing = listing
                    }

                    if listing.id != sortedListings.last?.id {
                        Divider()
                            .padding(.leading, 76)
                    }
                }
                }
                .padding(.top, 8)
            }
        }
    }

    private func handleAuthorization(_ authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            let userIdentifier = appleIDCredential.user
            UserDefaults.standard.set(userIdentifier, forKey: "userIdentifier")
            authManager.userIdentifier = userIdentifier

            if let fullName = appleIDCredential.fullName {
                let name = [fullName.givenName, fullName.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                if !name.isEmpty {
                    authManager.userName = name
                    UserDefaults.standard.set(name, forKey: "userName")
                }
            }

            if let email = appleIDCredential.email {
                authManager.userEmail = email
                UserDefaults.standard.set(email, forKey: "userEmail")
            }

            authManager.isAuthenticated = true

            Task {
                do {
                    let user = try await APIService.shared.upsertUser(
                        userId: userIdentifier,
                        name: authManager.userName
                    )
                    if let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !name.isEmpty {
                        authManager.userName = name
                        UserDefaults.standard.set(name, forKey: "userName")
                    }
                    authManager.userAddress = user.address
                    authManager.userLatitude = user.latitude
                    authManager.userLongitude = user.longitude
                    if let enabled = user.messageNotificationsEnabled {
                        authManager.messageNotificationsEnabled = enabled
                    }
                    if let enabled = user.listingNotificationsEnabled {
                        authManager.listingNotificationsEnabled = enabled
                    }
                    if let radius = user.listingNotificationRadiusKm {
                        authManager.listingNotificationRadiusKm = radius
                    }
                    if let address = user.address {
                        UserDefaults.standard.set(address, forKey: "userAddress")
                    }
                    if let latitude = user.latitude {
                        UserDefaults.standard.set(latitude, forKey: "userLatitude")
                    }
                    if let longitude = user.longitude {
                        UserDefaults.standard.set(longitude, forKey: "userLongitude")
                    }
                    if let enabled = user.messageNotificationsEnabled {
                        UserDefaults.standard.set(enabled, forKey: "messageNotificationsEnabled")
                    }
                    if let enabled = user.listingNotificationsEnabled {
                        UserDefaults.standard.set(enabled, forKey: "listingNotificationsEnabled")
                    }
                    if let radius = user.listingNotificationRadiusKm {
                        UserDefaults.standard.set(radius, forKey: "listingNotificationRadiusKm")
                    }
                    await authManager.syncDeviceTokenIfNeeded()
                } catch {
                    print("Failed to upsert user: \(error)")
                }
            }
        }
    }

    private var sortedListings: [APIListing] {
        guard let userLocation else { return listings }

        return listings.sorted { left, right in
            let leftDistance = distance(for: left, userLocation: userLocation) ?? .greatestFiniteMagnitude
            let rightDistance = distance(for: right, userLocation: userLocation) ?? .greatestFiniteMagnitude
            if leftDistance == rightDistance {
                return (left.id ?? 0) < (right.id ?? 0)
            }
            return leftDistance < rightDistance
        }
    }

    private func distance(for listing: APIListing, userLocation: CLLocation) -> CLLocationDistance? {
        guard let lat = listing.latitude, let lon = listing.longitude else { return nil }
        let listingLocation = CLLocation(latitude: lat, longitude: lon)
        return listingLocation.distance(from: userLocation)
    }

    private func getCoordinates(for result: MKLocalSearchCompletion) async {
        let searchRequest = MKLocalSearch.Request(completion: result)
        let search = MKLocalSearch(request: searchRequest)

        do {
            let response = try await search.start()
            if let item = response.mapItems.first {
                newLatitude = item.placemark.coordinate.latitude
                newLongitude = item.placemark.coordinate.longitude
            }
        } catch {
            print("Failed to get coordinates: \(error)")
        }
    }

    private func createListing() async {
        guard let userId = authManager.userIdentifier else { return }

        isSubmitting = true
        errorMessage = nil

        do {
            let addressToUse: String
            let latitudeToUse: Double?
            let longitudeToUse: Double?

            if useSavedAddress,
               let savedAddress = authManager.userAddress {
                addressToUse = savedAddress
                latitudeToUse = authManager.userLatitude
                longitudeToUse = authManager.userLongitude
            } else {
                addressToUse = newSelectedAddress.isEmpty ? newAddressQuery : newSelectedAddress
                latitudeToUse = newLatitude
                longitudeToUse = newLongitude
            }

            let trimmedPrice = newPrice.trimmingCharacters(in: .whitespacesAndNewlines)
            let priceToSend = trimmedPrice.isEmpty ? 0 : Double(trimmedPrice) ?? 0

            // Create listing with image in one request
            _ = try await APIService.shared.createListing(
                title: newTitle,
                description: newDescription,
                address: addressToUse,
                latitude: latitudeToUse,
                longitude: longitudeToUse,
                price: priceToSend,
                userId: userId,
                userName: authManager.userName,
                imageData: selectedImageData
            )
            showSuccess = true

            // Refresh listings
            await onListingCreated()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                isCreatingListing = false
                withAnimation {
                    sheetDetent = .height(70)
                }
                clearForm()
                showSuccess = false
            }
        } catch {
            errorMessage = "Kunne ikke opprette annonse. Prøv igjen."
        }

        isSubmitting = false
    }

    private func clearForm() {
        newTitle = ""
        newDescription = ""
        newAddressQuery = ""
        newSelectedAddress = ""
        newLatitude = nil
        newLongitude = nil
        newPrice = ""
        errorMessage = nil
        showingAddressSuggestions = false
        selectedPhotoItem = nil
        selectedImage = nil
        selectedImageData = nil
    }
}

struct ProfileSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @State private var nameDraft = ""
    @State private var isEditingName = false
    @State private var isSavingName = false
    @State private var nameError: String?
    @State private var showLogoutConfirm = false
    @StateObject private var addressSearch = AddressSearchCompleter()
    @State private var addressDraft = ""
    @State private var addressError: String?
    @State private var addressLatitude: Double?
    @State private var addressLongitude: Double?
    @State private var showAddressSuggestions = false
    @State private var addressIsConfirmed = false
    @State private var isSelectingAddressSuggestion = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sheetHeader

                ScrollView {
                    VStack(spacing: 16) {
                        if authManager.isAuthenticated {
                            profileCard
                            menuCard
                        } else {
                            signInCard
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: .infinity)

            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .confirmationDialog("Logg ut?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Logg ut", role: .destructive) {
                authManager.signOut()
                dismiss()
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Du kan logge inn igjen når som helst.")
        }
        .onAppear {
            if nameDraft.isEmpty {
                nameDraft = authManager.userName ?? ""
            }
            if addressDraft.isEmpty {
                addressDraft = authManager.userAddress ?? ""
                addressLatitude = authManager.userLatitude
                addressLongitude = authManager.userLongitude
                addressIsConfirmed = authManager.userLatitude != nil &&
                    authManager.userLongitude != nil &&
                    !addressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        .onDisappear {
            addressSearch.search(query: "")
        }
        .onChange(of: nameDraft) { _, newValue in
            guard isEditingName else { return }
            nameError = nil
        }
        .onChange(of: addressDraft) { _, newValue in
            guard isEditingName else { return }
            if isSelectingAddressSuggestion { return }
            showAddressSuggestions = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            addressSearch.search(query: newValue)
            addressIsConfirmed = false
            addressLatitude = nil
            addressLongitude = nil
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
                Text("Profil")
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
    }

    private var profileCard: some View {
        VStack(spacing: 16) {
            nameEditorRow

            if isSavingName {
                ProgressView()
                    .scaleEffect(0.9)
            }

            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            addressEditorSection

            if let addressError {
                Text(addressError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var nameEditorRow: some View {
        HStack(spacing: 8) {
            if isEditingName {
                TextField("Navn", text: $nameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: .infinity)
            } else {
                Text(displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(displayName == "Legg til navn" ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if isEditingName {
                    Task { await saveProfile() }
                } else {
                    startEditingProfile()
                }
            } label: {
                if isEditingName {
                    BoenklereActionButtonLabel(
                        title: "Lagre",
                        systemImage: "checkmark",
                        height: 36,
                        horizontalPadding: 12,
                        isFullWidth: false
                    )
                } else {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.gray, in: Circle())
                }
            }
        }
    }

    private var addressEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Adresse")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()
            }

            if isEditingName {
                TextField("Adresse", text: $addressDraft)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if showAddressSuggestions && !addressSearch.results.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(addressSearch.results.prefix(5), id: \.self) { result in
                            Button {
                                selectAddressSuggestion(result)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.body)
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                            }
                            .buttonStyle(.plain)

                            if result != addressSearch.results.prefix(5).last {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.blue)
                    Text(displayAddress)
                        .font(.subheadline)
                        .foregroundColor(displayAddress == "Legg til adresse" ? .secondary : .primary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var menuCard: some View {
        VStack(spacing: 0) {
            menuLink(title: "Meldinger", systemImage: "bubble.left.and.bubble.right") {
                ConversationsSheet(showsBackButton: true, showsCloseButton: false)
            }
            Divider()
                .padding(.leading, 52)
            menuLink(title: "Mine annonser", systemImage: "tray.full", showsChevron: true) {
                MyListingsSheet(showsBackButton: true , showsCloseButton: false)
            }
            Divider()
                .padding(.leading, 52)
            menuLink(title: "Vurderinger", systemImage: "star.bubble") {
                RatingsSheet()
            }
            Divider()
                .padding(.leading, 52)
            menuLink(title: "Varslinger", systemImage: "bell.badge") {
                NotificationsSheet()
            }
            Divider()
                .padding(.leading, 52)
            menuRow(
                title: "Logg ut",
                systemImage: "rectangle.portrait.and.arrow.right",
                tint: .red,
                showsChevron: false
            ) {
                showLogoutConfirm = true
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var signInCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.circle")
                .font(.system(size: 80))
                .foregroundColor(.secondary)

            Text("Logg inn for å opprette annonser")
                .foregroundColor(.secondary)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    handleAuthorization(authorization)
                case .failure(let error):
                    print("Sign in failed: \(error)")
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func menuRow(
        title: String,
        systemImage: String,
        tint: Color = .blue,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            menuRowContent(title: title, systemImage: systemImage, tint: tint, showsChevron: showsChevron)
        }
        .buttonStyle(.plain)
    }

    private func menuLink<Destination: View>(
        title: String,
        systemImage: String,
        tint: Color = .blue,
        showsChevron: Bool = true,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
                .environmentObject(authManager)
        } label: {
            menuRowContent(title: title, systemImage: systemImage, tint: tint, showsChevron: showsChevron)
        }
        .buttonStyle(.plain)
    }

    private func menuRowContent(
        title: String,
        systemImage: String,
        tint: Color = .blue,
        showsChevron: Bool = true
    ) -> some View {
        HStack {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 28, height: 28, alignment: .center)
                .clipped()

            Text(title)
                .font(.body)
                .foregroundColor(tint == .red ? .red : .primary)

            Spacer()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
        .contentShape(Rectangle())
    }

    private var displayName: String {
        let name = authManager.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Legg til navn" : name
    }

    private var displayAddress: String {
        let address = authManager.userAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? "Legg til adresse" : address
    }

    private func startEditingProfile() {
        nameDraft = authManager.userName ?? ""
        addressDraft = authManager.userAddress ?? ""
        addressLatitude = authManager.userLatitude
        addressLongitude = authManager.userLongitude
        addressIsConfirmed = authManager.userAddress != nil &&
            authManager.userLatitude != nil &&
            authManager.userLongitude != nil
        showAddressSuggestions = false
        nameError = nil
        addressError = nil
        isEditingName = true
    }

    private func selectAddressSuggestion(_ result: MKLocalSearchCompletion) {
        let fullAddress = [result.title, result.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        isSelectingAddressSuggestion = true
        addressDraft = fullAddress
        showAddressSuggestions = false
        addressSearch.search(query: "")
        Task {
            let coordinate = await getCoordinates(for: result)
            await MainActor.run {
                addressLatitude = coordinate?.latitude
                addressLongitude = coordinate?.longitude
                addressIsConfirmed = coordinate != nil
                isSelectingAddressSuggestion = false
            }
        }
    }

    @MainActor
    private func saveProfile() async {
        guard let userId = authManager.userIdentifier else { return }

        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            nameError = "Navn kan ikke være tomt"
            return
        }

        let trimmedAddress = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddress.isEmpty || !addressIsConfirmed {
            addressError = "Velg adresse fra forslag"
            return
        }

        guard let latitude = addressLatitude, let longitude = addressLongitude else {
            addressError = "Velg adresse fra forslag"
            return
        }

        isSavingName = true
        nameError = nil
        addressError = nil

        do {
            let shouldEnableListingNotifications = NotificationPreferenceStore.isPendingListingEnable()
            let user = try await APIService.shared.upsertUser(
                userId: userId,
                name: trimmedName,
                address: trimmedAddress,
                latitude: latitude,
                longitude: longitude,
                listingNotificationsEnabled: shouldEnableListingNotifications ? true : nil,
                listingNotificationRadiusKm: shouldEnableListingNotifications ? authManager.listingNotificationRadiusKm : nil
            )
            authManager.userName = user.name
            authManager.userAddress = user.address
            authManager.userLatitude = user.latitude
            authManager.userLongitude = user.longitude
            if let enabled = user.messageNotificationsEnabled {
                authManager.messageNotificationsEnabled = enabled
            }
            if let enabled = user.listingNotificationsEnabled {
                authManager.listingNotificationsEnabled = enabled
            }
            if let radius = user.listingNotificationRadiusKm {
                authManager.listingNotificationRadiusKm = radius
            }

            if let name = user.name {
                UserDefaults.standard.set(name, forKey: "userName")
            }
            if let address = user.address {
                UserDefaults.standard.set(address, forKey: "userAddress")
            }
            if let latitude = user.latitude {
                UserDefaults.standard.set(latitude, forKey: "userLatitude")
            }
            if let longitude = user.longitude {
                UserDefaults.standard.set(longitude, forKey: "userLongitude")
            }
            if let enabled = user.messageNotificationsEnabled {
                UserDefaults.standard.set(enabled, forKey: "messageNotificationsEnabled")
            }
            if let enabled = user.listingNotificationsEnabled {
                UserDefaults.standard.set(enabled, forKey: "listingNotificationsEnabled")
            }
            if let radius = user.listingNotificationRadiusKm {
                UserDefaults.standard.set(radius, forKey: "listingNotificationRadiusKm")
            }
            if shouldEnableListingNotifications {
                NotificationPreferenceStore.clearPendingListingEnable()
            }

            isEditingName = false
        } catch {
            nameError = "Kunne ikke lagre endringer"
        }

        isSavingName = false
    }

    private func getCoordinates(for result: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let searchRequest = MKLocalSearch.Request(completion: result)
        let search = MKLocalSearch(request: searchRequest)

        do {
            let response = try await search.start()
            return response.mapItems.first?.placemark.coordinate
        } catch {
            print("Failed to get coordinates: \(error)")
            return nil
        }
    }

    private func handleAuthorization(_ authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            let userIdentifier = appleIDCredential.user
            UserDefaults.standard.set(userIdentifier, forKey: "userIdentifier")
            authManager.userIdentifier = userIdentifier

            if let fullName = appleIDCredential.fullName {
                let name = [fullName.givenName, fullName.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                if !name.isEmpty {
                    authManager.userName = name
                    UserDefaults.standard.set(name, forKey: "userName")
                }
            }

            if let email = appleIDCredential.email {
                authManager.userEmail = email
                UserDefaults.standard.set(email, forKey: "userEmail")
            }

            authManager.isAuthenticated = true
            dismiss()

            Task {
                do {
                    let user = try await APIService.shared.upsertUser(
                        userId: userIdentifier,
                        name: authManager.userName
                    )
                    authManager.userAddress = user.address
                    authManager.userLatitude = user.latitude
                    authManager.userLongitude = user.longitude
                    if let enabled = user.messageNotificationsEnabled {
                        authManager.messageNotificationsEnabled = enabled
                    }
                    if let enabled = user.listingNotificationsEnabled {
                        authManager.listingNotificationsEnabled = enabled
                    }
                    if let radius = user.listingNotificationRadiusKm {
                        authManager.listingNotificationRadiusKm = radius
                    }
                    if let address = user.address {
                        UserDefaults.standard.set(address, forKey: "userAddress")
                    }
                    if let latitude = user.latitude {
                        UserDefaults.standard.set(latitude, forKey: "userLatitude")
                    }
                    if let longitude = user.longitude {
                        UserDefaults.standard.set(longitude, forKey: "userLongitude")
                    }
                    if let enabled = user.messageNotificationsEnabled {
                        UserDefaults.standard.set(enabled, forKey: "messageNotificationsEnabled")
                    }
                    if let enabled = user.listingNotificationsEnabled {
                        UserDefaults.standard.set(enabled, forKey: "listingNotificationsEnabled")
                    }
                    if let radius = user.listingNotificationRadiusKm {
                        UserDefaults.standard.set(radius, forKey: "listingNotificationRadiusKm")
                    }
                    await authManager.syncDeviceTokenIfNeeded()
                } catch {
                    print("Failed to upsert user: \(error)")
                }
            }
        }
    }
}

struct MyListingsSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @State private var listings: [APIListing] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedListing: APIListing?
    @State private var editSheetDetent: PresentationDetent = .large
    let showsBackButton: Bool
    let showsCloseButton: Bool

    init(showsBackButton: Bool = false, showsCloseButton: Bool = true) {
        self.showsBackButton = showsBackButton
        self.showsCloseButton = showsCloseButton
    }
    @State private var deletingListingIds: Set<Int64> = []
    @State private var pendingDeleteId: Int64?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(spacing: 12) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 20)
                    }

                    if isLoading && listings.isEmpty {
                        ProgressView()
                            .padding(.top, 12)
                    } else if listings.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("Ingen annonser enda")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 20)
                        .padding(.horizontal, 20)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(listings, id: \.id) { listing in
                                ListingRow(listing: listing, userLocation: nil) {
                                    selectedListing = listing
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if let listingId = listing.id {
                                        Button(role: .destructive) {
                                            pendingDeleteId = listingId
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("Slett", systemImage: "trash")
                                        }
                                    }
                                }
                                .opacity(deletingListingIds.contains(listing.id ?? -1) ? 0.6 : 1)

                                if listing.id != listings.last?.id {
                                    Divider()
                                        .padding(.leading, 76)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.bottom, 20)
            }
            .refreshable {
                await loadListings()
            }
        }
        .sheet(item: $selectedListing) { listing in
            EditListingSheet(
                listing: listing,
                onUpdated: { updated in
                    if let index = listings.firstIndex(where: { $0.id == updated.id }) {
                        listings[index] = updated
                    }
                },
                onDeleted: { deletedId in
                    listings.removeAll { $0.id == deletedId }
                }
            )
            .environmentObject(authManager)
            .presentationDetents([.large], selection: $editSheetDetent)
            .presentationDragIndicator(.hidden)
        }
        .confirmationDialog("Slett annonse?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Slett annonse", role: .destructive) {
                if let listingId = pendingDeleteId {
                    Task { await deleteListing(id: listingId) }
                }
                pendingDeleteId = nil
            }
            Button("Avbryt", role: .cancel) {
                pendingDeleteId = nil
            }
        } message: {
            Text("Dette kan ikke angres.")
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadListings()
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

                Text("Mine annonser")
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

    @MainActor
    private func loadListings() async {
        guard let userId = authManager.userIdentifier else { return }

        isLoading = true
        errorMessage = nil
        do {
            listings = try await APIService.shared.getListings(userId: userId)
        } catch is CancellationError {
            return
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            errorMessage = "Kunne ikke hente annonser"
        }
        isLoading = false
    }

    @MainActor
    private func deleteListing(id: Int64) async {
        guard !deletingListingIds.contains(id) else { return }
        deletingListingIds.insert(id)
        errorMessage = nil
        do {
            try await APIService.shared.deleteListing(id: id)
            listings.removeAll { $0.id == id }
        } catch {
            errorMessage = "Kunne ikke slette annonsen"
        }
        deletingListingIds.remove(id)
    }
}

private struct ProfileSubpageHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 5)
                .padding(.bottom, 3)

            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }

                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Color.clear
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

private struct RatingsSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: RatingsTab = .received
    @State private var givenReviews: [ReviewItem] = []
    @State private var receivedReviews: [ReviewItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ProfileSubpageHeader(title: "Vurderinger") {
                dismiss()
            }

            if !authManager.isAuthenticated {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Logg inn for å se vurderinger")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Picker("Vurderinger", selection: $selectedTab) {
                        Text("Vurderinger gitt").tag(RatingsTab.given)
                        Text("Vurderinger fått").tag(RatingsTab.received)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                    if isLoading {
                        ProgressView()
                            .padding(.top, 16)
                    } else {
                        ScrollView {
                            VStack(spacing: 12) {
                                if let errorMessage {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }

                                let items = selectedTab == .given ? givenReviews : receivedReviews

                                if items.isEmpty {
                                    Text("Ingen vurderinger enda")
                                        .foregroundColor(.secondary)
                                        .padding(.top, 16)
                                } else {
                                    ForEach(items) { item in
                                        ReviewRow(item: item)
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
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadReviews()
        }
    }

    @MainActor
    private func loadReviews() async {
        guard let userId = authManager.userIdentifier else { return }

        isLoading = true
        errorMessage = nil

        do {
            async let given = APIService.shared.getReviewsByReviewer(userId: userId)
            async let received = APIService.shared.getReviewsByReviewee(userId: userId)

            let (givenReviewsRaw, receivedReviewsRaw) = try await (given, received)

            let givenItems = await buildReviewItems(reviews: givenReviewsRaw, isGiven: true)
            let receivedItems = await buildReviewItems(reviews: receivedReviewsRaw, isGiven: false)

            self.givenReviews = givenItems
            self.receivedReviews = receivedItems
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Kunne ikke hente vurderinger"
        }

        isLoading = false
    }

    private func buildReviewItems(reviews: [APIReview], isGiven: Bool) async -> [ReviewItem] {
        guard !reviews.isEmpty else { return [] }

        let listingIds = Set(reviews.map { $0.listingId })
        let userIds = Set(reviews.map { isGiven ? $0.revieweeId : $0.reviewerId })

        var listingMap: [Int64: APIListing] = [:]
        var userNameMap: [String: String] = [:]

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
            for userId in userIds {
                group.addTask {
                    let user = try? await APIService.shared.getUser(userId: userId)
                    let name = user?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (userId, name?.isEmpty == false ? name : nil)
                }
            }

            for await (userId, name) in group {
                if let name {
                    userNameMap[userId] = name
                }
            }
        }

        let sortedReviews = reviews.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }

        return sortedReviews.map { review in
            let listingTitle = listingMap[review.listingId]?.title ?? "Oppdrag"
            let listingDescription = listingMap[review.listingId]?.description
            let otherId = isGiven ? review.revieweeId : review.reviewerId
            let fallback = "Bruker \(otherId.suffix(4))"
            let otherName = userNameMap[otherId] ?? fallback
            return ReviewItem(
                id: "\(review.id ?? 0)-\(review.reviewerId)-\(review.revieweeId)",
                listingTitle: listingTitle,
                listingDescription: listingDescription,
                otherName: otherName,
                rating: review.rating,
                comment: review.comment,
                createdAt: review.createdAt,
                isGiven: isGiven
            )
        }
    }
}

private enum RatingsTab {
    case given
    case received
}

private struct ReviewItem: Identifiable {
    let id: String
    let listingTitle: String
    let listingDescription: String?
    let otherName: String
    let rating: Int
    let comment: String?
    let createdAt: String?
    let isGiven: Bool
}

private struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.listingTitle)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                StarRatingView(rating: item.rating)
            }

            Text(item.isGiven ? "Til \(item.otherName)" : "Fra \(item.otherName)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let description = item.listingDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

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

private struct StarRatingView: View {
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

private struct NotificationsSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @State private var messageNotificationsEnabled = true
    @State private var listingNotificationsEnabled = false
    @State private var listingNotificationRadiusKm = 10.0
    @State private var didLoad = false
    @State private var suppressSave = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var showAddressRequiredAlert = false
    @State private var isAdjustingRadius = false

    var body: some View {
        VStack(spacing: 0) {
            ProfileSubpageHeader(title: "Varslinger") {
                dismiss()
            }

            if !authManager.isAuthenticated {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Logg inn for å administrere varsler")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        notificationCard(
                            title: "Meldinger",
                            subtitle: "Få varsel når du får en ny melding.",
                            isOn: $messageNotificationsEnabled
                        )

                        listingNotificationCard

                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.9)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            messageNotificationsEnabled = authManager.messageNotificationsEnabled
            listingNotificationsEnabled = authManager.listingNotificationsEnabled
            listingNotificationRadiusKm = authManager.listingNotificationRadiusKm
            DispatchQueue.main.async {
                didLoad = true
            }
        }
        .onChange(of: messageNotificationsEnabled) { _, _ in
            scheduleSave()
        }
        .onChange(of: listingNotificationsEnabled) { _, newValue in
            if newValue, !hasAddress {
                NotificationPreferenceStore.markPendingListingEnable()
                suppressSave = true
                listingNotificationsEnabled = false
                showAddressRequiredAlert = true
                DispatchQueue.main.async {
                    suppressSave = false
                }
                return
            }
            scheduleSave()
        }
        .confirmationDialog("Legg til adresse", isPresented: $showAddressRequiredAlert, titleVisibility: .visible) {
            Button("Gå til profil") {
                dismiss()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Du må legge til adresse i profilen før du kan skru på oppdragsvarsler.")
        }
    }

    private var hasAddress: Bool {
        authManager.userLatitude != nil && authManager.userLongitude != nil
    }

    private var listingNotificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Varsel på oppdrag som legges ut")
                        .font(.headline)
                    Text("Få varsel når nye oppdrag legges ut innen ønsket rekkevidde.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: $listingNotificationsEnabled)
                    .labelsHidden()
                    .tint(.blue)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Rekkevidde")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(listingNotificationRadiusKm)) km")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }

                Slider(value: $listingNotificationRadiusKm, in: 0...50, step: 1) { editing in
                    isAdjustingRadius = editing
                    if !editing {
                        scheduleSave()
                    }
                }
                    .tint(.blue)
                    .disabled(!listingNotificationsEnabled)
                    .opacity(listingNotificationsEnabled ? 1 : 0.4)

                if !hasAddress {
                    Text("Legg til adresse i profilen for å bruke rekkeviddevarsel.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func notificationCard(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(.blue)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func scheduleSave() {
        guard didLoad, !suppressSave else { return }
        saveTask?.cancel()
        saveTask = Task { [messageNotificationsEnabled, listingNotificationsEnabled, listingNotificationRadiusKm] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await saveSettings(
                messageEnabled: messageNotificationsEnabled,
                listingEnabled: listingNotificationsEnabled,
                radiusKm: listingNotificationRadiusKm
            )
        }
    }

    @MainActor
    private func saveSettings(messageEnabled: Bool, listingEnabled: Bool, radiusKm: Double) async {
        guard let userId = authManager.userIdentifier else {
            errorMessage = "Du må være logget inn"
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            let user = try await APIService.shared.upsertUser(
                userId: userId,
                name: nil,
                messageNotificationsEnabled: messageEnabled,
                listingNotificationsEnabled: listingEnabled,
                listingNotificationRadiusKm: radiusKm
            )
            suppressSave = true
            if let enabled = user.messageNotificationsEnabled {
                authManager.messageNotificationsEnabled = enabled
                UserDefaults.standard.set(enabled, forKey: "messageNotificationsEnabled")
                messageNotificationsEnabled = enabled
            }
            if let enabled = user.listingNotificationsEnabled {
                authManager.listingNotificationsEnabled = enabled
                UserDefaults.standard.set(enabled, forKey: "listingNotificationsEnabled")
                listingNotificationsEnabled = enabled
            }
            if let radius = user.listingNotificationRadiusKm {
                authManager.listingNotificationRadiusKm = radius
                UserDefaults.standard.set(radius, forKey: "listingNotificationRadiusKm")
                listingNotificationRadiusKm = radius
            }
            DispatchQueue.main.async {
                suppressSave = false
            }
        } catch {
            errorMessage = "Kunne ikke lagre varsler"
            suppressSave = true
            messageNotificationsEnabled = authManager.messageNotificationsEnabled
            listingNotificationsEnabled = authManager.listingNotificationsEnabled
            listingNotificationRadiusKm = authManager.listingNotificationRadiusKm
            DispatchQueue.main.async {
                suppressSave = false
            }
        }

        isSaving = false
    }
}

private enum NotificationPreferenceStore {
    private static let pendingListingEnableKey = "pendingListingNotificationsEnable"

    static func markPendingListingEnable() {
        UserDefaults.standard.set(true, forKey: pendingListingEnableKey)
    }

    static func isPendingListingEnable() -> Bool {
        UserDefaults.standard.bool(forKey: pendingListingEnableKey)
    }

    static func clearPendingListingEnable() {
        UserDefaults.standard.removeObject(forKey: pendingListingEnableKey)
    }
}

struct EditListingSheet: View {
    let listing: APIListing
    let onUpdated: (APIListing) -> Void
    let onDeleted: (Int64) -> Void
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @FocusState private var focusedField: EditListingField?
    @StateObject private var addressSearch = AddressSearchCompleter()
    @State private var titleDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var priceDraft: String = ""
    @State private var addressQuery: String = ""
    @State private var selectedAddress: String = ""
    @State private var draftLatitude: Double?
    @State private var draftLongitude: Double?
    @State private var isEditingTitle = false
    @State private var isEditingDescription = false
    @State private var isEditingPrice = false
    @State private var isEditingAddress = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImage: Image?
    @State private var selectedImageData: Data?
    @State private var existingImage: UIImage?
    @State private var showDeleteConfirm = false
    @State private var showCompleteSheet = false
    @State private var isCompleted = false
    @State private var justSaved = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(spacing: 16) {
                    imageSection
                    titleSection
                    descriptionSection
                    priceSection
                    addressSection

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await saveChanges() }
                } label: {
                    if isSaving {
                        BoenklereActionButtonLabel(title: "Lagre endringer", systemImage: "checkmark")
                            .overlay(ProgressView())
                    } else {
                        BoenklereActionButtonLabel(title: "Lagre endringer", systemImage: "checkmark")
                    }
                }
                .disabled(!canSave)

                if !isEditingTitle && !isEditingDescription && !isEditingPrice && !isEditingAddress {
                    actionSection
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isEditingTitle)
            .animation(.easeInOut(duration: 0.2), value: isEditingDescription)
            .animation(.easeInOut(duration: 0.2), value: isEditingPrice)
            .animation(.easeInOut(duration: 0.2), value: isEditingAddress)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .confirmationDialog("Slett annonse?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Slett annonse", role: .destructive) {
                Task { await deleteListing() }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Dette kan ikke angres.")
        }
        .sheet(isPresented: $showCompleteSheet) {
            CompleteListingSheet(
                listing: listing,
                onReviewSaved: { updatedListing in
                    if let updatedListing {
                        onUpdated(updatedListing)
                    }
                    isCompleted = true
                }
            )
            .environmentObject(authManager)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .onAppear {
            titleDraft = listing.title
            descriptionDraft = listing.description
            if listing.price <= 0 {
                priceDraft = ""
            } else {
                priceDraft = listing.price.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(listing.price))
                    : String(listing.price)
            }
            addressQuery = listing.address
            selectedAddress = listing.address
            draftLatitude = listing.latitude
            draftLongitude = listing.longitude
            isCompleted = listing.isCompleted ?? false
            loadExistingImage()
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else {
                selectedImage = nil
                selectedImageData = nil
                return
            }

            newItem.loadTransferable(type: Data.self) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let data):
                        guard let data, let uiImage = UIImage(data: data) else { return }
                        let resizedImage = resizeImage(uiImage)
                        selectedImageData = resizedImage.jpegData(compressionQuality: 0.6)
                        selectedImage = Image(uiImage: resizedImage)
                    case .failure(let error):
                        print("Error loading image: \(error)")
                    }
                }
            }
        }
        .onChange(of: addressQuery) { _, newValue in
            guard isEditingAddress else { return }
            addressSearch.search(query: newValue)
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
                Text("Rediger annonse")
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
    }

    private var imageSection: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            ZStack(alignment: .topTrailing) {
                if let selectedImage {
                    selectedImage
                        .resizable()
                        .scaledToFill()
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .cornerRadius(12)
                } else if let existingImage {
                    Image(uiImage: existingImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .cornerRadius(12)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.1))
                        .frame(height: 200)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 34))
                                .foregroundColor(.blue)
                        )
                }

                Image(systemName: "pencil.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .shadow(radius: 2)
                    .padding(10)
            }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldHeader(title: "Tittel", isEditing: isEditingTitle) {
                isEditingTitle.toggle()
            }

            if isEditingTitle {
                TextField("", text: $titleDraft)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($focusedField, equals: .title)
            } else {
                Text(titleDraft)
                    .font(.headline)
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldHeader(title: "Beskrivelse", isEditing: isEditingDescription) {
                isEditingDescription.toggle()
            }

            if isEditingDescription {
                TextField("", text: $descriptionDraft, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($focusedField, equals: .description)
            } else {
                Text(descriptionDraft)
                    .font(.body)
            }
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldHeader(title: "Pris", isEditing: isEditingPrice) {
                isEditingPrice.toggle()
            }

            if isEditingPrice {
                TextField("kr", text: $priceDraft)
                    .keyboardType(.decimalPad)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($focusedField, equals: .price)
            } else {
                if priceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Ikke oppgitt")
                        .font(.body)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(priceDraft) kr")
                        .font(.body)
                }
            }
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldHeader(title: "Adresse", isEditing: isEditingAddress) {
                isEditingAddress.toggle()
            }

            if isEditingAddress {
                TextField("Adresse", text: $addressQuery)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($focusedField, equals: .address)

                if !addressSearch.results.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(addressSearch.results.prefix(5), id: \.self) { result in
                            Button {
                                let fullAddress = [result.title, result.subtitle]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: ", ")
                                selectedAddress = fullAddress
                                addressQuery = fullAddress
                                Task { await getCoordinates(for: result) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.body)
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                            }
                            .buttonStyle(.plain)

                            if result != addressSearch.results.prefix(5).last {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } else {
                Text(addressQuery)
                    .font(.body)
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            Button {
                showCompleteSheet = true
            } label: {
                BoenklereActionButtonLabel(
                    title: "Merk som utført",
                    systemImage: "checkmark.seal.fill",
                    textColor: isCompleted ? .secondary : Color(red: 0.07, green: 0.34, blue: 0.68),
                    fillColor: Color(red: 0.88, green: 0.95, blue: 1.0).opacity(isCompleted ? 0.6 : 1.0)
                )
            }
            .disabled(isCompleted)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                BoenklereActionButtonLabel(
                    title: "Slett annonse",
                    systemImage: "trash",
                    textColor: .red,
                    fillColor: Color.red.opacity(0.12)
                )
            }
        }
    }

    private func fieldHeader(title: String, isEditing: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: action) {
                Image(systemName: isEditing ? "xmark" : "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.gray, in: Circle())
            }
        }
    }

    private var canSave: Bool {
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = addressQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrice = priceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let priceIsValid = trimmedPrice.isEmpty || Double(trimmedPrice) != nil
        return !trimmedTitle.isEmpty &&
            !trimmedDescription.isEmpty &&
            !trimmedAddress.isEmpty &&
            priceIsValid &&
            !isSaving
    }

    @MainActor
    private func saveChanges() async {
        guard let userId = authManager.userIdentifier else { return }
        guard let listingId = listing.id else { return }

        isSaving = true
        errorMessage = nil

        let addressToSave = selectedAddress.isEmpty ? addressQuery : selectedAddress
        let trimmedPrice = priceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let priceToSave: Double
        if trimmedPrice.isEmpty {
            priceToSave = 0
        } else if let parsedPrice = Double(trimmedPrice) {
            priceToSave = parsedPrice
        } else {
            errorMessage = "Ugyldig pris"
            isSaving = false
            return
        }

        do {
            let updated = try await APIService.shared.updateListing(
                listingId: listingId,
                title: titleDraft,
                description: descriptionDraft,
                address: addressToSave,
                latitude: draftLatitude,
                longitude: draftLongitude,
                price: priceToSave,
                userId: userId,
                imageData: selectedImageData
            )
            onUpdated(updated)
            justSaved = true
            focusedField = nil
            isEditingTitle = false
            isEditingDescription = false
            isEditingPrice = false
            isEditingAddress = false
        } catch {
            errorMessage = "Kunne ikke lagre endringer"
        }

        isSaving = false
    }

    @MainActor
    private func deleteListing() async {
        guard let listingId = listing.id else { return }

        isSaving = true
        errorMessage = nil

        do {
            try await APIService.shared.deleteListing(id: listingId)
            onDeleted(listingId)
            dismiss()
        } catch {
            errorMessage = "Kunne ikke slette annonse"
        }

        isSaving = false
    }

    private func getCoordinates(for result: MKLocalSearchCompletion) async {
        let searchRequest = MKLocalSearch.Request(completion: result)
        let search = MKLocalSearch(request: searchRequest)

        do {
            let response = try await search.start()
            if let item = response.mapItems.first {
                draftLatitude = item.placemark.coordinate.latitude
                draftLongitude = item.placemark.coordinate.longitude
            }
        } catch {
            print("Failed to get coordinates: \(error)")
        }
    }

    private func loadExistingImage() {
        guard let imageUrl = listing.imageUrl, let url = URL(string: imageUrl) else { return }

        if let cached = ImageCache.shared.image(for: imageUrl) {
            existingImage = cached
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        existingImage = uiImage
                    }
                    ImageCache.shared.insert(uiImage, for: imageUrl)
                }
            } catch {
                print("Failed to load listing image: \(error)")
            }
        }
    }

    private func resizeImage(_ image: UIImage) -> UIImage {
        let maxSize: CGFloat = 800
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

private enum EditListingField: Hashable {
    case title
    case description
    case price
    case address
}

private struct ReviewCandidate: Identifiable {
    let id: String
    let name: String
}

private struct CompleteListingSheet: View {
    let listing: APIListing
    let onReviewSaved: (APIListing?) -> Void
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @State private var candidates: [ReviewCandidate] = []
    @State private var selectedBuyerId: String?
    @State private var rating: Int = 0
    @State private var comment: String = ""
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(spacing: 16) {
                    if isLoading {
                        ProgressView()
                            .padding(.top, 12)
                    } else if candidates.isEmpty {
                        Text("Ingen meldinger på denne annonsen enda")
                            .foregroundColor(.secondary)
                            .padding(.top, 12)
                    } else {
                        candidateSection
                        ratingSection
                        commentSection

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        Button {
                            Task { await submitReview() }
                        } label: {
                            if isSubmitting {
                                BoenklereActionButtonLabel(title: "Lagre anmeldelse", systemImage: "checkmark")
                                    .overlay(ProgressView())
                            } else {
                                BoenklereActionButtonLabel(title: "Lagre anmeldelse", systemImage: "checkmark")
                            }
                        }
                        .disabled(!canSubmit)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .task {
            await loadCandidates()
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
                Text("Fullfør oppdrag")
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
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hvem utførte oppdraget?")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    Button {
                        selectedBuyerId = candidate.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedBuyerId == candidate.id ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedBuyerId == candidate.id ? .blue : .secondary)

                            Text(candidate.name)
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)

                    if candidate.id != candidates.last?.id {
                        Divider()
                            .padding(.leading, 36)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vurdering")
                .font(.subheadline)
                .foregroundColor(.secondary)

            StarRatingPicker(rating: $rating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kommentar")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextEditor(text: $comment)
                .frame(minHeight: 110)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var canSubmit: Bool {
        selectedBuyerId != nil && rating > 0 && !isSubmitting
    }

    @MainActor
    private func loadCandidates() async {
        guard let userId = authManager.userIdentifier else { return }
        guard let listingId = listing.id else { return }

        isLoading = true
        errorMessage = nil

        do {
            let conversations = try await APIService.shared.getConversations(userId: userId)
            let listingConversations = conversations.filter { $0.listingId == listingId }
            let conversationsWithMessages = listingConversations.filter {
                let trimmed = $0.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !trimmed.isEmpty
            }
            let buyerIds = Array(Set(conversationsWithMessages.map { $0.buyerId }))

            if buyerIds.isEmpty {
                candidates = []
                isLoading = false
                return
            }

            var fetchedCandidates: [ReviewCandidate] = []
            await withTaskGroup(of: ReviewCandidate?.self) { group in
                for buyerId in buyerIds {
                    group.addTask {
                        let user = try? await APIService.shared.getUser(userId: buyerId)
                        let name = user?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let displayName = (name?.isEmpty == false) ? name! : "Bruker \(buyerId.suffix(4))"
                        return ReviewCandidate(id: buyerId, name: displayName)
                    }
                }

                for await candidate in group {
                    if let candidate {
                        fetchedCandidates.append(candidate)
                    }
                }
            }

            candidates = fetchedCandidates.sorted { $0.name < $1.name }
        } catch {
            errorMessage = "Kunne ikke hente kontakter"
        }

        isLoading = false
    }

    @MainActor
    private func submitReview() async {
        guard let listingId = listing.id else { return }
        guard let reviewerId = authManager.userIdentifier else { return }
        guard let revieweeId = selectedBuyerId else { return }

        isSubmitting = true
        errorMessage = nil

        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            _ = try await APIService.shared.createReview(
                listingId: listingId,
                reviewerId: reviewerId,
                revieweeId: revieweeId,
                rating: rating,
                comment: trimmedComment.isEmpty ? nil : trimmedComment
            )

            let updatedListing = try? await APIService.shared.getListing(id: listingId)
            onReviewSaved(updatedListing)
            dismiss()
        } catch {
            errorMessage = "Kunne ikke lagre anmeldelsen"
        }

        isSubmitting = false
    }
}

private struct StarRatingPicker: View {
    @Binding var rating: Int
    private let maxRating = 5

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...maxRating, id: \.self) { star in
                Button {
                    rating = star
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(star <= rating ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Listing Detail Sheet
struct ListingDetailSheet: View {
    let listing: APIListing
    @Binding var sheetDetent: PresentationDetent
    let userLocation: CLLocation?
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss
    @State private var image: UIImage?
    @State private var driveTimeText: String?
    @State private var showNavigationOptions = false
    @State private var showChat = false
    @State private var showChatLoginAlert = false

    private var isCollapsed: Bool {
        sheetDetent == .height(70)
    }

    private var isOwner: Bool {
        guard let userId = authManager.userIdentifier else { return false }
        return listing.userId == userId
    }

    private var displayUserName: String {
        if let name = listing.userName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return listing.userId
    }

    private var distanceText: String? {
        guard let lat = listing.latitude,
              let lon = listing.longitude,
              let userLocation else {
            return nil
        }

        let listingLocation = CLLocation(latitude: lat, longitude: lon)
        let meters = listingLocation.distance(from: userLocation)

        if meters < 1000 {
            let rounded = Int(meters.rounded())
            return "\(rounded) m unna"
        }

        let km = meters / 1000
        if km < 10 {
            return String(format: "%.1f km unna", km)
        }

        let roundedKm = Int(km.rounded())
        return "\(roundedKm) km unna"
    }

    private let actionButtonHeight: CGFloat = 52
    private let actionButtonSpacing: CGFloat = 6

    private var actionButtonsHeight: CGFloat {
        actionButtonHeight * 2 + actionButtonSpacing
    }

    @ViewBuilder
    private var listingImageView: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if listing.imageUrl != nil {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .overlay(ProgressView())
        } else {
            Rectangle()
                .fill(Color.blue.opacity(0.1))
                .overlay(
                    Image(systemName: "house.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color(.systemGray3))
                        .frame(width: 36, height: 5)
                        .padding(.top, 5)
                        .padding(.bottom, 3)

                    HStack {
                        if isCollapsed {
                            Text(listing.title)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Spacer()

                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.gray, in: Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if !isCollapsed {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                        // Image + Actions
                        if !isOwner {
                            HStack(alignment: .top, spacing: 12) {
                                listingImageView
                                    .frame(width: actionButtonsHeight, height: actionButtonsHeight)
                                    .clipped()
                                    .cornerRadius(16)

                                VStack(spacing: actionButtonSpacing) {
                                    if let driveTimeText {
                                        Button {
                                            showNavigationOptions = true
                                        } label: {
                                            BoenklereActionButtonLabel(title: driveTimeText, systemImage: "car.fill", height: actionButtonHeight)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Color.clear
                                            .frame(height: actionButtonHeight)
                                    }

                                    Button {
                                        if authManager.isAuthenticated {
                                            showChat = true
                                        } else {
                                            showChatLoginAlert = true
                                        }
                                    } label: {
                                        BoenklereActionButtonLabel(title: "Send melding", systemImage: "bubble.left.and.bubble.right.fill", height: actionButtonHeight)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .frame(height: actionButtonsHeight)
                            }
                        } else {
                            listingImageView
                                .frame(height: 250)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .cornerRadius(16)
                        }

                    // Title and Price
                    HStack(alignment: .top) {
                        Text(listing.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            Spacer()
                            if listing.price > 0 {
                                Text("\(Int(listing.price)) kr")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                            } else {
                                Text("Ikke oppgitt")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)
                            }
                        }

                    // Description
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Beskrivelse")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(listing.description)
                            .font(.body)
                    }

                    if let distanceText {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Avstand")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            HStack {
                                Image(systemName: "location.fill")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                Text(distanceText)
                                    .font(.body)
                            }
                        }

                    }

                    // Address
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Adresse")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        HStack {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text(listing.address)
                                .font(.body)
                        }
                    }

                        // Posted by
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lagt ut av")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text(displayUserName)
                                .font(.body)
                                .lineLimit(1)
                        }
                    }

                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }

                Spacer(minLength: 0)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChat) {
                ChatSheet(listing: listing, isModalStyle: false)
                    .environmentObject(authManager)
            }
        }
        .task {
            await loadImage()
            await loadDriveTime()
        }
        .confirmationDialog("Åpne navigasjon", isPresented: $showNavigationOptions, titleVisibility: .visible) {
            Button("Apple Kart") {
                openAppleMaps()
            }
            Button("Google Maps") {
                openGoogleMaps()
            }
            Button("Avbryt", role: .cancel) {}
        }
        .confirmationDialog("Logg inn", isPresented: $showChatLoginAlert, titleVisibility: .visible) {
            Button("Logg inn med Apple") {
                authManager.signInWithApple()
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Logg inn for å sende meldinger")
        }
    }

    private func loadImage() async {
        guard let imageUrl = listing.imageUrl, let url = URL(string: imageUrl) else { return }

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
            print("Failed to load detail image: \(error)")
        }
    }

    private func loadDriveTime() async {
        guard let lat = listing.latitude,
              let lon = listing.longitude,
              let userLocation,
              !isOwner else { return }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: userLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        request.transportType = .automobile

        let directions = MKDirections(request: request)

        do {
            let response = try await directions.calculate()
            if let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) {
                let formatted = formattedTravelTime(route.expectedTravelTime)
                await MainActor.run {
                    driveTimeText = formatted
                }
            }
        } catch {
            print("Failed to load drive time: \(error)")
        }
    }

    private func formattedTravelTime(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 1)
        if minutes < 60 {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remaining = minutes % 60
        if remaining == 0 {
            return "\(hours) t"
        }

        return "\(hours) t \(remaining) min"
    }

    private func openAppleMaps() {
        guard let lat = listing.latitude,
              let lon = listing.longitude else { return }

        let destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        destination.name = listing.title

        MKMapItem.openMaps(
            with: [MKMapItem.forCurrentLocation(), destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
    }

    private func openGoogleMaps() {
        guard let lat = listing.latitude,
              let lon = listing.longitude else { return }

        let appUrlString = "comgooglemaps://?daddr=\(lat),\(lon)&directionsmode=driving"
        let webUrlString = "https://maps.google.com/?daddr=\(lat),\(lon)&directionsmode=driving"

        if let appUrl = URL(string: appUrlString) {
            UIApplication.shared.open(appUrl, options: [:]) { success in
                if !success, let webUrl = URL(string: webUrlString) {
                    UIApplication.shared.open(webUrl, options: [:], completionHandler: nil)
                }
            }
        } else if let webUrl = URL(string: webUrlString) {
            UIApplication.shared.open(webUrl, options: [:], completionHandler: nil)
        }
    }
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func search(query: String) {
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.results = completer.results
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Address search error: \(error.localizedDescription)")
    }
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            self.location = location
            manager.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

#Preview {
    MainMapView()
        .environmentObject(AuthenticationManager())
}
