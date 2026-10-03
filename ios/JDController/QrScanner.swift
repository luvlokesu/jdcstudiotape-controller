import UIKit
import AVFoundation

/// Escáner del QR que enseña el PC («http://192.168.1.23/»): cámara trasera, se cierra al leer uno.
final class QrScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String?) -> Void)?
    private let session = AVCaptureSession()
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            DispatchQueue.main.async { self.finish(nil) }; return
        }
        session.addInput(input)
        let out = AVCaptureMetadataOutput()
        guard session.canAddOutput(out) else { DispatchQueue.main.async { self.finish(nil) }; return }
        session.addOutput(out)
        out.setMetadataObjectsDelegate(self, queue: .main)
        out.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)

        let hint = UILabel()
        hint.text = "Apunta al QR de la pantalla del PC"
        hint.textColor = .white
        hint.font = .boldSystemFont(ofSize: 17)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        let close = UIButton(type: .system)
        close.setTitle("Cancelar", for: .normal)
        close.titleLabel?.font = .boldSystemFont(ofSize: 18)
        close.tintColor = .white
        close.backgroundColor = UIColor(red: 1, green: 0.18, blue: 0.54, alpha: 1)
        close.layer.cornerRadius = 22
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        view.addSubview(hint)
        view.addSubview(close)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            close.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            close.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            close.widthAnchor.constraint(equalToConstant: 180),
            close.heightAnchor.constraint(equalToConstant: 44),
        ])
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach { $0.frame = view.bounds }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue { finish(s) }
    }

    @objc private func cancel() { finish(nil) }

    private func finish(_ text: String?) {
        guard !done else { return }
        done = true
        DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
        dismiss(animated: true) { self.onResult?(text) }
    }
}
