import XCTest
@testable import OpenVision

@MainActor
final class ThinkingSoundTests: XCTestCase {
    private var activationSound = false
    private var thinkingSound = false

    override func setUp() async throws {
        activationSound = SettingsManager.shared.settings.playActivationSound
        thinkingSound = SettingsManager.shared.settings.playThinkingSound
        SoundService.shared.stopThinkingSound()
        await expectPlayback(false)
    }

    override func tearDown() async throws {
        SoundService.shared.stopThinkingSound()
        await expectPlayback(false)
        SettingsManager.shared.settings.playActivationSound = activationSound
        SettingsManager.shared.settings.playThinkingSound = thinkingSound
        SettingsManager.shared.saveNow()
    }

    func testThinkingLoopContinuesPastClipEndWithoutActivationChime() async throws {
        SettingsManager.shared.settings.playActivationSound = false
        SettingsManager.shared.settings.playThinkingSound = true
        SoundService.shared.startThinkingSound()
        await expectPlayback(true)

        // The bundled clip is about five seconds; a longer wait detects one-shot playback.
        try await Task.sleep(for: .seconds(6))
        await expectPlayback(true)

        SoundService.shared.stopThinkingSound()
        await expectPlayback(false)
    }

    func testDisablingThinkingSoundStopsPlaybackImmediately() async {
        SettingsManager.shared.settings.playThinkingSound = true
        SoundService.shared.startThinkingSound()
        await expectPlayback(true)

        SettingsManager.shared.settings.playThinkingSound = false
        await expectPlayback(false)
        SoundService.shared.startThinkingSound()
        await expectPlayback(false)
    }

    func testStopBeforeQueuedStartCannotRevivePlayback() async {
        SettingsManager.shared.settings.playThinkingSound = true
        SoundService.shared.startThinkingSound()
        SoundService.shared.stopThinkingSound()
        await expectPlayback(false)

        SoundService.shared.startThinkingSound()
        await expectPlayback(true)
        SoundService.shared.stopThinkingSound()
        await expectPlayback(false)
    }

    func testCameraAccessDrainsPlaybackAndDefersThinkingRequests() async {
        SettingsManager.shared.settings.playThinkingSound = true
        SoundService.shared.startThinkingSound()
        await expectPlayback(true)

        await SoundService.shared.beginCameraAccess()
        await expectPlayback(false)
        SoundService.shared.stopThinkingSound()
        SoundService.shared.startThinkingSound()
        await expectPlayback(false)

        SoundService.shared.endCameraAccess()
        await expectPlayback(true)
    }

    func testCameraReleaseDoesNotReviveACancelledReply() async {
        SettingsManager.shared.settings.playThinkingSound = true
        SoundService.shared.startThinkingSound()
        await SoundService.shared.beginCameraAccess()
        await expectPlayback(false)

        SoundService.shared.stopThinkingSound()
        SoundService.shared.endCameraAccess()
        await expectPlayback(false)
    }

    func testCameraAccessCancelsAQueuedStart() async {
        SettingsManager.shared.settings.playThinkingSound = true
        SoundService.shared.startThinkingSound()
        await SoundService.shared.beginCameraAccess()
        await expectPlayback(false)

        SettingsManager.shared.settings.playThinkingSound = false
        SoundService.shared.endCameraAccess()
        await expectPlayback(false)
    }

    private func expectPlayback(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let playing = await SoundService.shared.isPlayingThinkingSound
        XCTAssertEqual(playing, expected, file: file, line: line)
    }
}
