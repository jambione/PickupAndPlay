import SwiftUI
import AVFoundation

// MARK: - Cross-platform Camera Preview

#if os(iOS)
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var camera: CameraSessionManager
    var onTap: ((CGPoint, CGSize) -> Void)?

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if let layer = camera.previewLayer {
            layer.frame = uiView.bounds
            if layer.superlayer == nil {
                uiView.layer.insertSublayer(layer, at: 0)
            }
        }
        context.coordinator.onTap = onTap
        context.coordinator.viewSize = uiView.bounds.size
    }

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    class Coordinator: NSObject {
        let camera: CameraSessionManager
        var onTap: ((CGPoint, CGSize) -> Void)?
        var viewSize: CGSize = .zero
        private var pinchBaseZoom: CGFloat = 1.0

        init(camera: CameraSessionManager) { self.camera = camera }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let pt = gesture.location(in: gesture.view)
            onTap?(pt, viewSize)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchBaseZoom = camera.zoomFactor
            case .changed:
                camera.setZoom(pinchBaseZoom * gesture.scale)
            default:
                break
            }
        }
    }
}

class CameraPreviewUIView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}

#elseif os(macOS)
import AppKit

struct CameraPreviewView: NSViewRepresentable {
    @ObservedObject var camera: CameraSessionManager
    var onTap: ((CGPoint, CGSize) -> Void)?

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleClick(_:)))
        view.addGestureRecognizer(click)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if let layer = camera.previewLayer {
            layer.frame = nsView.bounds
            if layer.superlayer == nil {
                nsView.layer?.insertSublayer(layer, at: 0)
            }
        }
        context.coordinator.onTap = onTap
        context.coordinator.viewSize = nsView.bounds.size
    }

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    class Coordinator: NSObject {
        let camera: CameraSessionManager
        var onTap: ((CGPoint, CGSize) -> Void)?
        var viewSize: CGSize = .zero

        init(camera: CameraSessionManager) { self.camera = camera }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            let pt = gesture.location(in: gesture.view)
            // NSView has flipped coords — convert
            let flippedPt = CGPoint(x: pt.x, y: viewSize.height - pt.y)
            onTap?(flippedPt, viewSize)
        }
    }
}

class CameraPreviewNSView: NSView {
    override var isFlipped: Bool { false }
    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }
}
#endif
