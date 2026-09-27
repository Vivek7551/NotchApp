import AudioToolbox
import CoreAudio

/// Reads and changes the output volume of the current audio device
/// (speakers, headphones, AirPods...) using CoreAudio.
enum SystemVolume {
    static var defaultOutputDevice: AudioDeviceID? {
        var device = AudioDeviceID(0)
        let status = getProperty(AudioObjectID(kAudioObjectSystemObject),
                                 kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// 0...1. "Virtual main volume" works even for devices that only have
    /// per-channel (left/right) volume controls.
    static func volume(of device: AudioDeviceID) -> Float? {
        var volume = Float32(0)
        let status = getProperty(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                 kAudioDevicePropertyScopeOutput, &volume)
        return status == noErr ? volume : nil
    }

    static func setVolume(_ volume: Float, of device: AudioDeviceID) {
        var value = Float32(min(max(volume, 0), 1))
        setProperty(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, &value)
    }

    static func canSetVolume(of device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var muted = UInt32(0)
        return getProperty(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, &muted) == noErr && muted != 0
    }

    static func setMuted(_ muted: Bool, device: AudioDeviceID) {
        var value = UInt32(muted ? 1 : 0)
        setProperty(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, &value)
    }

    // MARK: - CoreAudio plumbing

    @discardableResult
    static func getProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    @discardableResult
    static func setProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }
}

/// Calls `onChange` whenever the output volume or mute state changes, from
/// any source (keyboard, Control Center, another app). Follows the default
/// output device when you switch, e.g. to AirPods.
@MainActor
final class VolumeObserver {
    var onChange: ((_ volume: Float, _ muted: Bool) -> Void)?

    private var device: AudioDeviceID?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var lastReported: (Float, Bool)?

    func start() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultDevice() }
        }
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        if let device {
            for (address, block) in deviceListeners {
                var address = address
                AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
            }
        }
        deviceListeners.removeAll()
        device = SystemVolume.defaultOutputDevice
        guard let device else { return }
        lastReported = SystemVolume.volume(of: device).map { ($0, SystemVolume.isMuted(device)) }

        // Devices report volume on the main element or per channel, so listen to all.
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyVolumeScalar, 2),
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain),
        ]
        for (selector, element) in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.volumeDidChange() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                deviceListeners.append((address, block))
            }
        }
    }

    private func volumeDidChange() {
        guard let device, let volume = SystemVolume.volume(of: device) else { return }
        let muted = SystemVolume.isMuted(device)
        // Several listeners can fire for one change; only report real changes.
        if let (lastVolume, lastMuted) = lastReported, abs(lastVolume - volume) < 0.001, lastMuted == muted { return }
        lastReported = (volume, muted)
        onChange?(volume, muted)
    }
}
