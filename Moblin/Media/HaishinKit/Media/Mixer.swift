import AVFoundation
import SwiftUI

func makeCaptureSession() -> AVCaptureSession {
    let session = AVCaptureSession()
    if session.isMultitaskingCameraAccessSupported {
        session.isMultitaskingCameraAccessEnabled = true
    }
    return session
}

protocol MixerDelegate: AnyObject {
    func mixer(audioLevel: Float, numberOfAudioChannels: Int, presentationTimestamp: Double)
    func mixerVideo(presentationTimestamp: Double)
    func mixerVideo(failedEffect: String?)
    func mixerVideo(lowFpsImage: Data?, frameNumber: UInt64)
    func mixerRecorderFinished()
    func mixerRecorderError()
    func mixer(findVideoFormatError: String, activeFormat: String)
    func mixer(audioSampleBuffer: CMSampleBuffer)
    func mixerNoTorch()
    func getNetStreamDelegate() -> NetStreamDelegate?
}

class Mixer {
    weak var delegate: (any MixerDelegate)?

    let audio = AudioUnit()
    let video = VideoUnit()
    let recorder = Recorder()

    init() {
        audio.mixer = self
        video.mixer = self
        recorder.delegate = self
    }

    func attachCamera(_ device: AVCaptureDevice?, _ replaceVideo: UUID?) throws {
        try video.attach(device, replaceVideo)
    }

    func attachAudio(_ device: AVCaptureDevice?, _ replaceAudio: UUID?) throws {
        try audio.attach(device, replaceAudio)
    }

    func startEncoding(_ delegate: any AudioCodecDelegate & VideoCodecDelegate) {
        video.startEncoding(delegate)
        audio.startEncoding(delegate)
    }

    func stopEncoding() {
        video.stopEncoding()
        audio.stopEncoding()
    }

    func startRunning() {
        video.startRunning()
        audio.startRunning()
    }

    func stopRunning() {
        video.stopRunning()
        audio.stopRunning()
    }

    func setReplaceAudioDrift(cameraId: UUID, drift: Double) {
        audio.setReplaceAudioDrift(cameraId: cameraId, drift: drift)
    }

    func setReplaceVideoDrift(cameraId: UUID, drift: Double) {
        video.setReplaceVideoDrift(cameraId: cameraId, drift: drift)
    }
}

extension Mixer: IORecorderDelegate {
    func recorderFinished() {
        delegate?.mixerRecorderFinished()
    }

    func recorderError() {
        delegate?.mixerRecorderError()
    }
}
