// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct KeyboardLockState {
    var enabled = false
    private(set) var channelsByNote: [UInt32: UInt32] = [:]
    var notes: Set<UInt32> { Set(channelsByNote.keys) }

    func channels(for note: UInt32) -> UInt32 { channelsByNote[note] ?? 0 }

    func notes(on channels: UInt32) -> Set<UInt32> {
        Set(channelsByNote.compactMap { $0.value & channels != 0 ? $0.key : nil })
    }

    mutating func lock(_ note: UInt32, channels: UInt32 = 1) {
        let mask = channels & 0xFFFF
        if enabled && mask != 0 { channelsByNote[note, default: 0] |= mask }
    }

    @discardableResult
    mutating func release(_ note: UInt32, channels: UInt32 = 1) -> UInt32 {
        let released = self.channels(for: note) & channels
        let remaining = self.channels(for: note) & ~released
        channelsByNote[note] = remaining == 0 ? nil : remaining
        return released
    }

    mutating func clear() { channelsByNote.removeAll() }

    static func isLockSwipe(startY: CGFloat, endY: CGFloat, keyHeight: CGFloat,
                            duration: TimeInterval) -> Bool {
        duration >= 0 && duration <= 0.45 && endY > keyHeight && endY - startY >= 20
    }
}
