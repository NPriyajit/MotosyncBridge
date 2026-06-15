//
//  MessageManager.swift
//  MotosyncBridge
//
//  Created by Antigravity on 15/06/26.
//

import Foundation
import Combine

final class MessageManager: NSObject, ObservableObject {
    static let shared = MessageManager()
    
    @Published var hasUnreadPriorityMessages: Bool = false
    @Published var enabledApps: Set<String> = ["Messages", "WhatsApp", "Telegram", "Signal"]
    @Published var lastMessageSender: String? = nil
    @Published var lastMessageApp: String? = nil
    
    private var observer: AnyObject? = nil
    private var dismissTimer: Timer?
    
    private override init() {
        super.init()
        setupBulletinBoardObserver()
    }
    
    private func setupBulletinBoardObserver() {
        // Dynamically load BulletinBoard private framework
        let path = "/System/Library/PrivateFrameworks/BulletinBoard.framework"
        if let bundle = Bundle(path: path), bundle.load() {
            if let observerClass = NSClassFromString("BBObserver") as? NSObject.Type {
                let observerInstance = observerClass.init()
                self.observer = observerInstance
                
                // Set delegate
                observerInstance.setValue(self, forKey: "delegate")
                print("✅ MessageManager: BulletinBoard BBObserver initialized.")
                return
            }
        }
        print("⚠️ MessageManager: BulletinBoard BBObserver unavailable.")
    }
    
    func toggleAppPriority(_ app: String) {
        DispatchQueue.main.async {
            if self.enabledApps.contains(app) {
                self.enabledApps.remove(app)
            } else {
                self.enabledApps.insert(app)
            }
        }
    }
    
    func clearMessages() {
        DispatchQueue.main.async {
            self.hasUnreadPriorityMessages = false
            self.lastMessageSender = nil
            self.lastMessageApp = nil
            self.dismissTimer?.invalidate()
            self.dismissTimer = nil
        }
    }
    
    // Auto-dismiss indicator after 20 seconds
    private func startAutoDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            self?.clearMessages()
        }
    }
}

// MARK: - BBObserverDelegate implementation dynamically via NSObject
extension MessageManager {
    // This is the private BBObserver delegate method called by iOS when a new notification is posted
    @objc func observer(_ observer: AnyObject, addBulletin bulletin: AnyObject, forFeed feed: Int) {
        guard let sectionID = bulletin.value(forKey: "sectionID") as? String else { return }
        
        var matchedApp: String? = nil
        switch sectionID {
        case "com.apple.MobileSMS":
            matchedApp = "Messages"
        case "net.whatsapp.WhatsApp":
            matchedApp = "WhatsApp"
        case "ph.telegra.Telegra":
            matchedApp = "Telegram"
        case "org.whispersystems.signal":
            matchedApp = "Signal"
        default:
            break
        }
        
        guard let app = matchedApp, enabledApps.contains(app) else { return }
        
        let title = bulletin.value(forKey: "title") as? String ?? ""
        let message = bulletin.value(forKey: "message") as? String ?? ""
        print("💬 MessageManager Intercepted notification from \(app): \(title) — \(message)")
        
        DispatchQueue.main.async {
            self.lastMessageSender = title.isEmpty ? "New Message" : title
            self.lastMessageApp = app
            self.hasUnreadPriorityMessages = true
            self.startAutoDismissTimer()
        }
    }
}
