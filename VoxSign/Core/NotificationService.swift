//
//  NotificationService.swift
//  VoxSign
//
//  T1 background capability · local-notification bridge:
//  when the app is backgrounded / locked, SSE events (need_ask / need_confirm / done / failed /
//  canceled) are turned into local notifications so the user can tap back into the task.
//  Zero third-party dependencies: UNUserNotificationCenter (iOS 10+).
//

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

final class NotificationService {
    static let shared = NotificationService()

    /// Whether notification permission is granted (shown in Settings).
    private(set) var authorized: Bool = false

    private init() {}

    /// Request notification permission (called on launch; does not block the main flow if denied).
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    /// Post a notification only when backgrounded / locked (the foreground UI already presents it,
    /// to avoid duplicate interruptions).
    /// - Returns: whether a notification was posted.
    @discardableResult
    func notifyIfBackground(title: String, body: String, taskId: String? = nil) -> Bool {
        guard isAppBackgrounded, authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: taskId.map { "vhs-\($0)" } ?? "vhs-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(req) { _ in }
        return true
    }

    /// Driven by SSE events: need_ask / need_confirm / done / failed / canceled.
    func routeEvent(_ type: String, taskId: String, seq: Int, payload: [String: Any]) {
        switch type {
        case "need_ask":
            let q = payload["question"] as? String ?? "A question needs your answer"
            notifyIfBackground(title: "VoxSign: Your answer needed", body: q, taskId: taskId)
        case "need_confirm":
            let q = payload["question"] as? String ?? "An operation needs your confirmation"
            notifyIfBackground(title: "VoxSign: Confirmation needed", body: q, taskId: taskId)
        case "done":
            notifyIfBackground(title: "VoxSign: Task done", body: "The receipt is ready; view the result", taskId: taskId)
        case "failed":
            let e = payload["error"] as? String ?? "Task failed"
            notifyIfBackground(title: "VoxSign: Task failed", body: String(e.prefix(80)), taskId: taskId)
        case "canceled":
            notifyIfBackground(title: "VoxSign: Task canceled", body: "The task was canceled", taskId: taskId)
        default:
            break
        }
    }

    /// Whether the app is backgrounded / locked (do not disturb in the foreground).
    private var isAppBackgrounded: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState != .active
        #else
        return false
        #endif
    }
}
