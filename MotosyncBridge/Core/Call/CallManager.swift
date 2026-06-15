//
//  CallManager.swift
//  MotosyncBridge
//
//  Created by Antigravity on 15/06/26.
//

import Foundation
import Combine
import CallKit

final class CallManager: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = CallManager()
    
    @Published var isIncomingCallActive: Bool = false
    @Published var isCallActive: Bool = false
    @Published var callerName: String? = nil
    @Published var callerNumber: String? = nil
    
    private var callObserver: CXCallObserver!
    private var tuCallCenter: AnyObject? = nil
    private var isPrivateAPIAvailable: Bool = false
    
    private override init() {
        super.init()
        callObserver = CXCallObserver()
        callObserver.setDelegate(self, queue: DispatchQueue.main)
        
        setupPrivateCallCenter()
    }
    
    private func setupPrivateCallCenter() {
        // Dynamically load TelephonyUtilities private framework
        let path = "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities"
        let handle = dlopen(path, RTLD_NOW)
        if handle != nil {
            if let tuCallCenterClass = NSClassFromString("TUCallCenter") as? NSObject.Type {
                let selector = NSSelectorFromString("sharedInstance")
                if tuCallCenterClass.responds(to: selector) {
                    let sharedInstance = tuCallCenterClass.perform(selector).takeUnretainedValue()
                    self.tuCallCenter = sharedInstance
                    self.isPrivateAPIAvailable = true
                    print("✅ CallManager: TelephonyUtilities TUCallCenter initialized.")
                    
                    // Register for private call status changed notifications
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(handlePrivateCallNotification),
                        name: NSNotification.Name("TUCallCenterCallStatusChangedNotification"),
                        object: nil
                    )
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(handlePrivateCallNotification),
                        name: NSNotification.Name("TUCallCenterCallsChangedNotification"),
                        object: nil
                    )
                    
                    // Initial check
                    updatePrivateCallState()
                    return
                }
            }
        }
        print("⚠️ CallManager: TelephonyUtilities unavailable, falling back to public CallKit.")
    }
    
    // MARK: - CXCallObserverDelegate (Public API Fallback)
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if isPrivateAPIAvailable {
            // Let the private API handle it if available to get caller details
            return
        }
        
        let calls = callObserver.calls.filter { !$0.hasEnded }
        let hasIncoming = calls.contains { !$0.hasConnected && !$0.isOutgoing }
        let hasActive = calls.contains { $0.hasConnected }
        
        DispatchQueue.main.async {
            self.isIncomingCallActive = hasIncoming
            self.isCallActive = hasActive
            if hasIncoming {
                self.callerName = "Incoming Call"
                self.callerNumber = "Unknown Number"
            } else if hasActive {
                self.callerName = "Active Call"
                self.callerNumber = nil
            } else {
                self.callerName = nil
                self.callerNumber = nil
            }
        }
    }
    
    // MARK: - Private API Event Handler
    @objc private func handlePrivateCallNotification() {
        updatePrivateCallState()
    }
    
    private func updatePrivateCallState() {
        guard let tuCallCenter = tuCallCenter else { return }
        
        let callsSelector = NSSelectorFromString("currentCalls")
        guard tuCallCenter.responds(to: callsSelector) else { return }
        
        let calls = tuCallCenter.perform(callsSelector).takeUnretainedValue() as? [AnyObject] ?? []
        
        var incomingActive = false
        var activeActive = false
        var name: String? = nil
        var number: String? = nil
        
        for call in calls {
            let status = call.value(forKey: "status") as? Int ?? 0
            // status 1 = active, 3 = incoming/ringing, 4 = dialing
            if status == 3 {
                incomingActive = true
                name = call.value(forKey: "displayName") as? String
                number = call.value(forKey: "destinationID") as? String
            } else if status == 1 {
                activeActive = true
                name = call.value(forKey: "displayName") as? String
                number = call.value(forKey: "destinationID") as? String
            }
        }
        
        DispatchQueue.main.async {
            self.isIncomingCallActive = incomingActive
            self.isCallActive = activeActive
            self.callerName = name
            self.callerNumber = number
        }
    }
    
    // MARK: - Answering and Disconnecting
    func answerCall() -> Bool {
        if isPrivateAPIAvailable, let tuCallCenter = tuCallCenter {
            let callsSelector = NSSelectorFromString("currentCalls")
            if tuCallCenter.responds(to: callsSelector) {
                let calls = tuCallCenter.perform(callsSelector).takeUnretainedValue() as? [AnyObject] ?? []
                // Find incoming call (status == 3)
                if let incomingCall = calls.first(where: { (call) -> Bool in
                    let status = call.value(forKey: "status") as? Int ?? 0
                    return status == 3
                }) {
                    let answerSelector = NSSelectorFromString("answerCall:")
                    if tuCallCenter.responds(to: answerSelector) {
                        _ = tuCallCenter.perform(answerSelector, with: incomingCall)
                        print("📞 CallManager: Answered incoming call via private API.")
                        return true
                    }
                }
            }
        }
        
        print("⚠️ CallManager: Cannot answer call (TelephonyUtilities unavailable or no incoming call).")
        return false
    }
    
    func disconnectCall() -> Bool {
        if isPrivateAPIAvailable, let tuCallCenter = tuCallCenter {
            let callsSelector = NSSelectorFromString("currentCalls")
            if tuCallCenter.responds(to: callsSelector) {
                let calls = tuCallCenter.perform(callsSelector).takeUnretainedValue() as? [AnyObject] ?? []
                if let call = calls.first {
                    let disconnectSelector = NSSelectorFromString("disconnectCall:")
                    if tuCallCenter.responds(to: disconnectSelector) {
                        _ = tuCallCenter.perform(disconnectSelector, with: call)
                        print("📞 CallManager: Disconnected call via private API.")
                        return true
                    }
                }
            }
            
            let disconnectAllSelector = NSSelectorFromString("disconnectAllCalls")
            if tuCallCenter.responds(to: disconnectAllSelector) {
                _ = tuCallCenter.perform(disconnectAllSelector)
                print("📞 CallManager: Disconnected all calls via private API.")
                return true
            }
        }
        
        print("⚠️ CallManager: Cannot disconnect call (TelephonyUtilities unavailable).")
        return false
    }
    
    // MARK: - Mocking for Simulator / Testing
    func simulateIncomingCall(name: String, number: String) {
        DispatchQueue.main.async {
            self.isIncomingCallActive = true
            self.isCallActive = false
            self.callerName = name
            self.callerNumber = number
        }
    }
    
    func simulateAnswer() {
        DispatchQueue.main.async {
            if self.isIncomingCallActive {
                self.isIncomingCallActive = false
                self.isCallActive = true
            }
        }
    }
    
    func simulateEnd() {
        DispatchQueue.main.async {
            self.isIncomingCallActive = false
            self.isCallActive = false
            self.callerName = nil
            self.callerNumber = nil
        }
    }
}
