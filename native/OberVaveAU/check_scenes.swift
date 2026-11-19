// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics

@main
struct SceneChecks {
    static func checkSceneDefaults() throws {
        let instrument = RackInstrument.oberVave(slot: 0, channel: 1)
        var baseline = RackSceneDocument(name: "Scene", instruments: [instrument], tempo: 120,
            masterDB: 0, masterPan: 0, keyboardMask: 1, selectedSlot: 0,
            patterns: [SequencerPattern(slot: 0, row: 0, name: "Pattern")])
        var defaults = SceneDefaultLibrary()
        try defaults.seedMissing(baseline, scene: "one")
        precondition(defaults.value(scene: "one")?.patterns == nil)
        baseline.tempo = 140
        try defaults.seedMissing(baseline, scene: "one")
        precondition(defaults.value(scene: "one")?.tempo == 120)
        do {
            try defaults.set(baseline, scene: "one")
            fatalError("Scene default accepted patterns")
        } catch { }
        try defaults.copyScene(from: "one", to: "copy")
        baseline.patterns = nil
        try defaults.set(baseline, scene: "one")
        precondition(defaults.value(scene: "copy")?.tempo == 120)
        precondition(defaults.value(scene: "one")?.tempo == 140)
        let decoded = try JSONDecoder().decode(SceneDefaultLibrary.self, from: JSONEncoder().encode(defaults))
        try decoded.validate()
        precondition(decoded.value(scene: "one")?.tempo == 140)
        precondition(decoded.value(scene: "copy")?.patterns == nil)
        print("PASS scene defaults: saved baseline, no patterns, independent copy and serialization")
    }

    static func checkDefaultLibraries() throws {
        var instrument = RackInstrument.oberVave(slot: 0, channel: 1)
        let scene = RackSceneDocument(name: "Scene", instruments: [instrument], tempo: 120,
            masterDB: 0, masterPan: 0, keyboardMask: 1, selectedSlot: 0, patterns: nil)
        var pattern = SequencerPattern(slot: 0, row: 0, name: "Original")
        var libraries = DefaultLibraries(scenes: SceneDefaultLibrary(),
            instruments: InstrumentDefaultLibrary(), patterns: PatternDefaultLibrary(), sequencers: [:])
        try libraries.scenes.set(scene, scene: "one")
        try libraries.instruments.set(instrument, scene: "one")
        try libraries.patterns.replaceScene([pattern], scene: "one")
        try libraries.setPatternLayout([pattern], scene: "one")
        libraries.sequencers["one"] = SequencerDefault(launchGrid: 2, recordMode: 0, countBars: 1,
            recordOutput: true, columns: [SequencerDefault.Column(slot: 0, level: 0, pan: 0,
                                                                   muted: false, recordBeats: 4)])
        try libraries.validate()
        var decoded = try JSONDecoder().decode(DefaultLibraries.self, from: JSONEncoder().encode(libraries))
        try decoded.validate()
        instrument.parameters[SynthParameter.cutoff.rawValue] = 45
        pattern.name = "Changed"
        try decoded.instruments.set(instrument, scene: "one")
        try decoded.patterns.set(pattern, scene: "one", cell: PatternCell(slot: 0, row: 0))
        let again = try JSONDecoder().decode(DefaultLibraries.self, from: JSONEncoder().encode(decoded))
        precondition(again.instruments.value(scene: "one", instrument: instrument) == instrument)
        precondition(again.patterns.value(scene: "one", cell: PatternCell(slot: 0, row: 0)) == pattern)
        let defaultPatterns = try again.defaultPatterns(scene: "one", instruments: [instrument])
        precondition(defaultPatterns == [pattern])
        precondition(again.scenes.value(scene: "one")?.tempo == 120)
        precondition(again.sequencers["one"]?.launchGrid == 2)
        let target = try again.sceneRestoreTarget(scene: "one")
        precondition(target.document.instruments[0].parameters[SynthParameter.cutoff.rawValue] == 45)
        precondition(target.document.patterns == [pattern])
        precondition(target.document.instruments[0].levelDB == 0)
        precondition(target.sequencer.launchGrid == 2)
        var savedLayout = again
        var laterPattern = pattern
        laterPattern.name = "Current edit"
        var newPattern = laterPattern
        newPattern.row = 2
        try savedLayout.patterns.seedMissing([laterPattern, newPattern], scene: "one")
        try savedLayout.setPatternLayout([laterPattern, newPattern], scene: "one")
        let savedPatterns = try savedLayout.defaultPatterns(scene: "one", instruments: [instrument])
        precondition(savedPatterns == [pattern, newPattern])
        guard let settings = again.sequencers["one"] else { fatalError("Missing sequencer settings") }
        let priorEditor = try PianoRollEditBuffer(pattern: laterPattern)
        let currentCells = [
            SequencerCellSnapshot(cell: PatternCell(slot: 0, row: 0), pattern: laterPattern, pianoHistory: priorEditor),
            SequencerCellSnapshot(cell: PatternCell(slot: 0, row: 2), pattern: nil, pianoHistory: nil)
        ]
        let restore = try SequencerHistoryEntry.restoringDefault(beforeSettings: settings, targetSettings: settings,
                                                                  cells: currentCells, defaults: savedPatterns)
        precondition(restore.before.count == 2 && restore.after.map(\.pattern) == [pattern, newPattern])
        var restoredEditor = restore.after[0].pianoHistory
        precondition(restoredEditor?.canUndo == true)
        restoredEditor?.undo()
        precondition(restoredEditor?.pattern == laterPattern)
        var restoreHistory = SequencerHistory()
        restoreHistory.record(restore)
        precondition(restoreHistory.next(undo: true)?.before.count == 2)
        restoreHistory.acknowledge(restore, undo: true)
        precondition(restoreHistory.next(undo: false)?.after.count == 2)
        do {
            _ = try SequencerHistoryEntry.restoringDefault(beforeSettings: settings, targetSettings: settings,
                                                            cells: [currentCells[0]], defaults: savedPatterns)
            fatalError("Sequencer restore accepted missing cells")
        } catch { }
        var invalid = again
        invalid.sequencers[""] = invalid.sequencers["one"]
        do {
            try invalid.validate()
            fatalError("Invalid default library accepted")
        } catch { }
        invalid = again
        invalid.patternLayouts["one"] = [128]
        do {
            try invalid.validate()
            fatalError("Invalid pattern layout accepted")
        } catch { }
        invalid.patternLayouts["one"] = [0, 0]
        do {
            _ = try invalid.defaultPatterns(scene: "one", instruments: [instrument])
            fatalError("Duplicate pattern layout accepted")
        } catch { }
        do {
            _ = try again.defaultPatterns(scene: "one", instruments: [])
            fatalError("Pattern layout with missing instrument accepted")
        } catch { }
        invalid = again
        try invalid.patterns.set(nil, scene: "one", cell: PatternCell(slot: 0, row: 0))
        do {
            _ = try invalid.defaultPatterns(scene: "one", instruments: [instrument])
            fatalError("Pattern layout with missing default accepted")
        } catch { }
        do {
            _ = try invalid.sceneRestoreTarget(scene: "one")
            fatalError("Scene restore accepted a missing pattern default")
        } catch { }
        invalid = again
        invalid.sequencers["one"]?.columns = []
        do {
            _ = try invalid.sceneRestoreTarget(scene: "one")
            fatalError("Scene restore accepted mismatched instruments")
        } catch { }
        invalid = again
        invalid.instruments = InstrumentDefaultLibrary()
        let fallback = try invalid.sceneRestoreTarget(scene: "one")
        precondition(fallback.document.instruments[0].parameters == scene.instruments[0].parameters)
        let encoded = try JSONEncoder().encode(again)
        guard var old = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            fatalError("Expected default libraries JSON object")
        }
        old.removeValue(forKey: "patternLayouts")
        let migrated = try JSONDecoder().decode(DefaultLibraries.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(migrated.patternLayouts.isEmpty)
        try migrated.validate()
        var moved = again
        let source = PatternCell(slot: 0, row: 0)
        let destination = PatternCell(slot: 0, row: 1)
        try moved.transferPatternDefault(scene: "one", source: source, destination: destination,
                                         copying: true, deleting: false)
        precondition(moved.patternLayouts["one"] == [0, 1])
        var copied = pattern
        copied.row = 1
        precondition(moved.patterns.value(scene: "one", cell: destination) == copied)
        pattern.name = "Updated after copy"
        try moved.patterns.set(pattern, scene: "one", cell: source)
        precondition(moved.patterns.value(scene: "one", cell: destination) == copied)
        try moved.transferPatternDefault(scene: "one", source: source, destination: source,
                                         copying: false, deleting: true)
        precondition(moved.patternLayouts["one"] == [1])
        let third = PatternCell(slot: 0, row: 2)
        try moved.transferPatternDefault(scene: "one", source: destination, destination: third,
                                         copying: false, deleting: false)
        precondition(moved.patternLayouts["one"] == [2])
        try moved.setPatternLayoutMembership(true, scene: "one", cell: destination)
        try moved.setPatternLayoutMembership(false, scene: "one", cell: third)
        precondition(moved.patternLayouts["one"] == [1])
        try moved.transferPatternDefault(scene: "one", source: third, destination: destination,
                                         copying: true, deleting: false)
        precondition(moved.patternLayouts["one"] == [])
        precondition(moved.patterns.value(scene: "one", cell: destination) != nil)
        do {
            try moved.setPatternLayoutMembership(nil, scene: "one", cell: source)
            fatalError("Changed pattern layout accepted")
        } catch { }
        try moved.validate()
        let movedRoundTrip = try JSONDecoder().decode(DefaultLibraries.self, from: JSONEncoder().encode(moved))
        precondition(movedRoundTrip.patternLayouts["one"] == [])
        print("PASS default libraries: combined serialization and independent subsequent updates")
    }

    static func checkInstrumentDefaults() throws {
        var first = RackInstrument.oberVave(slot: 0, channel: 1)
        var second = RackInstrument.oberVave(slot: 1, channel: 2)
        first.parameters[SynthParameter.cutoff.rawValue] = 23
        second.parameters[SynthParameter.cutoff.rawValue] = 55
        var library = InstrumentDefaultLibrary()
        try library.set(first, scene: "one")
        try library.set(second, scene: "one")
        var savedBaseline = first
        savedBaseline.parameters[SynthParameter.cutoff.rawValue] = 81
        try library.seedMissing([savedBaseline], scene: "one")
        precondition(library.value(scene: "one", instrument: first) == first)
        try library.seedMissing([savedBaseline], scene: "baseline")
        precondition(library.value(scene: "baseline", instrument: first) == savedBaseline)
        precondition(library.value(scene: "one", instrument: first) == first)
        precondition(library.value(scene: "one", instrument: second) == second)
        var alternate = first
        alternate.programIndex += 1
        try library.set(alternate, scene: "one")
        precondition(library.value(scene: "one", instrument: first) == first)
        try library.copyScene(from: "one", to: "copy")
        first.parameters[SynthParameter.cutoff.rawValue] = 31
        try library.set(first, scene: "one")
        precondition(library.value(scene: "copy", instrument: first) != first)
        let decoded = try JSONDecoder().decode(InstrumentDefaultLibrary.self, from: JSONEncoder().encode(library))
        try decoded.validate()
        precondition(decoded == library)
        let encodedInstrument = try JSONEncoder().encode(first)
        guard var oldFields = try JSONSerialization.jsonObject(with: encodedInstrument) as? [String: Any] else {
            fatalError("Instrument JSON is not an object")
        }
        oldFields.removeValue(forKey: "defaultIdentity")
        let legacy = try JSONDecoder().decode(RackInstrument.self,
            from: JSONSerialization.data(withJSONObject: oldFields))
        precondition(legacy.defaultIdentity == nil)
        try library.set(legacy, scene: "legacy")
        let reopenedLegacy = try JSONDecoder().decode(RackInstrument.self,
            from: JSONSerialization.data(withJSONObject: oldFields))
        precondition(library.value(scene: "legacy", instrument: reopenedLegacy) == legacy)
        var replacement = RackInstrument.oberVave(slot: 0, channel: 1)
        precondition(library.value(scene: "one", instrument: replacement) == nil)
        replacement.parameters[SynthParameter.cutoff.rawValue] = 77
        try library.set(replacement, scene: "one")
        precondition(library.value(scene: "one", instrument: first) == first)
        precondition(library.value(scene: "one", instrument: replacement) == replacement)
        precondition(library.value(scene: "one", instrument: second) == second)
        precondition(library.value(scene: "copy", instrument: alternate) == alternate)
        do {
            try library.set(first, scene: "")
            fatalError("Empty scene key accepted")
        } catch { }
        print("PASS instrument defaults: scene, instrument and preset isolation, replacement, copy and serialization")
    }

    static func checkPatternDefaults() throws {
        let a = PatternCell(slot: 0, row: 1)
        let b = PatternCell(slot: 2, row: 3)
        let c = PatternCell(slot: 4, row: 5)
        var pattern = SequencerPattern(slot: a.slot, row: a.row, name: "Original")
        pattern.notes = [SequencerNote(id: 1, start: 0, duration: 240, pitch: 60, velocity: 100)]
        var library = PatternDefaultLibrary()
        try library.set(pattern, scene: "one", cell: a)
        var savedVersion = pattern
        savedVersion.name = "Saved scene version"
        try library.seedMissing([savedVersion], scene: "one")
        precondition(library.value(scene: "one", cell: a) == pattern)
        try library.seedMissing([savedVersion], scene: "fresh")
        precondition(library.value(scene: "fresh", cell: a) == savedVersion)
        try library.transfer(scene: "one", source: a, destination: b, copying: true, deleting: false)
        precondition(library.value(scene: "one", cell: a) == pattern)
        var copy = try { () throws -> SequencerPattern in
            guard let result = library.value(scene: "one", cell: b) else {
                throw SceneError.invalid("Copied default is missing.")
            }
            return result
        }()
        precondition(copy.slot == b.slot && copy.row == b.row && copy.notes == pattern.notes)
        copy.name = "Changed copy"
        try library.set(copy, scene: "one", cell: b)
        precondition(library.value(scene: "one", cell: a)?.name == "Original")
        try library.transfer(scene: "one", source: b, destination: c, copying: false, deleting: false)
        precondition(library.value(scene: "one", cell: b) == nil)
        precondition(library.value(scene: "one", cell: c)?.name == "Changed copy")
        precondition(library.value(scene: "two", cell: c) == nil)
        let roundTrip = try JSONDecoder().decode(PatternDefaultLibrary.self, from: JSONEncoder().encode(library))
        try roundTrip.validate()
        precondition(roundTrip.value(scene: "one", cell: c) == library.value(scene: "one", cell: c))
        try library.copyScene(from: "one", to: "other")
        try library.replaceScene([pattern, copy], scene: "one")
        precondition(library.value(scene: "one", cell: c) == nil)
        precondition(library.value(scene: "other", cell: c)?.name == "Changed copy")
        copy.name = "New individual default"
        try library.set(copy, scene: "one", cell: b)
        precondition(library.value(scene: "one", cell: b)?.name == "New individual default")
        do {
            try library.replaceScene([pattern, pattern], scene: "one")
            fatalError("Duplicate defaults accepted")
        } catch { }
        precondition(library.value(scene: "one", cell: b)?.name == "New individual default")
        var editor = try PianoRollEditBuffer(pattern: pattern)
        var restored = pattern
        restored.notes = [SequencerNote(id: 50, start: 120, duration: 240, pitch: 65, velocity: 90)]
        try editor.restoreDefault(restored)
        precondition(editor.pattern == restored && editor.canUndo)
        editor.undo()
        precondition(editor.pattern == pattern)
        editor.redo()
        precondition(editor.pattern == restored)
        try editor.create(start: 480, pitch: 67, duration: 240, velocity: 100, output: false)
        precondition(editor.pattern.notes.contains { $0.id == 51 })
        do {
            try editor.restoreDefault(copy)
            fatalError("A different cell default was accepted")
        } catch { }
        try library.transfer(scene: "one", source: c, destination: c, copying: false, deleting: true)
        precondition(library.value(scene: "one", cell: c) == nil)
        do {
            try library.set(pattern, scene: "one", cell: b)
            fatalError("Mismatched default accepted")
        } catch { }
        print("PASS pattern defaults: scene isolation, independent copy, move, deletion, validation and serialization")
    }

    static func checkSequencerDefaults() throws {
        let column = SequencerDefault.Column(slot: 0, level: -6, pan: 0.25, muted: false, recordBeats: 16)
        let baseline = SequencerDefault(launchGrid: 2, recordMode: 0, countBars: 1,
                                        recordOutput: true, columns: [column])
        try baseline.validate()
        let decoded = try JSONDecoder().decode(SequencerDefault.self, from: JSONEncoder().encode(baseline))
        precondition(decoded == baseline)
        let legacy = Data(#"{"slot":0,"level":-6,"pan":0.25,"muted":false,"recordBeats":16}"#.utf8)
        let legacyColumn = try JSONDecoder().decode(SequencerDefault.Column.self, from: legacy)
        precondition(legacyColumn == column)
        var after = baseline
        after.columns[0].muted = true
        after.launchGrid = 1
        var history = SequencerHistory()
        let entry = SequencerHistoryEntry(before: [], after: [], title: "Restore sequencer default",
            settings: SequencerSettingsEdit(before: baseline, after: after))
        let edit = SequencerSettingsEdit(before: baseline, after: after)
        var current = after
        current.columns[0].pan = -0.5
        current.countBars = 3
        current.columns.append(SequencerDefault.Column(slot: 1, level: -3, pan: 0,
                                                       muted: false, recordBeats: 4))
        let undone = try edit.applying(to: current, undo: true)
        precondition(undone.columns[0].muted == false && undone.launchGrid == baseline.launchGrid)
        precondition(undone.columns[0].pan == -0.5 && undone.countBars == 3 && undone.columns.count == 2)
        let redone = try edit.applying(to: undone, undo: false)
        precondition(redone == current)
        let gesture = SequencerMixerGesture(slot: 0, field: .pan)
        let panEdit = try SequencerSettingsEdit.mixerGesture(gesture, before: baseline, current: current)
        precondition(panEdit.after.columns[0].pan == -0.5)
        precondition(panEdit.after.columns[0].muted == baseline.columns[0].muted)
        precondition(panEdit.after.countBars == baseline.countBars && panEdit.after.columns.count == 1)
        let panUndo = try panEdit.applying(to: current, undo: true)
        precondition(panUndo.columns[0].pan == baseline.columns[0].pan)
        precondition(panUndo.columns[0].muted == current.columns[0].muted && panUndo.countBars == current.countBars)
        var longer = baseline
        longer.columns[0].recordBeats = 32
        let lengthEdit = SequencerSettingsEdit(before: baseline, after: longer)
        var longerWithOtherChanges = longer
        longerWithOtherChanges.columns[0].pan = -0.5
        longerWithOtherChanges.recordOutput = false
        let lengthUndo = try lengthEdit.applying(to: longerWithOtherChanges, undo: true)
        precondition(lengthUndo.columns[0].recordBeats == 16)
        precondition(lengthUndo.columns[0].pan == -0.5 && !lengthUndo.recordOutput)
        let unchanged = try SequencerSettingsEdit.mixerGesture(gesture, before: baseline, current: baseline)
        var noOpHistory = SequencerHistory()
        noOpHistory.record(SequencerHistoryEntry(before: [], after: [], settings: unchanged))
        precondition(noOpHistory.undoStack.isEmpty)
        var conflicting = current
        conflicting.launchGrid = 0
        do {
            _ = try edit.applying(to: conflicting, undo: true)
            fatalError("Changed sequencer setting accepted")
        } catch { }
        conflicting = current
        conflicting.columns.removeFirst()
        do {
            _ = try edit.applying(to: conflicting, undo: true)
            fatalError("Missing mixer column accepted")
        } catch { }
        history.record(entry)
        precondition(history.undoStack.count == 1)
        history.acknowledge(entry, undo: true)
        precondition(history.redoStack.count == 1)
        history.acknowledge(entry, undo: false)
        precondition(history.undoStack.count == 1)
        after.columns.append(column)
        do {
            try after.validate()
            fatalError("Duplicate mixer column accepted")
        } catch { }
        print("PASS sequencer defaults: validation, serialization and independent undo/redo")
    }

    static func checkDefaultGesture() {
        var gesture = DefaultButtonGesture()
        precondition(gesture.down(at: 0).isEmpty)
        precondition(gesture.up(at: 0.1).isEmpty)
        precondition(gesture.tick(at: 0.35) == [.restore])
        precondition(gesture.tick(at: 0.5).isEmpty)
        precondition(gesture.down(at: 1).isEmpty)
        precondition(gesture.up(at: 1.05).isEmpty)
        precondition(gesture.down(at: 1.1).isEmpty)
        precondition(gesture.up(at: 1.15).isEmpty)
        precondition(gesture.tick(at: 1.4) == [.restoreInstruments])
        precondition(gesture.down(at: 2).isEmpty)
        precondition(gesture.up(at: 2.05).isEmpty)
        precondition(gesture.down(at: 2.1).isEmpty)
        precondition(gesture.up(at: 2.15).isEmpty)
        precondition(gesture.down(at: 2.2).isEmpty)
        precondition(gesture.up(at: 2.25) == [.restoreScene])
        precondition(gesture.tick(at: 2.6).isEmpty)
        precondition(gesture.down(at: 3).isEmpty)
        precondition(gesture.tick(at: 3.5) == [.save])
        precondition(gesture.up(at: 3.6).isEmpty)
        precondition(gesture.down(at: 4).isEmpty)
        precondition(gesture.up(at: 4.05).isEmpty)
        precondition(gesture.down(at: 4.1).isEmpty)
        precondition(gesture.up(at: 4.6) == [.saveScene])
        precondition(gesture.tick(at: 5).isEmpty)
        precondition(gesture.down(at: 6).isEmpty)
        precondition(gesture.up(at: 6.05).isEmpty)
        precondition(gesture.down(at: 6.1).isEmpty)
        precondition(gesture.up(at: 6.15).isEmpty)
        precondition(gesture.down(at: 6.2).isEmpty)
        precondition(gesture.tick(at: 6.7) == [.saveAll])
        precondition(gesture.up(at: 6.8).isEmpty)
        precondition(gesture.down(at: 8).isEmpty)
        gesture.cancel()
        precondition(gesture.tick(at: 9).isEmpty)
        precondition(gesture.down(at: 10).isEmpty)
        precondition(gesture.up(at: 10.05).isEmpty)
        gesture.cancel()
        precondition(gesture.tick(at: 11).isEmpty)
        precondition(gesture.down(at: 12).isEmpty)
        precondition(gesture.up(at: 12.05).isEmpty)
        precondition(gesture.down(at: 12.4) == [.restore])
        precondition(gesture.up(at: 12.45).isEmpty)
        precondition(gesture.tick(at: 12.7) == [.restore])
        precondition(gesture.down(at: 13).isEmpty)
        precondition(gesture.up(at: 13.05).isEmpty)
        precondition(gesture.down(at: 13.1).isEmpty)
        gesture.cancel()
        precondition(gesture.tick(at: 14).isEmpty)
        print("PASS default gestures: single, double, triple, hold, tap-hold, double-tap-hold and cancellation")
    }

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

    static func checkUIRefreshDriver() {
        precondition(RackUIRefreshDriver.interval == 0.04)
        let driver = RackUIRefreshDriver()
        var fastTicks = 0
        var slowTicks = 0
        var received = false
        var readyAt = ProcessInfo.processInfo.systemUptime
        var receivedAt = 0.0
        driver.start {
            fastTicks += 1
            var clip = ov_seq_clip()
            var result: UInt32 = 0
            var epoch: UInt64 = 0
            if ov_seq_read_completion(&clip, &result, &epoch) != 0 {
                precondition(!received && result == 1 && clip.slot == 0 && clip.row == 7)
                precondition(ov_seq_record_state() == 0 && ov_seq_active(0) == 7)
                received = true
                receivedAt = ProcessInfo.processInfo.systemUptime - readyAt
            }
        } slow: {
            slowTicks += 1
        }
        precondition(ov_seq_arm(0, 7, 2, 1, 1, 1) != 0)
        var left = [Float](repeating: 0, count: 32)
        var right = left
        for _ in 0..<900 { ov_render(&left, &right, 32) }
        precondition(ov_seq_record_ready() != 0)
        readyAt = ProcessInfo.processInfo.systemUptime
        let until = Date().addingTimeInterval(0.55)
        while Date() < until {
            // Frequent view reevaluations must neither replace callbacks nor postpone polling.
            driver.start(fast: { fatalError("Refresh driver restarted") }, slow: { fatalError("Refresh driver restarted") })
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(received && fastTicks >= 10 && slowTicks >= 2 && slowTicks <= 4)
        precondition(receivedAt < 0.15, "Completed take refresh exceeded the UI polling budget")
        precondition(ov_seq_record_ready() == 0)
        precondition(ov_rack_stop_all() != 0)
        ov_render(&left, &right, 32)
        print("PASS persistent UI refresh: \(fastTicks) fast / \(slowTicks) slow polls, completion delivered at \(receivedAt)s without a view event or another action")
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
        var barLength = migrated
        for bars in [0, 1, 2, 8, 64] {
            barLength.setRecordBars(bars)
            precondition(barLength.recordBeats == bars * 4 && barLength.recordBars == Double(bars))
            let roundtrip = try JSONDecoder().decode(RackInstrument.self, from: JSONEncoder().encode(barLength))
            precondition(roundtrip.recordBars == Double(bars))
        }
        barLength.recordBeats = 13
        precondition(barLength.recordBars == 3.25)
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
        try checkSceneDefaults()
        try checkDefaultLibraries()
        try checkInstrumentDefaults()
        try checkSequencerDefaults()
        try checkPatternDefaults()
        checkDefaultGesture()
        checkCircularLayout()
        precondition(PianoRollGrid.visibleTicks(from: -300, through: 500, snap: 120, beatWidth: 96)
                     == [-240, -120, 0, 120, 240, 360, 480])
        precondition(PianoRollGrid.visibleTicks(from: 0, through: 100, snap: 0, beatWidth: 96).isEmpty)
        let denseGrid = PianoRollGrid.visibleTicks(from: 0, through: 100_000, snap: 1, beatWidth: 24)
        precondition(denseGrid.count <= 2049 && denseGrid.allSatisfy { $0 % 240 == 0 })
        precondition(PianoRollTapSequence.isPrefix(note: 2, lastNote: 2, elapsed: 0.39))
        precondition(!PianoRollTapSequence.isPrefix(note: 2, lastNote: 2, elapsed: 0.4))
        precondition(!PianoRollTapSequence.isPrefix(note: 2, lastNote: 1, elapsed: 0.1))
        precondition(!PianoRollTapSequence.isPrefix(note: 2, lastNote: nil, elapsed: 0.1))
        var viewport = PianoRollViewport()
        let first = CoreGraphics.CGPoint(x: 100, y: 120)
        let second = CoreGraphics.CGPoint(x: 200, y: 220)
        let anchorTick = viewport.tick(at: 150), anchorPitch = viewport.pitch(at: 170)
        var navigation = PianoRollNavigation(first: first, second: second)
        navigation.update(viewport: &viewport, first: first, second: CoreGraphics.CGPoint(x: 300, y: 220))
        precondition(viewport.beatWidth == 192 && viewport.pitchHeight == 20)
        precondition(abs(viewport.tick(at: 200) - anchorTick) < 0.000001)
        precondition(abs(viewport.pitch(at: 170) - anchorPitch) < 0.000001)
        navigation.update(viewport: &viewport, first: first, second: CoreGraphics.CGPoint(x: 300, y: 320))
        precondition(viewport.beatWidth == 192 && viewport.pitchHeight == 40)
        precondition(abs(viewport.pitch(at: 220) - anchorPitch) < 0.000001)
        navigation.update(viewport: &viewport, first: first, second: CoreGraphics.CGPoint(x: 102, y: 320))
        let crossedScale = viewport.beatWidth
        navigation.update(viewport: &viewport, first: first, second: CoreGraphics.CGPoint(x: 70, y: 320))
        precondition(viewport.beatWidth == crossedScale && viewport.beatWidth.isFinite)
        navigation.update(viewport: &viewport, first: first, second: CoreGraphics.CGPoint(x: -10000, y: -10000))
        precondition(viewport.beatWidth <= PianoRollViewport.maximumBeatWidth &&
                     viewport.pitchHeight <= PianoRollViewport.maximumPitchHeight)
        var simultaneous = PianoRollViewport()
        var simultaneousNavigation = PianoRollNavigation(first: .init(x: 100, y: 120),
                                                         second: .init(x: 200, y: 220))
        let tickAnchor = simultaneous.tick(at: 150), pitchAnchor = simultaneous.pitch(at: 170)
        simultaneousNavigation.update(viewport: &simultaneous, first: .init(x: 80, y: 100),
                                      second: .init(x: 260, y: 280))
        precondition(abs(simultaneous.beatWidth - 172.8) < 0.000001 &&
                     abs(simultaneous.pitchHeight - 36) < 0.000001)
        precondition(abs(simultaneous.tick(at: 170) - tickAnchor) < 0.000001 &&
                     abs(simultaneous.pitch(at: 190) - pitchAnchor) < 0.000001)
        var bounded = PianoRollViewport()
        bounded.leftTick = 4790
        var boundedNavigation = PianoRollNavigation(first: .init(x: 100, y: 100),
                                                    second: .init(x: 200, y: 200))
        boundedNavigation.update(viewport: &bounded, first: .init(x: 0, y: 100),
                                 second: .init(x: 100, y: 200))
        bounded.clamp(length: 3840, intro: 0, size: .init(width: 600, height: 400))
        precondition(bounded.leftTick == 4800)
        boundedNavigation.update(viewport: &bounded, first: .init(x: 10, y: 100),
                                 second: .init(x: 110, y: 200))
        precondition(abs(bounded.leftTick - 4700) < 0.000001)
        var limited = PianoRollViewport()
        var limitedNavigation = PianoRollNavigation(first: .init(x: 0, y: 0), second: .init(x: 100, y: 100))
        limitedNavigation.update(viewport: &limited, first: .init(x: 0, y: 0), second: .init(x: 1000, y: 100))
        precondition(limited.beatWidth == PianoRollViewport.maximumBeatWidth)
        limitedNavigation.update(viewport: &limited, first: .init(x: 0, y: 0), second: .init(x: 900, y: 100))
        precondition(limited.beatWidth < PianoRollViewport.maximumBeatWidth)
        var arbitration = PianoRollTouchArbitration()
        arbitration.begin()
        precondition(arbitration.mode == .editing && arbitration.secondFinger())
        arbitration.fingerLifted(); arbitration.begin()
        precondition(arbitration.mode == .awaitingRelease)
        arbitration.allReleased(); arbitration.begin()
        precondition(arbitration.mode == .editing)
        arbitration.cancel()
        precondition(arbitration.mode == .idle)
        arbitration.begin(); arbitration.abandonEdit(); arbitration.begin()
        precondition(arbitration.mode == .awaitingRelease)
        arbitration.allReleased()
        precondition(arbitration.mode == .idle)
        viewport.leftTick = 1_000_000; viewport.topPitch = -100
        viewport.clamp(length: 3840, intro: 0, size: .init(width: 600, height: 400))
        precondition(viewport.leftTick == 4800 && viewport.topPitch == 0)
        viewport.leftTick = -1_000_000; viewport.topPitch = 1_000_000
        viewport.clamp(length: 3840, intro: 960, size: .init(width: 600, height: 400))
        precondition(viewport.leftTick >= -960 - 600 * 960 / viewport.beatWidth &&
                     viewport.topPitch <= 127 + 400 / viewport.pitchHeight)
        print("PASS piano roll navigation foundation: independent axes, moving midpoint anchor, dead zone/crossing, bounded zoom and touch arbitration")
        var editPattern = SequencerPattern(slot: 0, row: 0, name: "Edit")
        editPattern.notes = [
            SequencerNote(id: 1, start: 120, duration: 240, pitch: 60, velocity: 60),
            SequencerNote(id: 2, start: 360, duration: 480, pitch: 64, velocity: 90),
            SequencerNote(id: 3, start: 600, duration: 960, pitch: 67, velocity: 120, output: false)
        ]
        let hitViewport = PianoRollViewport()
        let noteRect = PianoRollNoteHit.rectangle(editPattern.notes[1], viewport: hitViewport)
        let y = noteRect.midY
        precondition(PianoRollNoteHit.pitch(y: y, viewport: hitViewport) == 64)
        precondition(PianoRollNoteHit.velocity(y: 0, height: 100) == 127 &&
                     PianoRollNoteHit.velocity(y: 100, height: 100) == 1 &&
                     PianoRollNoteHit.velocity(y: 50, height: 100) == 64)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.minX + 1, y: y),
            notes: editPattern.notes, viewport: hitViewport)?.zone == .velocity)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.midX, y: y),
            notes: editPattern.notes, viewport: hitViewport)?.zone == .body)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.maxX - 1, y: y),
            notes: editPattern.notes, viewport: hitViewport)?.zone == .duration)
        precondition(PianoRollNoteHit.zone(x: 0, width: 2) == .velocity &&
                     PianoRollNoteHit.zone(x: 1, width: 2) == .body &&
                     PianoRollNoteHit.zone(x: 2, width: 2) == .duration)
        let isolated = [editPattern.notes[1]]
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.minX - 6, y: y), radius: 6,
                                          notes: isolated, viewport: hitViewport)?.zone == .velocity)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.maxX + 6, y: y), radius: 6,
                                          notes: isolated, viewport: hitViewport)?.zone == .duration)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.midX, y: noteRect.minY - 5), radius: 5,
                                          notes: isolated, viewport: hitViewport)?.zone == .body)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.minX - 4, y: noteRect.minY - 4), radius: 5,
                                          notes: isolated, viewport: hitViewport) == nil)
        var short = editPattern.notes[1]
        short.duration = 1
        let shortRect = PianoRollNoteHit.rectangle(short, viewport: hitViewport)
        let shortTarget = PianoRollNoteHit.target(shortRect)
        precondition(shortTarget.width == 18)
        precondition(PianoRollNoteHit.hit(point: .init(x: shortTarget.minX + 1, y: shortRect.midY),
                                          notes: [short], viewport: hitViewport)?.zone == .velocity)
        precondition(PianoRollNoteHit.hit(point: .init(x: shortTarget.maxX - 1, y: shortRect.midY),
                                          notes: [short], viewport: hitViewport)?.zone == .duration)
        var neighbor = editPattern.notes[1]
        neighbor.id = 99; neighbor.pitch += 1
        let neighborRect = PianoRollNoteHit.rectangle(neighbor, viewport: hitViewport)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.midX, y: noteRect.midY), radius: 30,
                                          notes: [editPattern.notes[1], neighbor], viewport: hitViewport)?.id == editPattern.notes[1].id)
        precondition(PianoRollNoteHit.hit(point: .init(x: noteRect.midX, y: neighborRect.maxY),
                                          notes: [editPattern.notes[1], neighbor], viewport: hitViewport)?.id == neighbor.id)
        var pasted = try PianoRollEditBuffer(pattern: editPattern)
        pasted.selection = [1, 3]
        let copiedNotes = try pasted.copySelection()
        try pasted.paste(copiedNotes, at: 1000)
        precondition(pasted.pattern.notes.suffix(2).map(\.start) == [1000, 1480])
        precondition(pasted.pattern.notes.suffix(2).map(\.id) == [4, 5])
        precondition(pasted.pattern.notes.last?.output == false)
        pasted.undo()
        precondition(pasted.pattern == editPattern)
        pasted.redo()
        precondition(pasted.pattern.notes.count == 5)
        precondition(pasted.historyTitles(undo: true) == ["Notes · 5 → 3"])
        var historyJump = pasted
        historyJump.undo()
        precondition(historyJump.historyTitles(undo: false) == ["Notes · 3 → 5"])
        historyJump.redo()
        precondition(historyJump.pattern == pasted.pattern)
        try historyJump.transpose(by: 1)
        let latestJumpPattern = historyJump.pattern
        precondition(historyJump.historyTitles(undo: true) == ["Edit notes", "Notes · 5 → 3"])
        historyJump.undo(); historyJump.undo()
        precondition(historyJump.pattern == editPattern)
        precondition(historyJump.historyTitles(undo: false) == ["Notes · 3 → 5", "Edit notes"])
        historyJump.redo(); historyJump.redo()
        precondition(historyJump.pattern == latestJumpPattern)
        var copiedHistory = pasted.retargeted(to: PatternCell(slot: 2, row: 3))
        precondition(copiedHistory.pattern.slot == 2 && copiedHistory.pattern.row == 3 && copiedHistory.canUndo)
        copiedHistory.undo()
        precondition(copiedHistory.pattern.slot == 2 && copiedHistory.pattern.row == 3 &&
                     copiedHistory.pattern.notes == editPattern.notes)
        copiedHistory.redo()
        precondition(copiedHistory.pattern.slot == 2 && copiedHistory.pattern.row == 3 &&
                     copiedHistory.pattern.notes.count == 5)
        precondition(pasted.pattern.slot == editPattern.slot && pasted.pattern.row == editPattern.row)
        let historyCell = PatternCell(slot: pasted.pattern.slot, row: pasted.pattern.row)
        let filled = SequencerCellSnapshot(cell: historyCell, pattern: pasted.pattern, pianoHistory: pasted)
        let empty = SequencerCellSnapshot(cell: historyCell, pattern: nil, pianoHistory: nil)
        let deletedEntry = SequencerHistoryEntry(before: [filled], after: [empty])
        var sequenceHistory = SequencerHistory()
        sequenceHistory.record(deletedEntry)
        precondition(sequenceHistory.undoStack.count == 1 && sequenceHistory.redoStack.isEmpty)
        let pendingUndo = sequenceHistory.next(undo: true)!
        precondition(sequenceHistory.undoStack.count == 1 && sequenceHistory.redoStack.isEmpty)
        sequenceHistory.acknowledge(pendingUndo, undo: true)
        precondition(sequenceHistory.undoStack.isEmpty && sequenceHistory.redoStack.count == 1)
        var restoredHistory = sequenceHistory.next(undo: false)!.before[0].pianoHistory!
        restoredHistory.undo()
        precondition(restoredHistory.pattern == editPattern && pasted.pattern.notes.count == 5)
        sequenceHistory.acknowledge(deletedEntry, undo: false)
        sequenceHistory.acknowledge(deletedEntry, undo: true)
        sequenceHistory.record(deletedEntry)
        precondition(sequenceHistory.redoStack.isEmpty && sequenceHistory.undoStack.count == 1)
        sequenceHistory.record(SequencerHistoryEntry(before: [empty], after: [empty]))
        precondition(sequenceHistory.undoStack.count == 1)
        for _ in 0..<40 { sequenceHistory.record(deletedEntry) }
        precondition(sequenceHistory.undoStack.count == 32)
        print("PASS sequencer history: acknowledged undo/redo, restored piano history, branching and bounded storage")
        var soundHistory = SceneParameterHistory()
        var savedSound = RackInstrument.oberVave(slot: 0, channel: 1)
        let priorSound = savedSound
        savedSound.parameters[SynthParameter.cutoff.rawValue] = 23
        savedSound.cc[SynthParameter.cutoff.rawValue] = 74
        var presetHistory = SceneParameterHistory()
        presetHistory.recordSound(before: priorSound, after: priorSound)
        precondition(presetHistory.undoStack.isEmpty)
        presetHistory.recordSound(before: priorSound, after: savedSound)
        precondition(presetHistory.undoStack == [.sounds([SceneSoundEdit(before: priorSound, after: savedSound)])])
        presetHistory.acknowledge(undo: true)
        precondition(presetHistory.redoStack == [.sounds([SceneSoundEdit(before: priorSound, after: savedSound)])])
        presetHistory.acknowledge(undo: false)
        precondition(presetHistory.undoStack.count == 1 && presetHistory.redoStack.isEmpty)
        let otherBefore = RackInstrument.oberVave(slot: 1, channel: 2)
        var otherAfter = otherBefore
        otherAfter.parameters[SynthParameter.cutoff.rawValue] = 37
        let group = [SceneSoundEdit(before: priorSound, after: savedSound),
                     SceneSoundEdit(before: otherBefore, after: otherAfter)]
        var groupedHistory = SceneParameterHistory()
        groupedHistory.recordSounds(group + [SceneSoundEdit(before: otherBefore, after: otherBefore)])
        precondition(groupedHistory.undoStack == [.sounds(group)])
        groupedHistory.acknowledge(undo: true)
        precondition(groupedHistory.redoStack == [.sounds(group)])
        groupedHistory.acknowledge(undo: false)
        precondition(groupedHistory.undoStack == [.sounds(group)] && groupedHistory.redoStack.isEmpty)
        let soundEdit = SceneParameterEdit(slot: 0, parameter: 1, before: 10, after: 40)
        soundHistory.record([soundEdit])
        precondition(soundHistory.undoStack == [.parameters([soundEdit])] && soundHistory.redoStack.isEmpty)
        soundHistory.acknowledge(undo: true)
        precondition(soundHistory.undoStack.isEmpty && soundHistory.redoStack == [.parameters([soundEdit])])
        soundHistory.acknowledge(undo: false)
        precondition(soundHistory.undoStack == [.parameters([soundEdit])] && soundHistory.redoStack.isEmpty)
        soundHistory.acknowledge(undo: true)
        soundHistory.record([SceneParameterEdit(slot: 0, parameter: 1, before: 10, after: 20)])
        precondition(soundHistory.redoStack.isEmpty)
        soundHistory.record([SceneParameterEdit(slot: 0, parameter: 1, before: 20, after: 20)])
        precondition(soundHistory.undoStack.count == 1)
        for _ in 0..<40 { soundHistory.record([soundEdit]) }
        precondition(soundHistory.undoStack.count == 32)
        let masterEdit = SceneValueEdit(field: .masterPan, before: 0, after: 0.5)
        soundHistory.record(masterEdit)
        precondition(soundHistory.undoStack.last == .value(masterEdit) && soundHistory.undoStack.count == 32)
        soundHistory.acknowledge(undo: true)
        precondition(soundHistory.redoStack.last == .value(masterEdit))
        var routeBefore = RackInstrument.oberVave(slot: 0, channel: 1)
        routeBefore.name = "Original"
        var routeAfter = routeBefore
        routeAfter.channel = 2
        routeAfter.name = "Edited"
        let routeEdit = SceneRouteEdit(before: routeBefore, after: routeAfter)
        precondition(routeEdit.mask == 1)
        var currentRoute = routeAfter
        currentRoute.levelDB = -12
        routeEdit.apply(to: &currentRoute, undo: true)
        precondition(currentRoute.channel == 1 && currentRoute.name == "Original" && currentRoute.levelDB == -12)
        soundHistory.record(routeEdit)
        precondition(soundHistory.undoStack.last == .route(routeEdit) && soundHistory.redoStack.isEmpty)
        var midiGesture = ExternalParameterGesture(epoch: 1, source: 7, status: 0xB0,
                                                   controller: 74, frame: 100)
        midiGesture.merge(slot: 0, before: [10, 5], after: [20, 5])
        midiGesture.merge(slot: 1, before: [2, 5], after: [9, 5])
        midiGesture.merge(slot: 0, before: [20, 5], after: [30, 5])
        precondition(midiGesture.edits == [
            SceneParameterEdit(slot: 0, parameter: 0, before: 10, after: 30),
            SceneParameterEdit(slot: 1, parameter: 0, before: 2, after: 9)])
        precondition(!midiGesture.expired(at: 100 + 22_049))
        precondition(midiGesture.expired(at: 100 + 22_050))
        midiGesture.frame = UInt32.max - 10
        precondition(midiGesture.expired(at: 22_039))
        print("PASS parameter history: acknowledged undo/redo, no-op filtering, branching and bounded storage")
        let beforeInvalidPaste = pasted.pattern
        do {
            try pasted.paste(copiedNotes, at: editPattern.length - 1)
            preconditionFailure("Out-of-range paste must fail")
        } catch { precondition(pasted.pattern == beforeInvalidPaste) }
        var quantizedEditor = try PianoRollEditBuffer(pattern: editPattern)
        try quantizedEditor.playbackQuantization(grid: 240)
        try quantizedEditor.playbackQuantization(grid: 120)
        precondition(quantizedEditor.pattern.notes == editPattern.notes)
        quantizedEditor.undo()
        precondition(quantizedEditor.pattern.quantize == 240 && quantizedEditor.pattern.notes == editPattern.notes)
        quantizedEditor.undo()
        precondition(quantizedEditor.pattern == editPattern)
        var regionEditor = try PianoRollEditBuffer(pattern: editPattern)
        var legacyMarkerEditor = regionEditor
        try legacyMarkerEditor.moveMarker(.patternStart, to: 240)
        precondition(legacyMarkerEditor.pattern.hasRegions && legacyMarkerEditor.pattern.patternStart == 240 &&
                     legacyMarkerEditor.pattern.loopStart == 0 &&
                     legacyMarkerEditor.pattern.loopEnd == editPattern.length &&
                     legacyMarkerEditor.pattern.notes == editPattern.notes)
        legacyMarkerEditor.undo()
        precondition(legacyMarkerEditor.pattern == editPattern)
        legacyMarkerEditor.redo()
        precondition(legacyMarkerEditor.pattern.patternStart == 240)
        try legacyMarkerEditor.moveMarker(.patternStart, to: 0)
        precondition(legacyMarkerEditor.pattern.patternStart == legacyMarkerEditor.pattern.loopStart)
        try regionEditor.regions(patternStart: 0, loopStart: 240, loopEnd: 960, tailEnd: 3840, loop: true)
        let regionPattern = regionEditor.pattern
        precondition(regionPattern.version == 6 && regionPattern.patternStart == 0)
        var independent = regionEditor
        try independent.regions(patternStart: 200, loopStart: 240, loopEnd: 960, tailEnd: 3840, loop: true)
        precondition(independent.pattern.notes == editPattern.notes && independent.pattern.patternStart == 200)
        let independentJSON = try JSONEncoder().encode(independent.pattern)
        let decodedIndependent = try JSONDecoder().decode(SequencerPattern.self, from: independentJSON)
        precondition(decodedIndependent == independent.pattern)
        precondition(SequencerPattern(core: independent.pattern.coreClip()) == independent.pattern)
        try independent.regions(patternStart: -480, loopStart: -240, loopEnd: 960, tailEnd: 3840, loop: true)
        precondition(independent.pattern.intro == 480 && independent.pattern.loopStart == -240)
        try independent.regions(patternStart: 240, loopStart: -480, loopEnd: 960, tailEnd: 3840, loop: true)
        let earlierLoop = independent.pattern
        precondition(earlierLoop.patternStart == 240 && earlierLoop.loopStart == -480 &&
                     earlierLoop.notes == editPattern.notes)
        let earlierJSON = try JSONEncoder().encode(earlierLoop)
        let earlierDecoded = try JSONDecoder().decode(SequencerPattern.self, from: earlierJSON)
        precondition(earlierDecoded == earlierLoop && SequencerPattern(core: earlierLoop.coreClip()) == earlierLoop)
        independent.undo()
        precondition(independent.pattern.loopStart == -240)
        independent.redo()
        precondition(independent.pattern == earlierLoop)
        try independent.regions(patternStart: 240, loopStart: 240, loopEnd: 960, tailEnd: 3840, loop: true)
        precondition(independent.pattern.patternStart == independent.pattern.loopStart)
        let markerViewport = PianoRollViewport()
        for marker in PianoRollMarker.allCases {
            let point = CoreGraphics.CGPoint(x: markerViewport.x(forTick: Double(marker.tick(in: regionPattern))),
                                             y: -60 + Double(marker.rawValue) * 15 + 7.5)
            precondition(PianoRollMarker.hit(point, pattern: regionPattern, viewport: markerViewport) == marker)
        }
        for position: Int64 in [-120, 0, 960, 3839, 3840, 1234567, SequencerPattern.maxTicks] {
            precondition(PianoRollPosition.parse(PianoRollPosition.format(position)) == position)
        }
        precondition(PianoRollPosition.parse("1:4:959") == 3839)
        precondition(PianoRollPosition.parse("0:1:0") == nil &&
                     PianoRollPosition.parse("1:5:0") == nil &&
                     PianoRollPosition.parse("1:1:960") == nil &&
                     PianoRollPosition.parse("9999999999999999999:1:0") == nil)
        let regionJSON = try JSONEncoder().encode(regionPattern)
        let decodedRegion = try JSONDecoder().decode(SequencerPattern.self, from: regionJSON)
        precondition(decodedRegion == regionPattern)
        precondition(SequencerPattern(core: regionPattern.coreClip()) == regionPattern)
        regionEditor.undo()
        precondition(regionEditor.pattern == editPattern)
        regionEditor.redo()
        precondition(regionEditor.pattern == regionPattern)
        do {
            try regionEditor.regions(patternStart: 0, loopStart: 0, loopEnd: 240, tailEnd: 240, loop: true)
            preconditionFailure("Shortening cannot delete notes")
        } catch { precondition(regionEditor.pattern == regionPattern) }
        let points = [
            SequencerAutomation(id: 1, tick: 480, kind: .cc, controller: 1, value: 127),
            SequencerAutomation(id: 2, tick: 480, kind: .pitchBend, controller: 0, value: 8192)
        ]
        try regionEditor.setAutomation(points)
        let automatedPattern = regionEditor.pattern
        let automatedJSON = try JSONEncoder().encode(automatedPattern)
        let decodedAutomation = try JSONDecoder().decode(SequencerPattern.self, from: automatedJSON)
        precondition(decodedAutomation == automatedPattern)
        precondition(SequencerPattern(core: automatedPattern.coreClip()) == automatedPattern)
        var json = try JSONSerialization.jsonObject(with: automatedJSON) as! [String: Any]
        var jsonPoints = json["automation"] as! [[String: Any]]
        jsonPoints[0]["kind"] = 99
        json["automation"] = jsonPoints
        let unknownKind = try JSONSerialization.data(withJSONObject: json)
        do {
            _ = try JSONDecoder().decode(SequencerPattern.self, from: unknownKind)
            preconditionFailure("Unknown automation kinds must fail")
        } catch {}
        regionEditor.undo()
        precondition(regionEditor.pattern == regionPattern)
        regionEditor.redo()
        precondition(regionEditor.pattern == automatedPattern)
        regionEditor.selection = [1]
        try regionEditor.quantizeNotes(grid: 240, strength: 50, ends: true)
        let perNotePattern = regionEditor.pattern
        precondition(perNotePattern.version == 6 && perNotePattern.notes[0].start == automatedPattern.notes[0].start &&
                     perNotePattern.notes[0].quantization == NoteQuantization(grid: 240, strength: 50, ends: true) &&
                     perNotePattern.notes[1].quantization == nil)
        let perNoteJSON = try JSONEncoder().encode(perNotePattern)
        let decodedPerNote = try JSONDecoder().decode(SequencerPattern.self, from: perNoteJSON)
        precondition(decodedPerNote == perNotePattern)
        precondition(SequencerPattern(core: perNotePattern.coreClip()) == perNotePattern)
        var combinedEditor = regionEditor
        try combinedEditor.regions(patternStart: -480, loopStart: -240, loopEnd: 960, tailEnd: 3840, loop: true)
        let combined = combinedEditor.pattern
        precondition(combined.version == 6 && combined.patternStart == -480 &&
                     combined.loopStart == -240 && combined.automation == perNotePattern.automation &&
                     combined.notes[0].quantization == perNotePattern.notes[0].quantization)
        precondition(SequencerPattern(core: combined.coreClip()) == combined)
        let combinedJSON = try JSONEncoder().encode(combined)
        let decodedCombined = try JSONDecoder().decode(SequencerPattern.self, from: combinedJSON)
        precondition(decodedCombined == combined)
        try regionEditor.quantizeNotes(grid: 120, strength: 100, ends: false)
        precondition(regionEditor.pattern.notes[0].start == perNotePattern.notes[0].start)
        regionEditor.undo()
        precondition(regionEditor.pattern == perNotePattern)
        regionEditor.undo()
        precondition(regionEditor.pattern == automatedPattern)
        var invalidPoint = points[0]; invalidPoint.value = 128
        do {
            try regionEditor.setAutomation([invalidPoint])
            preconditionFailure("Invalid automation must be rejected")
        } catch { precondition(regionEditor.pattern == automatedPattern) }
        try regionEditor.automationStroke([(tick: 480, value: 10), (tick: 720, value: 20)],
                                          kind: .cc, controller: 1)
        precondition(regionEditor.pattern.automation.count == 3)
        precondition(regionEditor.pattern.automation.filter { $0.kind == .cc }.map(\.id) == [3, 4])
        precondition(regionEditor.pattern.automation.contains(where: { $0.kind == .pitchBend && $0.id == 2 }))
        regionEditor.undo()
        var simplifiedEditor = regionEditor
        let flatStroke = (0...300).map { (tick: Int64($0), value: 64) }
        try simplifiedEditor.automationStroke(flatStroke, kind: .cc, controller: 1)
        precondition(simplifiedEditor.pattern.automation.filter { $0.kind == .cc }.count == 2)
        simplifiedEditor.undo()
        precondition(simplifiedEditor.pattern == regionEditor.pattern)
        try regionEditor.automationStroke([(tick: 960, value: 64)], kind: .cc, controller: 1)
        precondition(regionEditor.pattern.automation.contains(where: { $0.id == 5 }))
        var editor = try PianoRollEditBuffer(pattern: editPattern)
        editor.selection = [1, 2, 3]
        try editor.changeDuration(by: 120)
        precondition(editor.pattern.notes.map(\.duration) == [360, 600, 1080])
        try editor.changeVelocity(by: 15)
        precondition(editor.pattern.notes.map(\.velocity) == [75, 105, 127])
        try editor.move(ticks: -9999, semitones: 9999)
        precondition(editor.pattern.notes.map(\.start) == [0, 240, 480])
        precondition(editor.pattern.notes.map(\.pitch) == [120, 124, 127])
        editor.undo()
        precondition(editor.pattern.notes.map(\.start) == [120, 360, 600] && editor.canRedo)
        editor.redo()
        precondition(editor.pattern.notes.map(\.pitch) == [120, 124, 127])
        try editor.move(ticks: 120, semitones: -12, copying: true)
        precondition(editor.pattern.notes.count == 6 && editor.selection == [4, 5, 6])
        precondition(editor.pattern.notes[5].output == false)
        editor.undo()
        precondition(editor.pattern.notes.count == 3 && editor.selection.isEmpty)
        editor.redo()
        editor.selection = [4, 5, 6]
        try editor.deleteSelection()
        precondition(editor.pattern.notes.count == 3 && !editor.canRedo)
        editor.undo()
        precondition(editor.pattern.notes.count == 6)
        editor.selection = [4, 5, 6]
        try editor.move(ticks: 0, semitones: 0, copying: true)
        precondition(editor.selection == [7, 8, 9] && !editor.canRedo)
        editor.undo()
        for _ in 0..<40 {
            editor.selection = [1]
            try editor.changeVelocity(by: 1)
        }
        var undoCount = 0
        while editor.canUndo { editor.undo(); undoCount += 1 }
        precondition(undoCount == 32)
        print("PASS piano roll edit buffer: additive group edits, common bounds, independent IDs/routing, atomic undo/redo and bounded history")
        var musicalEditor = try PianoRollEditBuffer(pattern: editPattern)
        try musicalEditor.create(start: 960, pitch: 61, duration: 240, velocity: 81, output: false)
        precondition(musicalEditor.selection == [4] && musicalEditor.pattern.notes.last?.output == false)
        try musicalEditor.conform(root: 0, scale: .major, direction: .nearest)
        precondition(musicalEditor.pattern.notes.last?.pitch == 60)
        musicalEditor.undo()
        try musicalEditor.conform(root: 0, scale: .major, direction: .up)
        precondition(musicalEditor.pattern.notes.last?.pitch == 62 && !musicalEditor.canRedo)
        musicalEditor.selection = []
        try musicalEditor.transpose(by: 12)
        precondition(musicalEditor.pattern.notes.map(\.pitch) == [72, 76, 79, 74])
        musicalEditor.selection = [4]
        try musicalEditor.transpose(by: -12)
        precondition(musicalEditor.pattern.notes.map(\.pitch) == [72, 76, 79, 62])
        let beforeInvalid = musicalEditor.pattern
        do {
            try musicalEditor.transpose(by: 100)
            preconditionFailure("Out-of-range transpose must be rejected")
        } catch { precondition(musicalEditor.pattern == beforeInvalid) }
        try musicalEditor.conform(root: 3, scale: .dorian, direction: .down)
        precondition(musicalEditor.pattern.notes.last?.pitch == 61)
        musicalEditor.undo()
        precondition(musicalEditor.pattern == beforeInvalid)
        print("PASS piano roll musical edits: note creation, all/selected transpose, bounds rejection, directional scale mapping and lower-pitch tie break")
        let publication = PendingPianoPublication(token: 42, epoch: 5, replacement: musicalEditor.pattern)
        var newer = editPattern
        newer.notes[0].pitch = 85
        precondition(publication.acknowledged(in: [newer], epoch: 6, revisionMatches: true) == [newer])
        precondition(publication.acknowledged(in: [newer], epoch: 5, revisionMatches: false) == [newer])
        precondition(publication.acknowledged(in: [newer], epoch: 5, revisionMatches: true) == [musicalEditor.pattern])
        print("PASS piano roll publication acknowledgement: newer scene and cell revisions are never overwritten")
        var testedCells = Set<PatternCell>()
        for offset in [CoreGraphics.CGPoint.zero, CoreGraphics.CGPoint(x: -118 * 8, y: 0),
                       CoreGraphics.CGPoint(x: 0, y: -240), CoreGraphics.CGPoint(x: -118 * 8, y: -240)] {
            let cells = Dictionary(uniqueKeysWithValues: (0..<16).flatMap { slot in
                (0..<8).map { row in
                    (PatternCell(slot: slot, row: row),
                     CoreGraphics.CGRect(x: 12 + CGFloat(slot) * 118 + offset.x,
                            y: 120 + CGFloat(row) * 60 + offset.y, width: 110, height: 54))
                }
            })
            let horizontal = CoreGraphics.CGRect(x: 12, y: 40, width: 1024, height: 700)
            let vertical = CoreGraphics.CGRect(x: 12 + offset.x, y: 100, width: 1900, height: 340)
            for (cell, frame) in cells {
                let center = CoreGraphics.CGPoint(x: frame.midX, y: frame.midY)
                let visible = horizontal.contains(center) && vertical.contains(center)
                precondition(PatternGridHitTesting.contains(center, cells: cells,
                    verticalViewport: vertical, horizontalViewport: horizontal) == visible)
                precondition(PatternGridHitTesting.target(at: center, cells: cells,
                    verticalViewport: vertical, horizontalViewport: horizontal, recordingCells: []) == (visible ? cell : nil))
                precondition(PatternGridHitTesting.target(at: center, cells: cells,
                    verticalViewport: vertical, horizontalViewport: horizontal, recordingCells: [cell.id]) == nil)
                if visible {
                    testedCells.insert(cell)
                    for copying in [false, true] {
                        var gesture = PatternCellGesture()
                        _ = gesture.down(at: 0, editable: true, dragAllowed: true)
                        if copying { precondition(gesture.tick(at: 0.46) == [.copyReady]) }
                        precondition(gesture.move(distance: 10, at: copying ? 0.5 : 0.1) == [.beginDrag(copy: copying)])
                        precondition(PatternGridHitTesting.contains(CoreGraphics.CGPoint(x: center.x, y: center.y + 10),
                            cells: cells, verticalViewport: vertical, horizontalViewport: horizontal))
                        precondition(gesture.up(at: 0.6) == [.drop])
                    }
                }
            }
            let gap = CoreGraphics.CGPoint(x: 125, y: 200)
            precondition(PatternGridHitTesting.contains(gap, cells: cells,
                verticalViewport: vertical, horizontalViewport: horizontal))
            precondition(PatternGridHitTesting.target(at: gap, cells: cells,
                verticalViewport: vertical, horizontalViewport: horizontal, recordingCells: []) == nil)
            for outside in [CoreGraphics.CGPoint(x: 11, y: 200), CoreGraphics.CGPoint(x: 200, y: 441)] {
                precondition(!PatternGridHitTesting.contains(outside, cells: cells,
                    verticalViewport: vertical, horizontalViewport: horizontal))
            }
        }
        precondition(testedCells.count == 16 * 8)
        var recordingInstruments = (0..<16).map { RackInstrument.oberVave(slot: $0, channel: 16 - $0) }
        for slot in 0..<16 {
            precondition(SequencerRecordingSelection.keyboardMask(slots: [slot], instruments: recordingInstruments) == 1 << (15 - slot))
        }
        precondition(SequencerRecordingSelection.keyboardMask(slots: [0, 3, 15], instruments: recordingInstruments) == 0x9001)
        recordingInstruments[3].channel = 16
        precondition(SequencerRecordingSelection.keyboardMask(slots: [0, 3], instruments: recordingInstruments) == 0x8000)
        for side in [36.0, 44.0, 58.0] {
            let cells = Dictionary(uniqueKeysWithValues: (0..<16).flatMap { slot in
                (0..<8).map { row in
                    (PatternCell(slot: slot, row: row),
                     CoreGraphics.CGRect(x: Double(slot) * (side + 8), y: Double(row) * (side + 6), width: side, height: side))
                }
            })
            let viewport = CoreGraphics.CGRect(x: 0, y: 0, width: 1100, height: 800)
            for (cell, frame) in cells {
                precondition(frame.width == frame.height && frame.width == side)
                precondition(PatternGridHitTesting.target(at: CoreGraphics.CGPoint(x: frame.midX, y: frame.midY),
                    cells: cells, verticalViewport: viewport, horizontalViewport: viewport, recordingCells: []) == cell)
            }
        }
        print("PASS compact squares: 36/44/58 pt hit targets; recording keyboard masks use instrument channels, multiple selections and shared-channel layers")
        print("PASS grid hit testing: MOVE/COPY from all visible columns and rows, scrolled coordinates, gaps, clipped cells and recording targets")
        var gesture = PatternCellGesture()
        func down(_ time: Double) {
            precondition(gesture.down(at: time, editable: true, dragAllowed: true).isEmpty)
        }
        down(0); precondition(gesture.up(at: 0.05).isEmpty)
        precondition(gesture.tick(at: 0.30) == [.tap])
        down(1); precondition(gesture.move(distance: 10, at: 1.05) == [.beginDrag(copy: false)])
        precondition(gesture.up(at: 1.10) == [.drop])
        down(2); _ = gesture.up(at: 2.05); down(2.15)
        precondition(gesture.move(distance: 10, at: 2.20) == [.beginDrag(copy: true)])
        precondition(gesture.up(at: 2.25) == [.drop])
        down(3); precondition(gesture.tick(at: 3.46) == [.copyReady])
        precondition(gesture.move(distance: 10, at: 3.50) == [.beginDrag(copy: true)])
        _ = gesture.up(at: 3.55)
        down(4); _ = gesture.up(at: 4.05); down(4.15)
        precondition(gesture.tick(at: 4.61) == [.copyReady])
        precondition(gesture.up(at: 4.65) == [.delete])
        down(5); _ = gesture.up(at: 5.05); down(5.15)
        precondition(gesture.up(at: 5.20) == [.edit] && gesture.tick(at: 6).isEmpty)
        _ = gesture.down(at: 7, editable: true, dragAllowed: false)
        precondition(gesture.move(distance: 10, at: 7.1) == [.scroll])
        precondition(gesture.up(at: 7.2).isEmpty)
        down(8); _ = gesture.up(at: 8.1); gesture.cancel()
        precondition(gesture.tick(at: 9).isEmpty)
        _ = gesture.down(at: 10, editable: false, dragAllowed: false)
        precondition(gesture.up(at: 10.1) == [.tap])
        _ = gesture.down(at: 11, editable: false, dragAllowed: false)
        precondition(gesture.hasInteraction && gesture.up(at: 11.6) == [.menu] && !gesture.hasInteraction)
        print("PASS gesture state machine: delayed single tap, direct MOVE, both COPY prefixes, stationary DELETE, double EDIT, scroll and cancellation without premature musical actions")
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
        var laterRecording = sourcePattern
        laterRecording.notes[0].pitch = 88
        let lateAck = move.acknowledged(in: [laterRecording], sourceUnchanged: false, destinationUnchanged: true)
        precondition(lateAck.contains(laterRecording) && lateAck.contains(moved[0]))
        let supersededAck = move.acknowledged(in: [laterRecording], sourceUnchanged: false, destinationUnchanged: false)
        precondition(supersededAck == [laterRecording])
        var deletion = move
        deletion.deleting = true
        let deleted = try deletion.applying(to: [sourcePattern, moved[0]])
        precondition(deleted == moved)
        let persisted = try JSONDecoder().decode([SequencerPattern].self, from: JSONEncoder().encode(copiedReplacement))
        precondition(persisted == copiedReplacement)
        do {
            _ = try move.applying(to: [laterRecording])
            preconditionFailure("Stale source must fail before publication")
        } catch is SceneError {}
        do {
            _ = try move.applying(to: [sourcePattern, moved[0]])
            preconditionFailure("Unconfirmed replacement must fail")
        } catch is SceneError {}
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
        checkUIRefreshDriver()
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
