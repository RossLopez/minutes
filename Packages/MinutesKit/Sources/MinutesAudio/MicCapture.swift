// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import CoreAudio
import MinutesAudioRT
import os

/// Captures the microphone on a chosen device, or the default one and follows its changes.
public final class MicCapture: AudioCaptureSource, @unchecked Sendable {
    public struct Options: Equatable, Sendable {
        public var voiceProcessing: Bool
        /// Nil follows the system default input. Ignored with voice processing on, because
        /// the voice processing unit doesn't honor a chosen device (see docs/NOTES.md).
        public var deviceUID: String?

        public init(voiceProcessing: Bool, deviceUID: String?) {
            self.voiceProcessing = voiceProcessing
            self.deviceUID = deviceUID
        }
    }

    public enum MicError: Error, Equatable {
        case noInputChannels
    }

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "mic")
    private static let retryDelay = DispatchTimeInterval.seconds(1)

    private let options: Options
    private let queue = DispatchQueue(label: "io.github.rosslopez.minutes.mic", qos: .userInitiated)

    // Used only on `queue`.
    private var engine: AVAudioEngine?
    private var sink: AVAudioSinkNode?
    private var configurationObserver: any NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var ring: AudioRing?
    private var events: (@Sendable (CaptureEvent) -> Void)?
    private var running = false
    private var rebuildPending = false
    private var fellBack = false

    public init(options: Options) {
        self.options = options
    }

    public func start(writingTo ring: AudioRing, events: @escaping @Sendable (CaptureEvent) -> Void) throws {
        try queue.sync {
            self.ring = ring
            self.events = events
            try build()
            running = true
            if followsDefaultInput {
                addInputListener()
            }
        }
    }

    public func stop() {
        queue.sync {
            running = false
            removeInputListener()
            tearDown()
            ring = nil
            events = nil
        }
    }

    private var followsDefaultInput: Bool {
        options.voiceProcessing || options.deviceUID == nil || fellBack
    }

    private func build() throws {
        guard let ring else {
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if options.voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Min is the lowest Apple offers. It still ducks (see docs/NOTES.md).
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false,
                duckingLevel: .min,
            )
        } else if let uid = options.deviceUID, !fellBack {
            if let device = AudioDevices.device(withUID: uid) {
                try input.withAUAudioUnit { try $0.setDeviceID(device) }
            } else {
                fellBack = true
                events?(.fellBackToDefaultInput(missingDeviceUID: uid))
                addInputListener()
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MicError.noInputChannels
        }
        ring.setSampleRate(format.sampleRate)
        // The input's timestamps come after the sound reached the microphone.
        ring.setTimeOffset(seconds: -AudioDevices.reportedLatency(
            of: inputDevice(),
            scope: kAudioObjectPropertyScopeInput,
        ))

        let sink = mrt_make_sink_node(ring.raw)
        engine.attach(sink)
        try engine.connectNode(input, to: sink, format: format)
        if !options.voiceProcessing {
            // Without a running output side the sink never gets audio (see docs/NOTES.md).
            engine.mainMixerNode.outputVolume = 0
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil,
        ) { [weak self] _ in
            self?.scheduleRebuild()
        }

        try engine.start()
        self.engine = engine
        self.sink = sink
    }

    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        sink = nil
    }

    private func addInputListener() {
        guard inputListener == nil else {
            return
        }
        var address = AudioDevices.address(kAudioHardwarePropertyDefaultInputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild()
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        inputListener = listener
    }

    private func removeInputListener() {
        guard let inputListener else {
            return
        }
        var address = AudioDevices.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, inputListener)
        self.inputListener = nil
    }

    /// A device change often sends several notifications, so they're coalesced into one rebuild.
    private func scheduleRebuild() {
        queue.async { [weak self] in
            guard let self, running, !rebuildPending else {
                return
            }
            rebuildPending = true
            queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                self?.rebuild()
            }
        }
    }

    private func rebuild() {
        rebuildPending = false
        guard running else {
            return
        }
        tearDown()
        do {
            try build()
            Self.logger.info("Rebuilt mic engine after device change")
            events?(.restarted(deviceName: currentInputName()))
        } catch {
            Self.logger.error("Mic rebuild failed: \(String(describing: error), privacy: .public)")
            tearDown()
            events?(.retrying)
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.retryIfNeeded()
            }
        }
    }

    private func retryIfNeeded() {
        if running, engine == nil {
            rebuild()
        }
    }

    /// The real microphone. The engine's own device ID can be a private aggregate it made,
    /// with a meaningless name.
    private func inputDevice() -> AudioObjectID {
        if !followsDefaultInput, let uid = options.deviceUID, let device = AudioDevices.device(withUID: uid) {
            return device
        }
        return AudioDevices.defaultInputDevice()
    }

    private func currentInputName() -> String {
        AudioDevices.deviceName(inputDevice())
    }
}
