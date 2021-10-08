//
//  CaptureSessionManager.swift
//  CameraKit
//
//  Created by cleexiang on 2021/8/30.
//

import Foundation
import AVFoundation
import UIKit

public extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeRight
        case .landscapeRight: self = .landscapeLeft
        default: return nil
        }
    }
    
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}

public enum CaptureError: Error {
    case invalidDevice
    case invalidData
}

public protocol CaptureSessionManagerDelegate: NSObjectProtocol {
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didCapturePhoto data: Data)
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didReceive sampleBuffer: CMSampleBuffer)
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didFailWithError error: Error)
}

public class CaptureSessionManager: NSObject {
    var captureSession = AVCaptureSession()
    let videoPreviewLayer: AVCaptureVideoPreviewLayer?
    let photoOutput = AVCapturePhotoOutput()
    var videoDeviceInput: AVCaptureDeviceInput?
    
    public weak var delegate: CaptureSessionManagerDelegate?
    private let sessionQueue = DispatchQueue(label: "com.queue.videoutput")
    public init?(videoPreviewLayer: AVCaptureVideoPreviewLayer, position: AVCaptureDevice.Position) {
        self.videoPreviewLayer = videoPreviewLayer
        super.init()
        var discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera, .builtInWideAngleCamera], mediaType: .video, position: .front)
        if position == .back {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInDualWideCamera, .builtInWideAngleCamera], mediaType: .video, position: .back)
        }
        guard let device = discoverySession.devices.first else {
            delegate?.captureSessionManager(self, didFailWithError: CaptureError.invalidDevice)
            return nil
        }
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo
        defer {
            captureSession.commitConfiguration()
            device.unlockForConfiguration()
        }
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard let deviceInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(deviceInput),
              captureSession.canAddOutput(photoOutput),
              captureSession.canAddOutput(videoOutput) else {
            delegate?.captureSessionManager(self, didFailWithError: CaptureError.invalidDevice)
            return nil
        }
        videoDeviceInput = deviceInput
        do {
            try device.lockForConfiguration()
            device.isSubjectAreaChangeMonitoringEnabled = true
        } catch {
            delegate?.captureSessionManager(self, didFailWithError: CaptureError.invalidDevice)
            return nil
        }
        captureSession.addInput(deviceInput)
        captureSession.addOutput(photoOutput)
        captureSession.addOutput(videoOutput)
        
        videoPreviewLayer.session = captureSession
        videoPreviewLayer.videoGravity = .resizeAspectFill
        
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    }
    
    public func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async {
                self.captureSession.startRunning()
            }
            break
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { [weak self] granted in
                self?.start()
                self?.sessionQueue.resume()
            })
        default:
            break
        }
    }
    
    public func stop() {
        captureSession.stopRunning()
    }
    
    internal func capturePhoto() {
        guard let connection = photoOutput.connection(with: .video), connection.isEnabled, connection.isActive else {
            delegate?.captureSessionManager(self, didFailWithError: CaptureError.invalidDevice)
            return
        }
        let photoSettings = AVCapturePhotoSettings()
        let pbpf = photoSettings.availablePreviewPhotoPixelFormatTypes[0]
        photoSettings.previewPhotoFormat = [
            kCVPixelBufferPixelFormatTypeKey as String: pbpf,
            kCVPixelBufferWidthKey as String: 480,
            kCVPixelBufferHeightKey as String: 640
            ]
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }
    
    internal func changeCamera() {
        guard let currentVideoDeviceInput = self.videoDeviceInput else { return }
        let currentVideoDevice = currentVideoDeviceInput.device
        sessionQueue.async {
            let currentPosition = currentVideoDevice.position
            let backVideoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
                                                                                   mediaType: .video, position: .back)
            let frontVideoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera, .builtInWideAngleCamera],
                                                                                    mediaType: .video, position: .front)
            var newVideoDevice: AVCaptureDevice? = nil
            switch currentPosition {
            case .unspecified, .front:
                newVideoDevice = backVideoDeviceDiscoverySession.devices.first
            case .back:
                newVideoDevice = frontVideoDeviceDiscoverySession.devices.first
            @unknown default:
                print("Unknown capture position. Defaulting to back, dual-camera.")
                newVideoDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            }
            if let videoDevice = newVideoDevice {
                do {
                    let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                    self.captureSession.beginConfiguration()
                    self.captureSession.removeInput(currentVideoDeviceInput)
                    
                    if self.captureSession.canAddInput(videoDeviceInput) {
                        self.captureSession.addInput(videoDeviceInput)
                        self.videoDeviceInput = videoDeviceInput
                    } else {
                        self.captureSession.addInput(currentVideoDeviceInput)
                    }
                    self.captureSession.commitConfiguration()
                } catch {
                    self.delegate?.captureSessionManager(self, didFailWithError: CaptureError.invalidDevice)
                }
            } else {
                self.delegate?.captureSessionManager(self, didFailWithError: CaptureError.invalidDevice)
            }
        }
    }
}

extension CaptureSessionManager: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let err = error {
            DispatchQueue.main.async {
                self.delegate?.captureSessionManager(self, didFailWithError: err)
            }
        } else {
            if let data = photo.fileDataRepresentation() {
                self.delegate?.captureSessionManager(self, didCapturePhoto: data)
            } else {
                self.delegate?.captureSessionManager(self, didFailWithError: CaptureError.invalidData)
            }
        }
    }
}

extension CaptureSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        DispatchQueue.main.async {
            self.delegate?.captureSessionManager(self, didReceive: sampleBuffer)
        }
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
    }
}
