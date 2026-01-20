import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()
        if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            routeNotification(from: userInfo)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "deviceToken")
        NotificationCenter.default.post(name: .didRegisterDeviceToken, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register device token: \(error)")
    }

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        routeNotification(from: response.notification.request.content.userInfo)
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let content = localNotificationContent(from: userInfo) {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
        completionHandler(.noData)
    }

    private func localNotificationContent(from userInfo: [AnyHashable: Any]) -> UNMutableNotificationContent? {
        guard let aps = userInfo["aps"] as? [String: Any] else { return nil }
        if aps["alert"] != nil {
            return nil
        }

        let content = UNMutableNotificationContent()
        content.title = (userInfo["title"] as? String) ?? "Ny melding"

        if let body = userInfo["body"] as? String {
            content.body = body
        } else if let message = userInfo["message"] as? String {
            content.body = message
        } else {
            content.body = "Du har mottatt en ny melding."
        }

        content.sound = .default
        content.userInfo = userInfo
        return content
    }

    private func routeNotification(from userInfo: [AnyHashable: Any]) {
        if let payload = chatPayload(from: userInfo) {
            ChatNotificationStore.save(payload)
            NotificationCenter.default.post(name: .didReceiveChatNotification, object: payload)
            return
        }
        if let payload = listingPayload(from: userInfo) {
            ListingNotificationStore.save(payload)
            NotificationCenter.default.post(name: .didReceiveListingNotification, object: payload)
        }
    }

    private func chatPayload(from userInfo: [AnyHashable: Any]) -> ChatNotificationPayload? {
        guard let conversationId = int64Value(userInfo["conversationId"]) else { return nil }
        let listingId = int64Value(userInfo["listingId"])
        return ChatNotificationPayload(conversationId: conversationId, listingId: listingId)
    }

    private func listingPayload(from userInfo: [AnyHashable: Any]) -> ListingNotificationPayload? {
        guard int64Value(userInfo["conversationId"]) == nil else { return nil }
        guard let listingId = int64Value(userInfo["listingId"]) else { return nil }
        return ListingNotificationPayload(listingId: listingId)
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }
}

struct ChatNotificationPayload {
    let conversationId: Int64
    let listingId: Int64?
}

struct ListingNotificationPayload {
    let listingId: Int64
}

enum ChatNotificationStore {
    private static let conversationIdKey = "pendingConversationId"
    private static let listingIdKey = "pendingListingId"

    static func save(_ payload: ChatNotificationPayload) {
        let defaults = UserDefaults.standard
        defaults.set(payload.conversationId, forKey: conversationIdKey)
        if let listingId = payload.listingId {
            defaults.set(listingId, forKey: listingIdKey)
        } else {
            defaults.removeObject(forKey: listingIdKey)
        }
    }

    static func consume() -> ChatNotificationPayload? {
        let defaults = UserDefaults.standard
        guard let conversationId = defaults.object(forKey: conversationIdKey) as? NSNumber else {
            return nil
        }
        let listingId = defaults.object(forKey: listingIdKey) as? NSNumber
        clear()
        return ChatNotificationPayload(
            conversationId: conversationId.int64Value,
            listingId: listingId?.int64Value
        )
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: conversationIdKey)
        defaults.removeObject(forKey: listingIdKey)
    }
}

enum ListingNotificationStore {
    private static let listingIdKey = "pendingListingNotificationId"

    static func save(_ payload: ListingNotificationPayload) {
        let defaults = UserDefaults.standard
        defaults.set(payload.listingId, forKey: listingIdKey)
    }

    static func consume() -> ListingNotificationPayload? {
        let defaults = UserDefaults.standard
        guard let listingId = defaults.object(forKey: listingIdKey) as? NSNumber else {
            return nil
        }
        clear()
        return ListingNotificationPayload(listingId: listingId.int64Value)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: listingIdKey)
    }
}

extension Notification.Name {
    static let didReceiveChatNotification = Notification.Name("didReceiveChatNotification")
    static let didReceiveListingNotification = Notification.Name("didReceiveListingNotification")
    static let didMarkConversationRead = Notification.Name("didMarkConversationRead")
    static let openMyListings = Notification.Name("openMyListings")
}
