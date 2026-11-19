// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics

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
        checkCircularLayout()
        var viewport = PianoRollViewport()
        let first = CoreGraphics.CGPoint(x: 100, y: 120)
        let second = CoreGraphics.CGPoint(x: 200, y: 220)
        let anchorTick = viewport.tick(at: 150), anchorPitch = viewport.pitch(at: 170)
        var navigation = PianoRollNavigation(viewport: viewport, first: first, second: second)
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
        var arbitration = PianoRollTouchArbitration()
        arbitration.begin()
        precondition(arbitration.mode == .editing && arbitration.secondFinger())
        arbitration.fingerLifted(); arbitration.begin()
        precondition(arbitration.mode == .awaitingRelease)
        arbitration.allReleased(); arbitration.begin()
        precondition(arbitration.mode == .editing)
        arbitration.cancel()
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
        try regionEditor.regions(patternStart: 0, loopStart: 240, loopEnd: 960, tailEnd: 3840, loop: true)
        let regionPattern = regionEditor.pattern
        let markerViewport = PianoRollViewport()
        for marker in PianoRollMarker.allCases {
            let point = CoreGraphics.CGPoint(x: markerViewport.x(forTick: Double(marker.tick(in: regionPattern))),
                                             y: -60 + Double(marker.rawValue) * 15 + 7.5)
            precondition(PianoRollMarker.hit(point, pattern: regionPattern, viewport: markerViewport) == marker)
        }
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
