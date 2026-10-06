//
//  SpeechRecognizer.swift
//  VoxSign
//
//  Microphone input: v3 record-only build (decided 2026-10-04: all local offline recognition removed).
//  Flow: hold to record (AVAudioEngine -> WAV) -> release -> POST Harness /v1/asr
//        -> ASR server (platform model + custom hotwords) calibrates -> calibrated text shown once ->
//        auto-submit. Calibration failure -> explicit error; NO local-recognition fallback.
//

import Foundation
import AVFoundation
import Combine

final class SpeechRecognizer: ObservableObject {
    static let shared = SpeechRecognizer()

    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    /// Recognition unavailable (no permission / unsupported) -> the UI falls back to the keyboard.
    @Published var unavailable: Bool = false
    /// Doubao-style "hold to talk": hold to record, release to upload to the ASR server, auto-submit.
    private var holdMode = false
    /// ASR calibrating state: on release -> "Calibrating…" (no text) -> text appears once calibration completes.
    @Published var calibrating: Bool = false
    /// Calibration failed state: show the failure hint (no local-recognition fallback).
    @Published var asrFailed: Bool = false
    /// WAV is empty after release (no sound captured) -> prompt to retry (distinct from asrFailed, gives the user a clear reason).
    @Published var emptyRecording: Bool = false
    /// Live amplitude while holding (0~1), drives the waveform animation (Doubao-style "responds on hold").
    @Published var meterLevel: Float = 0

    /// UI v3: cumulative hold seconds (shown as the voice bubble duration, e.g. "3s"). startHold resets it; stopHold/cancelHold freeze it.
    private(set) var lastHoldSeconds: Int = 0
    private var holdTimer: Timer?

    private let engine = AVAudioEngine()
    /// Dedicated background serial queue for audio session/engine startup (hold-latency fix: does not block main-thread rendering).
    private let audioSetupQueue = DispatchQueue(label: "com.voicesign.audio-setup", qos: .userInitiated)
    /// Recording WAV file (for platform calibration) and its URL.
    private var audioFile: AVAudioFile?
    private var audioURL: URL?
    /// v2.3 re-entry guard: isRecording is set asynchronously, so rapid taps could call start() twice,
    /// which crashed from a double installTap. Calls while starting/recording are ignored.
    private var starting = false

    // MARK: - Hold-latency timing (LAT): touch->pressActive->startHold->session->engine->first meter frame
    private static var touchMs: TimeInterval = 0
    /// Called by InputBarView.onChanged the instant the finger lands (main thread, most recent).
    static func markTouch() { touchMs = Date().timeIntervalSince1970 * 1000 }
    private func lat(_ tag: String) {
        let now = Date().timeIntervalSince1970 * 1000
        let d = Self.touchMs > 0 ? now - Self.touchMs : 0
        print("[LAT] \(tag) +\(String(format: "%.0f", d))ms")
        DiagLogger.shared.log("LAT", "\(tag) +\(String(format: "%.0f", d))ms")
    }
    /// Log the first meter frame only once.
    private var didLogFirstMeter = false

    private init() {}

    /// Request microphone permission (shows the system prompt on first use).
    func requestAuthorization() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async { if !ok { self?.unavailable = true } }
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    // MARK: - Doubao-style "hold to talk" (main interaction)

    /// Hold to start recording (record only; no local recognition fed).
    func startHold() {
        lat("startHold entry")
        didLogFirstMeter = false
        holdMode = true
        // UI v3: hold-recording timer (voice bubble duration).
        lastHoldSeconds = 0
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            self.lastHoldSeconds += 1
        }
        // The user wants to speak: stop the previous reply TTS first (the recording session also ducks playback).
        VoiceOutputService.shared.stop()
        start()
    }

    /// Release (ASR calibration): stop engine/close WAV -> upload to the ASR server (platform model + hotwords) for calibration.
    /// Calibration success -> text appears once -> auto-submit; failure -> asrFailed hint (no local fallback).
    func stopHold() {
        holdMode = false
        holdTimer?.invalidate()
        holdTimer = nil
        endRecordingSession()
        startCalibration()
    }

    /// Swipe up to cancel (same gesture as Doubao): discard the recording, do NOT send.
    func cancelHold() {
        print("[ASR] cancelHold (swipe-up cancel)")
        DiagLogger.shared.log("ASR", "cancelHold (swipe-up cancel)")
        holdMode = false
        holdTimer?.invalidate()
        holdTimer = nil
        calibrating = false
        asrFailed = false
        emptyRecording = false
        audioFile = nil
        audioURL = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        transcript = ""
    }

    /// End the recording session: stop tap/engine/session, close the WAV file.
    private func endRecordingSession() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioFile = nil   // close AVAudioFile（flush WAV）
        isRecording = false
    }

    /// ASR calibration: on release upload the WAV to /v1/asr -> ASR server (platform model + personal hotwords).
    /// Success -> text appears once + auto-submit; failure -> asrFailed (prompt to retry, no local fallback).
    private func startCalibration() {
        calibrating = true
        asrFailed = false
        emptyRecording = false
        guard let url = audioURL, FileManager.default.fileExists(atPath: url.path),
              let audioData = try? Data(contentsOf: url), !audioData.isEmpty else {
            // No valid recording (silence/recording failed) -> explicitly prompt "no sound captured", distinct from recognition failure.
            calibrating = false
            emptyRecording = true
            return
        }
        // WAV file exists but its data chunk is empty (e.g. conversion failed) -> treat as "no sound captured" too.
        let wavDataLen = wavDataChunkLength(audioData)
        if wavDataLen == 0 {
            print("[ASR] WAV data chunk empty (bytes=\(audioData.count))")
            DiagLogger.shared.log("ASR", "WAV data empty bytes=\(audioData.count)")
            calibrating = false
            emptyRecording = true
            return
        }
        print("[ASR] WAV bytes=\(audioData.count) dataLen=\(wavDataLen) at \(url.lastPathComponent)")
        DiagLogger.shared.log("ASR", "WAV bytes=\(audioData.count) dataLen=\(wavDataLen)")
        uploadAudio(audioData) { [weak self] text, ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.calibrating = false
                if ok, let text = text, !text.isEmpty {
                    // ASR server calibration succeeded: text appears once + auto-submit (Doubao-style).
                    self.transcript = text
                    self.asrFailed = false
                    self.onFinalSegment?(text)
                } else {
                    // ASR server not ready/failed: explicitly prompt to retry; never fall back to local recognition.
                    self.asrFailed = true
                }
            }
        }
    }

    /// T2 Doubao-style: callback with the calibrated full text.
    /// Once AppModel sets this, it is "speak-and-go" — after calibration it auto-submits, no send tap needed.
    var onFinalSegment: ((String) -> Void)?

    /// Upload WAV -> harness /v1/asr (multipart file=) -> ASR server calibration. 20s timeout.
    private func uploadAudio(_ data: Data, completion: @escaping (String?, Bool) -> Void) {
        let base = SettingsStore.shared.base
        guard !base.isEmpty, let endpoint = URL(string: base + "/v1/asr") else {
            completion(nil, false); return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        let tok = SettingsStore.shared.token
        if !tok.isEmpty {
            req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        }
        let boundary = "vhs-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = obj["ok"] as? Bool, ok,
                  let text = obj["text"] as? String, !text.isEmpty else {
                completion(nil, false)
                return
            }
            completion(text, true)
        }.resume()
    }

    func start() {
        guard !isRecording, !starting else {
            print("[ASR] start ignored (already recording/starting)")
            return
        }
        starting = true
        // Doubao-style: enter recording state the instant the button is pressed (UI feedback first, don't wait for the engine).
        DispatchQueue.main.async {
            self.transcript = ""
            self.isRecording = true
            self.calibrating = false
            self.asrFailed = false
        }
        print("[ASR] start: mic=\(micStatus()) hold=\(holdMode)")
        DiagLogger.shared.log("ASR", "start mic=\(micStatus())")
        // [Crash fix T3] Pre-check permission: when the mic is not authorized, AVAudioEngine's
        // installTap/engine.start raises an NSException (Swift do-catch cannot catch it) -> hard crash.
        let mic = AVAudioSession.sharedInstance().recordPermission
        switch mic {
        case .granted:
            break
        case .undetermined:
            print("[ASR] mic undetermined -> requesting permission")
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    print("[ASR] mic permission result ok=\(ok)")
                    DiagLogger.shared.log("ASR", "mic permission ok=\(ok)")
                    if ok {
                        self.start()   // permission granted: start immediately (no need to tap again)
                    } else {
                        self.unavailable = true
                        self.isRecording = false
                    }
                }
            }
            return
        case .denied:
            print("[ASR] mic denied → unavailable")
            DispatchQueue.main.async {
                self.unavailable = true
                self.isRecording = false
            }
            return
        @unknown default:
            return
        }
        // [Hold-latency fix] AVAudioSession setCategory/setActive and engine.start() are synchronous,
        // blocking calls (on a real device the first launch can take hundreds of ms to ~1s). Running them
        // on the main thread previously blocked the pressActive=true SwiftUI render, so the user waited
        // ~1s after pressing before seeing the waveform. Now they run on a background serial queue: the
        // main thread returns instantly on press and pressActive visuals + haptics take effect at once;
        // once the engine is up in the background meterLevel feeds the waveform. AVAudioSession/AVAudioEngine
        // calls are thread-safe; only UI state hops back to the main thread.
        audioSetupQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                self.lat("session active")
                print("[ASR] session active (record)")
                DiagLogger.shared.log("ASR", "session active")
                // v2.3 crash fix: installTap again on an AVAudioEngine that already has a tap raises an ObjC NSException.
                // Idempotent cleanup before installTap: if the engine is running stop it; if a tap exists remove it; then add the new tap.
                if self.engine.isRunning { self.engine.stop() }
                self.engine.inputNode.removeTap(onBus: 0)

                let node = self.engine.inputNode
                let hardwareFormat = node.outputFormat(forBus: 0)
                print("[ASR] installTap format=\(hardwareFormat.sampleRate)Hz ch=\(hardwareFormat.channelCount)")
                // v2.5 recording fix: AVAudioFile always writes 16k Int16 mono.
                // 16k Int16 is the platform ASR standard input; the tap receives hardware-format buffers,
                // converted to 16k Int16 mono via AVAudioConverter before writing.
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vhs-voice-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
                let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                 sampleRate: 16000, channels: 1, interleaved: false)!
                do {
                    self.audioFile = try AVAudioFile(forWriting: fileURL,
                                                settings: targetFormat.settings,
                                                commonFormat: .pcmFormatInt16, interleaved: false)
                } catch {
                    print("[ASR] AVAudioFile create FAIL: \(error.localizedDescription)")
                    DiagLogger.shared.log("ASR", "AVAudioFile FAIL: \(error.localizedDescription)")
                    self.audioFile = nil
                }
                self.audioURL = fileURL
                let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
                node.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
                    guard let self = self else { return }
                    guard let af = self.audioFile else { return }
                    guard let cv = converter else { return }
                    let ratio = targetFormat.sampleRate / hardwareFormat.sampleRate
                    let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
                    guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
                    var convErr: NSError?
                    // [Repeated-syllable fix] the input block must supply only one buffer per call, then return .noDataNow.
                    var suppliedInput = false
                    let status = cv.convert(to: outBuf, error: &convErr) { _, outStatus in
                        if suppliedInput {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        suppliedInput = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if convErr != nil {
                        print("[ASR] convert FAIL: \(convErr!.localizedDescription)")
                        return
                    }
                    if status == .haveData || status == .inputRanDry {
                        if outBuf.frameLength > 0 {
                            do {
                                try af.write(from: outBuf)
                            } catch {
                                print("[ASR] tap write FAIL: \(error.localizedDescription)")
                                DiagLogger.shared.log("ASR", "tap write FAIL: \(error.localizedDescription)")
                            }
                        }
                    }
                    // Live amplitude feedback while holding: supports both float32 and int16 tap formats,
                    // low-pass smoothed to drive the UI waveform bar (Doubao-style "responds on hold").
                    var peak: Float = 0
                    let n = Int(buffer.frameLength)
                    if buffer.format.commonFormat == .pcmFormatFloat32, let ch = buffer.floatChannelData {
                        let stride = buffer.stride
                        for i in 0..<n {
                            let v = abs(ch[0][i * stride])
                            if v > peak { peak = v }
                        }
                        if buffer.format.channelCount > 1, let ch1 = buffer.floatChannelData?[1] {
                            for i in 0..<n {
                                let v = abs(ch1[i * stride])
                                if v > peak { peak = v }
                            }
                        }
                    } else if buffer.format.commonFormat == .pcmFormatInt16, let ch = buffer.int16ChannelData {
                        let stride = buffer.stride
                        for i in 0..<n {
                            let v = abs(Float(ch[0][i * stride]) / 32768.0)
                            if v > peak { peak = v }
                        }
                        if buffer.format.channelCount > 1, let ch1 = buffer.int16ChannelData?[1] {
                            for i in 0..<n {
                                let v = abs(Float(ch1[i * stride]) / 32768.0)
                                if v > peak { peak = v }
                            }
                        }
                    }
                    // dB-domain mapping: 0.001(-60dB)~1(0dB) linearly mapped to 0~1
                    let lvl: Float
                    if peak > 1e-3 {
                        lvl = min(1, max(0, (log10(peak) + 3.0) / 3.0))
                    } else {
                        lvl = 0
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        if !self.didLogFirstMeter {
                            self.didLogFirstMeter = true
                            self.lat("first meter (tap alive)")
                        }
                        self.meterLevel = self.meterLevel * 0.65 + lvl * 0.35
                    }
                }
                self.engine.prepare()
                try self.engine.start()
                self.lat("engine started")
                print("[ASR] engine.start OK")
                DiagLogger.shared.log("ASR", "engine.start OK")
                self.starting = false
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.transcript = ""
                }
            } catch {
                print("[ASR] start error (catchable): \(error.localizedDescription)")
                DiagLogger.shared.log("ASR", "start error: \(error.localizedDescription)")
                self.starting = false
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.unavailable = true
                }
            }
        }
    }

    func stop() {
        print("[ASR] stop")
        audioFile = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        meterLevel = 0
    }

    // MARK: - Logging helpers

    private func micStatus() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    /// Parse the byte length of the data chunk in the WAV header (4 bytes, little-endian). Returns -1 on failure.
    private func wavDataChunkLength(_ data: Data) -> Int {
        guard data.count >= 12, data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else {
            return -1
        }
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(data: data.subdata(in: offset..<offset + 4), encoding: .ascii) ?? ""
            let len = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
            if id == "data" { return Int(len) }
            offset += 8 + Int(len)
        }
        return -1
    }

    /// P1 one-turn-one-clear: clear the recognition buffer after send; the next turn starts blank.
    func resetRound() {
        transcript = ""
    }
}
