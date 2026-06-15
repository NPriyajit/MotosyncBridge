//
//  MessageManager.swift
//  MotosyncBridge
//
//  Created by Antigravity on 15/06/26.
//

import Foundation
import Combine

final class MessageManager: ObservableObject {
    static let shared = MessageManager()
    
    @Published var hasUnreadPriorityMessages: Bool = false
    @Published var enabledApps: Set<String> = ["Messages", "WhatsApp"] // default enabled priority apps
    
    private init() {}
    
    func toggleAppPriority(_ app: String) {
        if enabledApps.contains(app) {
            enabledApps.remove(app)
        } else {
            enabledApps.insert(app)
        }
    }
    
    func simulateNewMessage() {
        DispatchQueue.main.async {
            self.hasUnreadPriorityMessages = true
        }
    }
    
    func clearMessages() {
        DispatchQueue.main.async {
            self.hasUnreadPriorityMessages = false
        }
    }
}
