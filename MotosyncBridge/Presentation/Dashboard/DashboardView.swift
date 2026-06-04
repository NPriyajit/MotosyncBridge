import SwiftUI

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
            .onChange(of: isPlaying) { _ in animate() }
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

    @State private var appear = false
    @State private var trackAppear = false
    @State private var trackKey = UUID()

    var isScanning: Bool {
        ble.status == .scanning || ble.status == .connecting
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
                Spacer()
                artSection
                Spacer()
                trackSection
                Spacer()
                statusBar
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { appear = true }
            withAnimation(.easeOut(duration: 0.6).delay(0.3)) { trackAppear = true }
            
            media.onMetadataChanged = { t, a in
                ble.sendMetadata(track: t, artist: a)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                    trackKey = UUID()
                }
            }
            media.fetchCurrentMedia()
        }
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
            
            // Animated dynamic icon based on status
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
                if media.isPlaying {
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

                Text("BTU TX")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(statusColor(ble.status).opacity(0.7))
                    .tracking(4)
            }
        }
        .opacity(appear ? 1 : 0)
        .scaleEffect(appear ? 1 : 0.85)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: appear)
    }

    // MARK: - Track Info
    private var trackSection: some View {
        VStack(spacing: 12) {
            Text(media.currentTrack)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .id(trackKey) // Forces SwiftUI to transition when the text changes
                .transition(.asymmetric(
                    insertion: .offset(y: 15).combined(with: .opacity),
                    removal:   .offset(y: -15).combined(with: .opacity) // Syntax fixed here!
                ))

            Text(media.currentArtist)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .id(trackKey)
                .transition(.asymmetric(
                    insertion: .offset(y: 10).combined(with: .opacity),
                    removal:   .offset(y: -10).combined(with: .opacity)
                ))
        }
        .frame(height: 80) // Prevents UI jumping when text wraps
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
            
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
                .symbolEffect(.variableColor.iterative, isActive: isScanning)        }
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

    private func statusColor(_ s: BLEStatus) -> Color {
        switch s {
        case .connected:             return Color(red: 0.2, green: 0.9, blue: 0.5)
        case .scanning, .connecting: return Color.orange
        default:                     return Color.red
        }
    }
}
