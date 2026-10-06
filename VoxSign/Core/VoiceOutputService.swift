//
//  VoiceOutputService.swift
//  VoxSign
//
//  T3 voice output (TTS): speaks harness replies / decision-point questions aloud as they
//  arrive, so the user doesn't have to look at the screen. On-device AVSpeechSynthesizer.
//

import Foundation
import AVFoundation

final class VoiceOutputService: ObservableObject {
    static let shared = VoiceOutputService()

    /// Whether speech is enabled (on by default; toggle in Settings).
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: enabledKey) }
    }
    /// Speech rate (0.4~0.6, comfortable range).
    @Published var rate: Float {
        didSet { defaults.set(rate, forKey: rateKey) }
    }

    private let defaults = UserDefaults.standard
    private let enabledKey = "vhs-ios-tts-enabled"
    private let rateKey = "vhs-ios-tts-rate"
    private let synthesizer = AVSpeechSynthesizer()

    private init() {
        enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let r = defaults.object(forKey: rateKey) as? Float ?? 0.5
        rate = min(max(r, 0.4), 0.6)
    }

    /// Speak a piece of text. No-op when disabled or empty.
    func speak(_ text: String) {
        guard enabled else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Interrupt the previous utterance (on consecutive replies only the newest is spoken).
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: t)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    /// Stop speaking immediately (call when the user holds to talk again / backgrounds the app).
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
