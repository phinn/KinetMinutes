// SystemAudioTap.swift — macOS 14.2+ Core Audio process tap for system audio.
// Records the far-end (meeting) audio to its own CAF track, separate from the
// mic track (PRD F03 双轨分轨). Uses CATapDescription global stereo tap wired
// through an aggregate device; no screen-recording permission needed.
// Sandboxed OK: tap captures audio output of other processes, we only write
// files inside our container.

import AVFoundation
import CoreAudio

final class SystemAudioTap {
    private(set) var isRunning = false
    private var tapID: AudioObjectID = 0
    private var aggID: AudioDeviceID = 0
    private var proc: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var lastLevel: Float = 0
    var onLevelChange: ((Float) -> Void)?
    private static let apiAvailable: Bool = {
        if #available(macOS 14.2, *) { return true }
        return false
    }()

    static var available: Bool { apiAvailable }

    /// Start capturing system output into `url` (48 kHz mono PCM16, same format as mic track).
    func start(url: URL) -> Bool {
        guard !isRunning else { return false }
        if #available(macOS 14.2, *) {
            return startImpl(url: url)
        }
        return false
    }

    @available(macOS 14.2, *)
    private func startImpl(url: URL) -> Bool {
        // 1. global stereo tap (all processes; we filter nothing — a meeting is
        //    whatever is playing, keeps detection simple and robust)
        let desc = CATapDescription(__stereoGlobalTapButExcludeProcesses: [NSNumber]())
        desc.name = "KinetMinutesTap"
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted   // capture AND keep playing (user still hears the meeting)
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { NSLog("KM_TAP create err %d", status); return false }

        // 2. aggregate device: [tap] + [default output device] so we can pull IO
        let outUID = defaultOutputUID()
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "KinetMinutesAgg",
            kAudioAggregateDeviceUIDKey: "com.kinet.minutes.agg.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,      // invisible to the user
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ] as [String: Any]]
        ]
        var aggID = AudioDeviceID(0)
        status = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
        guard status == noErr else {
            NSLog("KM_TAP agg err %d", status)
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            return false
        }
        self.aggID = aggID

        // 3. output file 48k mono 16-bit (matches mic track format exactly)
        let fileFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let file = try? AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]) else {
            teardown(); return false
        }
        self.file = file
        // tap delivers stereo at device rate; convert to 48k mono
        if let hw = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) {
            converter = AVAudioConverter(from: hw, to: fileFormat)
        }

        // 4. IOProc on the aggregate device — the tap stream arrives on the input side
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, nil) { [weak self] _, inData, _, outData, _ in
            guard let self else { return }
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            self.consume(buffers: bufList)
        }
        guard status == noErr else { NSLog("KM_TAP ioproc err %d", status); teardown(); return false }
        status = AudioDeviceStart(aggID, proc)
        guard status == noErr else { NSLog("KM_TAP start err %d", status); teardown(); return false }

        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let proc { AudioDeviceStop(aggID, proc); AudioDeviceDestroyIOProcID(aggID, proc) }
        teardown()
    }

    private func teardown() {
        isRunning = false
        file = nil
        converter = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }; tapID = 0 }
        proc = nil
    }

    private func consume(buffers: UnsafeMutableAudioBufferListPointer) {
        DispatchQueue.main.async { self.lastLevel > 0 ? (self.onLevelChange?(self.lastLevel)) : nil }
        guard let file, let converter,
              let srcFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return }
        // merge the buffer list into one stereo float buffer
        var frames: AVAudioFrameCount = 0
        for b in buffers where b.mNumberChannels > 0 { frames = max(frames, b.mDataByteSize / UInt32(MemoryLayout<Float>.size) / b.mNumberChannels) }
        guard frames > 0, let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else { return }
        for (i, b) in buffers.enumerated() where i < 2 {
            guard let data = b.mData else { continue }
            let ch = data.bindMemory(to: Float.self, capacity: Int(frames))
            for f in 0..<Int(frames) { src.floatChannelData![i][f] = ch[f] }
        }
        src.frameLength = frames
        let cap = AVAudioFrameCount(Double(frames) * 0.51) + 1024
        guard let dst = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: cap) else { return }
        var err: NSError?
        var consumed = false
        converter.convert(to: dst, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return src
        }
        if err == nil, dst.frameLength > 0 {
            try? file.write(from: dst)
            if let ch = dst.floatChannelData?[0] {
                var peak: Float = 0
                for i in 0..<Int(dst.frameLength) { peak = max(peak, abs(ch[i])) }
                lastLevel = peak
                onLevelChange?(peak)
            }
        }
    }

    private func defaultOutputUID() -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil as CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &uid)
        return uid as String? ?? ""
    }
}
