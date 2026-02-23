import AVFoundation
import Accelerate
import CoreAudio

final class AudioEngine: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 48000
    private var levelCallback: ((Float) -> Void)?
    private var deviceChangeListener: NSObjectProtocol?

    /// Request microphone permission (call before first recording)
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        owLog("[AudioEngine] Current mic permission: \(status.rawValue)")
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return false
    }

    func startRecording(levelCallback: @escaping (Float) -> Void) {
        self.levelCallback = levelCallback
        lock.lock()
        samples = []
        lock.unlock()

        // Reset engine to pick up current default input device
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputSampleRate = format.sampleRate
        owLog("[AudioEngine] Recording format: \(format.sampleRate)Hz, \(format.channelCount)ch, device: \(inputNode.auAudioUnit.deviceID)")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // Calculate RMS level
            var rms: Float = 0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
            levelCallback(rms)

            // Accumulate mono samples (channel 0)
            let channelSamples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            self.lock.lock()
            self.samples.append(contentsOf: channelSamples)
            self.lock.unlock()
        }

        do {
            try engine.start()
            owLog("[AudioEngine] Engine started")
        } catch {
            owLog("[AudioEngine] Failed to start: \(error)")
        }
    }

    func stopRecording() -> [Float]? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let captured = samples
        samples = []
        lock.unlock()

        guard !captured.isEmpty else { return nil }

        // Resample to 16kHz mono for WhisperKit
        return resampleTo16kHz(captured, fromRate: inputSampleRate)
    }

    // MARK: - Resampling

    private func resampleTo16kHz(_ input: [Float], fromRate: Double) -> [Float]? {
        let targetRate: Double = 16000

        // Already at target rate
        if abs(fromRate - targetRate) < 1.0 {
            return input
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: fromRate,
            channels: 1,
            interleaved: false
        ),
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        // Create input buffer
        let inputFrameCount = AVAudioFrameCount(input.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            return nil
        }
        inputBuffer.frameLength = inputFrameCount
        if let dest = inputBuffer.floatChannelData?[0] {
            input.withUnsafeBufferPointer { src in
                dest.initialize(from: src.baseAddress!, count: input.count)
            }
        }

        // Create output buffer
        let ratio = targetRate / fromRate
        let outputFrameCount = AVAudioFrameCount(Double(input.count) * ratio) + 100
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        // Convert
        var consumed = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard error == nil,
              let channelData = outputBuffer.floatChannelData?[0],
              outputBuffer.frameLength > 0 else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
    }
}
