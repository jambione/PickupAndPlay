import SwiftUI

// MARK: - Paper Piano Entry Card
// Add this to HomeView's ScrollView to surface the Paper Piano feature.

struct PaperPianoEntryCard: View {
    @State private var showPaperPiano = false

    var body: some View {
        Button {
            showPaperPiano = true
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.indigo, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)

                    Image(systemName: "pianokeys.inverse")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Paper Piano")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                        Text("NEW")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .clipShape(Capsule())
                    }
                    Text("Print a keyboard, play with your fingers — camera does the rest")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Label("Camera", systemImage: "camera.fill")
                        Label("MIDI Audio", systemImage: "waveform")
                        Label("Print", systemImage: "printer")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.indigo)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(16)
            .background(Color(.systemBackground))
            .cornerRadius(18)
            .shadow(color: .indigo.opacity(0.12), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .sheet(isPresented: $showPaperPiano) {
            NavigationStack {
                PaperPianoView()
            }
        }
    }
}
