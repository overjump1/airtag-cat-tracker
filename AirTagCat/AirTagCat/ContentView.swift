import SwiftUI

struct ContentView: View {
    @StateObject private var service = AirTagService()
    @State private var renamingID:  String? = nil
    @State private var renameText:  String  = ""

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Header bar ────────────────────────────────────────────────
                HStack(spacing: 6) {
                    if service.state == .scanning {
                        ProgressView().scaleEffect(0.6).tint(.orange)
                    } else {
                        Circle()
                            .fill(service.state == .ready ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                    }
                    Text(service.state.label)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                    Spacer()
                    Text("AirTagCat 🐾")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.15)

                // ── Content ───────────────────────────────────────────────────
                if service.tags.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        ProgressView().tint(.orange).scaleEffect(1.2)
                        Text("Looking for your AirTags…")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(service.tags) { tag in
                                TagCard(
                                    tag: tag,
                                    onPlay:   { service.playSound(tagID: tag.id) },
                                    onStop:   { service.stopSound(tagID: tag.id) },
                                    onRename: {
                                        renameText = tag.name
                                        renamingID = tag.id
                                    }
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { service.start() }
        .sheet(isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            RenameSheet(text: $renameText) {
                if let id = renamingID { service.setName(renameText, forTagID: id) }
                renamingID = nil
            } onCancel: {
                renamingID = nil
            }
        }
    }
}

// MARK: - TagCard

struct TagCard: View {
    let tag: FoundTag
    let onPlay:   () -> Void
    let onStop:   () -> Void
    let onRename: () -> Void

    private var ringColor: Color {
        guard let d = tag.distance else { return .gray }
        switch d {
        case ..<1:   return .green
        case ..<3:   return Color(red: 0.4, green: 0.9, blue: 0.5)
        case ..<7:   return .yellow
        case ..<15:  return .orange
        default:     return .red
        }
    }

    private var ringScale: CGFloat {
        guard let d = tag.distance else { return 0.2 }
        let c = min(max(d, 0.3), 30.0)
        return CGFloat(0.85 - (log(c) / log(30.0)) * 0.70)
    }

    private var proximityLabel: String {
        guard let d = tag.distance else { return "Searching…" }
        switch d {
        case ..<1:   return "Right here 🐱"
        case ..<3:   return "Very close"
        case ..<7:   return "Same room"
        case ..<15:  return "Nearby"
        default:     return "Far away"
        }
    }

    var body: some View {
        VStack(spacing: 16) {

            // Name + rename button
            HStack(alignment: .center) {
                Text(tag.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.leading, 4)
                }
                Spacer()
                if let rssi = tag.rssi {
                    Text("\(rssi) dBm")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            // Proximity ring
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 130, height: 130)
                Circle()
                    .fill(ringColor.opacity(0.14))
                    .frame(width: 130 * ringScale, height: 130 * ringScale)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: tag.distance)
                VStack(spacing: 3) {
                    Text("🐾").font(.system(size: 26))
                    if let d = tag.distance {
                        Text(String(format: "≈ %.1f m", d))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }

            Text(proximityLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ringColor)

            // Sound controls
            HStack(spacing: 10) {
                Button(action: onPlay) {
                    Label("Play Sound", systemImage: "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(tag.soundOn ? .orange : .white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(tag.soundOn
                            ? Color.orange.opacity(0.22)
                            : Color.white.opacity(0.09))
                        .clipShape(Capsule())
                }
                if tag.soundOn {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tag.soundOn)
        }
        .padding(16)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    @Binding var text: String
    let onSave:   () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("Label") {
                    TextField("e.g. Felix's collar", text: $text)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("This name is saved only on this device.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Rename AirTag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
