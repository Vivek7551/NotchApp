import AppKit
import CoreAudio
import CoreMediaIO

/// Knows when any app is using the microphone or camera.
///
/// Only checks whether devices are *in use*; it never records anything, so no
/// mic/camera permission is needed. Everything is listener-based (no polling).
@MainActor
final class PrivacyMonitor: ObservableObject {
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false
    /// Names of apps using the mic, e.g. ["Zoom"].
    @Published private(set) var micApps: [String] = []

    var isActive: Bool { micInUse || cameraInUse }

    /// System services that listen to the mic all the time ("Hey Siri",
    /// Sound Recognition). macOS doesn't show its orange dot for these either.
    private static let ignoredMicBundlePrefixes = [
        "com.apple.CoreSpeech", "com.apple.corespeech", "com.apple.siri", "com.apple.assistant",
        "com.apple.SpeechRecognitionCore", "com.apple.accessibility.heard", "com.apple.voicetrigger",
    ]

    private struct ListenerKey: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
    }
    private var audioListeners: Set<ListenerKey> = []
    private var observedCameras: Set<CMIOObjectID> = []

    func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Re-check when apps start/stop using audio, or devices come and go.
        listenAudio(system, kAudioHardwarePropertyProcessObjectList)
        listenAudio(system, kAudioHardwarePropertyDevices)
        refreshMic()

        listenCamera(CMIOObjectID(kCMIOObjectSystemObject), CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        refreshCamera()
    }

    // MARK: - Microphone

    private func refreshMic() {
        // Watch every input device and every audio process for start/stop.
        for device in Self.audioObjects(kAudioHardwarePropertyDevices) {
            listenAudio(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        var apps: [String] = []
        for process in Self.audioObjects(kAudioHardwarePropertyProcessObjectList) {
            listenAudio(process, kAudioProcessPropertyIsRunningInput)

            var isRunningInput = UInt32(0)
            SystemVolume.getProperty(process, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, &isRunningInput)
            guard isRunningInput != 0 else { continue }

            var pid = pid_t(0)
            SystemVolume.getProperty(process, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid)
            let bundleID = Self.bundleID(of: process) ?? ""
            if pid == getpid() || Self.ignoredMicBundlePrefixes.contains(where: bundleID.hasPrefix) { continue }
            apps.append(Self.appName(bundleID: bundleID, pid: pid))
        }
        micApps = Array(Set(apps)).sorted()
        micInUse = !apps.isEmpty
    }

    private func listenAudio(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        let key = ListenerKey(object: object, selector: selector)
        guard !audioListeners.contains(key) else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshMic() }
        }
        if status == noErr { audioListeners.insert(key) }
    }

    private static func audioObjects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func appName(bundleID: String, pid: pid_t) -> String {
        if bundleID.hasPrefix("com.apple.WebKit") { return "Safari" }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID
        // "Google Chrome Helper (Renderer)" → "Google Chrome"
        return name.components(separatedBy: " Helper").first ?? name
    }

    // MARK: - Camera

    private func refreshCamera() {
        var anyRunning = false
        for camera in Self.cameraDevices() {
            if !observedCameras.contains(camera) {
                listenCamera(camera, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
                observedCameras.insert(camera)
            }
            var address = Self.cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            var running = UInt32(0)
            var used = UInt32(0)
            if CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr,
               running != 0 {
                anyRunning = true
            }
        }
        cameraInUse = anyRunning
    }

    private func listenCamera(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) {
        var address = Self.cmioAddress(selector)
        CMIOObjectAddPropertyListenerBlock(object, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshCamera() }
        }
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var address = cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return [] }
        return devices
    }

    private static func cmioAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    }
}

#if DEBUG
extension PrivacyMonitor {
    func showPreview(mic: Bool, camera: Bool) {
        micInUse = mic
        cameraInUse = camera
        micApps = mic ? ["Zoom"] : []
    }
}
#endif
