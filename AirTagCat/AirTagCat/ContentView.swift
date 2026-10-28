import SwiftUI

struct ContentView: View {
    @StateObject private var service = AirTagService()

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

    private var ringScale: CGFloat {
        guard let d = service.distance else { return 0.18 }
        let clamped = min(max(d, 0.3), 30.0)
        return CGFloat(0.85 - (log(clamped) / log(30.0)) * 0.70)
    }

    private var proximityLabel: String {
        guard let d = service.distance else { return "Searching…" }
        switch d {
        case ..<1.0:  return "Right here \u{1F431}"
        case ..<3.0:  return "Very close"
        case ..<7.0:  return "Same room"
        case ..<15.0: return "Nearby"
        default:      return "Far away"
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Status chip ────────────────────────────────────────────────
                HStack(spacing: 6) {
                    if service.state.isScanning {
                        ProgressView().scaleEffect(0.6).tint(.orange)
                    } else {
                        Circle()
                            .fill(service.state.isReady ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                    }
                    Text(service.state.label)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(service.state.isReady ? .green : .orange)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.white.opacity(0.05)).cornerRadius(20)
                .padding(.top, 16).padding(.horizontal, 20)

                Spacer()

                // ── Title ──────────────────────────────────────────────────────
                VStack(spacing: 4) {
                    Text("\u{1F43E}").font(.system(size: 44))
                    Text("Cat Tracker")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                // ── Proximity ring ─────────────────────────────────────────────
                ZStack {
                    Circle().stroke(Color.white.opacity(0.06), lineWidth: 1.5)

                    // Outer halo
                    Circle()
                        .stroke(ringColor.opacity(0.25), lineWidth: 2)
                        .scaleEffect(ringScale * 1.18)

                    // Filled dot
                    Circle()
                        .fill(RadialGradient(
                            gradient: Gradient(colors: [ringColor, ringColor.opacity(0.35)]),
                            center: .center, startRadius: 0, endRadius: 60
                        ))
                        .scaleEffect(ringScale)
                        .shadow(color: ringColor.opacity(0.55), radius: 14)

                    // RSSI + distance label
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
                            Text(String(format: "\u{2248} %.1f m", d))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                }
                .frame(width: 240, height: 240)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: service.distance)

                Text(proximityLabel)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.top, 22)

                Spacer()

                // ── Sound buttons ──────────────────────────────────────────────
                HStack(spacing: 14) {
                    Button {
                        service.playSound()
                    } label: {
                        Label("Play Sound", systemImage: "bell.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(service.soundOn ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(service.soundOn ? Color.yellow : Color.white.opacity(0.14))
                            .cornerRadius(15)
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.white.opacity(service.soundOn ? 0 : 0.2), lineWidth: 1)
                            )
                    }
                    .disabled(!service.state.isReady)

                    Button {
                        service.stopSound()
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
                    .disabled(!service.state.isReady)
                }
                .padding(.horizontal, 24)

                Spacer().frame(height: 44)
            }
        }
        .onAppear { service.start() }
    }
}

#Preview { ContentView() }
