// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct SceneChecks {
    static func waitForSave(_ finished: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !finished() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(finished(), "Scene save did not finish without a view refresh")
    }

    static func checkSaveMonitor() {
        let monitor = SceneSaveMonitor()
        var left = [Float](repeating: 0, count: 32)
        var right = left
        func render() { ov_render(&left, &right, 32) }
        for cutoff in [43, 87] {
            ov_set_parameter(UInt32(SynthParameter.cutoff.rawValue), UInt32(cutoff))
            precondition(ov_rack_snapshot_request() != 0)
            var finished = false
            monitor.start(timeout: 0.5, interval: 0.005) {
                var captured = ov_scene_config()
                guard ov_rack_snapshot_read(&captured) != 0 else { return false }
                let parameters = withUnsafeBytes(of: captured.slots.0.config.parameters) {
                    Array($0.bindMemory(to: UInt8.self))
                }
                precondition(Int(parameters[SynthParameter.cutoff.rawValue]) == cutoff)
                finished = true
                return true
            } onTimeout: { fatalError("A ready audio snapshot timed out") }
            render()
            waitForSave { finished }
        }
        precondition(ov_rack_snapshot_request() != 0)
        var timedOut = false
        monitor.start(timeout: 0.02, interval: 0.005, poll: { false }) {
            timedOut = true
        }
        waitForSave { timedOut }
        render()
        var stale = ov_scene_config()
        precondition(ov_rack_snapshot_read(&stale) != 0)
        precondition(ov_rack_snapshot_request() != 0)
        var recovered = false
        monitor.start(interval: 0.005, poll: {
            var captured = ov_scene_config()
            recovered = ov_rack_snapshot_read(&captured) != 0
            return recovered
        }) {
            fatalError("Scene save monitor did not recover after timeout")
        }
        render()
        waitForSave { recovered }
        print("PASS scene save completes without view refresh, saves again after edits, times out and recovers")
    }

    static func rejects(_ value: RackSceneDocument) {
        do {
            try value.validate()
            fatalError("Invalid scene was accepted")
        } catch { }
    }

    static func checkSequencer(_ original: RackSceneDocument) throws {
        var document = original
        let legacy = try JSONDecoder().decode(RackSceneDocument.self, from: JSONEncoder().encode(document))
        precondition(legacy.patterns == nil)
        guard var oldFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.instruments[0])) as? [String: Any] else {
            fatalError("Instrument must encode as a JSON object")
        }
        oldFields.removeValue(forKey: "recordBeats")
        let migrated = try JSONDecoder().decode(RackInstrument.self, from: JSONSerialization.data(withJSONObject: oldFields))
        precondition(migrated.recordBeats == 4)
        document.instruments[0].recordBeats = 0
        document.instruments[1].recordBeats = 13
        var pattern = SequencerPattern(slot: 0, row: 3, name: "Pickup")
        pattern.intro = 480
        pattern.notes = [
            SequencerNote(id: 1, start: -480, duration: 720, pitch: 60, velocity: 100),
            SequencerNote(id: 2, start: 0, duration: 240, pitch: 64, velocity: 80, output: false)
        ]
        document.patterns = [pattern]
        try document.validate()
        let decoded = try JSONDecoder().decode(RackSceneDocument.self, from: JSONEncoder().encode(document))
        precondition(decoded.patterns == document.patterns)
        precondition(decoded.instruments[0].recordBeats == 0 && decoded.instruments[1].recordBeats == 13)
        precondition(SequencerPattern(core: pattern.coreClip()) == pattern)
        document.patterns = [pattern, pattern]; rejects(document)
        document.patterns = [pattern]; document.patterns?[0].slot = Int.max; rejects(document)
        document.patterns = [pattern]; document.patterns?[0].row = 8; rejects(document)
        document.patterns = [pattern]; document.patterns?[0].notes[0].start = -481; rejects(document)
        document.patterns = [pattern]; document.patterns?[0].notes[1].id = 1; rejects(document)
        document.patterns = [pattern]; document.patterns?[0].notes[0].velocity = 128; rejects(document)
        document.patterns = [pattern]; document.instruments[0].recordBeats = 257; rejects(document)
        document.instruments[0].recordBeats = 0
        pattern.intro = 11520; pattern.notes[0].start = -11520
        document.patterns = [pattern]; try document.validate()
        document.patterns?[0].intro = 11521; rejects(document)
        document.patterns = [pattern]
        document.patterns?[0].length = 960 * 1000
        document.patterns?[0].notes[0].duration = 960 * 600
        let longScene = try JSONDecoder().decode(RackSceneDocument.self, from: JSONEncoder().encode(document))
        try longScene.validate()
        precondition(longScene.patterns?[0].length == 960 * 1000)
        precondition(longScene.patterns?[0].notes[0].duration == 960 * 600)
        guard var oldPattern = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pattern)) as? [String: Any] else {
            fatalError("Pattern must encode as a JSON object")
        }
        oldPattern["version"] = 1; oldPattern["intro"] = 480
        oldPattern["notes"] = [["id": 1, "start": -480, "duration": 720, "pitch": 60, "velocity": 100, "output": true]]
        let migratedPattern = try JSONDecoder().decode(SequencerPattern.self, from: JSONSerialization.data(withJSONObject: oldPattern))
        precondition(migratedPattern.version == 2 && migratedPattern.intro == 480)
        document.patterns = [pattern]; document.instruments.removeAll { $0.slot == 0 }; rejects(document)
        print("PASS sequencer scene migration, JSON/core pickup roundtrip and invalid cells/IDs/notes/missing instruments")
    }

    static func checkCircularLayout() {
        var pattern = SequencerPattern(slot: 0, row: 0, name: "Geometry")
        precondition(CircularNoteLayout(pattern).arcs.isEmpty)
        pattern.notes = [SequencerNote(id: 1, start: 0, duration: 1920, pitch: 60, velocity: 100)]
        var layout = CircularNoteLayout(pattern)
        precondition(layout.lanes == 1 && layout.arcs.count == 1 && layout.arcs[0].end == 0.5)
        pattern.notes[0].start = 2880
        layout = CircularNoteLayout(pattern)
        precondition(layout.arcs.count == 2 && layout.arcs[0].end == 0.25 && layout.arcs[1].start == 0.75)
        pattern.notes[0].duration = 20000
        layout = CircularNoteLayout(pattern)
        precondition(layout.arcs.count == 1 && layout.arcs[0].start == 0 && layout.arcs[0].end == 1)
        pattern.notes = (0..<128).map {
            SequencerNote(id: UInt64($0 + 1), start: 0, duration: 1, pitch: $0, velocity: 100)
        }
        layout = CircularNoteLayout(pattern)
        precondition(layout.lanes == 8 && layout.arcs.count == 8 && layout.arcs[0].end == 1 / 360.0)
        pattern.intro = 960
        pattern.notes = [SequencerNote(id: 1, start: -960, duration: 100, pitch: 60, velocity: 100)]
        precondition(CircularNoteLayout(pattern).arcs.first?.pickup == true)
        pattern.introEnabled = false
        precondition(CircularNoteLayout(pattern).arcs.isEmpty)
        pattern.notes = (0..<1024).map {
            SequencerNote(id: UInt64($0 + 1), start: Int64($0 * 3), duration: 7000, pitch: $0 % 128, velocity: 100)
        }
        let start = Date()
        for _ in 0..<100 { precondition(CircularNoteLayout(pattern).arcs.count == 8) }
        print("PASS circular geometry: durations, wraps, bounded multilap arcs, short notes, 128-pitch lane compression, pickup; 100 dense layouts \(Date().timeIntervalSince(start))s")
    }

    static func main() throws {
        checkCircularLayout()
        var sourcePattern = SequencerPattern(slot: 0, row: 0, name: "Move")
        sourcePattern.notes = [SequencerNote(id: 1, start: 120, duration: 500, pitch: 60, velocity: 100)]
        let move = PatternTransfer(source: sourcePattern, destination: PatternCell(slot: 1, row: 2),
                                   sourceRevision: 1, targetRevision: 0, epoch: 1)
        let moved = try move.applying(to: [sourcePattern])
        precondition(moved.count == 1 && moved[0].slot == 1 && moved[0].row == 2 && moved[0].notes == sourcePattern.notes)
        let restored = try JSONDecoder().decode([SequencerPattern].self, from: JSONEncoder().encode(moved))
        precondition(restored == moved)
        var copy = move; copy.copying = true
        var copied = try copy.applying(to: [sourcePattern])
        precondition(copied.count == 2 && copied[1].notes == copied[0].notes)
        copied[1].notes[0].pitch = 80
        precondition(copied[0] == sourcePattern && copied[1].notes[0].pitch == 80)
        var replace = move
        replace.expectedDestination = moved[0]
        replace.replace = true
        let replaced = try replace.applying(to: [sourcePattern, moved[0]])
        precondition(replaced == moved)
        replace.copying = true
        let copiedReplacement = try replace.applying(to: [sourcePattern, moved[0]])
        precondition(copiedReplacement.count == 2)
        print("PASS transactional MOVE model: exact note preservation, destination identity and JSON persistence")
        precondition(SynthParameter.allCases.count == Int(ov_parameter_count()))
        precondition(SynthParameter.arpVelocity.audioUnitID == 64)
        precondition(SynthParameter.mod1Source.audioUnitID == 72 && SynthParameter.legacyWheel.audioUnitID == 96)
        precondition(ModulationMatrix.amountText(0) == "-100.0%")
        precondition(ModulationMatrix.amountText(64) == "+0.0%")
        precondition(ModulationMatrix.amountText(128) == "+100.0%")
        let legacyMappings = Array(repeating: -1, count: 65)
        let defaultMappings = SynthParameter.allCases.map { Int(ov_rack_default_cc(UInt32($0.rawValue))) }
        let expandedMappings = ModulationMatrix.migrateLegacy(legacyMappings, defaults: defaultMappings)
        precondition(expandedMappings.count == 202 && Array(expandedMappings.prefix(65)) == legacyMappings)
        precondition(expandedMappings.dropFirst(65).allSatisfy { $0 == 255 })
        precondition(ModulationMatrix.migrateLegacy(expandedMappings, defaults: defaultMappings) == expandedMappings)
        precondition(ControllerRouting.sources.count == 132 && ControllerRouting.targetNames.count == 65)
        precondition(ControllerRouting.parameter(0, 0).audioUnitID == 97)
        precondition(ControllerRouting.parameter(15, 6).audioUnitID == 208)
        precondition(ModulationMatrix.migrateLegacy(Array(defaultMappings.prefix(90)),
            defaults: defaultMappings) == defaultMappings)
        for slot in 0..<8 {
            let p = ModulationMatrix.parameters(slot: slot)
            precondition(p.source.rawValue == 65 + slot * 3)
            precondition(p.destination.rawValue == 66 + slot * 3)
            precondition(p.amount.rawValue == 67 + slot * 3)
        }
        var modulation = [Int](repeating: 0, count: SynthParameter.allCases.count)
        func routes() -> [LFOModulationRoute] { LFOModulationRoute.routes { modulation[$0.rawValue] } }
        precondition(routes().allSatisfy { $0.depth == 0 && $0.text.hasSuffix("OFF") && $0.warning == nil })
        modulation[SynthParameter.lfoPitchTarget.rawValue] = 1
        modulation[SynthParameter.lfoPitch.rawValue] = 73
        modulation[SynthParameter.lfoPulseTarget.rawValue] = 2
        modulation[SynthParameter.lfoPulseWidth.rawValue] = 64
        modulation[SynthParameter.osc1Wave.rawValue] = 2
        modulation[SynthParameter.osc2Wave.rawValue] = 1
        modulation[SynthParameter.modWheelDepth.rawValue] = 99
        modulation[SynthParameter.legacyWheel.rawValue] = 1
        precondition(routes()[0].text == "LFO → OSC 2 PITCH  73/127")
        precondition(routes()[1].warning == "OSC 2: enable PULSE wave for PWM")
        precondition(routes()[4].depth == 99 && routes()[4].destination.contains("OSC 1+2 PITCH + CUTOFF"))
        modulation[SynthParameter.legacyWheel.rawValue] = 0
        precondition(routes()[4].depth == 0)
        modulation[SynthParameter.osc2Wave.rawValue] = 3
        precondition(routes()[1].warning == nil)
        print("PASS LFO route labels: oscillator targets, independent wheel depth, OFF state and pulse-wave warnings")
        precondition(lfoRateText(0) == "0.05 Hz")
        precondition(lfoRateText(70) == "1.70 Hz")
        for rate in 0...127 {
            let text = lfoRateText(rate)
            let shown = Double(text.replacingOccurrences(of: " Hz", with: ""))!
            precondition(abs(shown - ov_lfo_rate_hz(UInt32(rate))) <= 0.005001)
        }
        print("PASS LFO displayed Hz tracks engine frequency within 0.005 Hz at every knob setting")
        for note in 0...127 {
            precondition(KeyboardZoneLayout.note(at: KeyboardZoneLayout.position(note)) == note)
            if note > 0 {
                precondition(KeyboardZoneLayout.position(note) > KeyboardZoneLayout.position(note - 1))
            }
        }
        precondition(KeyboardZoneLayout.note(at: -1) == 0)
        precondition(KeyboardZoneLayout.note(at: 2) == 127)
        precondition(KeyboardZoneLayout.whiteIndex(127) == 74)
        print("PASS full MIDI keyboard range geometry: 128 aligned marker positions and clamped drag endpoints")
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
        checkSaveMonitor()
        var instruments = (0..<16).map { RackInstrument.oberVave(slot: $0, channel: $0 + 1) }
        instruments[0].channel = 2
        instruments[0].lowNote = 24
        instruments[0].highNote = 64
        instruments[0].parameters[SynthParameter.cutoff.rawValue] = 87
        instruments[0].parameters[SynthParameter.mod1Source.rawValue] = 4
        instruments[0].parameters[SynthParameter.mod1Destination.rawValue] = 4
        instruments[0].parameters[SynthParameter.mod1Amount.rawValue] = 128
        instruments[0].parameters[SynthParameter.mod8Source.rawValue] = 7
        instruments[0].parameters[SynthParameter.mod8Destination.rawValue] = 7
        instruments[0].parameters[SynthParameter.mod8Amount.rawValue] = 0
        instruments[0].parameters[SynthParameter.legacyWheel.rawValue] = 0
        instruments[0].parameters[SynthParameter.ctl1Source.rawValue] = 2
        instruments[0].parameters[SynthParameter.ctl1Target.rawValue] = SynthParameter.lfoRate.rawValue
        instruments[0].parameters[SynthParameter.ctl1Mode.rawValue] = 1
        instruments[0].parameters[SynthParameter.ctl1Depth.rawValue] = 96
        instruments[0].parameters[SynthParameter.ctl1Override.rawValue] = 1
        instruments[0].parameters[SynthParameter.ctl16Source.rawValue] = 131
        instruments[0].cc[SynthParameter.cutoff.rawValue] = 19
        precondition(instruments.allSatisfy { $0.latchMode == 2 })
        instruments[0].arpMode = 7; instruments[0].latchMode = 2
        instruments[0].parameters[SynthParameter.arpMode.rawValue] = 7
        instruments[1].arpMode = 6
        instruments[1].parameters[SynthParameter.arpMode.rawValue] = 6
        instruments[2].arpMode = 8
        instruments[2].parameters[SynthParameter.arpMode.rawValue] = 8
        instruments[0].sync = true; instruments[0].grid = 4
        instruments[0].levelDB = -6.5; instruments[0].pan = -0.75
        var document = RackSceneDocument(name: "Split + Layer", instruments: instruments, tempo: 137,
            masterDB: -9, masterPan: 0.1, keyboardMask: 0x8003, selectedSlot: 7)
        try document.validate()
        try checkSequencer(document)
        let encoder = JSONEncoder()
        var oldInstrument = RackInstrument.oberVave(slot: 0, channel: 1)
        oldInstrument.parameters = Array(oldInstrument.parameters.prefix(65))
        oldInstrument.cc = Array(oldInstrument.cc.prefix(65))
        let migrated = try JSONDecoder().decode(RackInstrument.self, from: encoder.encode(oldInstrument))
        try migrated.validate()
        precondition(Array(migrated.parameters.prefix(65)) == oldInstrument.parameters)
        for slot in 0..<8 {
            let p = ModulationMatrix.parameters(slot: slot)
            precondition(migrated.parameters[p.source.rawValue] == 0 && migrated.parameters[p.amount.rawValue] == 64)
            precondition(migrated.cc[p.source.rawValue] == 255)
        }
        precondition(migrated.parameters[SynthParameter.legacyWheel.rawValue] == 1)
        var matrixInstrument = instruments[0]
        matrixInstrument.parameters = Array(matrixInstrument.parameters.prefix(90))
        matrixInstrument.cc = Array(matrixInstrument.cc.prefix(90))
        let migratedMatrix = try JSONDecoder().decode(RackInstrument.self, from: encoder.encode(matrixInstrument))
        try migratedMatrix.validate()
        precondition(Array(migratedMatrix.parameters.prefix(90)) == matrixInstrument.parameters)
        for slot in 0..<16 {
            precondition(migratedMatrix.parameters[ControllerRouting.parameter(slot, 0).rawValue] == 0)
            precondition(migratedMatrix.parameters[ControllerRouting.parameter(slot, 5).rawValue] == 64)
        }
        print("PASS matrix signed controls, stable AU IDs and legacy 65-parameter scene migration without sound changes")
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
