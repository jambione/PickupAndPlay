import SwiftUI
import AVFoundation

// MARK: - Paper Piano View (Main Screen)

struct PaperPianoView: View {
    @StateObject private var camera = CameraSessionManager()
    @State private var showingPrintSheet = false
    @State private var showCalibrationHelp = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.calibrationState {
            case .idle, .scanning:
                ScanningView(camera: camera, showHelp: $showCalibrationHelp)
            case .aligned:
                AlignmentConfirmView(camera: camera)
            case .calibrated:
                PlayView(camera: camera, showPrint: $showingPrintSheet)
            }
        }
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
    }
}

// MARK: - Scanning View

private struct ScanningView: View {
    @ObservedObject var camera: CameraSessionManager
    @Binding var showHelp: Bool
    @State private var manualCalibrationMode = false
    @State private var manualCorners: [CGPoint] = []

    var body: some View {
        ZStack {
            GeometryReader { geo in
                CameraPreviewView(camera: camera) { pt, size in
                    if manualCalibrationMode { handleManualTap(pt, size: size) }
                }
                .ignoresSafeArea()
                ScanGuideOverlay(geo: geo, isAligning: camera.calibrationState == .scanning)
                if !camera.detectedCorners.isEmpty {
                    DetectedRectOverlay(corners: camera.detectedCorners, geo: geo)
                }
                ForEach(manualCorners.indices, id: \.self) { i in
                    Circle().fill(Color.orange).frame(width: 16, height: 16).position(manualCorners[i])
                }
            }
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder").foregroundColor(.orange)
                        Text(statusText)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    if manualCalibrationMode {
                        Text("Tap the \(4 - manualCorners.count) remaining corners of the printed keyboard")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                        if !manualCorners.isEmpty {
                            Button("Reset corners") { manualCorners = []; camera.resetCalibration() }
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.orange)
                        }
                    } else {
                        Button("Tap to calibrate manually") { manualCalibrationMode = true }
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
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
        }
        .onChange(of: camera.calibrationState) { }
    }

    private var statusText: String {
        if manualCalibrationMode { return "Manual: tap each corner" }
        switch camera.calibrationState {
        case .idle: return "Looking for printed keyboard…"
        case .scanning: return "Scanning… hold steady"
        default: return "Keyboard detected!"
        }
    }

    private func handleManualTap(_ pt: CGPoint, size: CGSize) {
        guard manualCorners.count < 4 else { return }
        manualCorners.append(pt)
        if manualCorners.count == 4 {
            camera.calibration.corners = manualCorners.map {
                CGPoint(x: $0.x / size.width, y: $0.y / size.height)
            }
            camera.calibrationState = .calibrated
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

// MARK: - Alignment Confirm View

private struct AlignmentConfirmView: View {
    @ObservedObject var camera: CameraSessionManager
    var body: some View {
        ZStack {
            CameraPreviewView(camera: camera, onTap: nil).ignoresSafeArea()
            GeometryReader { geo in DetectedRectOverlay(corners: camera.detectedCorners, geo: geo) }
            VStack {
                Spacer()
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 20))
                        Text("Keyboard detected!")
                            .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(.white)
                    }
                    Text("Does the green outline match your printed keyboard?")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Retry") { camera.resetCalibration() }
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.orange)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(Color.white.opacity(0.1), in: Capsule())
                        Button("Looks Good — Start Playing!") { camera.confirmAutoCalibration() }
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(Color.indigo, in: Capsule())
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
        }
    }
}

// MARK: - Play View

private struct PlayView: View {
    @ObservedObject var camera: CameraSessionManager
    @Binding var showPrint: Bool
    @State private var showKeyboard = true
    private let keyboardHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreviewView(camera: camera) { pt, size in camera.handleTap(at: pt, previewSize: size) }
                GeometryReader { geo in
                    if let result = camera.latestFingerResult {
                        ForEach(result.fingerTips.indices, id: \.self) { i in
                            let pt = result.fingerTips[i]
                            Circle().fill(Color.yellow.opacity(0.85)).frame(width: 14, height: 14)
                                .shadow(color: .yellow, radius: 4)
                                .position(x: pt.x * geo.size.width, y: pt.y * geo.size.height)
                        }
                    }
                }
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
            .frame(maxHeight: .infinity)

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
        .animation(.spring(response: 0.35), value: showKeyboard)
        .ignoresSafeArea(.all, edges: .bottom)
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
                        PrintStep(number: "1", title: "Download the PDF",
                                  description: "Tap below to share the 3-octave piano keyboard PDF.")
                        PrintStep(number: "2", title: "Print on A2 paper",
                                  description: "Best results on A2. Or tile on 2 A3 sheets side by side.")
                        PrintStep(number: "3", title: "Lay flat on a table",
                                  description: "Place in a well-lit area. Avoid glare from overhead lights.")
                        PrintStep(number: "4", title: "Open the camera",
                                  description: "Tap 'Start Camera', align the orange corners.")
                        PrintStep(number: "5", title: "Play!",
                                  description: "Tap or hover your fingers — the app detects and plays each note.")
                    }
                    .padding(.horizontal, 24)
                    Button { } label: {
                        Label("Download Piano PDF", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.indigo).cornerRadius(14)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 30)
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
                    TipRow(icon: "arrow.up.and.down.and.arrow.left.and.right", text: "Keep the full keyboard in frame — all orange corners visible.")
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
