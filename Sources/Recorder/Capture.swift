import AVFoundation
import CoreAudio
import Foundation
import Synchronization

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Lines already in the log, counted once; the lock also keeps lines from two threads whole.
private let logLines = Mutex<Int?>(nil)

/// Appends one line to `~/Library/Logs/Recorder.log` and returns its line number (the condition report under an error).
@discardableResult
func log(_ text: String) -> Int {
    let line = "\(Date().formatted(.iso8601)) \(text)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Recorder.log")
    return logLines.withLock { count in
        let existing: Data? = count == nil ? try? Data(contentsOf: url) : nil
        let before: Int = count ?? existing.map { $0.reduce(0) { $1 == 10 ? $0 + 1 : $0 } } ?? 0
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))  // the throwing form: a full disk must not crash the app
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        // ponytail: counted once per run; another copy writing to the same log shifts the number until a restart.
        count = before + line.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return before + 1
    }
}

// MARK: - Core Audio helpers

private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) throws -> T {
    var addr = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    guard status == noErr else { throw RecorderError("Core Audio property \(fourCC(selector)) failed (\(status))") }
    return value
}

private func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &values) == noErr else { return [] }
    return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
}

private func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    (try? get(object, selector, kAudioObjectPropertyScopeGlobal, "" as CFString)) as String?
}

private func fourCC(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "\(value)"
}

private let systemObject = AudioObjectID(kAudioObjectSystemObject)

private func inputChannels(_ device: AudioDeviceID) -> Int {
    getArray(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, AudioStreamID(0)).reduce(0) { sum, stream in
        let format = try? get(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
        return sum + Int(format?.mChannelsPerFrame ?? 0)
    }
}

/// True when another process is currently capturing from `device`.
func micInUseByOthers(_ device: AudioDeviceID) -> Bool {
    let me = getpid()
    return getArray(systemObject, kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)).contains { process in
        guard (try? get(process, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0))) != me else { return false }
        let running = (try? get(process, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, UInt32(0))) ?? 0
        return running != 0 && getArray(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput, AudioObjectID(0)).contains(device)
    }
}

private func isBluetooth(_ device: AudioDeviceID) -> Bool {
    let transport = (try? get(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0))) ?? 0
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
}

/// The default input, except an idle Bluetooth mic: opening that forces the headset into call mode
/// and lowers what he hears, so the built-in mic is used instead when there is one.
/// The mic a recording would use right now (Settings shows it).
func currentMicName() -> String? {
    (try? chooseMic()).flatMap { getString($0, kAudioObjectPropertyName) }
}

private func chooseMic() throws -> AudioDeviceID {
    let device: AudioDeviceID = try get(systemObject, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0))
    guard device != kAudioObjectUnknown, inputChannels(device) > 0 else { throw RecorderError("No microphone found.") }
    guard isBluetooth(device), !micInUseByOthers(device) else { return device }
    let builtIn = getArray(systemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)).first {
        (try? get($0, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0))) == kAudioDeviceTransportTypeBuiltIn && inputChannels($0) > 0
    }
    return builtIn ?? device
}

func threeChannelFormat(sampleRate: Double) -> AVAudioFormat {
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
    return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: true, channelLayout: layout)
}

// MARK: - Capture

/// Records the mic plus everything the Mac plays into a 3 channel CAF (mic, system L, system R).
/// One private aggregate device holds the mic (clock) and a global unmuted tap, so both sides
/// arrive in the same IO callback and stay sample aligned.
final class Capture: @unchecked Sendable {
    let micName: String
    let micIsBluetooth: Bool
    let sampleRate: Double
    let url: URL

    // Written by the IO thread, read by the UI.
    let micPeak = Atomic<UInt32>(0)
    let systemPeak = Atomic<UInt32>(0)
    let micZeroRun = Atomic<Int>(0)  // consecutive frames of exact digital silence on the mic
    let gaps = Atomic<Int>(0)
    let fault = Atomic<Int>(0)  // see `faultText`
    /// Set by the UI. While paused the device keeps running but nothing is written, for both sides at once.
    let paused = Atomic<Bool>(false)
    /// Frames that went into the file (gap fill included): the recording's real length, for the timer.
    let framesKept = Atomic<Int>(0)

    /// Called on the main queue when a watcher sees a change that makes the recording invalid.
    var onFault: (@MainActor (String) -> Void)?

    private let ring: Ring
    private let file: AVAudioFile
    private let writeBuffer: AVAudioPCMBuffer
    private let writerQueue = DispatchQueue(label: "recorder.writer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var writeError: Error?
    private(set) var framesWritten = 0
    private var lastTouch = Date()

    private let mic: AudioDeviceID
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Whether the default output is running, when that is not only this capture's doing (a headset is mic and output in one).
    func outputIsPlayingElsewhere() -> Bool {
        guard let output = try? get(systemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)), output != mic else { return false }
        return ((try? get(output, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0))) ?? 0) != 0
    }

    static let faultText = [1: "the audio devices changed while recording", 2: "the recording buffer overflowed", 3: "a gap in the audio stream was too long", 4: "writing to disk failed"]

    init(url: URL) throws {
        self.url = url
        mic = try chooseMic()
        micName = getString(mic, kAudioObjectPropertyName) ?? "Microphone"
        micIsBluetooth = isBluetooth(mic)
        guard let micUID = getString(mic, kAudioDevicePropertyDeviceUID) else { throw RecorderError("Could not read the microphone.") }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Recorder"
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw RecorderError("Could not tap system audio (\(status)). Allow Kagu in System Settings, Privacy & Security, Screen & System Audio Recording.") }

        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "local.recorder.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Recorder",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality,
            ]],
            // ponytail: off on purpose, "on" makes start wait for the first played sound and loses the mic until then
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RecorderError("Could not create the capture device (\(status)).")
        }

        let micStreams: Int, micFormat: AudioStreamBasicDescription, tapFormat: AudioStreamBasicDescription
        do {
            sampleRate = try get(aggregateID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))
            // ponytail: the AAC encoder rejects rates above 48 kHz; resample in Convert if a 96 kHz interface ever matters
            guard sampleRate <= 48000 else {
                throw RecorderError("\(micName) runs at \(Int(sampleRate)) Hz. Set it to 48000 Hz in Audio MIDI Setup and try again.")
            }
            tapFormat = try get(tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())

            // Expected layout: the mic's streams first, then one tap stream right after the mic channels.
            micStreams = getArray(mic, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, AudioStreamID(0)).count
            let micChannels = inputChannels(mic)
            let streams = getArray(aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, AudioStreamID(0))
            guard let tapStream = streams.last, streams.count == micStreams + 1 else {
                throw RecorderError("Unexpected capture layout: \(streams.count) streams for \(micStreams) mic streams.")
            }
            let tapStreamFormat: AudioStreamBasicDescription = try get(tapStream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
            let tapStart: UInt32 = try get(tapStream, kAudioStreamPropertyStartingChannel, kAudioObjectPropertyScopeGlobal, UInt32(0))
            micFormat = try get(streams[0], kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
            let isFloat = { (f: AudioStreamBasicDescription) in f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32 }
            guard tapStreamFormat.mChannelsPerFrame == tapFormat.mChannelsPerFrame, tapFormat.mChannelsPerFrame == 2,
                  Int(tapStart) == micChannels + 1, isFloat(tapStreamFormat), isFloat(micFormat),
                  micFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 || micFormat.mChannelsPerFrame == 1
            else {
                throw RecorderError("Unexpected capture format (tap \(tapStreamFormat.mChannelsPerFrame) ch at \(tapStart), mic \(micChannels) ch).")
            }
            log("capture: mic \(micName) \(micChannels) ch in \(micStreams) streams, rate \(sampleRate), tap \(tapFormat.mSampleRate) Hz")

            let format = threeChannelFormat(sampleRate: sampleRate)
            var settings = format.settings
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate))!
            ring = Ring(channels: 3, capacity: Int(sampleRate) * 10)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        tap = tapID
        aggregate = aggregateID

        do {
            try start(expectedBuffers: micStreams + 1, micBufferChannels: Int(micFormat.mChannelsPerFrame), tapFormat: tapFormat)
        } catch {
            teardown()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func start(expectedBuffers: Int, micBufferChannels: Int, tapFormat: AudioStreamBasicDescription) throws {
        let block = Self.ioBlock(capture: self, expectedBuffers: expectedBuffers, micChannels: micBufferChannels, maxGap: Int(sampleRate))
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil, block)
        guard status == noErr else { throw RecorderError("Could not start capture (\(status)).") }

        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer

        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { throw RecorderError("Could not start capture (\(status)).") }

        let rate = sampleRate
        watch(aggregate, kAudioDevicePropertyNominalSampleRate) { [aggregate] in
            ((try? get(aggregate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))) ?? 0) != rate
        }
        watch(aggregate, kAudioDevicePropertyIOStoppedAbnormally) { true }
        watch(mic, kAudioDevicePropertyDeviceIsAlive) { [mic] in
            ((try? get(mic, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, UInt32(0))) ?? 0) == 0
        }
        watch(tap, kAudioTapPropertyFormat) { [tap] in
            let now = try? get(tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
            return now?.mSampleRate != tapFormat.mSampleRate || now?.mChannelsPerFrame != tapFormat.mChannelsPerFrame
        }
        watch(systemObject, kAudioHardwarePropertyServiceRestarted) { true }
    }

    /// Listens on the main queue; `isFault` decides whether the change breaks the recording.
    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, isFault: @escaping @Sendable () -> Bool) {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, isFault() else { return }
                log("capture: fault from \(fourCC(selector))")
                self.onFault?(Self.faultText[1]!)
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr {
            listeners.append((object, addr, block))
        }
    }

    /// The real time callback. Built outside any actor so it never hops executors.
    private nonisolated static func ioBlock(capture: Capture, expectedBuffers: Int, micChannels: Int, maxGap: Int) -> AudioDeviceIOBlock {
        let ring = capture.ring
        nonisolated(unsafe) var nextSampleTime = -1.0
        nonisolated(unsafe) var gain: Float = 1  // 1 recording, 0 paused; a buffer long ramp at each switch so the cut does not click
        return { _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count == expectedBuffers,
                  let micData = buffers[0].mData, buffers[0].mNumberChannels == micChannels,
                  let tapData = buffers[buffers.count - 1].mData, buffers[buffers.count - 1].mNumberChannels == 2
            else {
                capture.fault.store(1, ordering: .relaxed)
                return
            }
            let frames = min(Int(buffers[0].mDataByteSize) / 4 / micChannels, Int(buffers[buffers.count - 1].mDataByteSize) / 8)
            let micSamples = micData.assumingMemoryBound(to: Float.self)
            let tapSamples = tapData.assumingMemoryBound(to: Float.self)

            // Pause: the first paused buffer fades out, later ones are dropped, the first resumed one fades in.
            // The expected sample time still moves on, so a resume is never mistaken for a gap.
            let sampleTime = inputTime.pointee.mSampleTime
            let paused = capture.paused.load(ordering: .relaxed)
            if paused && gain == 0 {
                nextSampleTime = sampleTime + Double(frames)
                return
            }
            let from = gain, to: Float = paused ? 0 : 1
            gain = to

            // Keep both sides at their time position across a skipped cycle.
            if from == 1, nextSampleTime >= 0, sampleTime > nextSampleTime {
                let gap = Int(sampleTime - nextSampleTime)
                capture.gaps.add(1, ordering: .relaxed)
                if gap > maxGap { capture.fault.store(3, ordering: .relaxed); return }
                if !ring.write(frames: gap, { _, dst in dst.update(repeating: 0, count: 3) }) {
                    capture.fault.store(2, ordering: .relaxed)
                    return
                }
                capture.framesKept.add(gap, ordering: .relaxed)
            }
            nextSampleTime = sampleTime + Double(frames)

            var micPeak: Float = 0
            var systemPeak: Float = 0
            let ramp = from != to
            let ok = ring.write(frames: frames) { i, dst in
                let g = ramp ? from + (to - from) * Float(i + 1) / Float(frames) : 1
                let m = micSamples[i * micChannels]  // channel 0 of the first mic stream
                let l = tapSamples[i * 2], r = tapSamples[i * 2 + 1]
                dst[0] = m * g
                dst[1] = l * g
                dst[2] = r * g
                micPeak = max(micPeak, abs(m))
                systemPeak = max(systemPeak, abs(l), abs(r))
            }
            if ok { capture.framesKept.add(frames, ordering: .relaxed) } else { capture.fault.store(2, ordering: .relaxed) }
            if paused { return }  // the fade-out buffer: no meters, no silent-mic count

            if micPeak == 0 { capture.micZeroRun.add(frames, ordering: .relaxed) } else { capture.micZeroRun.store(0, ordering: .relaxed) }
            if micPeak > Float(bitPattern: capture.micPeak.load(ordering: .relaxed)) { capture.micPeak.store(micPeak.bitPattern, ordering: .relaxed) }
            if systemPeak > Float(bitPattern: capture.systemPeak.load(ordering: .relaxed)) { capture.systemPeak.store(systemPeak.bitPattern, ordering: .relaxed) }
        }
    }

    /// For a Bluetooth mic: whether a call app still records from it. When none does, holding the mic
    /// keeps the headset in call mode and lowers what he hears, so the app stops.
    var micStillNeeded: Bool { micInUseByOthers(mic) }

    /// Peak levels since the last call, for the meters.
    func takePeaks() -> (mic: Float, system: Float) {
        (Float(bitPattern: micPeak.exchange(0, ordering: .relaxed)), Float(bitPattern: systemPeak.exchange(0, ordering: .relaxed)))
    }

    /// Writer queue only.
    private func drain() {
        guard writeError == nil else { return }
        let samples = writeBuffer.floatChannelData![0]
        while true {
            let n = ring.read(into: samples, maxFrames: Int(writeBuffer.frameCapacity))
            if n == 0 {
                // While paused nothing is written; keep the file fresh so another copy of the app never takes it for a crash leftover.
                if paused.load(ordering: .relaxed), Date().timeIntervalSince(lastTouch) > 3 {
                    lastTouch = Date()
                    try? FileManager.default.setAttributes([.modificationDate: lastTouch], ofItemAtPath: url.path)
                }
                return
            }
            writeBuffer.frameLength = AVAudioFrameCount(n)
            do {
                try file.write(from: writeBuffer)
                framesWritten += n
            } catch {
                writeError = error
                fault.store(4, ordering: .relaxed)
                log("capture: write failed: \(error)")
                return
            }
        }
    }

    /// Stops capture and flushes everything to disk. Returns a write error if one happened.
    func stop() -> Error? {
        teardown()
        timer?.cancel()
        writerQueue.sync { drain() }
        writerQueue.sync { file.close() }
        log("capture: stopped, \(framesWritten) frames, \(gaps.load(ordering: .relaxed)) gaps, fault \(fault.load(ordering: .relaxed))")
        return writeError
    }

    private func teardown() {
        for (object, addr, block) in listeners {
            var addr = addr
            AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
        }
        listeners = []
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }
}
