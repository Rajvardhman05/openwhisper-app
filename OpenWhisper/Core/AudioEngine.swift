import AVFoundation
import Accelerate
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
    let isBuiltIn: Bool
}

final class AudioEngine: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {
    // AVCaptureSession, not AVAudioEngine: AVAudioEngine can't reliably pin a non-default mic
    // (it reports the default device's stale format and installTap throws a sampleRate mismatch),
    // which made "MacBook mic while Bluetooth headset is default" crash the app.
    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "com.openwhisper.capture")
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

    /// Start recording. If `deviceUID` is non-nil, capture from that input device;
    /// otherwise the system default input is used.
    func startRecording(deviceUID: String?, levelCallback: @escaping (Float) -> Void) {
        self.levelCallback = levelCallback
        lock.lock()
        samples = []
        lock.unlock()

        var device: AVCaptureDevice?
        if let uid = deviceUID {
            device = AVCaptureDevice(uniqueID: uid)
            if device == nil { owLog("[AudioEngine] Input device \(uid) not found. Falling back to default.") }
        }
        if device == nil { device = AVCaptureDevice.default(for: .audio) }
        guard let device else {
            owLog("[AudioEngine] No input device available")
            return
        }
        owLog("[AudioEngine] Using input device \(device.localizedName) UID=\(device.uniqueID)")

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                owLog("[AudioEngine] Cannot add input \(device.localizedName)")
                return
            }
            session.addInput(input)
        } catch {
            owLog("[AudioEngine] Failed to open \(device.localizedName): \(error)")
            return
        }

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            owLog("[AudioEngine] Cannot add audio output")
            return
        }
        session.addOutput(output)

        self.session = session
        // startRunning blocks while the device opens; keep it off the main thread.
        captureQueue.async {
            session.startRunning()
            owLog("[AudioEngine] Capture started")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }

        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = bufferList.mBuffers.mData else { return }
        let frameLength = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard frameLength > 0 else { return }
        let channelData = data.assumingMemoryBound(to: Float.self)

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
        levelCallback?(rms)

        let channelSamples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        lock.lock()
        inputSampleRate = asbd.mSampleRate
        samples.append(contentsOf: channelSamples)
        lock.unlock()
    }

    func stopRecording() -> [Float]? {
        // Stop on the capture queue so every in-flight buffer is delivered before we read samples.
        // Releasing the session drops the device claim, so a Bluetooth headset returns to A2DP immediately.
        if let session {
            captureQueue.sync { session.stopRunning() }
        }
        session = nil
        levelCallback = nil

        lock.lock()
        let captured = samples
        let rate = inputSampleRate
        samples = []
        lock.unlock()

        owLog("[AudioEngine] Captured \(captured.count) samples at \(rate)Hz")
        guard !captured.isEmpty else { return nil }
        return resampleTo16kHz(captured, fromRate: rate)
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
            let transport = transportType(deviceID: id)
            return AudioInputDevice(
                id: id, uid: uid, name: name,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
            )
        }
    }

    /// True when the system's current default input is a Bluetooth device.
    static func systemDefaultInputIsBluetooth() -> Bool {
        guard let id = defaultInputDeviceID() else { return false }
        return isBluetoothTransport(deviceID: id)
    }

    /// UID of the Mac's own microphone (transport type, not name, so a Continuity iPhone never matches).
    static func builtInInputUID() -> String? {
        return availableInputDevices().first(where: { $0.isBuiltIn })?.uid
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
        let transport = transportType(deviceID: deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }
}
