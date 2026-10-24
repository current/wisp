import CoreAudio
import Foundation

public struct AudioDevice: Sendable, Equatable, Identifiable {
    public var id: AudioObjectID
    public var name: String
    public var hasOutput: Bool
    public var hasInput: Bool
}

/// An app with an audio connection open, and whether it is making or taking sound now.
public struct AudioClient: Sendable, Equatable {
    public var pid: Int32
    public var playing: Bool
    public var recording: Bool
}

/// The default devices, their volume and which apps use audio, through Core Audio
/// properties. Every call is a property read; nothing runs in the background.
public enum Audio {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func channels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func devices() -> [AudioDevice] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, name: name, hasOutput: channels(id, kAudioObjectPropertyScopeOutput) > 0,
                               hasInput: channels(id, kAudioObjectPropertyScopeInput) > 0)
        }
    }

    public static func defaultDevice(input: Bool) -> AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject),
              address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
    }

    public static func setDefaultDevice(_ id: AudioObjectID, input: Bool) {
        var address = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
    }

    /// Volume from 0 to 1: the main element if the device has one, else the average of its first two channels.
    public static func volume(_ device: AudioObjectID, input: Bool) -> Float? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        if let main = value(device, address(kAudioDevicePropertyVolumeScalar, scope), Float32(0)) { return main }
        let channels = [1, 2].compactMap { value(device, address(kAudioDevicePropertyVolumeScalar, scope, UInt32($0)), Float32(0)) }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
    }

    public static func setVolume(_ device: AudioObjectID, input: Bool, to level: Float) {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var volume = Float32(min(1, max(0, level)))
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = address(kAudioDevicePropertyVolumeScalar, scope, element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
            if element == kAudioObjectPropertyElementMain { return }
        }
    }

    /// Apps with audio open (macOS 14.4 and later).
    public static func clients() -> [AudioClient] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard let pid = value(object, address(kAudioProcessPropertyPID), pid_t(0)), pid > 0 else { return nil }
            let output = value(object, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0
            let input = value(object, address(kAudioProcessPropertyIsRunningInput), UInt32(0)) ?? 0
            return AudioClient(pid: pid, playing: output != 0, recording: input != 0)
        }
    }
}
