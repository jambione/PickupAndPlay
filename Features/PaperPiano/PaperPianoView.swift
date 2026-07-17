import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Haptics

/// Lightweight haptic helpers (no-ops on Mac Catalyst).
enum Haptics {
    static func success() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
    static func selection() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

// MARK: - Paper Piano View (Main Screen)

struct PaperPianoView: View {
    @StateObject private var camera = CameraSessionManager()
    @State private var showingPrintSheet = false
    @State private var showCalibrationHelp = false
    @State private var manualCalibrationMode = false
    @State private var manualCorners: [CGPoint] = []
    @State private var showKeyboard = true
    @Environment(\.dismiss) var dismiss
    private let keyboardHeight: CGFloat = 160

    private var isPlaying: Bool { camera.calibrationState == .calibrated }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // ONE camera preview persists across scanning → lock-on → play.
                // The previous design swapped whole view hierarchies (preview
                // included) per state, which made every transition flash/jump.
                CameraPreviewView(camera: camera) { pt, size in
                    if isPlaying {
                        camera.handleTap(at: pt, previewSize: size)
                    } else if manualCalibrationMode {
                        handleManualTap(pt, size: size)
                    }
                }

                if isPlaying {
                    KeyboardProjectionOverlay(calibration: camera.calibration,
                                              activeKeyIDs: Set(camera.activeNotes.map { $0.key.id }))
                        .allowsHitTesting(false)
                    FingertipOverlay(model: camera.overlayModel)
                        .allowsHitTesting(false)
                    NoteFlashOverlay(activeNotes: camera.activeNotes)
                    playTopBar
                } else {
                    RegistrationOverlay(camera: camera,
                                        manualMode: $manualCalibrationMode,
                                        manualCorners: $manualCorners,
                                        showHelp: $showCalibrationHelp)
                }

                ZoomBadge(zoom: camera.zoomFactor)
            }
            .frame(maxHeight: .infinity)
            .background(Color.black)

            if isPlaying {
                InstrumentPickerBar()
                keyboardHandleBar
                if showKeyboard {
                    ZStack {
                        Color(white: 0.07)
                        VirtualPianoView(activeNotes: camera.activeNotes) { key in
                            camera.triggerKey(key, velocity: 0.85)
                        }
                        .padding(.horizontal, 4).padding(.vertical, 6)
                        GeometryReader { geo in
                            NoteRippleOverlay(activeNotes: camera.activeNotes,
                                              containerSize: CGSize(width: geo.size.width, height: keyboardHeight))
                        }
                    }
                    .frame(height: keyboardHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: camera.calibrationState)
        .animation(.spring(response: 0.35), value: showKeyboard)
        .ignoresSafeArea(.all, edges: .bottom)
        .navigationTitle("Paper Piano")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.foregroundColor(.white)
            }
            ToolbarItem(placement: .automatic) {
                Button { showingPrintSheet = true } label: {
                    Label("Print Keyboard", systemImage: "printer.fill").foregroundColor(.white)
                }
            }
        }
        .sheet(isPresented: $showingPrintSheet) { PrintInstructionsView() }
        .sheet(isPresented: $showCalibrationHelp) { CalibrationHelpView() }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.calibrationState) {
            if camera.calibrationState == .calibrated {
                manualCalibrationMode = false
                manualCorners = []
            }
        }
    }

    private var playTopBar: some View {
        VStack {
            HStack {
                ActiveNoteBar(activeNotes: camera.activeNotes)
                Spacer()
                Button { camera.resetCalibration() } label: {
                    Image(systemName: "viewfinder.circle")
                        .font(.system(size: 22)).foregroundColor(.white.opacity(0.7))
                }
                .padding(.trailing, 16)
            }
            .padding(.top, 12).padding(.leading, 16)
            Spacer()
        }
    }

    private var keyboardHandleBar: some View {
        Button { showKeyboard.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: showKeyboard ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                Text(showKeyboard ? "Hide Keyboard" : "Show Keyboard")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white.opacity(0.6))
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(Color(white: 0.12))
        }
        .buttonStyle(.plain)
    }

    private func handleManualTap(_ pt: CGPoint, size: CGSize) {
        guard manualCorners.count < 4 else { return }
        manualCorners.append(pt)
        if manualCorners.count == 4 {
            camera.setCalibrationCorners(manualCorners.map {
                CGPoint(x: $0.x / size.width, y: $0.y / size.height)
            })
            camera.calibrationState = .calibrated
        }
    }
}

// MARK: - Registration Overlay

/// Everything shown while registering the keyboard: a highlight ring on each
/// recognized QR corner, a 4-corner checklist, the smoothed detected outline,
/// manual calibration, and the lock-on progress once all corners hold steady.
private struct RegistrationOverlay: View {
    @ObservedObject var camera: CameraSessionManager
    @Binding var manualMode: Bool
    @Binding var manualCorners: [CGPoint]
    @Binding var showHelp: Bool

    private static let markerOrder = ["TL", "TR", "BL", "BR"]
    private static let markerArrows = ["TL": "↖", "TR": "↗", "BL": "↙", "BR": "↘"]

    var body: some View {
        ZStack {
            GeometryReader { geo in
                if !manualMode && camera.foundMarkers.isEmpty && camera.detectedCorners.isEmpty {
                    ScanGuideOverlay(geo: geo, isAligning: false)
                }
                if !camera.detectedCorners.isEmpty {
                    DetectedRectOverlay(corners: camera.detectedCorners, geo: geo)
                }
                if !manualMode {
                    MarkerDotsOverlay(markers: camera.foundMarkers, geo: geo)
                }
                ForEach(manualCorners.indices, id: \.self) { i in
                    Circle().fill(Color.orange).frame(width: 16, height: 16)
                        .position(manualCorners[i])
                }
            }
            .allowsHitTesting(false)

            VStack {
                Spacer()
                statusCard
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            if camera.calibrationState == .aligned && !manualMode {
                LockProgressContent(camera: camera)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: manualMode ? "hand.tap.fill" : "qrcode.viewfinder")
                        .foregroundColor(.orange)
                    Text(statusText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                if manualMode {
                    Text("Tap the \(4 - manualCorners.count) remaining corners of the printed keyboard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    if !manualCorners.isEmpty {
                        Button("Reset corners") { manualCorners = []; camera.resetCalibration() }
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.orange)
                    }
                    Button("Back to auto-detect") { manualMode = false; manualCorners = [] }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.6))
                } else {
                    cornerChecklist
                    Button("Tap to calibrate manually") { manualMode = true }
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.orange)
                }
                // Camera authorization state (black preview usually means no access)
                if camera.authStatus == .denied || camera.authStatus == .restricted {
                    Button("Enable Camera Access") { camera.openSystemSettings() }
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.orange)
                } else if camera.authStatus != .authorized {
                    Text("Camera: \(camera.authStatus.rawValue)")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                }
                Button { showHelp = true } label: {
                    Label("Setup Help", systemImage: "questionmark.circle")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20).padding(.bottom, 30)
        .animation(.easeInOut(duration: 0.2), value: camera.foundMarkers.keys.sorted())
    }

    /// One chip per corner QR, lighting up green as each is recognized.
    private var cornerChecklist: some View {
        HStack(spacing: 12) {
            ForEach(Self.markerOrder, id: \.self) { name in
                let found = camera.foundMarkers[name] != nil
                HStack(spacing: 4) {
                    Image(systemName: found ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.system(size: 12, weight: .semibold))
                    Text(Self.markerArrows[name] ?? name)
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(found ? .green : .white.opacity(0.4))
            }
        }
    }

    private var statusText: String {
        if manualMode { return "Manual: tap each corner" }
        let count = camera.foundMarkers.count
        switch count {
        case 0:  return "Point at the printed keyboard"
        case 4:  return "All corners found — hold steady…"
        default: return "Found \(count) of 4 QR corners"
        }
    }
}

// MARK: - Marker Dots Overlay

/// A green ring over every QR corner the camera currently recognizes — direct
/// confirmation of what's seen and what's still missing.
private struct MarkerDotsOverlay: View {
    let markers: [String: CGPoint]
    let geo: GeometryProxy

    var body: some View {
        ZStack {
            ForEach(markers.keys.sorted(), id: \.self) { name in
                if let pt = markers[name] {
                    Circle()
                        .stroke(Color.green, lineWidth: 3)
                        .background(Circle().fill(Color.green.opacity(0.2)))
                        .frame(width: 36, height: 36)
                        .position(x: pt.x * geo.size.width, y: pt.y * geo.size.height)
                }
            }
        }
    }
}

// MARK: - Lock Progress

/// Shown once all four corners are stable: a short countdown, then play starts
/// automatically (with a success haptic + arpeggio cue).
private struct LockProgressContent: View {
    @ObservedObject var camera: CameraSessionManager
    @State private var lockProgress: CGFloat = 0
    private let lockDelay: TimeInterval = 0.75

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 20))
                Text("Keyboard locked — starting…")
                    .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(.white)
            }
            SwiftUI.ProgressView(value: lockProgress)
                .tint(.green)
                .frame(width: 180)
            Button("Re-scan") { camera.resetCalibration() }
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.orange)
        }
        .task {
            withAnimation(.linear(duration: lockDelay)) { lockProgress = 1 }
            try? await Task.sleep(nanoseconds: UInt64(lockDelay * 1_000_000_000))
            // Corners lost during the wait drop the state back to .scanning,
            // which removes this view and cancels the task — the guard is belt & braces.
            guard camera.calibrationState == .aligned else { return }
            camera.confirmAutoCalibration()
            Haptics.success()
            PianoAudioEngine.shared.playCalibrationCue()
        }
    }
}

// MARK: - Fingertip Overlay

/// Draws tracked fingertips over the camera feed. Observes only the isolated
/// frame-rate publisher, so 60 Hz updates re-render just this Canvas.
private struct FingertipOverlay: View {
    @ObservedObject var model: FingerOverlayModel

    var body: some View {
        Canvas { context, size in
            guard let frame = model.frame else { return }
            for dot in frame.fingers {
                let rect = CGRect(x: dot.location.x * size.width - 7,
                                  y: dot.location.y * size.height - 7,
                                  width: 14, height: 14)
                let color: Color = dot.isPressed ? .green : .yellow.opacity(0.85)
                context.fill(Ellipse().path(in: rect), with: .color(color))
            }
        }
    }
}

// MARK: - Scan Guide Overlay

private struct ScanGuideOverlay: View {
    let geo: GeometryProxy
    let isAligning: Bool

    var body: some View {
        let w = geo.size.width * 0.88
        let h = geo.size.height * 0.28
        let y = geo.size.height * 0.38
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .mask(
                    Rectangle()
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .frame(width: w, height: h)
                                .position(x: geo.size.width / 2, y: y + h / 2)
                                .blendMode(.destinationOut)
                        )
                        .compositingGroup()
                )
            RoundedRectangle(cornerRadius: 12)
                .stroke(isAligning ? Color.green : Color.orange,
                        style: StrokeStyle(lineWidth: 2.5, dash: isAligning ? [] : [10, 5]))
                .frame(width: w, height: h)
                .position(x: geo.size.width / 2, y: y + h / 2)
                .animation(.easeInOut(duration: 0.4), value: isAligning)
            Text("Point at the printed piano keyboard")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.black.opacity(0.6), in: Capsule())
                .position(x: geo.size.width / 2, y: y - 20)
        }
    }
}

// MARK: - Detected Rect Overlay

private struct DetectedRectOverlay: View {
    let corners: [CGPoint]
    let geo: GeometryProxy
    var body: some View {
        Canvas { ctx, _ in
            guard corners.count == 4 else { return }
            var path = Path()
            let scaled = corners.map { CGPoint(x: $0.x * geo.size.width, y: $0.y * geo.size.height) }
            path.move(to: scaled[0]); path.addLine(to: scaled[1])
            path.addLine(to: scaled[3]); path.addLine(to: scaled[2])
            path.closeSubpath()
            ctx.stroke(path, with: .color(.green.opacity(0.8)), style: StrokeStyle(lineWidth: 2))
            ctx.fill(path, with: .color(.green.opacity(0.1)))
        }
    }
}

// MARK: - Keyboard Projection Overlay

/// Projects the key layout onto the camera image through the inverse homography,
/// so the printed keyboard shows its boundaries and pressed keys glow in place.
private struct KeyboardProjectionOverlay: View {
    let calibration: KeyboardCalibration
    let activeKeyIDs: Set<Int>

    var body: some View {
        Canvas { ctx, size in
            guard calibration.isCalibrated else { return }

            func quad(_ frame: CGRect) -> Path? {
                let corners = [
                    CGPoint(x: frame.minX, y: frame.minY),
                    CGPoint(x: frame.maxX, y: frame.minY),
                    CGPoint(x: frame.maxX, y: frame.maxY),
                    CGPoint(x: frame.minX, y: frame.maxY),
                ].compactMap { calibration.previewPoint(fromKeyboard: $0) }
                guard corners.count == 4 else { return nil }
                var path = Path()
                path.move(to: CGPoint(x: corners[0].x * size.width, y: corners[0].y * size.height))
                for pt in corners.dropFirst() {
                    path.addLine(to: CGPoint(x: pt.x * size.width, y: pt.y * size.height))
                }
                path.closeSubpath()
                return path
            }

            for key in PaperPianoKey.layout {
                guard let path = quad(key.normalizedFrame) else { continue }
                if activeKeyIDs.contains(key.id) {
                    ctx.fill(path, with: .color(.indigo.opacity(0.4)))
                }
                let stroke: Color = key.isBlack ? .white.opacity(0.35) : .white.opacity(0.2)
                ctx.stroke(path, with: .color(stroke), lineWidth: key.isBlack ? 1.2 : 1.0)
            }
        }
    }
}

// MARK: - Note Flash Overlay

/// Flashes the newest note's name large near the top of the camera view.
private struct NoteFlashOverlay: View {
    let activeNotes: [ActiveNote]

    var body: some View {
        VStack {
            if let latest = activeNotes.last {
                Text(latest.key.displayName)
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .indigo, radius: 12)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 1.3).combined(with: .opacity),
                        removal: .opacity))
                    .id(latest.id)
            }
            Spacer()
        }
        .padding(.top, 46)
        .animation(.spring(response: 0.25), value: activeNotes.last?.id)
        .allowsHitTesting(false)
    }
}

// MARK: - Zoom Badge

/// Shows the current zoom while pinching, fading out shortly after.
private struct ZoomBadge: View {
    let zoom: CGFloat
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        VStack {
            HStack {
                Spacer()
                if visible {
                    Text(String(format: "%.1f×", zoom))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .transition(.opacity)
                }
            }
            Spacer()
        }
        .padding(.top, 12).padding(.trailing, 14)
        .allowsHitTesting(false)
        .onChange(of: zoom) {
            withAnimation(.easeIn(duration: 0.1)) { visible = true }
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.4)) { visible = false }
            }
        }
    }
}

// MARK: - Instrument Picker

/// Horizontal instrument chips. Selection persists across launches and is
/// applied to the audio engine on appear and on change.
private struct InstrumentPickerBar: View {
    @AppStorage("tapnote.instrument") private var instrumentRaw = InstrumentPreset.grandPiano.rawValue

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InstrumentPreset.allCases) { preset in
                    let selected = preset.rawValue == instrumentRaw
                    Button {
                        guard !selected else { return }
                        instrumentRaw = preset.rawValue
                        Haptics.selection()
                        PianoAudioEngine.shared.loadInstrument(preset)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: preset.sfSymbol)
                                .font(.system(size: 11, weight: .semibold))
                            Text(preset.displayName)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(selected ? .white : .white.opacity(0.65))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selected ? Color.indigo : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color(white: 0.1))
        .onAppear {
            if let preset = InstrumentPreset(rawValue: instrumentRaw) {
                PianoAudioEngine.shared.loadInstrument(preset)
            }
        }
    }
}

// MARK: - Print Instructions View

struct PrintInstructionsView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "printer.fill")
                        .font(.system(size: 56, weight: .light)).foregroundColor(.indigo).padding(.top, 20)
                    Text("Print Your Paper Piano")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 16) {
                        PrintStep(number: "1", title: "Get the PDF",
                                  description: "Tap below to share the 3-octave keyboard PDF — AirDrop it, save to Files, or print directly.")
                        PrintStep(number: "2", title: "Print big & flat",
                                  description: "A2 is ideal; tiling 2× A3 (or 4× A4) at 100% scale works too.")
                        PrintStep(number: "3", title: "Lay flat on a table",
                                  description: "Place in a well-lit area. Avoid glare from overhead lights.")
                        PrintStep(number: "4", title: "Point the camera",
                                  description: "Keep all four QR squares in frame — the keyboard locks on automatically.")
                        PrintStep(number: "5", title: "Play!",
                                  description: "Tap keys with your fingers — every finger plays its own note.")
                    }
                    .padding(.horizontal, 24)
                    if let pdfURL = Bundle.main.url(forResource: "TapNote_Keyboard_QR", withExtension: "pdf") {
                        ShareLink(item: pdfURL) {
                            Label("Share Piano PDF", systemImage: "square.and.arrow.up.fill")
                                .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.indigo).cornerRadius(14)
                        }
                        .padding(.horizontal, 24).padding(.bottom, 30)
                    } else {
                        Label("PDF unavailable", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14)).foregroundColor(.secondary)
                            .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("Setup Guide")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// Fixed: renamed `body` stored property to `description` — avoids redeclaration conflict
private struct PrintStep: View {
    let number: String
    let title: String
    let description: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(.white)
                .frame(width: 28, height: 28).background(Color.indigo).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(description).font(.system(size: 14)).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Calibration Help

struct CalibrationHelpView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "camera.metering.spot")
                    .font(.system(size: 52, weight: .light)).foregroundColor(.orange).padding(.top, 30)
                Text("Camera Calibration Tips")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                VStack(alignment: .leading, spacing: 14) {
                    TipRow(icon: "sun.max.fill", text: "Use bright, even lighting. Avoid harsh shadows.")
                    TipRow(icon: "rectangle.landscape.rotate", text: "Hold your device in landscape mode for best alignment.")
                    TipRow(icon: "arrow.up.and.down.and.arrow.left.and.right", text: "Keep the full keyboard in frame — all four QR squares visible. Pinch to zoom if needed.")
                    TipRow(icon: "hand.tap.fill", text: "If auto-detect fails, use Manual Calibration and tap each corner.")
                    TipRow(icon: "figure.wave", text: "Keep your hand above the keyboard so the camera can see your fingertips.")
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .navigationTitle("Tips")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct TipRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(.orange).frame(width: 24)
            Text(text).font(.system(size: 14)).foregroundColor(.secondary)
        }
    }
}
