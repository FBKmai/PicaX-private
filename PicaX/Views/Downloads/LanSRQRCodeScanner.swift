#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// All mutable capture state belongs to the serial queue, not the main actor.
nonisolated private final class LanSRCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "moye.PicaX.lan-qr-camera")
    private let onCode: @Sendable (String) -> Void
    private let onError: @Sendable (String) -> Void
    private var configured = false
    private var stopped = true

    init(onCode: @escaping @Sendable (String) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
    }
    func start() {
        queue.async { [self] in
            stopped = false
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                    queue.async { [self] in
                        guard !stopped else { return }
                        if granted { configureAndStart() }
                        else { onError("未允许相机权限。可以关闭扫码，改为粘贴电脑上的连接信息。") }
                    }
                }
            default: onError("相机权限不可用。请到系统设置允许相机，或改为粘贴连接信息。")
            }
        }
    }
    private func configureAndStart() {
        guard !stopped else { return }
        if !configured {
            do {
                guard let device = AVCaptureDevice.default(for: .video) else {
                    throw LanSRError.message("此设备没有可用相机；请改为粘贴连接信息。")
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    throw LanSRError.message("无法配置扫码相机。")
                }
                session.addInput(input)
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: queue)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    throw LanSRError.message("此设备不支持二维码扫描。")
                }
                output.metadataObjectTypes = [.qr]
                configured = true
            } catch { onError(error.localizedDescription); return }
        }
        session.startRunning()
    }
    func stop() {
        queue.async { [self] in stopped = true; session.stopRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !stopped, let text = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        guard text.utf8.count <= 4096 else { onError("二维码内容过长，不是 PicaX 配对信息。"); return }
        stopped = true
        session.stopRunning()
        onCode(text)
    }
}

@MainActor
private final class LanSRScannerController: UIViewController {
    private let camera: LanSRCamera
    private var preview: AVCaptureVideoPreviewLayer?
    init(onCode: @escaping @MainActor @Sendable (String) -> Void, onError: @escaping @MainActor @Sendable (String) -> Void) {
        camera = LanSRCamera(onCode: { text in Task { @MainActor in onCode(text) } },
                             onError: { message in Task { @MainActor in onError(message) } })
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: camera.session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); camera.start() }
    override func viewWillDisappear(_ animated: Bool) { camera.stop(); super.viewWillDisappear(animated) }
    func stop() { camera.stop() }
}

private struct LanSRScannerPreview: UIViewControllerRepresentable {
    let onCode: @MainActor @Sendable (String) -> Void
    let onError: @MainActor @Sendable (String) -> Void
    func makeUIViewController(context: Context) -> LanSRScannerController {
        LanSRScannerController(onCode: onCode, onError: onError)
    }
    func updateUIViewController(_ controller: LanSRScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: LanSRScannerController, coordinator: ()) { controller.stop() }
}

struct LanSRQRCodeScanner: View {
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    let onCode: @MainActor @Sendable (String) -> Void
    var body: some View {
        PicaxNavigationContainer {
            ZStack(alignment: .bottom) {
                LanSRScannerPreview(onCode: { text in onCode(text); dismiss() }, onError: { errorMessage = $0 })
                Text(errorMessage ?? "扫描电脑终端上的 PicaX 配对二维码；扫描后仍需确认连接。")
                    .padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .navigationTitle("扫描电脑二维码")
            .picaxNavigationBarTitleDisplayModeInline()
            .toolbar { ToolbarItem(placement: .picaxTopBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }
}
#endif
