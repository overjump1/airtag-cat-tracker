import SwiftUI

struct ContentView: View {

    @StateObject private var service = AirTagService()
    @State private var soundOn = false

    // ── Derived visuals ───────────────────────────────────────────────────────
    private var ringColor: Color {
        guard let d = service.distance else { return .gray }
        switch d {
        case ..<1.0:  return .green
        case ..<3.0:  return Color(red: 0.4, green: 0.9, blue: 0.5)
        case ..<7.0:  return .yellow
        case ..<15.0: return .orange
        default:      return .red
        }
    }

    // Maps distance → circle scale [0.15 … 0.85]
    private var ringScale: CGFloat {
        guard let d = service.distance else { return 0.25 }
        let clamped = min(max(d, 0.3), 30.0)
        let t = log(clamped) / log(30.0)          // 0 (close) → 1 (far)
        return CGFloat(0.85 - t * 0.70)
    }

    private var proximityLabel: String {
        guard let d = service.distance else { return "No signal" }
        switch d {
        case ..<1.0:  return "Right here 🐱"
        case ..<3.0:  return "Very close"
        case ..<7.0:  return "Same room"
        case ..<15.0: return "Nearby"
        default:      return "Far away"
        }
    }

    // ── View ──────────────────────────────────────────────────────────────────
    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {

                // Status chip
                statusChip
                    .padding(.top, 16)
                    .padding(.horizontal, 20)

                Spacer()

                // Title
                VStack(spacing: 4) {
                    Text("🐾")
                        .font(.system(size: 44))
                    Text("Cat Tracker")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                // Proximity ring
                proximityRing
                    .frame(width: 240, height: 240)

                Text(proximityLabel)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.top, 22)

                Spacer()

                // Control buttons
                soundButtons
                    .padding(.horizontal, 24)

                // Daemon hint
                if !service.daemonReady {
                    Text("python3 controller.py --server")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.85))
                        .padding(.top, 14)
                        .multilineTextAlignment(.center)
                }

                Spacer().frame(height: 44)
            }
        }
        .onAppear { service.startPolling() }
    }

    // ── Sub-views ─────────────────────────────────────────────────────────────
    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.daemonReady ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(service.daemonReady ? "Daemon connected" : "Daemon offline")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(service.daemonReady ? .green : .red)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05))
        .cornerRadius(20)
    }

    private var proximityRing: some View {
        ZStack {
            // Static outer guide ring
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 1.5)

            // Animated proximity ring
            Circle()
                .stroke(ringColor.opacity(0.3), lineWidth: 2)
                .scaleEffect(ringScale * 1.15)

            // Filled dot that shrinks with distance
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [ringColor, ringColor.opacity(0.4)]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .scaleEffect(ringScale)
                .shadow(color: ringColor.opacity(0.6), radius: 12)

            // RSSI + distance overlay
            VStack(spacing: 5) {
                if let r = service.rssi {
                    Text("\(r) dBm")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Text("---")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                }
                if let d = service.distance {
                    Text(String(format: "≈ %.1f m", d))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: service.distance)
    }

    private var soundButtons: some View {
        HStack(spacing: 14) {
            Button {
                Task {
                    await service.playSound()
                    soundOn = true
                }
            } label: {
                Label("Play Sound", systemImage: "bell.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(soundOn ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(soundOn ? Color.yellow : Color.white.opacity(0.15))
                    .cornerRadius(15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color.white.opacity(soundOn ? 0 : 0.2), lineWidth: 1)
                    )
            }
            .disabled(!service.daemonReady)

            Button {
                Task {
                    await service.stopSound()
                    soundOn = false
                }
            } label: {
                Label("Stop", systemImage: "bell.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(Color.white.opacity(0.10))
                    .cornerRadius(15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
            .disabled(!service.daemonReady)
        }
    }
}

#Preview {
    ContentView()
}
