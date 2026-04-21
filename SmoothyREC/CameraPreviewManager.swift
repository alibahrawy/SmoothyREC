//
//  CameraPreviewManager.swift
//  SmoothyREC
//
//  Live camera preview manager for pre-recording camera check
//

import Foundation
@preconcurrency import AVFoundation
import SwiftUI

/// Manages a lightweight AVCaptureSession for live camera preview (no recording)
@MainActor
class CameraPreviewManager: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var isRunning = false
    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var error: CameraPreviewError?

    // MARK: - Private Properties

    private var captureSession: AVCaptureSession?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentCameraID: String?

    private let sessionQueue = DispatchQueue(label: "com.smoothyrec.camerapreview", qos: .userInitiated)
    private let ciContext = CIContext()

    // MARK: - Error Types

    enum CameraPreviewError: Error, LocalizedError {
        case permissionDenied
        case cameraNotAvailable
        case sessionSetupFailed
        case inputDeviceNotAvailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Camera permission denied. Please enable it in System Settings."
            case .cameraNotAvailable:
                return "Selected camera is not available."
            case .sessionSetupFailed:
                return "Failed to setup camera preview session."
            case .inputDeviceNotAvailable:
                return "Camera input device is no longer available."
            }
        }
    }

    // MARK: - Public Methods

    /// Starts camera preview for the specified camera
    func startPreview(camera: Camera?) async {
        // Stop existing preview first
        await stopPreview()

        guard let camera = camera else {
            return
        }

        // Check permission
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            error = .permissionDenied
            return
        }

        currentCameraID = camera.uniqueID

        do {
            try await setupCaptureSession(camera: camera)
            await startSession()
            isRunning = true
            error = nil
        } catch let previewError as CameraPreviewError {
            error = previewError
            isRunning = false
        } catch {
            self.error = .sessionSetupFailed
            isRunning = false
        }
    }

    /// Stops the camera preview
    func stopPreview() async {
        guard captureSession != nil else { return }

        await stopSession()

        captureSession = nil
        videoInput = nil
        videoOutput = nil
        currentCameraID = nil
        currentFrame = nil

        isRunning = false
    }

    /// Switches to a different camera
    func switchCamera(to camera: Camera?) async {
        // If same camera, do nothing
        if let camera = camera, camera.uniqueID == currentCameraID {
            return
        }

        // Stop current and start new
        await startPreview(camera: camera)
    }

    // MARK: - Private Setup Methods

    private func setupCaptureSession(camera: Camera) async throws {
        // Find the AVCaptureDevice
        guard let device = AVCaptureDevice(uniqueID: camera.uniqueID) else {
            throw CameraPreviewError.cameraNotAvailable
        }

        // Create capture session
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Create input
        do {
            videoInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraPreviewError.inputDeviceNotAvailable
        }

        guard let videoInput = videoInput else {
            throw CameraPreviewError.inputDeviceNotAvailable
        }

        // Add input to session
        guard session.canAddInput(videoInput) else {
            throw CameraPreviewError.sessionSetupFailed
        }
        session.addInput(videoInput)

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        // Create output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput?.alwaysDiscardsLateVideoFrames = true

        // Set pixel format
        videoOutput?.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        guard let videoOutput = videoOutput else {
            throw CameraPreviewError.sessionSetupFailed
        }

        guard session.canAddOutput(videoOutput) else {
            throw CameraPreviewError.sessionSetupFailed
        }
        session.addOutput(videoOutput)

        self.captureSession = session
    }

    private func startSession() async {
        guard let session = captureSession else { return }

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    private func stopSession() async {
        guard let session = captureSession else { return }

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraPreviewManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Create CIImage from pixel buffer
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)

        // Mirror horizontally for selfie-style preview
        let mirroredImage = ciImage.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: ciImage.extent.width, y: 0))

        // Create CGImage
        guard let cgImage = ciContext.createCGImage(mirroredImage, from: mirroredImage.extent) else { return }

        // Convert to NSImage on main thread
        Task { @MainActor in
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            let nsImage = NSImage(cgImage: cgImage, size: size)
            self.currentFrame = nsImage
        }
    }
}

// MARK: - SwiftUI Camera Preview View

/// SwiftUI view that displays the live camera preview
struct CameraPreviewView: View {
    @ObservedObject var previewManager: CameraPreviewManager
    let height: CGFloat

    var body: some View {
        ZStack {
            if let frame = previewManager.currentFrame {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.9))

                    Image(nsImage: frame)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(1)
                }
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            } else if previewManager.isRunning {
                // Loading state
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.8))

                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                        Text("Starting camera...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: height)
            } else {
                // No preview available
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.controlBackgroundColor))

                    VStack(spacing: 8) {
                        Image(systemName: "video.slash.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("Camera preview unavailable")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        if let error = previewManager.error {
                            Text(error.localizedDescription)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                }
                .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview Support

extension CameraPreviewManager {
    static var preview: CameraPreviewManager {
        let manager = CameraPreviewManager()
        return manager
    }
}
