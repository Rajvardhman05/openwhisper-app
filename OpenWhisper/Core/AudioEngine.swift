import AVFoundation
import Accelerate
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
}

final class AudioEngine: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 48000
    private var levelCallback: ((Float) -> Void)?

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

    /// Start recording. If `deviceUID` is non-nil, route AUHAL to that input device;
    /// otherwise the system default input is used.
    func startRecording(deviceUID: String?, levelCallback: @escaping (Float) -> Void) {
        self.levelCallback = levelCallback
        lock.lock()
        samples = []
        lock.unlock()

        // Always start from a fresh engine so any prior HAL claim is fully released
        engine = AVAudioEngine()

        let inputNode = engine.inputNode

        if let uid = deviceUID, let deviceID = Self.audioDeviceID(forUID: uid) {
            do {
                try inputNode.auAudioUnit.setDeviceID(deviceID)
                owLog("[AudioEngine] Using input device UID=\(uid) id=\(deviceID)")
            } catch {
                owLog("[AudioEngine] Failed to set input device \(uid): \(error). Falling back to default.")
            }
        } else {
            owLog("[AudioEngine] Using system default input")
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputSampleRate = format.sampleRate
        owLog("[AudioEngine] Recording format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            var rms: Float = 0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
            self.levelCallback?(rms)

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
        // Drop the AUAudioUnit and its HAL device claim now, not lazily on the next start.
        // This lets a Bluetooth headset return to A2DP immediately instead of lingering in HFP/SCO.
        engine.reset()
        engine = AVAudioEngine()
        levelCallback = nil

        lock.lock()
        let captured = samples
        samples = []
        lock.unlock()

        guard !captured.isEmpty else { return nil }
        return resampleTo16kHz(captured, fromRate: inputSampleRate)
    }

    // MARK: - Resampling

    private func resampleTo16kHz(_ input: [Float], fromRate: Double) -> [Float]? {
        let targetRate: Double = 16000

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

        let ratio = targetRate / fromRate
        let outputFrameCount = AVAudioFrameCount(Double(input.count) * ratio) + 100
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

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

    // MARK: - Device enumeration

    /// All system input devices (those exposing at least one input stream).
    static func availableInputDevices() -> [AudioInputDevice] {
        return allAudioDeviceIDs().compactMap { id in
            guard hasInputStream(deviceID: id) else { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
            return AudioInputDevice(id: id, uid: uid, name: name, isBluetooth: isBluetoothTransport(deviceID: id))
        }
    }

    /// True when the system's current default input is a Bluetooth device.
    static func systemDefaultInputIsBluetooth() -> Bool {
        guard let id = defaultInputDeviceID() else { return false }
        return isBluetoothTransport(deviceID: id)
    }

    /// Look up an AudioDeviceID by its persistent UID.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }

    // MARK: - Core Audio property helpers

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        ) == noErr else { return nil }
        return id == 0 ? nil : id
    }

    private static func hasInputStream(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = cfStr?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func isBluetoothTransport(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
