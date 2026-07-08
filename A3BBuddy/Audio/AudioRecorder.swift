//
//  AudioRecorder.swift
//  Whisper — Workstream A
//
//  AVAudioEngine input tap → 16 kHz mono Float32 samples (what WhisperKit
//  expects). Publishes a smoothed 0–1 level for the pill waveform.
//
//  Threading: the tap fires on a realtime audio thread; samples are guarded
//  by a lock, levels are delivered on the main thread via `onLevel`.
//

import AVFoundation
import CoreAudio

final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    /// Smoothed 0–1 input level, delivered on the main thread ~30×/s.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var smoothedLevel: Float = 0
    private(set) var isRecording = false

    private lazy var targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    enum AudioError: Error {
        case noInputDevice
        case engineStartFailed(Error)
    }

    /// `preferredDeviceUID` is an AVCaptureDevice.uniqueID (== CoreAudio device
    /// UID) from Settings; empty/unknown falls back to the system default mic.
    func start(preferredDeviceUID: String = "") throws {
        guard !isRecording else { return }

        if !preferredDeviceUID.isEmpty, let deviceID = Self.deviceID(forUID: preferredDeviceUID) {
            setInputDevice(deviceID)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        smoothedLevel = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioError.engineStartFailed(error)
        }
        isRecording = true
    }

    /// Stops capture and returns everything recorded as 16 kHz mono Float32.
    func stop() -> [Float] {
        teardown()
        lock.lock()
        defer { samples.removeAll(); lock.unlock() }
        return samples
    }

    /// Stops capture and discards the audio.
    func cancel() {
        teardown()
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    private func teardown() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }

    // MARK: Tap processing (realtime thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Level from the raw buffer — cheaper than converting first.
        if let channel = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0 ..< frames { sum += channel[i] * channel[i] }
            let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
            // Speech RMS lives roughly in 0–0.3; scale up and smooth.
            let target = min(rms * 4, 1)
            smoothedLevel = smoothedLevel * 0.7 + target * 0.3
            let level = smoothedLevel
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        // Resample to 16 kHz mono.
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        lock.unlock()
    }

    // MARK: CoreAudio device selection

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &deviceUID) {
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
            }
            if status == noErr, let value = deviceUID?.takeRetainedValue(), value as String == uid {
                return device
            }
        }
        return nil
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}
