// OpenVision - GlassesManager.swift
// Singleton manager for Meta Ray-Ban glasses via DAT SDK

import Foundation
import SwiftUI
import CoreMedia
import OSLog
import MWDATCore
import MWDATCamera

/// Manages Meta Ray-Ban glasses registration, connection, and camera streaming
@MainActor
final class GlassesManager: ObservableObject {
    // MARK: - Singleton

    static let shared = GlassesManager()

    // MARK: - Published Properties

    /// Whether the app is registered with Meta AI
    @Published var isRegistered: Bool = false

    /// Currently connected device identifier
    @Published var connectedDevice: DeviceIdentifier?

    /// Number of connected devices
    @Published var connectedDeviceCount: Int = 0

    /// Current link state of the active device ("connected", "connecting", "disconnected")
    @Published var deviceLinkState: String = "Unknown"

    /// Whether camera streaming is active
    @Published var isStreaming: Bool = false

    /// Last captured video frame
    @Published var lastFrame: UIImage?

    /// When `lastFrame` was received. Lets the live loop tell a fresh frame from a stale one when
    /// the Bluetooth stream throttles under head motion (so it doesn't describe an old view).
    private(set) var lastFrameTime: Date = .distantPast

    /// Last captured photo data
    @Published var lastPhotoData: Data?

    /// Error message for UI display
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private let wearables = Wearables.shared
    // 0.9.0 camera lifecycle: DeviceSession owns the device link, Camera owns the camera
    // hardware, camera.stream carries frames. Stopping the camera cascades to the stream.
    private var deviceSession: DeviceSession?
    private var camera: Camera?
    private var cameraStopTask: Task<Void, Never>?

    // Listener tokens (retained to keep subscriptions active)
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var photoDataListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?

    // MARK: - Callbacks

    /// Called when a video frame is received
    var onVideoFrame: ((UIImage) -> Void)?

    /// Called with the raw sample buffer for every video frame — used by SessionRecorder to mux
    /// the glasses POV into a movie file without going through UIImage. Independent of `onVideoFrame`.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called when a photo is captured
    var onPhotoCaptured: ((Data) -> Void)?

    // MARK: - Initialization

    private init() {
        print("[GlassesManager] Initializing")
        setupRegistrationListener()
        setupDevicesListener()
    }

    // MARK: - Registration

    /// Register app with Meta AI
    func register() async throws {
        print("[GlassesManager] Starting registration")

        // Check if already registered
        for await state in wearables.registrationStateStream() {
            if case .registered = state {
                print("[GlassesManager] Already registered")
                isRegistered = true
                return
            }
            break
        }

        // Start registration flow
        try await wearables.startRegistration()
        print("[GlassesManager] Registration initiated, waiting for Meta AI callback")
    }

    /// Unregister app from Meta AI
    func unregister() async {
        print("[GlassesManager] Starting unregistration")

        // Release camera ownership even if the stream has already stopped.
        await stopStreaming()

        do {
            try await wearables.startUnregistration()
            isRegistered = false
            connectedDevice = nil
            connectedDeviceCount = 0
            errorMessage = nil
            print("[GlassesManager] Unregistration successful")
        } catch {
            errorMessage = "Unregister failed: \(error.localizedDescription)"
            print("[GlassesManager] Unregistration error: \(error)")
        }
    }

    // MARK: - Streaming

    /// Start camera streaming from glasses
    func startStreaming() async {
        await cameraStopTask?.value

        guard isRegistered else {
            errorMessage = "Not registered with Meta AI"
            print("[GlassesManager] Cannot start streaming - not registered")
            return
        }

        guard !isStreaming else {
            print("[GlassesManager] Already streaming")
            return
        }

        // Check for connected device
        guard let deviceId = connectedDevice else {
            errorMessage = "No glasses connected"
            print("[GlassesManager] Cannot start streaming - no device connected")
            return
        }

        // The cue's HFP output competes with camera transport. Do not rebuild the mic engine.
        await SoundService.shared.beginCameraAccess()
        defer {
            if deviceSession == nil && !isStreaming { SoundService.shared.endCameraAccess() }
        }

        print("[GlassesManager] Starting camera stream for device: \(deviceId)")

        // Diagnostic (issue #55 follow-up): the SDK's own verdict on whether it can drive
        // this hardware — surfaces firmware/SDK mismatches that otherwise fail as an opaque
        // "Device unavailable" at session start.
        if let device = wearables.deviceForIdentifier(deviceId) {
            print("[GlassesManager] Device \(device.nameOrId()): type=\(device.deviceType()) link=\(device.linkState) compatibility=\(device.compatibility())")
            self.deviceLinkState = "\(device.linkState)"
            if device.compatibility() == .deviceUpdateRequired {
                errorMessage = "Glasses firmware update required — update in the Meta AI app"
                return
            } else if device.compatibility() == .sdkUpdateRequired {
                errorMessage = "Glasses too new for this SDK version"
                return
            }

        } else {
            print("[GlassesManager] deviceForIdentifier returned nil")
        }

        // Request camera permission
        do {
            var status: PermissionStatus = .denied
            do {
                status = try await wearables.checkPermissionStatus(.camera)
                print("[GlassesManager] Camera permission status: \(status)")
            } catch {
                print("[GlassesManager] checkPermissionStatus threw: \(error) — requesting permission directly")
            }

            if status != .granted {
                print("[GlassesManager] Requesting camera permission via Meta AI...")
                status = try await wearables.requestPermission(.camera)
                print("[GlassesManager] After request, status: \(status)")
            }

            guard status == .granted else {
                errorMessage = "Camera permission denied in Meta AI"
                print("[GlassesManager] Camera permission not granted")
                return
            }
        } catch {
            let desc = error.localizedDescription
            if desc.contains("powered off or disconnected") {
                errorMessage = "Glasses link inactive. Keep Meta AI in background, wear the glasses, and try again."
            } else {
                errorMessage = "Permission error: \(desc)"
            }
            print("[GlassesManager] Permission error: \(error)")
            return
        }
        // Permission approval can switch to Meta AI. Wait after that handoff, not before it.
        if let device = wearables.deviceForIdentifier(deviceId),
           device.linkState != .connected || UIApplication.shared.applicationState != .active {
            print("[GlassesManager] Waiting up to 5s for the camera link and foreground app...")
            for _ in 0..<10 {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                deviceLinkState = "\(device.linkState)"
                if device.linkState == .connected && UIApplication.shared.applicationState == .active {
                    break
                }
            }
        }


        // SpecificDeviceSelector stays the more reliable choice over AutoDeviceSelector
        let specificSelector = SpecificDeviceSelector(device: deviceId)

        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .medium,
            frameRate: 30
        )

        do {
            let session = try wearables.createSession(deviceSelector: specificSelector)
            deviceSession = session

            // Order matters (SDK docs): the session must be STARTED before addCamera —
            // attaching the camera to an idle session returns nil (issue #55, Blayzer test).
            // Subscribe to state before start() so the .started transition can't be missed.
            let stateStream = session.stateStream()
            // The session can abort during startup (starting -> stopping -> stopped) with the
            // reason only on its error stream — log it or we debug blind (seen on Gen 1/2).
            let sessionErrorTask = Task {
                for await error in session.errorStream() {
                    print("[GlassesManager] Device session error: \(error) — \(error.description)")
                    await MainActor.run { self.errorMessage = "Session error: \(error.description)" }
                }
            }
            defer { sessionErrorTask.cancel() }
            print("[GlassesManager] Starting device session...")
            try session.start()

            let started = await waitForSessionState(.started, session: session, states: stateStream)
            guard started else {
                errorMessage = "Device session did not start (timeout)"
                print("[GlassesManager] Device session failed to reach .started")
                dumpSDKLogs(since: 30)
                await stopStreaming()
                return
            }

            guard let cam = try session.addCamera(config: config) else {
                errorMessage = "Failed to attach camera to device session"
                print("[GlassesManager] addCamera returned nil")
                await stopStreaming()
                return
            }
            camera = cam

            setupStreamListeners(stream: cam.stream)
            cam.stream.start()
            // The first frame can arrive before the caller resumes. Its timestamp, not its later
            // presence, distinguishes that fresh frame from one captured earlier.
            lastFrame = nil
            lastFrameTime = .distantPast
            isStreaming = true
            print("[GlassesManager] Streaming started successfully")
        } catch {
            errorMessage = "Stream start failed: \(error.localizedDescription)"
            print("[GlassesManager] Stream start error: \(error)")
            await stopStreaming()
        }
    }

    /// Stop camera streaming
    func stopStreaming() async {
        if let cameraStopTask {
            await cameraStopTask.value
            return
        }
        guard isStreaming || camera != nil || deviceSession != nil else { return }

        // Cleanup must finish even when its caller is canceled. Coalesce concurrent stops.
        let task = Task {
            await finishStoppingStream()
            cameraStopTask = nil
        }
        cameraStopTask = task
        await task.value
    }

    private func finishStoppingStream() async {

        print("[GlassesManager] Stopping camera stream")

        let session = deviceSession
        let states = session?.stateStream()   // subscribe before issuing stop
        camera?.stop()                       // cascades to the stream
        session?.stop()
        if let session, let states {
            guard await waitForSessionState(.stopped, session: session, states: states) else {
                errorMessage = "Camera session did not stop (timeout)"
                print("[GlassesManager] Camera session failed to reach .stopped; keeping thinking sound paused")
                return
            }
        }

        cleanupStreamListeners()
        camera = nil
        deviceSession = nil
        isStreaming = false
        lastFrame = nil
        lastFrameTime = .distantPast
        SoundService.shared.endCameraAccess()

        print("[GlassesManager] Streaming stopped")
    }

    /// Capture a photo from the glasses camera
    func capturePhoto() async {
        guard isStreaming, let stream = camera?.stream else {
            errorMessage = "Streaming must be active to capture photos"
            return
        }

        print("[GlassesManager] Capturing photo")

        // Non-throwing since 0.9.0; failures surface as StreamError.photoCaptureFailed
        // on the error publisher, which setupStreamListeners already routes to errorMessage.
        if !stream.capturePhoto(format: .jpeg) {
            errorMessage = "Failed to start photo capture"
            print("[GlassesManager] capturePhoto returned false")
        }
    }

    // MARK: - Private Methods

    private func waitForSessionState(
        _ expected: DeviceSessionState,
        session: DeviceSession,
        states: AsyncStream<DeviceSessionState>
    ) async -> Bool {
        if session.state == expected { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in states {
                    print("[GlassesManager] Device session state: \(state)")
                    if state == expected { return true }
                    if state == .stopped { return false }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func setupRegistrationListener() {
        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    if case .registered = state {
                        self.isRegistered = true
                        print("[GlassesManager] Registration state: registered")
                    } else {
                        self.isRegistered = false
                        print("[GlassesManager] Registration state: \(state)")
                    }
                }
            }
        }
    }

    private func setupDevicesListener() {
        devicesTask = Task {
            for await devices in wearables.devicesStream() {
                await MainActor.run {
                    self.connectedDeviceCount = devices.count
                    self.connectedDevice = devices.first
                    if let firstId = devices.first, let dev = self.wearables.deviceForIdentifier(firstId) {
                        self.deviceLinkState = "\(dev.linkState)"
                    } else {
                        self.deviceLinkState = devices.isEmpty ? "None" : "Disconnected"
                    }
                    print("[GlassesManager] Devices updated: \(devices.count) connected, link: \(self.deviceLinkState)")
                }
            }
        }
    }

    private func setupStreamListeners(stream: MWDATCamera.Stream) {
        // State listener
        stateListenerToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                switch state {
                case .streaming:
                    self?.isStreaming = true
                case .stopped:
                    self?.isStreaming = false
                default:
                    break
                }
            }
        }

        // Video frame listener
        videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                // Hand the raw sample buffer to the recorder (if any). SessionRecorder immediately
                // hops it onto its own writer queue, so this stays cheap even at 30fps.
                self?.onVideoSampleBuffer?(frame.sampleBuffer)
                if let image = frame.makeUIImage() {
                    self?.lastFrame = image
                    self?.lastFrameTime = Date()
                    self?.onVideoFrame?(image)
                }
            }
        }

        // Photo data listener
        photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                let data = photoData.data
                self?.lastPhotoData = data
                self?.onPhotoCaptured?(data)
                print("[GlassesManager] Photo captured: \(data.count) bytes")
            }
        }

        // Error listener
        errorListenerToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                // The raw video codec pauses by design when the app leaves the foreground
                // (screen lock, app switch) and the SDK reports that as a scary-sounding
                // error ("Critical error, the stream should end" — issue #55). Only alert
                // for errors that happen while the user is actually looking at the app.
                if UIApplication.shared.applicationState == .active {
                    self?.errorMessage = error.localizedDescription
                }
                print("[GlassesManager] Stream error: \(error)")
            }
        }
    }

    /// TEMP DIAGNOSTIC (issue #55 follow-up): the DAT SDK logs its teardown reasons via OSLog,
    /// which `devicectl --console` can't see. The app CAN read its own process's entries, so on
    /// session failure dump every non-Apple subsystem line from the last `seconds` to stdout.
    private func dumpSDKLogs(since seconds: TimeInterval) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-seconds))
            let entries = try store.getEntries(at: position)
            print("[GlassesManager] ===== SDK log dump (last \(Int(seconds))s) =====")
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let sub = log.subsystem
                guard !sub.isEmpty, !sub.hasPrefix("com.apple") else { continue }
                print("[SDKLOG] \(sub)/\(log.category) [\(log.level.rawValue)] \(log.composedMessage)")
            }
            print("[GlassesManager] ===== end SDK log dump =====")
        } catch {
            print("[GlassesManager] OSLogStore dump failed: \(error)")
        }
    }

    private func cleanupStreamListeners() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        errorListenerToken = nil
    }
}
