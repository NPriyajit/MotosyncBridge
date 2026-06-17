import SwiftUI
import MapKit
import CoreBluetooth
import CoreLocation

// MARK: - Radar Ring (Glowing pulse animation)
struct RadarRing: View {
    let delay: Double
    let color: Color
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0.8

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .shadow(color: color.opacity(0.5), radius: 8, x: 0, y: 0) // Added glow
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 2.2)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
                ) {
                    scale = 2.0
                    opacity = 0
                }
            }
    }
}

// MARK: - Waveform Bar (Gradient & fluid bounce)
struct WaveBar: View {
    let delay: Double
    let isPlaying: Bool
    @State private var height: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color.red, Color.orange]),
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: 6, height: height)
            .shadow(color: .red.opacity(0.4), radius: 4)
            .onAppear { animate() }
            .onChange(of: isPlaying) { animate() }
    }

    private func animate() {
        guard isPlaying else {
            withAnimation(.easeOut(duration: 0.4)) { height = 6 }
            return
        }
        withAnimation(
            .easeInOut(duration: Double.random(in: 0.3...0.6))
            .repeatForever(autoreverses: true)
            .delay(delay)
        ) {
            height = CGFloat.random(in: 16...48)
        }
    }
}

// MARK: - Dashboard View
struct DashboardView: View {
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var media: MediaObserver
    @StateObject private var nav = NavigationManager.shared
    @StateObject private var call = CallManager.shared
    @StateObject private var msg = MessageManager.shared

    @FocusState private var isFocused: Bool

    @State private var appear = false
    @State private var trackAppear = false
    @State private var trackKey = UUID()

    // Navigation and Search State
    enum DashboardTab {
        case media
        case navigation
        case settings
    }
    @State private var selectedTab: DashboardTab = .media
    @State private var searchQuery: String = ""
    @State private var hasPassedInitialThreeSeconds: Bool = false
    @State private var selectedMapApp: AppConfiguration.PreferredMapApp = AppConfiguration.preferredMapApp
    @State private var selectedItem: MKMapItem? = nil
    @State private var mapCameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    var isScanning: Bool {
        ble.status == .scanning || ble.status == .connecting
    }

    var isRefreshEnabled: Bool {
        hasPassedInitialThreeSeconds && ble.status != .connected
    }

    /// True only when MediaObserver has captured real track data (not the defaults).
    var hasRealMedia: Bool {
        media.currentTrack != "No Media Playing" || media.currentArtist != "Unknown Artist"
    }

    var body: some View {
        ZStack {
            // Deep automotive dark background
            Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea()
            
            // Subtle radial gradient for depth
            RadialGradient(
                gradient: Gradient(colors: [Color.white.opacity(0.03), .clear]),
                center: .center,
                startRadius: 10,
                endRadius: 400
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                
                indicatorRow
                    .padding(.top, 12)
                
                // Sliding Segmented Tab Control
                tabPicker
                    .padding(.vertical, 16)
                
                ZStack {
                    mediaView
                        .opacity(selectedTab == .media ? 1 : 0)
                        .offset(x: selectedTab == .media ? 0 : (selectedTab == .navigation ? -500 : -1000))
                    
                    mapsView
                        .opacity(selectedTab == .navigation ? 1 : 0)
                        .offset(x: selectedTab == .navigation ? 0 : (selectedTab == .media ? 500 : -500))
                    
                    settingsView
                        .opacity(selectedTab == .settings ? 1 : 0)
                        .offset(x: selectedTab == .settings ? 0 : (selectedTab == .navigation ? 500 : 1000))
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: selectedTab)
                
                Spacer()
                statusBar
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 28)
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress { press in
            print("⌨️ HONDA HOGP BUTTON PRESSED: \(press.key)")
            
            switch press.key {
            case .leftArrow:
                SystemMediaController.shared.previousTrack()
                return .handled
            case .rightArrow:
                SystemMediaController.shared.nextTrack()
                return .handled
            case .upArrow, .downArrow, .return:
                if CallManager.shared.isIncomingCallActive {
                    print("📞 Key press simulated answer.")
                    _ = CallManager.shared.answerCall()
                } else if CallManager.shared.isCallActive {
                    print("📞 Key press simulated hangup.")
                    _ = CallManager.shared.disconnectCall()
                } else {
                    SystemMediaController.shared.togglePlayPause()
                }
                return .handled
            case .escape:
                if CallManager.shared.isIncomingCallActive || CallManager.shared.isCallActive {
                    print("📞 Key press simulated decline/hangup.")
                    _ = CallManager.shared.disconnectCall()
                    return .handled
                }
                return .ignored
            default:
                return .ignored
            }
        }
        .onAppear {
            isFocused = true
            withAnimation(.easeOut(duration: 0.7)) { appear = true }
            withAnimation(.easeOut(duration: 0.6).delay(0.3)) { trackAppear = true }
            
            media.onMetadataChanged = { t, a in
                ble.updateKnownMetadata(track: t, artist: a)
                if !ble.isNavigationActive {
                    ble.sendMetadata(track: t, artist: a)
                }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                    trackKey = UUID()
                }
            }
            media.fetchCurrentMedia()
            
            // Request location capability prompts
            nav.requestAlwaysLocationAuthorization()
            
            // Enable refresh button after 3 seconds if not connected
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation {
                    hasPassedInitialThreeSeconds = true
                }
            }
        }
    }

    // MARK: - Tab Picker
    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach([DashboardTab.media, DashboardTab.navigation, DashboardTab.settings], id: \.self) { tab in
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tabName(tab))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.4))
                        .tracking(1.5)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: geo.size.width / 3 - 6, height: geo.size.height - 8)
                    .offset(x: offsetForTab(selectedTab, totalWidth: geo.size.width))
                    .padding(.vertical, 4)
            }
        )
        .background(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.02)))
        .frame(height: 38)
        .opacity(appear ? 1 : 0)
    }

    private func tabName(_ tab: DashboardTab) -> String {
        switch tab {
        case .media: return "MEDIA"
        case .navigation: return "NAVIGATION"
        case .settings: return "SETTINGS"
        }
    }

    private func offsetForTab(_ tab: DashboardTab, totalWidth: CGFloat) -> CGFloat {
        let tabWidth = totalWidth / 3
        switch tab {
        case .media: return 3
        case .navigation: return tabWidth + 3
        case .settings: return (tabWidth * 2) + 3
        }
    }

    // MARK: - Media View
    private var mediaView: some View {
        VStack(spacing: 0) {
            Spacer()
            artSection
            Spacer()
            trackSection
            Spacer()
            if call.isIncomingCallActive || call.isCallActive || msg.hasUnreadPriorityMessages {
                actionButtonsView
            } else if hasRealMedia || media.isPlaying {
                mediaControls
            } else {
                controlModeDisplay
            }
            Spacer()
        }
    }

    private var actionButtonsView: some View {
        HStack(spacing: 20) {
            if call.isIncomingCallActive {
                Button(action: {
                    _ = CallManager.shared.disconnectCall()
                }) {
                    HStack {
                        Image(systemName: "phone.down.fill")
                        Text("DECLINE")
                    }
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.85)))
                    .shadow(color: Color.red.opacity(0.3), radius: 6)
                }
                
                Button(action: {
                    _ = CallManager.shared.answerCall()
                }) {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("ANSWER")
                    }
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.2, green: 0.9, blue: 0.5)))
                    .shadow(color: Color(red: 0.2, green: 0.9, blue: 0.5).opacity(0.3), radius: 8)
                }
            } else if call.isCallActive {
                Button(action: {
                    _ = CallManager.shared.disconnectCall()
                }) {
                    HStack {
                        Image(systemName: "phone.down.fill")
                        Text("END CALL")
                    }
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.85)))
                    .shadow(color: Color.red.opacity(0.3), radius: 6)
                }
            } else if msg.hasUnreadPriorityMessages {
                Button(action: {
                    msg.clearMessages()
                }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("DISMISS")
                    }
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: call.isIncomingCallActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: call.isCallActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: msg.hasUnreadPriorityMessages)
    }

    private var indicatorRow: some View {
        HStack(spacing: 20) {
            // 1. Bluetooth Icon
            indicatorIcon(
                systemName: ble.status == .connected ? "wave.3.right.circle.fill" : "wave.3.right.circle",
                isActive: ble.status == .connected,
                activeColor: Color(red: 0.2, green: 0.6, blue: 1.0)
            )
            
            // 2. Navigation Icon
            indicatorIcon(
                systemName: "location.circle.fill",
                isActive: nav.isNavigating || ble.isNavigationActive || !nav.searchResults.isEmpty,
                activeColor: Color(red: 0.2, green: 0.9, blue: 0.5)
            )
            
            // 3. Call Icon
            indicatorIcon(
                systemName: call.isIncomingCallActive ? "phone.badge.plus.fill" : "phone.circle.fill",
                isActive: call.isIncomingCallActive || call.isCallActive,
                activeColor: Color.orange
            )
            
            // 4. Music Icon
            indicatorIcon(
                systemName: "music.note",
                isActive: media.isPlaying,
                activeColor: Color.pink
            )
            
            // 5. Message Icon
            indicatorIcon(
                systemName: "message.circle.fill",
                isActive: msg.hasUnreadPriorityMessages,
                activeColor: Color.yellow
            )
            
            // 6. Service Warning Icon
            indicatorIcon(
                systemName: "exclamationmark.triangle.fill",
                isActive: ble.status == .disconnected,
                activeColor: Color.red
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.04), lineWidth: 1))
        .opacity(appear ? 1 : 0)
    }

    private func indicatorIcon(systemName: String, isActive: Bool, activeColor: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(isActive ? activeColor : Color.white.opacity(0.12))
            .shadow(color: isActive ? activeColor.opacity(0.4) : .clear, radius: isActive ? 6 : 0)
            .scaleEffect(isActive ? 1.1 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isActive)
            .frame(maxWidth: .infinity)
    }

    private var settingsView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Connection Status section
                VStack(alignment: .leading, spacing: 12) {
                    Text("DEVICE CONFIGURATION")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(1.5)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ble.connectedPeripheral?.name ?? (ble.status == .scanning ? "SEARCHING..." : "DISCONNECTED"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            
                            Text(ble.connectedPeripheral?.identifier.uuidString ?? "UUID: N/A")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Spacer()
                        
                        Button(action: {
                            triggerRefresh()
                        }) {
                            Text(ble.status == .connecting ? "CONNECTING..." : "REFRESH")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(ble.status == .connected ? Color(red: 0.2, green: 0.9, blue: 0.5) : Color.orange)
                                .cornerRadius(8)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }
                
                // Priority Notification Apps
                VStack(alignment: .leading, spacing: 12) {
                    Text("PRIORITY MESSAGING")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(1.5)
                    
                    VStack(spacing: 0) {
                        ForEach(["Messages", "WhatsApp", "Telegram", "Signal"], id: \.self) { app in
                            Button(action: {
                                msg.toggleAppPriority(app)
                            }) {
                                HStack {
                                    Text(app)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Image(systemName: msg.enabledApps.contains(app) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(msg.enabledApps.contains(app) ? Color(red: 0.2, green: 0.9, blue: 0.5) : .white.opacity(0.2))
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 14)
                            }
                            if app != "Signal" {
                                Divider().background(Color.white.opacity(0.08))
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }
                
                // Navigation Preferences
                VStack(alignment: .leading, spacing: 12) {
                    Text("NAVIGATION PREFERENCES")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(1.5)
                    
                    VStack(spacing: 0) {
                        ForEach(AppConfiguration.PreferredMapApp.allCases, id: \.self) { mapApp in
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedMapApp = mapApp
                                    AppConfiguration.preferredMapApp = mapApp
                                }
                            }) {
                                HStack {
                                    Image(systemName: mapApp == .appleMaps ? "map.fill" : (mapApp == .googleMaps ? "globe" : "location.circle.fill"))
                                        .font(.system(size: 14))
                                        .foregroundColor(selectedMapApp == mapApp ? Color(red: 0.2, green: 0.9, blue: 0.5) : .white.opacity(0.4))
                                        .frame(width: 24)
                                    
                                    Text(mapApp.rawValue)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                    
                                    Spacer()
                                    
                                    Image(systemName: selectedMapApp == mapApp ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedMapApp == mapApp ? Color(red: 0.2, green: 0.9, blue: 0.5) : .white.opacity(0.2))
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 14)
                            }
                            if mapApp != AppConfiguration.PreferredMapApp.allCases.last {
                                Divider().background(Color.white.opacity(0.08))
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    
                    Text(selectedMapApp == .inApp ? "Route and navigation will be managed entirely within this app." : "Places found in the Navigation tab will open in your preferred map app for directions.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                        .padding(.horizontal, 4)
                }
                
                // End of Settings Options
                Spacer(minLength: 10)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Maps / Navigation View
    private var mapsView: some View {
        VStack(spacing: 16) {
            // Sleek Glassmorphic Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.4))
                
                TextField("Search Destination...", text: $searchQuery, onCommit: {
                    nav.searchDestinations(query: searchQuery)
                })
                .foregroundColor(.white)
                .font(.system(size: 14, weight: .medium))
                .autocorrectionDisabled()
                .submitLabel(.search)
                
                if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                        nav.searchResults = []
                        if selectedMapApp == .inApp {
                            nav.clearRoute()
                            selectedItem = nil
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
            
            // Hotspot Categories Grid
            HStack(spacing: 12) {
                ForEach(HotspotCategory.allCases, id: \.self) { category in
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            nav.searchHotspots(category: category)
                            searchQuery = category.rawValue
                            if selectedMapApp == .inApp {
                                nav.clearRoute()
                                selectedItem = nil
                            }
                        }
                    }) {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(searchQuery == category.rawValue ? Color(red: 0.2, green: 0.9, blue: 0.5).opacity(0.15) : Color.white.opacity(0.04))
                                    .frame(width: 42, height: 42)
                                    .overlay(Circle().stroke(
                                        searchQuery == category.rawValue ? Color(red: 0.2, green: 0.9, blue: 0.5).opacity(0.4) : Color.white.opacity(0.08),
                                        lineWidth: 1
                                    ))
                                
                                Image(systemName: category.sfSymbol)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(searchQuery == category.rawValue ? Color(red: 0.2, green: 0.9, blue: 0.5) : .white.opacity(0.8))
                            }
                            
                            Text(category.rawValue.uppercased())
                                .font(.system(size: 8, weight: .black, design: .rounded))
                                .foregroundColor(searchQuery == category.rawValue ? Color(red: 0.2, green: 0.9, blue: 0.5).opacity(0.7) : .white.opacity(0.4))
                                .tracking(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.vertical, 4)
            
            if selectedMapApp == .inApp {
                // IN-APP MAP RENDERING FLOW
                ZStack(alignment: .top) {
                    // Map view only rendered when tab is active to eliminate background lags
                    if selectedTab == .navigation {
                        Map(position: $mapCameraPosition) {
                            UserAnnotation()
                            if let route = nav.selectedRoute {
                                MapPolyline(route.polyline)
                                    .stroke(Color(red: 0.2, green: 0.9, blue: 0.5), lineWidth: 6)
                            }
                        }
                        .mapStyle(.standard(pointsOfInterest: .excludingAll))
                        .cornerRadius(18)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 8)
                        .animation(nil, value: selectedTab) // Prevent ZStack offset animations from updating/animating Map frame
                    } else {
                        // Placeholders to keep ZStack sizing identical while inactive
                        Color.clear
                            .cornerRadius(18)
                    }
                    
                    // Search Results dropdown overlay
                    if !nav.searchResults.isEmpty && !nav.isNavigating {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(nav.searchResults, id: \.self) { item in
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            selectedItem = item
                                            searchQuery = item.name ?? ""
                                        }
                                        nav.calculateRoute(to: item) { success in
                                            if success, let rect = nav.selectedRoute?.polyline.boundingMapRect {
                                                withAnimation(.easeInOut(duration: 0.5)) {
                                                    mapCameraPosition = .rect(rect)
                                                }
                                            }
                                        }
                                    }) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name ?? "Unknown Location")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.white)
                                            Text(item.placemark.title ?? "")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.4))
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        
                                        Divider().background(Color.white.opacity(0.08))
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.08, green: 0.08, blue: 0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                        }
                        .frame(maxHeight: 220)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                
                // Context Action Cards for In-App Nav
                if nav.isNavigating {
                    // Turn-by-Turn Guidance Banner
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.2, green: 0.9, blue: 0.5).opacity(0.12))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: getManeuverSFName(nav.currentManeuverIcon))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatDistanceText(nav.distanceToNextStep))
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text(nav.currentStepInstruction)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(2)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            nav.stopNavigation()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.red.opacity(0.85)))
                                .shadow(color: .red.opacity(0.3), radius: 4)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let route = nav.selectedRoute {
                    // Route Preview Details
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedItem?.name ?? "Destination")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            HStack(spacing: 6) {
                                Text(String(format: "%.1f miles", route.distance / 1609.34))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.4))
                                
                                Circle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(width: 4, height: 4)
                                
                                Text(formatDuration(route.expectedTravelTime))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    nav.clearRoute()
                                    selectedItem = nil
                                    searchQuery = ""
                                    nav.searchResults = []
                                    mapCameraPosition = .userLocation(fallback: .automatic)
                                }
                            }) {
                                Text("CANCEL")
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            }
                            
                            Button(action: {
                                nav.startNavigation()
                            }) {
                                Text("START")
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.2, green: 0.9, blue: 0.5)))
                                    .shadow(color: Color(red: 0.2, green: 0.9, blue: 0.5).opacity(0.3), radius: 8)
                            }
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                // EXTERNAL HANDOFF LIST FLOW
                // Results List or Empty State
                if nav.searchResults.isEmpty {
                    // Empty State
                    VStack(spacing: 16) {
                        Spacer()
                        
                        Image(systemName: "map.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundColor(.white.opacity(0.1))
                        
                        Text("DISCOVER NEARBY")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundColor(.white.opacity(0.2))
                            .tracking(2)
                        
                        Text("Tap a category above or search\nto find nearby places")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.3))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                        
                        // Map App Indicator
                        HStack(spacing: 6) {
                            Image(systemName: selectedMapApp == .appleMaps ? "map.fill" : "globe")
                                .font(.system(size: 10))
                            Text("Opens in \(selectedMapApp.rawValue)")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundColor(.white.opacity(0.2))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.04)))
                        
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // Search Results List
                    ScrollView {
                        VStack(spacing: 0) {
                            // Results Count Header
                            HStack {
                                Text("\(nav.searchResults.count) PLACES FOUND")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundColor(.white.opacity(0.3))
                                    .tracking(1.5)
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        searchQuery = ""
                                        nav.searchResults = []
                                    }
                                }) {
                                    Text("CLEAR")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 10)
                            
                            // Place Rows
                            ForEach(nav.searchResults, id: \.self) { item in
                                Button(action: {
                                    nav.openInExternalMaps(item: item)
                                }) {
                                    HStack(spacing: 14) {
                                        // Category Icon
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color(red: 0.2, green: 0.9, blue: 0.5).opacity(0.08))
                                                .frame(width: 40, height: 40)
                                            
                                            Image(systemName: "location.fill")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))
                                        }
                                        
                                        // Place Details
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name ?? "Unknown Location")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                            
                                            Text(item.placemark.title ?? "")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.35))
                                                .lineLimit(1)
                                        }
                                        
                                        Spacer()
                                        
                                        // Distance Badge
                                        VStack(alignment: .trailing, spacing: 4) {
                                            if let dist = nav.formattedDistance(to: item) {
                                                Text(dist)
                                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                                    .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))
                                            }
                                            
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.system(size: 12))
                                                .foregroundColor(.white.opacity(0.25))
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.02)))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.04), lineWidth: 1))
                                }
                                .padding(.bottom, 6)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    // MARK: - Control Mode
    private var controlModeDisplay: some View {
        HStack(spacing: 6) {
            Image(systemName: AppConfiguration.mediaControlMode == .systemWide ? "sparkles" : "music.note")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
            
            Text(AppConfiguration.mediaControlMode.rawValue.uppercased())
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .tracking(1.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .opacity(appear ? 1 : 0)
    }

    // MARK: - Media Transport Controls
    private var mediaControls: some View {
        HStack(spacing: 0) {
            Button(action: {
                SystemMediaController.shared.previousTrack()
            }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Button(action: {
                SystemMediaController.shared.togglePlayPause()
            }) {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Button(action: {
                SystemMediaController.shared.nextTrack()
            }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.04))
                .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
        .opacity(appear ? 1 : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: - Header
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MOTOSYNC")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .tracking(5)
                Text("BRIDGE LINK")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(3)
            }
            Spacer()
            
            Image(systemName: ble.status == .connected ? "motorcycle.fill" : "motorcycle")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(statusColor(ble.status))
                .shadow(color: statusColor(ble.status).opacity(0.4), radius: ble.status == .connected ? 10 : 0)
                .animation(.easeInOut(duration: 0.4), value: ble.status)
        }
        .padding(.top, 40)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : -15)
    }

    // MARK: - Art + Radar
    private var artSection: some View {
        ZStack {
            if isScanning {
                ForEach([0.0, 0.7, 1.4], id: \.self) { delay in
                    RadarRing(delay: delay, color: statusColor(ble.status))
                        .frame(width: 240, height: 240)
                }
            }

            // Central Hub UI
            Circle()
                .fill(Color(red: 0.1, green: 0.1, blue: 0.12))
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
                .overlay(
                    Circle()
                        .stroke(
                            statusColor(ble.status).opacity(ble.status == .connected ? 0.6 : 0.15),
                            lineWidth: 2
                        )
                        .animation(.easeInOut(duration: 0.5), value: ble.status)
                )

            VStack(spacing: 20) {
                if call.isIncomingCallActive || call.isCallActive {
                    Image(systemName: call.isIncomingCallActive ? "phone.badge.plus.fill" : "phone.fill")
                        .font(.system(size: 54, weight: .light))
                        .foregroundColor(call.isIncomingCallActive ? .orange : Color(red: 0.2, green: 0.9, blue: 0.5))
                        .shadow(color: (call.isIncomingCallActive ? Color.orange : Color.green).opacity(0.6), radius: 15)
                        .scaleEffect(call.isIncomingCallActive ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: call.isIncomingCallActive)
                } else if msg.hasUnreadPriorityMessages {
                    Image(systemName: "message.circle.fill")
                        .font(.system(size: 54, weight: .light))
                        .foregroundColor(.yellow)
                        .shadow(color: Color.yellow.opacity(0.6), radius: 15)
                        .scaleEffect(1.05)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: msg.hasUnreadPriorityMessages)
                } else if media.isPlaying {
                    HStack(alignment: .center, spacing: 6) {
                        ForEach([0.0, 0.15, 0.3, 0.1, 0.25], id: \.self) { d in
                            WaveBar(delay: d, isPlaying: media.isPlaying)
                        }
                    }
                    .frame(height: 50)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 54, weight: .thin))
                        .foregroundColor(Color.gray.opacity(0.5))
                        .transition(.scale.combined(with: .opacity))
                }

                Text(call.isIncomingCallActive ? "INCOMING CALL" : (call.isCallActive ? "ACTIVE CALL" : (msg.hasUnreadPriorityMessages ? "NEW MESSAGE" : "BTU TX")))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(
                        call.isIncomingCallActive ? .orange :
                        (call.isCallActive ? Color(red: 0.2, green: 0.9, blue: 0.5) :
                        (msg.hasUnreadPriorityMessages ? .yellow : statusColor(ble.status).opacity(0.7)))
                    )
                    .tracking(4)
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            // Tap the central hub to toggle play/pause
            SystemMediaController.shared.togglePlayPause()
        }
        .opacity(appear ? 1 : 0)
        .scaleEffect(appear ? 1 : 0.85)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: appear)
    }

    // MARK: - Track Info
    private var trackSection: some View {
        VStack(spacing: 12) {
            if call.isIncomingCallActive || call.isCallActive {
                Text(call.callerName ?? (call.isIncomingCallActive ? "Incoming Call" : "Active Call"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .transition(.opacity)

                Text(call.callerNumber ?? "Unknown Details")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .transition(.opacity)
            } else if msg.hasUnreadPriorityMessages {
                Text(msg.lastMessageSender ?? "Priority Message")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .transition(.opacity)

                Text("From \(msg.lastMessageApp ?? "Notification")")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .transition(.opacity)
            } else if hasRealMedia {
                Text(media.currentTrack)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .id(trackKey)
                    .transition(.asymmetric(
                        insertion: .offset(y: 15).combined(with: .opacity),
                        removal:   .offset(y: -15).combined(with: .opacity)
                    ))

                Text(media.currentArtist)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .id(trackKey)
                    .transition(.asymmetric(
                        insertion: .offset(y: 10).combined(with: .opacity),
                        removal:   .offset(y: -10).combined(with: .opacity)
                    ))
            } else {
                Text("AWAITING MEDIA")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.2))
                    .tracking(3)
            }
        }
        .frame(height: 80)
        .opacity(trackAppear ? 1 : 0)
        .offset(y: trackAppear ? 0 : 15)
        .animation(.easeOut(duration: 0.5), value: trackAppear)
    }

    // MARK: - Status Bar
    private var statusBar: some View {
        HStack(spacing: 12) {
            ZStack {
                if isScanning {
                    Circle()
                        .fill(statusColor(ble.status).opacity(0.3))
                        .frame(width: 22, height: 22)
                        .scaleEffect(isScanning ? 1.5 : 1)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isScanning
                        )
                }
                Circle()
                    .fill(statusColor(ble.status))
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor(ble.status), radius: 4)
            }

            Text(ble.status.rawValue.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(statusColor(ble.status))
                .tracking(2)
                .animation(.easeInOut(duration: 0.3), value: ble.status)
            
            Spacer()
            
            HStack(spacing: 14) {
                Button(action: {
                    triggerRefresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(isRefreshEnabled ? 0.6 : 0.15))
                }
                .disabled(!isRefreshEnabled)
                
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .symbolEffect(.variableColor.iterative, isActive: isScanning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 20)
    }

    private func triggerRefresh() {
        withAnimation {
            hasPassedInitialThreeSeconds = false
        }
        ble.manualRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation {
                hasPassedInitialThreeSeconds = true
            }
        }
    }

    private func statusColor(_ s: BLEStatus) -> Color {
        switch s {
        case .connected:             return Color(red: 0.2, green: 0.9, blue: 0.5)
        case .scanning, .connecting: return Color.orange
        default:                     return Color.red
        }
    }
    


    // MARK: - UI Formatting Helpers
    
    private func getManeuverSFName(_ iconId: UInt8) -> String {
        switch iconId {
        case 53: return "arrow.turn.up.left"
        case 44: return "arrow.turn.up.right"
        case 54: return "arrow.turn.up.left"
        case 45: return "arrow.turn.up.right"
        case 55: return "arrow.up.left"
        case 46: return "arrow.up.right"
        case 47: return "arrow.uturn.left"
        case 42: return "arrow.merge"
        case 59: return "arrow.turn.up.left.fill"
        case 50: return "arrow.turn.up.right.fill"
        case 49: return "arrow.counterclockwise"
        case 83: return "flag.fill"
        default: return "arrow.up"
        }
    }

    private func formatDistanceText(_ meters: CLLocationDistance) -> String {
        if meters < 1000.0 {
            return "\(Int(meters)) m"
        } else {
            return String(format: "%.1f km", meters / 1000.0)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? ""
    }
}

