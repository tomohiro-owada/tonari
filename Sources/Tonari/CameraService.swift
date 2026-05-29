import AVFoundation
import AppKit
import Foundation

/// Captures a single frame from the default video device.
///
/// Privacy: callers should discard the returned `Data` as soon as it has been
/// analyzed. We don't persist anything from here.
final class CameraService: NSObject {

    enum CameraError: LocalizedError {
        case notAuthorized
        case noDevice
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "カメラへのアクセスが許可されていません"
            case .noDevice: return "利用可能なカメラデバイスがありません"
            case .captureFailed(let s): return "撮影に失敗: \(s)"
            }
        }
    }

    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var currentDelegate: PhotoDelegate?

    // MARK: - Permission

    func requestAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        @unknown default: return false
        }
    }

    // MARK: - Setup

    private func ensureSession() throws {
        if session != nil { return }
        let s = AVCaptureSession()
        s.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw CameraError.captureFailed("input not addable") }
        s.addInput(input)
        let out = AVCapturePhotoOutput()
        guard s.canAddOutput(out) else { throw CameraError.captureFailed("output not addable") }
        s.addOutput(out)
        self.session = s
        self.photoOutput = out
    }

    // MARK: - Capture

    /// Returns JPEG bytes of a single captured frame.
    func captureOneJPEG() async throws -> Data {
        guard await requestAccess() else { throw CameraError.notAuthorized }
        try ensureSession()
        guard let session, let photoOutput else {
            throw CameraError.captureFailed("session not initialized")
        }

        if !session.isRunning {
            session.startRunning()
            // Let auto-exposure stabilize a bit
            try? await Task.sleep(for: .milliseconds(800))
        }

        let delegate = PhotoDelegate()
        self.currentDelegate = delegate
        defer {
            self.currentDelegate = nil
            session.stopRunning()
        }

        let settings = AVCapturePhotoSettings(
            format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
        )

        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    var continuation: CheckedContinuation<Data, Error>?

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer { continuation = nil }
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: CameraService.CameraError.captureFailed("no data"))
        }
    }
}
