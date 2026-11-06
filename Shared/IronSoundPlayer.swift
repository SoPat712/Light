import Foundation
#if os(watchOS)
import WatchKit
#else
import AVFoundation
import UIKit
#endif

/// Original, prewarmed UI cues. Session and playback work share a serial queue:
/// AVAudioPlayer preparation/playback may implicitly activate AVAudioSession.
final class IronSoundPlayer: NSObject {
    enum Sound: String, CaseIterable, Identifiable {
        case setComplete = "set_complete"
        case setRecord = "set_record"
        case tick
        case restComplete = "rest_complete"
        case workoutFinish = "workout_finish"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .setComplete: return "Set Complete"
            case .setRecord: return "Personal Record"
            case .tick: return "Controls & Keypad"
            case .restComplete: return "Rest Complete"
            case .workoutFinish: return "Workout Saved"
            }
        }

        fileprivate var volume: Float {
            switch self {
            case .tick: return 0.35
            case .restComplete: return 0.8
            case .setComplete, .setRecord, .workoutFinish: return 0.6
            }
        }
    }

    static let shared = IronSoundPlayer()

    #if os(watchOS)
    /// WatchKit supplies a paired system tap/tone, governed by Silent Mode.
    /// AVAudioPlayer's Watch silent-mode behavior is not guaranteed here, so
    /// the original CAF cues and their ambient session remain iPhone-only.
    /// Unlike the iPhone path, this method includes the matching haptic: callers
    /// must not add another haptic for the same event.
    func play(_ sound: Sound, preview: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.play(sound, preview: preview) }
            return
        }
        guard UserDefaults.standard.object(forKey: "workoutHaptics") as? Bool ?? true else { return }
        let haptic: WKHapticType
        switch sound {
        case .setComplete, .workoutFinish: haptic = .success
        case .setRecord: haptic = .directionUp
        case .tick: haptic = .click
        case .restComplete: haptic = .notification
        }
        WKInterfaceDevice.current().play(haptic)
    }

    // System cues need neither prewarming nor an app audio session/lifecycle.
    func preload() { }
    #else
    private var players: [Sound: AVAudioPlayer] = [:]
    private let sessionQueue = DispatchQueue(label: "com.joshpatra.Iron.audio-session", qos: .userInitiated)
    private var isPreloading = false
    private var isAppActive = false
    private var lastTickTime: TimeInterval = -.infinity
    private var isPreviewing = false

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stopPlayback),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stopPlayback),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(audioInterrupted(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// Called at app launch, before the first interaction. Extensions never preload.
    func preload() {
        sessionQueue.async { self.preloadOnSessionQueue() }
    }

    private func preloadOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard Bundle.main.bundleURL.pathExtension != "appex", players.isEmpty, !isPreloading else { return }
        isPreloading = true
        do {
            // Ambient mixes with the user's music and honors Ring/Silent.
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            // Construct on the main run loop so AVAudioPlayer keeps delivering
            // its delegate callbacks there. Preparation/activation stays off main.
            DispatchQueue.main.async { self.preparePlayers() }
        } catch {
            isPreloading = false
            print("Could not configure Light sounds: \(error.localizedDescription)")
        }
    }

    private func preparePlayers() {
        dispatchPrecondition(condition: .onQueue(.main))
        var prepared: [Sound: AVAudioPlayer] = [:]
        do {
            for sound in Sound.allCases {
                guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf") else {
                    print("Missing Light sound: \(sound.rawValue).caf")
                    continue
                }
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = sound.volume
                player.delegate = self
                prepared[sound] = player
            }
        } catch {
            print("Could not prepare Light sounds: \(error.localizedDescription)")
        }
        let newPlayers = prepared
        sessionQueue.async {
            for player in newPlayers.values { player.prepareToPlay() }
            self.players = newPlayers
            self.isPreloading = false
        }
    }

    func play(_ sound: Sound, preview: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.play(sound, preview: preview) }
            return
        }
        guard SettingsStore.shared.workoutSounds else { return }
        sessionQueue.async {
            guard self.isAppActive else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if sound == .tick {
                guard now - self.lastTickTime >= 0.035 else { return }
                self.lastTickTime = now
            }
            if preview {
                for player in self.players.values where player.isPlaying { player.stop() }
                // A preview is asked for on purpose, so it plays with Silent on; it still mixes
                // with music. Workout cues stay ambient and keep honoring Ring/Silent.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
                self.isPreviewing = true
            }
            guard let player = self.players[sound] else { return }
            player.currentTime = 0
            player.play()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Delegate callbacks can arrive on another queue. Keep all player/session
        // calls serialized, including the implicit activation in prepareToPlay.
        sessionQueue.async {
            if self.isPreviewing, !self.players.values.contains(where: \.isPlaying) {
                self.isPreviewing = false
                try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            }
            guard self.isAppActive else { return }
            player.currentTime = 0
            player.prepareToPlay()
        }
    }

    @objc private func didBecomeActive() {
        sessionQueue.async {
            self.isAppActive = true
            self.preloadOnSessionQueue()
            for player in self.players.values { player.prepareToPlay() }
        }
    }

    @objc private func stopPlayback() {
        sessionQueue.async {
            self.isAppActive = false
            for player in self.players.values { player.stop() }
        }
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        // Do not resume old cues after a call; the next foreground interaction
        // owns playback. Preparation can activate the session, so it stays here.
        sessionQueue.async {
            if type == .began {
                for player in self.players.values { player.stop() }
            } else if self.isAppActive {
                for player in self.players.values { player.prepareToPlay() }
            }
        }
    }
    #endif
}

#if !os(watchOS)
extension IronSoundPlayer: AVAudioPlayerDelegate { }
#endif
