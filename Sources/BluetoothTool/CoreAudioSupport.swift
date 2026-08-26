import CoreAudio
import Foundation

/// Thin, non-throwing wrappers over the CoreAudio HAL property API.
///
/// Every HAL read/write is "build an address, ask for a size, read into a buffer".
/// These helpers collapse that into one-liners so the rest of the code can talk
/// about devices and volumes instead of `UnsafeMutablePointer`.
enum CA {

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Read a single fixed-size value. `initial` only supplies the type and a
    /// safe starting value; it is overwritten on success.
    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, size, $0)
        }
        return status == noErr
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    /// Read a variable-length property as an array of fixed-size elements.
    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: T.self), count: count))
    }

    /// Total channel count across every stream in a scope. Zero means the device
    /// cannot play (or record) at all, which is how we filter to outputs.
    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Change notifications

    /// Observe a property, calling `handler` on the main queue. The returned
    /// token removes the listener when it is deallocated.
    static func observe(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        handler: @escaping () -> Void
    ) -> ListenerToken? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        return ListenerToken(object: object, address: address, block: block)
    }

    final class ListenerToken {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock

        init(object: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
            self.object = object
            self.address = address
            self.block = block
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
    }
}
