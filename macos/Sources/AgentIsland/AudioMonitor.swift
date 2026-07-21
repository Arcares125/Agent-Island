import CoreAudio
import Foundation
import os

/// Receives audio-related changes on the main actor: output volume, whether
/// system audio is playing, and (when the visualizer tap is enabled) the
/// smoothed spectrum bars.
@MainActor
protocol AudioMonitoringDelegate: AnyObject {
    func outputVolumeDidChange(_ level: Float, delta: Float)
    func audioPlayingDidChange(_ playing: Bool)
    func spectrumDidUpdate(_ bars: [Float])
}

/// Observes system audio *without capturing it*. Today it watches the default
/// output device's main volume and reports a 0...1 level plus a signed change.
@MainActor
protocol AudioMonitoring: AnyObject {
    var delegate: AudioMonitoringDelegate? { get set }
    func start()
    func stop()
    func setVisualizerEnabled(_ enabled: Bool)
}

@MainActor
final class AudioMonitor: AudioMonitoring {
    weak var delegate: AudioMonitoringDelegate?

    private let logger = Logger(subsystem: "AgentIsland", category: "AudioMonitor")

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: Float?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var lastPlaying = false
    private var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapChannels = 2
    private let ringBuffer = AudioRingBuffer(capacity: 8192)
    private var visualizerEnabled = false
    static let barCount = 5
    /// Publish rate for the bars. Each frame is an FFT plus a SwiftUI redraw, so
    /// this is the feature's main energy cost; 20 fps still reads as fluid once
    /// the view interpolates between frames.
    private static let spectrumFrameRate: Double = 20
    private let analyzer = SpectrumAnalyzer(size: 2048)
    private var spectrumTimer: Timer?
    private var smoothed = [Float](repeating: 0, count: AudioMonitor.barCount)

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeDefaultDeviceChanges()
        attachToDefaultOutputDevice()
    }

    func stop() {
        isRunning = false
        setVisualizerEnabled(false)
        detachVolumeListener()
        detachRunningListener()
        detachDeviceChangeListener()
    }

    // MARK: Default output device

    private func defaultOutputDeviceID() -> AudioObjectID {
        var address = defaultDeviceAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private func observeDefaultDeviceChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reattachToDefaultOutputDevice() }
        }
        deviceChangeListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, nil, block
        )
        if status != noErr {
            logger.error("failed to add default-device-change listener (status \(status, privacy: .public))")
        }
    }

    private func detachDeviceChangeListener() {
        guard let block = deviceChangeListener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, nil, block
        )
        deviceChangeListener = nil
    }

    private func reattachToDefaultOutputDevice() {
        detachVolumeListener()
        detachRunningListener()
        attachToDefaultOutputDevice()
    }

    // MARK: Volume listener

    private func volumeAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(device, &address) {
            address.mElement = 1  // fall back to the left channel
        }
        return address
    }

    private func attachToDefaultOutputDevice() {
        let device = defaultOutputDeviceID()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        deviceID = device

        // Volume tier — absent on some digital/HDMI outputs; that's fine.
        var address = volumeAddress(for: device)
        if AudioObjectHasProperty(device, &address) {
            lastVolume = readVolume(device: device, address: &address)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.emitVolumeChange() }
            }
            volumeListener = block
            let status = AudioObjectAddPropertyListenerBlock(device, &address, nil, block)
            if status != noErr {
                logger.error("failed to add volume listener (status \(status, privacy: .public))")
            }
        } else {
            logger.error("default output device has no scalar volume property; volume HUD inactive")
        }

        // Detection tier — no permission; always attach.
        var runningAddr = runningAddress()
        emitPlayingChange(readIsRunning(device: device, address: &runningAddr))
        let runningBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.emitRunningChange() }
        }
        runningListener = runningBlock
        let runStatus = AudioObjectAddPropertyListenerBlock(device, &runningAddr, nil, runningBlock)
        if runStatus != noErr {
            logger.error("failed to add running-state listener (status \(runStatus, privacy: .public))")
        }
    }

    private func detachVolumeListener() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown),
              let block = volumeListener else { return }
        var address = volumeAddress(for: deviceID)
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
        volumeListener = nil
    }

    private func detachRunningListener() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown),
              let block = runningListener else { return }
        var address = runningAddress()
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
        runningListener = nil
    }

    private func readVolume(
        device: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> Float? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func emitVolumeChange() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = volumeAddress(for: deviceID)
        guard let newVolume = readVolume(device: deviceID, address: &address) else { return }
        let delta = newVolume - (lastVolume ?? newVolume)
        lastVolume = newVolume
        delegate?.outputVolumeDidChange(newVolume, delta: delta)
    }

    // MARK: Running-state listener

    private func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readIsRunning(device: AudioObjectID, address: inout AudioObjectPropertyAddress) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func emitRunningChange() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = runningAddress()
        emitPlayingChange(readIsRunning(device: deviceID, address: &address))
    }

    private func emitPlayingChange(_ playing: Bool) {
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        delegate?.audioPlayingDidChange(playing)
    }

    // MARK: Visualizer process tap (opt-in, macOS 14.2+)

    func setVisualizerEnabled(_ enabled: Bool) {
        guard visualizerEnabled != enabled else { return }
        visualizerEnabled = enabled
        if #available(macOS 14.2, *) {
            if enabled { startTap() } else { stopTap() }
        } else {
            logger.error("audio visualizer requires macOS 14.2+")
        }
    }

    @available(macOS 14.2, *)
    private func startTap() {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "AgentIslandVisualizerTap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            logger.error("AudioHardwareCreateProcessTap failed (status \(tapStatus, privacy: .public)) — audio-capture permission may be denied")
            stopTap()
            return
        }
        tapID = newTap
        tapChannels = readTapChannels(tapID)

        let aggUID = UUID().uuidString
        let subTap: [String: Any] = [kAudioSubTapUIDKey as String: desc.uuid.uuidString]
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AgentIslandVisualizerAgg",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [subTap],
        ]
        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg)
        guard aggStatus == noErr, newAgg != kAudioObjectUnknown else {
            logger.error("AudioHardwareCreateAggregateDevice failed (status \(aggStatus, privacy: .public))")
            stopTap()
            return
        }
        aggregateID = newAgg

        let channels = tapChannels
        let ring = ringBuffer
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, let raw = first.mData else { return }
            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float32>.size / max(channels, 1)
            let samples = raw.assumingMemoryBound(to: Float32.self)
            // Downmix to mono directly into the ring — no allocation on the audio thread.
            ring.writeDownmix(samples, frameCount: frameCount, channels: channels)
        }
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil, ioBlock)
        guard procStatus == noErr, let proc = newProc else {
            logger.error("AudioDeviceCreateIOProcIDWithBlock failed (status \(procStatus, privacy: .public))")
            stopTap()
            return
        }
        ioProcID = proc
        let startStatus = AudioDeviceStart(aggregateID, proc)
        if startStatus != noErr {
            logger.error("AudioDeviceStart failed (status \(startStatus, privacy: .public))")
            stopTap()
        } else {
            logger.info("visualizer tap started (\(channels, privacy: .public) ch)")
            startSpectrumLoop()
        }
    }

    @available(macOS 14.2, *)
    private func readTapChannels(_ tap: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        let ch = Int(asbd.mChannelsPerFrame)
        return status == noErr && ch > 0 ? ch : 2
    }

    private func stopTap() {
        visualizerEnabled = false
        spectrumTimer?.invalidate()
        spectrumTimer = nil
        delegate?.spectrumDidUpdate([])
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Spectrum publish loop (~30 fps)

    private func startSpectrumLoop() {
        spectrumTimer?.invalidate()
        smoothed = [Float](repeating: 0, count: Self.barCount)
        spectrumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Self.spectrumFrameRate, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishSpectrum() }
        }
    }

    private func publishSpectrum() {
        guard lastPlaying else { return }
        let window = ringBuffer.latestWindow(analyzer.size)
        guard window.count >= analyzer.size else { return }
        let magnitudes = analyzer.magnitudes(from: window)
        let target = binMagnitudesToBars(magnitudes, barCount: Self.barCount)
        smoothed = smoothBars(previous: smoothed, target: target, attack: 0.6, decay: 0.18)
        delegate?.spectrumDidUpdate(smoothed)
    }
}
