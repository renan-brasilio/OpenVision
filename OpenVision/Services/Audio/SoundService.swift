// OpenVision - SoundService.swift
// Service for playing UI sound effects.
//
// Chimes and the thinking loop use the active audio session, so they follow its output route
// (including the glasses' Bluetooth speaker) without reconfiguring audio hardware.

import Combine
import AVFoundation
import Foundation

/// Service for playing UI sound effects
@MainActor
final class SoundService: ObservableObject {
    // MARK: - Singleton

    static let shared = SoundService()

    // MARK: - Players

    /// AVAudioPlayer so the wake-word chime routes to the active output (the glasses when connected).
    private var wakeWordPlayer: AVAudioPlayer?
    private var hasSetupSounds = false
    private var settingsSubscription: AnyCancellable?
    private var thinkingTask: Task<Void, Never>?
    private var thinkingRequested = false
    private var cameraAccessInProgress = false

    var isPlayingThinkingSound: Bool {
        get async {
            await thinkingTask?.value
            return await AudioSessionManager.shared.isPlayingThinkingSound
        }
    }

    // MARK: - Settings

    private var soundEnabled: Bool {
        SettingsManager.shared.settings.playActivationSound
    }

    // MARK: - Initialization

    private init() {
        // SettingsManager publishes synchronously from MainActor; cancel starts when disabled.
        settingsSubscription = SettingsManager.shared.$settings
            .map(\.playThinkingSound)
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else { return }
                MainActor.assumeIsolated { self?.stopThinkingSound() }
            }
    }

    // MARK: - Lazy Setup

    private func ensureSoundsReady() {
        guard !hasSetupSounds else { return }
        hasSetupSounds = true

        // Wake-word "listening" chime — via AVAudioPlayer so it follows the active route (glasses).
        // Falls back to the older ding file if the new asset isn't present.
        let wakeURL = Bundle.main.url(forResource: "wake_activation", withExtension: "mp3")
            ?? Bundle.main.url(forResource: "wake_word_ding", withExtension: "mp3")
        if let wakeURL {
            wakeWordPlayer = try? AVAudioPlayer(contentsOf: wakeURL)
            wakeWordPlayer?.prepareToPlay()
        }
    }

    // MARK: - Wake Word Sound

    func playWakeWordSound() {
        guard soundEnabled else { return }
        ensureSoundsReady()

        // Play on the app's audio session so it routes to the glasses (HFP) when connected.
        // The wake-word recognizer keeps a .playAndRecord session active, so the current output
        // route is already correct — just restart the player from the top and play.
        if let player = wakeWordPlayer {
            player.currentTime = 0
            player.play()
        }
    }

    /// Play an alert chime for timers/alarms — via the app's active AVAudioPlayer session, so it's
    /// audible even in silent mode and routes to the glasses. Notification sounds get suppressed while
    /// our audio session is active, so we play our own. Unconditional (a timer must be heard).
    func playAlert() {
        ensureSoundsReady()
        if let player = wakeWordPlayer {
            player.currentTime = 0
            player.play()
        }
    }

    // MARK: - Thinking Sound

    func startThinkingSound() {
        guard SettingsManager.shared.settings.playThinkingSound, !thinkingRequested else { return }
        thinkingRequested = true
        startThinkingPlayback()
    }

    func stopThinkingSound() {
        guard thinkingRequested else { return }
        thinkingRequested = false
        stopThinkingPlayback()
    }

    /// Camera access must wait until pending HFP playback has actually stopped.
    func beginCameraAccess() async {
        if !cameraAccessInProgress {
            cameraAccessInProgress = true
            if thinkingRequested { stopThinkingPlayback() }
        }
        await thinkingTask?.value
    }

    /// Only the owner of camera teardown releases this gate, after the SDK session has stopped.
    func endCameraAccess() {
        guard cameraAccessInProgress else { return }
        cameraAccessInProgress = false
        startThinkingPlayback()
    }

    private func startThinkingPlayback() {
        guard thinkingRequested, !cameraAccessInProgress,
              SettingsManager.shared.settings.playThinkingSound else { return }
        let previous = thinkingTask
        thinkingTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await AudioSessionManager.shared.startThinkingSound()
        }
    }

    private func stopThinkingPlayback() {
        guard let previous = thinkingTask else { return }
        previous.cancel()
        // Keep ordering even when a canceled start is already waiting on audio hardware.
        thinkingTask = Task {
            await previous.value
            await AudioSessionManager.shared.stopThinkingSound()
        }
    }
}
