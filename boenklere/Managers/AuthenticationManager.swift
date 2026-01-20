import Foundation
import AuthenticationServices
import UIKit

@MainActor
class AuthenticationManager: NSObject, ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var userIdentifier: String?
    @Published var userName: String?
    @Published var userEmail: String?
    @Published var userAddress: String?
    @Published var userLatitude: Double?
    @Published var userLongitude: Double?
    @Published var messageNotificationsEnabled: Bool = true
    @Published var listingNotificationsEnabled: Bool = false
    @Published var listingNotificationRadiusKm: Double = 10
    @Published var unreadMessageCount: Int = 0
    @Published var errorMessage: String?
    
    private let userIdentifierKey = "userIdentifier"
    private let userNameKey = "userName"
    private let userEmailKey = "userEmail"
    private let userAddressKey = "userAddress"
    private let userLatitudeKey = "userLatitude"
    private let userLongitudeKey = "userLongitude"
    private let messageNotificationsEnabledKey = "messageNotificationsEnabled"
    private let listingNotificationsEnabledKey = "listingNotificationsEnabled"
    private let listingNotificationRadiusKmKey = "listingNotificationRadiusKm"
    private let unreadMessageCountKey = "unreadMessageCount"
    private let deviceTokenKey = "deviceToken"
    
    override init() {
        super.init()
        checkExistingCredentials()
        registerForDeviceTokenNotifications()
    }
    
    private func checkExistingCredentials() {
        if let storedIdentifier = UserDefaults.standard.string(forKey: userIdentifierKey) {
            let appleIDProvider = ASAuthorizationAppleIDProvider()
            appleIDProvider.getCredentialState(forUserID: storedIdentifier) { [weak self] credentialState, error in
                Task { @MainActor in
                    switch credentialState {
                    case .authorized:
                        self?.isAuthenticated = true
                        self?.userIdentifier = storedIdentifier
                        if let self {
                            self.userName = UserDefaults.standard.string(forKey: self.userNameKey)
                            self.userEmail = UserDefaults.standard.string(forKey: self.userEmailKey)
                            self.userAddress = UserDefaults.standard.string(forKey: self.userAddressKey)
                            self.userLatitude = UserDefaults.standard.object(forKey: self.userLatitudeKey) as? Double
                            self.userLongitude = UserDefaults.standard.object(forKey: self.userLongitudeKey) as? Double
                            if UserDefaults.standard.object(forKey: self.messageNotificationsEnabledKey) != nil {
                                self.messageNotificationsEnabled = UserDefaults.standard.bool(forKey: self.messageNotificationsEnabledKey)
                            }
                            if UserDefaults.standard.object(forKey: self.listingNotificationsEnabledKey) != nil {
                                self.listingNotificationsEnabled = UserDefaults.standard.bool(forKey: self.listingNotificationsEnabledKey)
                            }
                            if let radius = UserDefaults.standard.object(forKey: self.listingNotificationRadiusKmKey) as? Double {
                                self.listingNotificationRadiusKm = radius
                            }
                            if UserDefaults.standard.object(forKey: self.unreadMessageCountKey) != nil {
                                self.unreadMessageCount = UserDefaults.standard.integer(forKey: self.unreadMessageCountKey)
                            }
                        }
                        Task {
                            if let user = try? await APIService.shared.getUser(userId: storedIdentifier) {
                                await MainActor.run {
                                    if let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !name.isEmpty {
                                        self?.userName = name
                                        UserDefaults.standard.set(name, forKey: self?.userNameKey ?? "userName")
                                    }
                                    self?.userAddress = user.address
                                    self?.userLatitude = user.latitude
                                    self?.userLongitude = user.longitude
                                    if let enabled = user.messageNotificationsEnabled {
                                        self?.messageNotificationsEnabled = enabled
                                    }
                                    if let enabled = user.listingNotificationsEnabled {
                                        self?.listingNotificationsEnabled = enabled
                                    }
                                    if let radius = user.listingNotificationRadiusKm {
                                        self?.listingNotificationRadiusKm = radius
                                    }
                                    if let address = user.address {
                                        UserDefaults.standard.set(address, forKey: self?.userAddressKey ?? "userAddress")
                                    }
                                    if let latitude = user.latitude {
                                        UserDefaults.standard.set(latitude, forKey: self?.userLatitudeKey ?? "userLatitude")
                                    }
                                    if let longitude = user.longitude {
                                        UserDefaults.standard.set(longitude, forKey: self?.userLongitudeKey ?? "userLongitude")
                                    }
                                    if let enabled = user.messageNotificationsEnabled {
                                        UserDefaults.standard.set(enabled, forKey: self?.messageNotificationsEnabledKey ?? "messageNotificationsEnabled")
                                    }
                                    if let enabled = user.listingNotificationsEnabled {
                                        UserDefaults.standard.set(enabled, forKey: self?.listingNotificationsEnabledKey ?? "listingNotificationsEnabled")
                                    }
                                    if let radius = user.listingNotificationRadiusKm {
                                        UserDefaults.standard.set(radius, forKey: self?.listingNotificationRadiusKmKey ?? "listingNotificationRadiusKm")
                                    }
                                }
                            }
                        }
                        Task {
                            await self?.syncDeviceTokenIfNeeded()
                        }
                        Task {
                            await self?.refreshUnreadMessageCount()
                        }
                    case .revoked, .notFound:
                        self?.signOut()
                    default:
                        break
                    }
                }
            }
        }
    }
    
    func signInWithApple() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.performRequests()
    }
    
    func signOut() {
        UserDefaults.standard.removeObject(forKey: userIdentifierKey)
        UserDefaults.standard.removeObject(forKey: userNameKey)
        UserDefaults.standard.removeObject(forKey: userEmailKey)
        UserDefaults.standard.removeObject(forKey: userAddressKey)
        UserDefaults.standard.removeObject(forKey: userLatitudeKey)
        UserDefaults.standard.removeObject(forKey: userLongitudeKey)
        UserDefaults.standard.removeObject(forKey: messageNotificationsEnabledKey)
        UserDefaults.standard.removeObject(forKey: listingNotificationsEnabledKey)
        UserDefaults.standard.removeObject(forKey: listingNotificationRadiusKmKey)
        UserDefaults.standard.removeObject(forKey: unreadMessageCountKey)
        UserDefaults.standard.removeObject(forKey: "pendingListingNotificationsEnable")
        isAuthenticated = false
        userIdentifier = nil
        userName = nil
        userEmail = nil
        userAddress = nil
        userLatitude = nil
        userLongitude = nil
        messageNotificationsEnabled = true
        listingNotificationsEnabled = false
        listingNotificationRadiusKm = 10
        setUnreadMessageCount(0)
    }
}

extension AuthenticationManager {
    @MainActor
    func refreshUnreadMessageCount() async {
        guard let userId = userIdentifier else {
            setUnreadMessageCount(0)
            return
        }
        do {
            let conversations = try await APIService.shared.getConversations(userId: userId)
            updateUnreadCount(with: conversations)
        } catch {
            return
        }
    }

    @MainActor
    func updateUnreadCount(with conversations: [APIConversationSummary]) {
        let total = conversations.reduce(0) { partial, conversation in
            partial + (conversation.unreadCount ?? 0)
        }
        setUnreadMessageCount(total)
    }

    @MainActor
    private func setUnreadMessageCount(_ count: Int) {
        unreadMessageCount = max(0, count)
        UserDefaults.standard.set(unreadMessageCount, forKey: unreadMessageCountKey)
        UIApplication.shared.applicationIconBadgeNumber = unreadMessageCount
    }
}

extension AuthenticationManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            handleAuthorization(authorization)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            handleAuthorizationError(error)
        }
    }

    private func registerForDeviceTokenNotifications() {
        NotificationCenter.default.addObserver(
            forName: .didRegisterDeviceToken,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            self?.registerDeviceToken(token)
        }
    }

    private func registerDeviceToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: deviceTokenKey)
        Task { @MainActor in
            await registerDeviceTokenIfNeeded()
        }
    }

    @MainActor
    private func registerDeviceTokenIfNeeded() async {
        guard let userId = userIdentifier else { return }
        guard let token = UserDefaults.standard.string(forKey: deviceTokenKey), !token.isEmpty else { return }
        do {
            try await APIService.shared.registerDeviceToken(userId: userId, token: token)
        } catch {
            print("Failed to register device token: \(error)")
        }
    }

    @MainActor
    func syncDeviceTokenIfNeeded() async {
        await registerDeviceTokenIfNeeded()
    }

    @MainActor
    func handleAuthorization(_ authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        let userIdentifier = appleIDCredential.user

        UserDefaults.standard.set(userIdentifier, forKey: userIdentifierKey)

        self.userIdentifier = userIdentifier

        if let fullName = appleIDCredential.fullName {
            let name = [fullName.givenName, fullName.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            if !name.isEmpty {
                self.userName = name
                UserDefaults.standard.set(name, forKey: userNameKey)
            }
        }
        if self.userName == nil {
            self.userName = UserDefaults.standard.string(forKey: userNameKey)
        }

        if let email = appleIDCredential.email {
            self.userEmail = email
            UserDefaults.standard.set(email, forKey: userEmailKey)
        }
        if self.userEmail == nil {
            self.userEmail = UserDefaults.standard.string(forKey: userEmailKey)
        }

        self.isAuthenticated = true
        self.errorMessage = nil

        Task {
            do {
                let user = try await APIService.shared.upsertUser(
                    userId: userIdentifier,
                    name: self.userName
                )
                if let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    self.userName = name
                    UserDefaults.standard.set(name, forKey: self.userNameKey)
                }
                self.userAddress = user.address
                self.userLatitude = user.latitude
                self.userLongitude = user.longitude
                if let enabled = user.messageNotificationsEnabled {
                    self.messageNotificationsEnabled = enabled
                }
                if let enabled = user.listingNotificationsEnabled {
                    self.listingNotificationsEnabled = enabled
                }
                if let radius = user.listingNotificationRadiusKm {
                    self.listingNotificationRadiusKm = radius
                }
                if let address = user.address {
                    UserDefaults.standard.set(address, forKey: self.userAddressKey)
                }
                if let latitude = user.latitude {
                    UserDefaults.standard.set(latitude, forKey: self.userLatitudeKey)
                }
                if let longitude = user.longitude {
                    UserDefaults.standard.set(longitude, forKey: self.userLongitudeKey)
                }
                if let enabled = user.messageNotificationsEnabled {
                    UserDefaults.standard.set(enabled, forKey: self.messageNotificationsEnabledKey)
                }
                if let enabled = user.listingNotificationsEnabled {
                    UserDefaults.standard.set(enabled, forKey: self.listingNotificationsEnabledKey)
                }
                if let radius = user.listingNotificationRadiusKm {
                    UserDefaults.standard.set(radius, forKey: self.listingNotificationRadiusKmKey)
                }
                await self.registerDeviceTokenIfNeeded()
            } catch {
                print("Failed to upsert user: \(error)")
            }
        }
    }

    @MainActor
    func handleAuthorizationError(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}

extension Notification.Name {
    static let didRegisterDeviceToken = Notification.Name("didRegisterDeviceToken")
}
