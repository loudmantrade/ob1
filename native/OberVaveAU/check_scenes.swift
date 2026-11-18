// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct SceneChecks {
    static func rejects(_ value: RackSceneDocument) {
        do {
            try value.validate()
            fatalError("Invalid scene was accepted")
        } catch { }
    }

    static func main() throws {
        var locks = KeyboardLockState()
        locks.lock(60)
        precondition(locks.notes.isEmpty)
        locks.enabled = true
        locks.lock(60); locks.lock(64); locks.lock(60)
        precondition(locks.notes == [60, 64])
        precondition(locks.release(60) == 1 && locks.release(60) == 0)
        precondition(locks.notes == [64])
        locks.clear(); precondition(locks.notes.isEmpty)
        locks.lock(60, channels: 1)
        locks.lock(60, channels: 2)
        locks.lock(64, channels: 4)
        precondition(locks.notes(on: 1) == [60] && locks.notes(on: 2) == [60])
        precondition(locks.notes(on: 4) == [64] && locks.notes(on: 8).isEmpty)
        precondition(locks.release(60, channels: 2) == 2)
        precondition(locks.channels(for: 60) == 1)
        precondition(locks.release(60, channels: 4) == 0)
        precondition(locks.channels(for: 60) == 1)
        precondition(locks.release(60, channels: 1) == 1)
        precondition(!locks.notes.contains(60) && locks.notes == [64])
        locks.clear()
        print("PASS per-channel key locks: same pitch on multiple channels, scoped visibility/release, inactive channels preserved")
        precondition(KeyboardLockState.isLockSwipe(startY: 40, endY: 140, keyHeight: 130, duration: 0.3))
        precondition(!KeyboardLockState.isLockSwipe(startY: 40, endY: 120, keyHeight: 130, duration: 0.3))
        precondition(!KeyboardLockState.isLockSwipe(startY: 125, endY: 140, keyHeight: 130, duration: 0.3))
        precondition(!KeyboardLockState.isLockSwipe(startY: 40, endY: 140, keyHeight: 130, duration: 0.6))
        precondition(!KeyboardLockState.isLockSwipe(startY: 40, endY: -10, keyHeight: 130, duration: 0.1))
        print("PASS keyboard key-lock: opt-in, independent notes, toggle release, clearing and fast downward boundary swipe")
        ov_init()
        var instruments = (0..<16).map { RackInstrument.oberVave(slot: $0, channel: $0 + 1) }
        instruments[0].channel = 2
        instruments[0].lowNote = 24
        instruments[0].highNote = 64
        instruments[0].parameters[SynthParameter.cutoff.rawValue] = 87
        instruments[0].cc[SynthParameter.cutoff.rawValue] = 19
        instruments[0].arpMode = 5; instruments[0].latchMode = 2
        instruments[0].sync = true; instruments[0].grid = 4
        instruments[0].levelDB = -6.5; instruments[0].pan = -0.75
        var document = RackSceneDocument(name: "Split + Layer", instruments: instruments, tempo: 137,
            masterDB: -9, masterPan: 0.1, keyboardMask: 0x8003, selectedSlot: 7)
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(document)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("obervave-scene-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appendingPathComponent("roundtrip.obscene.json")
        defer {
            do {
                try FileManager.default.removeItem(at: url)
                try FileManager.default.removeItem(at: folder)
            } catch { fatalError("Could not remove temporary scene files: \(error)") }
        }
        try encoded.write(to: url, options: .atomic)
        let decoded = try RackSceneDocument.read(from: url)
        try decoded.validate()
        precondition(decoded.instruments == document.instruments)
        precondition(decoded.keyboardMask == 0x8003 && decoded.tempo == 137 && decoded.selectedSlot == 7)
        for instrument in decoded.instruments {
            var copy = instrument
            copy.updateSound(instrument.coreConfig())
            precondition(copy == instrument)
        }
        print("PASS scene JSON/disk/core roundtrip: 16 sounds, zones, layers, CC maps, disabled-mode memory, mixer and keyboard channels")

        document.version = 2; rejects(document); document = decoded
        document.instruments.append(instruments[0]); rejects(document); document = decoded
        document.instruments[0].slot = 1; rejects(document); document = decoded
        document.instruments[0].engine = 99; rejects(document); document = decoded
        document.instruments[0].channel = 0; rejects(document); document = decoded
        document.instruments[0].lowNote = 120; rejects(document); document = decoded
        document.instruments[0].parameters[0] = 999; rejects(document); document = decoded
        document.instruments[0].cc.removeLast(); rejects(document); document = decoded
        document.instruments[0].levelDB = .nan; rejects(document); document = decoded
        document.keyboardMask = 0x10000; rejects(document); document = decoded
        document.selectedSlot = 100; rejects(document); document = decoded
        document.instruments = []; document.selectedSlot = nil; try document.validate()
        print("PASS scene validation rejects unknown versions/engines, duplicate slots, invalid zones/channels/parameters and nonfinite mixer values; empty scenes are valid")
    }
}
