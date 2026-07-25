import AVFoundation

// Manages AVAudioEngine for bidirectional 16 kHz PCM streaming.  Shared by both
// the iOS app and the watchOS app — the only platform difference is the audio
// session category options (see configure()).
//
// Lifecycle:
//   1. configure()          — request mic permission + activate AVAudioSession
//   2. addPlayerAndDrain()  — attach+connect a player node (engine not yet running)
//   3. startCapture()       — install tap, start engine, play all nodes
//
// After the initial sequence, additional addPlayerAndDrain() calls are safe.
//
// Recovery: when the engine stops itself (AVAudioEngineConfigurationChange,
// route change, interruption), scheduleRestart() performs a full stop/tap-
// removal before calling startCapture() again, ensuring a clean slate.
//
// Formats:
//   wireFormat   — int16, 16 kHz, mono, interleaved  (TCP wire)
//   engineFormat — float32, 16 kHz, mono, non-interleaved (AVAudioMixerNode)
final class AudioEngine {

    // MARK: - Formats

    let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000, channels: 1,
                                   interleaved: true)!

    private let engineFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false)!

    // MARK: - State

    private let engine            = AVAudioEngine()
    private var playerNodes       = [UUID: AVAudioPlayerNode]()
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?

    // Outgoing audio is re-framed into fixed-size frames matching the ESP's
    // expected frame: 512 samples × 2 bytes = 1024 bytes (32 ms @ 16 kHz).
    // The iOS input tap delivers irregular ~85 ms hardware buffers; sending
    // those raw produces oversized, bursty AUDIO frames that overflow the ESP's
    // fixed receive buffer (it resets the connection) and stutter on playback.
    private static let wireFrameBytes = 512 * 2
    private var captureAccumulator = Data()
    private var tapInstalled      = false
    private var restartTask: Task<Void, Never>?
    private var notificationTokens = [NSObjectProtocol]()

    // Recovery: `shouldBeRunning` is our intent (true between startCapture and
    // stop).  A watchdog periodically compares it against the engine's real
    // state and forces a restart if the engine died without us noticing, and
    // engine.start() failures retry with backoff instead of giving up — so a
    // transient interruption (phone call, Siri, another app grabbing the
    // session) self-heals rather than requiring a force-quit.
    private var shouldBeRunning   = false
    private var restartAttempts   = 0
    private var watchdogTimer: Timer?

    var isRunning: Bool { engine.isRunning }

    // Diagnostic counters (UI-display only; written on audio + main threads).
    private(set) var packetsSent     = 0
    private(set) var packetsReceived = 0

    /// Called on the audio thread with ~32 ms int16 PCM ready to send over TCP.
    var onCapture: ((Data) -> Void)?

    /// Fired on the main actor whenever the engine's real running state changes
    /// (started, or died and self-healed).  Lets the owner (IntercomSession)
    /// reflect the *live* state instead of latching a one-shot check that misses
    /// a later self-heal — the root cause of the stuck "engine failed to start".
    var onRunningStateChanged: ((Bool) -> Void)?
    private var lastReportedRunning = false

    // MARK: - Session

    enum ConfigureError: LocalizedError {
        case microphoneDenied
        var errorDescription: String? {
            "Microphone access denied. Enable it in Settings → Privacy & Security → Microphone."
        }
    }

    func configure() async throws {
        // 1. Microphone permission.
        let granted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        guard granted else { throw ConfigureError.microphoneDenied }

        // 2. Configure + activate the AVAudioSession.
        try applySessionConfiguration()
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        let s = AVAudioSession.sharedInstance()

        // 3. Establish the render graph's output path up front.  Accessing
        //    mainMixerNode lazily connects mainMixer → outputNode, so any player
        //    node connected later already has a valid path to the speaker.
        //    Without this, a player → mixer connection can exist while the
        //    mixer → output link is missing, leaving the player "disconnected".
        _ = engine.mainMixerNode

        // 4. Playback converter (wire int16 → engine float32, same sample rate).
        playbackConverter = AVAudioConverter(from: wireFormat, to: engineFormat)

        // 5. Closure-based observers — no NSObject required.
        let nc = NotificationCenter.default
        notificationTokens = [
            nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                           object: engine, queue: .main) { [weak self] _ in
                // Engine stopped itself and destroyed all graph connections.
                self?.scheduleRestart(delay: 150)
                print("AudioEngine: AVAudioEngineConfigurationChange — scheduling restart")
            },
            nc.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
                self?.handleInterruption(note)
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] note in
                self?.handleRouteChange(note)
            },
        ]

        startWatchdog()

        print("AudioEngine: configured, sampleRate=\(s.sampleRate), input=\(s.currentRoute.inputs.first?.portType.rawValue ?? "?")")
    }

    /// Apply the audio-session category, options, and preferred I/O.  Factored out
    /// of configure() so the recovery path can re-apply it verbatim when a start
    /// failure indicates the session was deactivated/reconfigured out from under us.
    private func applySessionConfiguration() throws {
        let s = AVAudioSession.sharedInstance()
        #if os(watchOS)
        // watchOS has no .defaultToSpeaker (and a smaller option set); keep it
        // minimal and let the system route to the watch speaker / paired audio.
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        #else
        // NOTE: deliberately NO .allowBluetoothHFP.  Allowing HFP lets the system
        // pull a paired headset (AirPods) into the bidirectional Hands-Free call
        // profile the moment our record-capable session activates — which is mono,
        // narrow-band, bumps the mixed-in audiobook's volume, and (worst of all)
        // hands the headset's own transport controls to "the call", so the
        // AirPods stem no longer pauses/skips the audiobook.  With A2DP-only, the
        // headset stays in high-quality stereo media mode for OUTPUT and input is
        // taken from the built-in mic (see setPreferredInput below).  Trade-off:
        // push-to-talk then captures the iPhone mic, not the headset mic — the
        // right call for a listen-focused intercom that mixes with an audiobook.
        try s.setCategory(.playAndRecord,
                          mode: .default,
                          options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])

        // Pin the hardware to a normal media sample rate (44.1 kHz) so activating
        // our record-capable session doesn't drop the shared output graph to a
        // 24 kHz voice rate.  That reconfiguration re-renders mixed-in audio
        // (e.g. an audiobook) at a different gain, making it jump in volume; at
        // the media rate the other app's level is preserved.  Preferred values
        // are best-effort — the system may pick a nearby rate.  (watchOS doesn't
        // expose setPreferredSampleRate.)
        try? s.setPreferredSampleRate(44_100)

        // Force input to the built-in mic so a paired Bluetooth headset is never
        // dragged into the HFP call profile just to satisfy our record path.
        if let builtIn = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? s.setPreferredInput(builtIn)
        }
        #endif
    }

    /// Re-apply the session configuration and reactivate.  Used by the start-
    /// failure recovery path: the most common cause of a persistent
    /// engine.start() failure is the AVAudioSession having been deactivated by an
    /// interruption (phone call, Siri) whose `.ended` notification we never saw
    /// (e.g. the app was suspended).  Reactivating it lets the next start succeed.
    private func hardResetSession() {
        do {
            try applySessionConfiguration()
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            print("AudioEngine: hard-reset AVAudioSession after repeated start failures")
        } catch {
            print("AudioEngine: hard reset failed — \(error)")
        }
    }

    /// Notify the owner when the engine's real running state flips.  Debounced so
    /// only genuine transitions are reported.
    private func reportRunningStateIfChanged() {
        let running = engine.isRunning
        guard running != lastReportedRunning else { return }
        lastReportedRunning = running
        onRunningStateChanged?(running)
    }

    // MARK: - Watchdog

    /// Periodically verify the engine is actually running when it should be.
    /// Catches cases where the engine stopped without firing a notification we
    /// observe (or a restart silently failed), and kicks a fresh restart.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Surface any state change (incl. a self-heal we didn't report
                // synchronously) so the owner's status reflects reality within a
                // tick, then decide whether a restart is still needed.
                self.reportRunningStateIfChanged()
                guard self.shouldBeRunning, !self.engine.isRunning
                else { return }
                // scheduleRestart() debounces (cancels any pending restart), so
                // it's safe to call even if a backoff restart is already queued —
                // the watchdog just caps recovery latency at the tick interval.
                print("AudioEngine: watchdog — engine stopped unexpectedly, restarting")
                self.scheduleRestart(delay: 0)
            }
        }
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    // MARK: - Player graph

    /// Attach and connect a player node for one remote endpoint.
    /// Safely called before or after the engine is running.
    func addPlayerAndDrain(for id: UUID) {
        guard playerNodes[id] == nil else { return }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        connectNode(node)           // only connects if not already connected
        playerNodes[id] = node

        if engine.isRunning {
            node.play()
            if let conv = playbackConverter {
                drainEarlyAudio(for: id, node: node, converter: conv)
            }
            print("AudioEngine: player \(id) added & started ✓")
        } else {
            // Engine stopped itself between startCapture() and here.
            // scheduleRestart will do a full teardown + rebuild so the node
            // will be started cleanly.
            print("AudioEngine: player \(id) added — engine not running, scheduling restart")
            scheduleRestart(delay: 100)
        }
    }

    func removePlayer(for id: UUID) {
        guard let node = playerNodes.removeValue(forKey: id) else { return }
        node.stop()
        engine.detach(node)
        earlyAudioQueue.removeValue(forKey: id)
        print("AudioEngine: player \(id) removed")
    }

    /// Connect a node to the mixer, but only if it is not already connected.
    /// Avoids the 'player started when in a disconnected state' crash that
    /// results from calling engine.connect() on an already-connected node
    /// while the engine is stopped (the call removes then re-adds the
    /// connection, leaving the node transiently disconnected).
    private func connectNode(_ node: AVAudioPlayerNode) {
        guard engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty else { return }
        engine.connect(node, to: engine.mainMixerNode, format: engineFormat)
    }

    // MARK: - Capture

    /// Install the input tap and start the engine.
    /// Always call with the tap removed first (scheduleRestart() ensures this).
    func startCapture() {
        precondition(!tapInstalled, "startCapture called with tap already installed")

        // We intend to be running from here until stop() — the watchdog uses this.
        shouldBeRunning = true

        // NOTE: deliberately do NOT re-activate the AVAudioSession here.  Calling
        // setActive(true) on every (re)start can itself trigger an
        // AVAudioEngineConfigurationChange, which schedules another restart, which
        // re-activates again — a reconfiguration loop that makes engine.start()
        // fail intermittently.  The session is activated once in configure(); the
        // only case that needs re-activation is an interruption, which the
        // interruption .ended handler covers before it schedules a restart.

        // Reconnect player nodes whose connections were destroyed by an
        // AVAudioEngineConfigurationChange.  connectNode() is a no-op for
        // nodes that are already properly connected.
        for (_, node) in playerNodes {
            if node.engine == nil { engine.attach(node) }
            connectNode(node)
        }

        // Install with format: nil so the tap always adopts the input node's
        // CURRENT hardware format.  Passing an explicit format pins the tap to
        // one sample rate; if the hardware later switches (e.g. another app
        // forces 24 kHz via .mixWithOthers, or the session settles to a voice
        // rate) the next graph reconfig asserts "formats don't match" (-10868)
        // and hard-crashes.  convertAndForward() already rebuilds its converter
        // for whatever format each buffer arrives in, so a changing input rate
        // is handled gracefully.
        let hwFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            self?.convertAndForward(buf)
        }
        tapInstalled = true
        print("AudioEngine: tap installed (format: nil), reported hwFormat=\(hwFormat)")

        do {
            try engine.start()
            restartAttempts = 0   // success — reset backoff
            reportRunningStateIfChanged()
            print("AudioEngine: engine started ✓  nodes=\(playerNodes.count)")
        } catch {
            // Don't give up — retry with backoff so a transient failure (session
            // still settling after an interruption, hardware momentarily busy)
            // self-heals instead of leaving the stream dead until a force-quit.
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            restartAttempts += 1
            // Escalate after the first retry: a start that keeps failing usually
            // means the AVAudioSession itself went stale (a missed interruption
            // .ended left it deactivated).  Re-apply + reactivate it before the
            // next attempt instead of just spinning on a dead session.
            if restartAttempts >= 2 { hardResetSession() }
            let backoff = min(2000, 250 * restartAttempts)
            print("AudioEngine: engine.start() FAILED (attempt \(restartAttempts)) — retrying in \(backoff) ms — \(error)")
            scheduleRestart(delay: backoff)
            return
        }

        // Only start nodes if the engine is genuinely running and the node
        // still has a live connection to the mixer.  A reconfiguration that
        // slipped in between engine.start() above and here would have torn the
        // graph down; calling play() on a disconnected node crashes hard.
        guard engine.isRunning else {
            print("AudioEngine: engine not running after start — skipping play(), scheduling restart")
            scheduleRestart(delay: 150)
            return
        }
        for (_, node) in playerNodes {
            guard !engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty else {
                print("AudioEngine: node disconnected after start — skipping play()")
                continue
            }
            node.play()
        }
        print("AudioEngine: \(playerNodes.count) player node(s) playing")
    }

    func stopCapture() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        captureAccumulator.removeAll(keepingCapacity: true)
    }

    // MARK: - Capture conversion (audio thread)

    private func convertAndForward(_ inBuf: AVAudioPCMBuffer) {
        if captureConverter == nil || captureConverter!.inputFormat != inBuf.format {
            captureConverter = AVAudioConverter(from: inBuf.format, to: wireFormat)
            print("AudioEngine: capture converter \(Int(inBuf.format.sampleRate)) Hz → 16 kHz int16")
        }
        guard let converter = captureConverter else { return }

        let ratio     = wireFormat.sampleRate / inBuf.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: outFrames)
        else { return }

        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, outBuf.frameLength > 0,
              let ch = outBuf.int16ChannelData else { return }

        // Append converted PCM to the accumulator, then drain it in exact
        // 1024-byte (512-sample) frames so every AUDIO frame matches the ESP's
        // expected size.  Any tail shorter than a full frame is kept for next
        // time, producing a steady, evenly-paced stream.
        captureAccumulator.append(Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2))

        let frameBytes = Self.wireFrameBytes
        while captureAccumulator.count >= frameBytes {
            let frame = captureAccumulator.prefix(frameBytes)
            captureAccumulator.removeFirst(frameBytes)
            packetsSent += 1
            onCapture?(Data(frame))
        }
    }

    // MARK: - Playback

    func playAudio(_ data: Data, for id: UUID) {
        // Drop incoming frames while the engine is restarting.  Without this
        // check, AVAudioPlayerNode.scheduleBuffer queues every arriving buffer
        // even though nothing can consume it — ballooning memory and causing a
        // CPU spike when the engine eventually starts and tries to drain them.
        guard engine.isRunning else { return }

        guard let node = playerNodes[id] else {
            queueEarlyAudio(data, for: id)
            return
        }
        // Also drop if the node itself hasn't started playing yet (e.g. it was
        // just reattached by scheduleRestart and play() hasn't been called).
        guard node.isPlaying else { return }
        guard let converter = playbackConverter else { return }
        scheduleOnNode(node, data: data, converter: converter)
    }

    private var earlyAudioQueue = [UUID: [Data]]()
    private let maxEarlyFrames  = 16

    private func queueEarlyAudio(_ data: Data, for id: UUID) {
        var q = earlyAudioQueue[id] ?? []
        q.append(data)
        if q.count > maxEarlyFrames { q.removeFirst() }
        earlyAudioQueue[id] = q
    }

    private func drainEarlyAudio(for id: UUID, node: AVAudioPlayerNode,
                                  converter: AVAudioConverter) {
        guard let q = earlyAudioQueue.removeValue(forKey: id), !q.isEmpty else { return }
        print("AudioEngine: draining \(q.count) early frame(s) for player \(id)")
        q.forEach { scheduleOnNode(node, data: $0, converter: converter) }
    }

    private func scheduleOnNode(_ node: AVAudioPlayerNode, data: Data,
                                 converter: AVAudioConverter) {
        let inFrames = AVAudioFrameCount(data.count / 2)
        guard inFrames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: inFrames),
              let inCh  = inBuf.int16ChannelData else { return }
        inBuf.frameLength = inFrames
        data.withUnsafeBytes { ptr in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress else { return }
            inCh[0].update(from: src, count: Int(inFrames))
        }

        let outFrames = AVAudioFrameCount(
            ceil(Double(inFrames) * engineFormat.sampleRate / wireFormat.sampleRate))
        guard outFrames > 0,
              let outBuf = AVAudioPCMBuffer(pcmFormat: engineFormat,
                                            frameCapacity: outFrames) else { return }

        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, outBuf.frameLength > 0 else { return }

        node.scheduleBuffer(outBuf, completionHandler: nil)
        packetsReceived += 1
    }

    func setVolume(_ volume: Float, for id: UUID) {
        playerNodes[id]?.volume = max(0, min(1, volume))
    }

    // MARK: - Full stop

    func stop() {
        shouldBeRunning = false
        restartAttempts = 0
        lastReportedRunning = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        restartTask?.cancel()
        restartTask = nil
        stopCapture()
        playerNodes.values.forEach { $0.stop() }
        playerNodes.removeAll()
        earlyAudioQueue.removeAll()
        engine.stop()
        packetsSent     = 0
        packetsReceived = 0
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        print("AudioEngine: stopped")
    }

    // MARK: - Restart helper

    /// Schedule a full rebuild + restart after `delay` ms.
    /// Each call cancels any previously pending restart (debouncing).
    ///
    /// Why detach/reattach instead of just reconnect:
    ///   When the engine stops *itself* (AVAudioEngineConfigurationChange,
    ///   hardware route change, etc.) it sets each node's internal state to
    ///   kState_Disconnected — independent of whether the graph connection
    ///   still exists.  Calling engine.stop() after the fact does NOT reset
    ///   that per-node flag.  The only reliable way to put a node back into a
    ///   playable state is engine.detach() + engine.attach() + engine.connect(),
    ///   which reinitialises the node's internal state machine from scratch.
    private func scheduleRestart(delay: Int = 300) {
        restartTask?.cancel()
        // @MainActor: serialize the whole rebuild onto the main thread so it
        // cannot interleave with the AVAudioEngineConfigurationChange observer
        // (which also runs on .main).  Running the rebuild on a background
        // cooperative thread races that observer — the observer tears down the
        // graph connections between engine.start() and node.play(), producing
        // the 'player started when in a disconnected state' crash.
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            // Don't resurrect a stopped engine: a late notification (config
            // change, route change) can fire after stop().  shouldBeRunning is
            // our intent and onCapture is required to forward audio.
            guard self.shouldBeRunning, self.onCapture != nil else { return }
            print("AudioEngine: restarting after delay=\(delay) ms")

            // 1. Stop engine only if it is still running.
            //    When the engine stops *itself* (hardware event) it does NOT
            //    fully release the audio hardware — calling engine.stop() after
            //    that does, making the subsequent engine.start() fail with
            //    IsFormatSampleRateAndChannelCountValid(outputHWFormat).
            //    Skipping the explicit stop preserves the hardware reservation
            //    so engine.start() can succeed after the delay.
            if self.engine.isRunning { self.engine.stop() }

            // 2. Remove tap so startCapture() can install a fresh one.
            self.stopCapture()

            // 3. Full detach→attach→connect cycle for every player node.
            //    This is the only way to reset a node out of kState_Disconnected.
            //    Clear the early-audio buffer too — any frames queued before
            //    the restart are now stale.
            self.earlyAudioQueue.removeAll()
            for (_, node) in self.playerNodes {
                node.stop()
                self.engine.detach(node)          // resets internal state machine
                self.engine.attach(node)          // fresh attach
                self.engine.connect(node, to: self.engine.mainMixerNode,
                                    format: self.engineFormat)
            }

            // 4. Fresh capture start.
            self.startCapture()
        }
    }

    // MARK: - Notification handlers (called on main queue via closure observers)

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw  = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { scheduleRestart(delay: 150) }
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard
            let info      = note.userInfo,
            let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason    = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            scheduleRestart(delay: 300)
        default:
            break
        }
    }
}
