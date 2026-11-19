// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum MIDIChannelColors {
    private static let palette: [UInt32] = [
        0x45D5F5, 0xFF9270, 0xA7DE65, 0xC5A0FF,
        0xFFD45C, 0xFF8FBB, 0x5EE0B5, 0x8FAAFF,
        0xE2B385, 0xDC9AE8, 0x8CCBEB, 0xD5DD81,
        0xF5A6A0, 0x9CCDB4, 0xB9B0E8, 0xD9C6A0
    ]

    static func color(_ channel: Int) -> Color {
        precondition((1...16).contains(channel))
        let rgb = palette[channel - 1]
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }

    static func channels(in mask: UInt32) -> [Int] {
        (1...16).filter { mask & (1 << ($0 - 1)) != 0 }
    }
}

private final class RackSidebarMeters: ObservableObject {
    @Published private(set) var levels = [Double](repeating: 0, count: 16)

    func refresh() {
        levels = (0..<16).map { slot in
            let peak = Double(ov_rack_take_level(UInt32(slot))) / 65535
            let decibels = 20 * log10(max(peak, 0.000001))
            let brightness = min(1, max(0, (decibels + 60) / 60))
            return max(brightness, levels[slot] - 0.08)
        }
    }
}

struct RackInstanceSidebar: View {
    @ObservedObject var model: OberVaveModel
    @StateObject private var meters = RackSidebarMeters()
    @State private var newInstrument: RackInstrument?

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                ForEach(model.instruments) { instrument in
                    instanceButton(instrument)
                }
                Button {
                    newInstrument = model.newInstrumentDraft
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.cyan)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(model.instruments.count >= 16 || model.pendingSceneName != nil)
                .accessibilityLabel("Add instrument")
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 44)
        .background(Color.black.opacity(0.18))
        .onReceive(Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()) { _ in
            meters.refresh()
        }
        .sheet(item: $newInstrument) { instrument in
            RackInstrumentEditor(instrument: instrument, adding: true, onSave: model.addInstrument)
        }
        .accessibilityLabel("Instrument tabs")
    }

    private func instanceButton(_ instrument: RackInstrument) -> some View {
        let selected = model.selectedSlot == instrument.slot
        let level = meters.levels[instrument.slot]
        let color = MIDIChannelColors.color(instrument.channel)
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                model.selectInstrument(instrument.slot)
            }
        } label: {
            Text("\(instrument.channel)")
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .frame(width: 28, height: 28)
            .foregroundStyle(level > 0.7 ? Color.black : color)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: selected ? 0.18 : 0.09))
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.10 + level * 0.8))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(selected ? 1 : 0.45), lineWidth: selected ? 2 : 1)
            }
            .shadow(color: color.opacity(level * 0.4), radius: 5)
            .scaleEffect(selected ? 1.08 : 1)
            .offset(x: selected ? 4 : 0)
        }
        .buttonStyle(.plain)
        .disabled(model.pendingSceneName != nil)
        .accessibilityLabel("\(instrument.name), MIDI channel \(instrument.channel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension OberVaveModel {
    func jumpSceneHistory(undo: Bool, steps: Int) {
        guard sceneHistoryJump == nil, steps > 0 else { return }
        syncExternalParameterHistory()
        guard externalParameterGestures.isEmpty, pendingSceneParameterHistory == nil else {
            errorMessage = "Finish the external controller movement before using history."
            return
        }
        sceneHistoryJump = HistoryJump(undo: undo, remaining: steps)
        advanceSceneHistoryJump()
    }

    private func advanceSceneHistoryJump() {
        while let jump = sceneHistoryJump, jump.remaining > 0 {
            let count = jump.undo ? sceneParameterHistory.undoStack.count : sceneParameterHistory.redoStack.count
            guard count > 0 else { sceneHistoryJump = nil; return }
            applySceneParameterHistory(undo: jump.undo)
            if pendingSceneParameterHistory != nil { return }
            let after = jump.undo ? sceneParameterHistory.undoStack.count : sceneParameterHistory.redoStack.count
            guard after == count - 1 else { sceneHistoryJump = nil; return }
            sceneHistoryJump?.remaining -= 1
        }
        sceneHistoryJump = nil
    }

    func jumpSequencerHistory(undo: Bool, steps: Int) {
        guard sequencerHistoryJump == nil, steps > 0 else { return }
        sequencerHistoryJump = HistoryJump(undo: undo, remaining: steps)
        advanceSequencerHistoryJump()
    }

    private func advanceSequencerHistoryJump() {
        guard let jump = sequencerHistoryJump, jump.remaining > 0 else {
            sequencerHistoryJump = nil
            return
        }
        applySequencerHistory(undo: jump.undo)
        if pendingSequencerHistory == nil { sequencerHistoryJump = nil }
    }

    func syncExternalParameterHistory(finish: Bool = false) {
        guard pendingSceneParameterHistory == nil, sceneHistoryJump == nil else { return }
        let lost = ov_rack_external_history_lost()
        if lost != 0 {
            externalParameterGestures.removeAll()
            sceneParameterHistory = SceneParameterHistory()
            var discarded = ov_rack_external_change()
            while ov_rack_read_external_change(&discarded) != 0 {}
            errorMessage = "External MIDI history overflowed; parameter history was cleared to avoid restoring incomplete changes."
            return
        }
        var event = ov_rack_external_change()
        while ov_rack_read_external_change(&event) != 0 {
            guard event.epoch == ov_seq_scene_epoch() else { continue }
            let kind = event.status & 0xF0
            guard kind == 0xB0 || kind == 0xD0 || kind == 0xE0 else { continue }
            let controller = kind == 0xB0 ? event.data1 : 0
            let frame = UInt32(truncatingIfNeeded: event.frame)
            let key = externalParameterGestures.firstIndex {
                $0.epoch == event.epoch && $0.source == event.source &&
                    $0.status == event.status && $0.controller == controller
            }
            let before = withUnsafeBytes(of: event.before.parameters) { Array($0.bindMemory(to: UInt8.self)) }
            let after = withUnsafeBytes(of: event.after.parameters) { Array($0.bindMemory(to: UInt8.self)) }
            if key == nil && before == after { continue }
            var index = key
            if let key, externalParameterGestures[key].expired(at: frame) {
                sceneParameterHistory.record(externalParameterGestures.remove(at: key).edits)
                index = nil
            }
            if index == nil {
                externalParameterGestures.append(ExternalParameterGesture(epoch: event.epoch,
                    source: event.source, status: event.status, controller: controller, frame: frame))
                index = externalParameterGestures.count - 1
            }
            externalParameterGestures[index!].merge(slot: Int(event.slot), before: before, after: after)
            externalParameterGestures[index!].frame = frame
        }
        let now = ov_audio_frame()
        var pending: [ExternalParameterGesture] = []
        for gesture in externalParameterGestures.sorted(by: { now &- $0.frame > now &- $1.frame }) {
            if finish || gesture.expired(at: now) {
                sceneParameterHistory.record(gesture.edits)
            } else {
                pending.append(gesture)
            }
        }
        externalParameterGestures = pending
    }

    func applySceneParameterHistory(undo: Bool) {
        syncExternalParameterHistory()
        guard pendingSceneParameterHistory == nil, activeParameterEdits.isEmpty, activeSceneValueEdits.isEmpty,
              externalParameterGestures.isEmpty,
              pendingSceneName == nil, !sceneSwitchPending else {
            errorMessage = "Finish the current parameter edit before using history."; return
        }
        guard let entry = undo ? sceneParameterHistory.undoStack.last : sceneParameterHistory.redoStack.last else { return }
        if case .sound(let before, let after) = entry {
            let expected = undo ? after : before
            let target = undo ? before : after
            submitSoundChange(expected: expected, target: target, undo: undo, recording: false)
            return
        }
        if case .route(let edit) = entry {
            let old = undo ? edit.after : edit.before
            let next = undo ? edit.before : edit.after
            guard let current = instruments.first(where: { $0.slot == old.slot }),
                  edit.before.name == edit.after.name || current.name == old.name else {
                errorMessage = "The instrument changed; history was not applied."
                return
            }
            if edit.mask == 0 {
                guard let index = instruments.firstIndex(where: { $0.slot == old.slot }) else { return }
                edit.apply(to: &instruments[index], undo: undo)
                sceneParameterHistory.acknowledge(undo: undo)
                return
            }
            var oldConfig = old.coreConfig(), newConfig = next.coreConfig()
            let epoch = ov_seq_scene_epoch()
            sceneParameterToken &+= 1
            guard ov_rack_change_route(UInt32(old.slot), edit.mask, &oldConfig, &newConfig,
                                       epoch, sceneParameterToken) != 0 else {
                errorMessage = "Could not queue the instrument history operation."
                return
            }
            pendingSceneParameterHistory = PendingSceneParameterHistory(token: sceneParameterToken,
                epoch: epoch, edits: [], undo: undo, route: edit)
            return
        }
        if case .value(let edit) = entry {
            let expected = undo ? edit.after : edit.before
            let replacement = undo ? edit.before : edit.after
            guard sceneValue(edit.field) == expected, edit.field != .tempo || !isMIDIClockActive else {
                errorMessage = "The scene setting changed or is controlled by MIDI clock; history was not applied."
                return
            }
            restoringSceneHistory = true
            switch edit.field {
            case .tempo: setTempo(Int(replacement))
            case .masterLevel: setMasterLevelDB(replacement)
            case .masterPan: setMasterPan(replacement)
            case .keyboardChannels:
                keyboardChannelMask = UInt32(replacement)
                ov_keyboard_channels(keyboardChannelMask)
            }
            restoringSceneHistory = false
            sceneParameterHistory.acknowledge(undo: undo)
            return
        }
        guard case .parameters(let edits) = entry else { return }
        let changes = edits.map { edit in
            ov_rack_parameter_change(slot: UInt32(edit.slot), parameter: UInt32(edit.parameter),
                expected: UInt32(undo ? edit.after : edit.before), replacement: UInt32(undo ? edit.before : edit.after))
        }
        let epoch = ov_seq_scene_epoch()
        sceneParameterToken &+= 1
        let accepted = changes.withUnsafeBufferPointer {
            ov_rack_change_parameters($0.baseAddress, UInt32($0.count), epoch, sceneParameterToken)
        }
        guard accepted != 0 else {
            errorMessage = "Could not queue the parameter history operation."; return
        }
        pendingSceneParameterHistory = PendingSceneParameterHistory(token: sceneParameterToken,
            epoch: epoch, edits: edits, undo: undo)
    }

    func submitSoundChange(expected: RackInstrument, target: RackInstrument, undo: Bool, recording: Bool) {
        guard pendingSceneParameterHistory == nil, !sceneSwitchPending,
              expected.slot == target.slot,
              let current = instruments.first(where: { $0.slot == expected.slot }),
              current.programIndex == expected.programIndex,
              current.arpMode == expected.arpMode, current.latchMode == expected.latchMode else {
            errorMessage = "The instrument changed; sound was not restored."
            return
        }
        var old = expected.coreConfig(), replacement = target.coreConfig()
        let epoch = ov_seq_scene_epoch()
        sceneParameterToken &+= 1
        guard ov_rack_change_sound(UInt32(expected.slot), &old, &replacement, epoch, sceneParameterToken) != 0 else {
            errorMessage = "Could not queue the sound restore."
            return
        }
        pendingSceneParameterHistory = PendingSceneParameterHistory(token: sceneParameterToken,
            epoch: epoch, edits: [], undo: undo, sound: (expected, target), recordingSound: recording)
    }

    var newInstrumentDraft: RackInstrument? {
        guard let slot = (0..<16).first(where: { candidate in
            !instruments.contains { $0.slot == candidate }
        }) else { return nil }
        let channel = (1...16).first { candidate in !instruments.contains { $0.channel == candidate } } ?? 1
        return .oberVave(slot: slot, channel: channel)
    }

    var selectedInstrument: RackInstrument? { instruments.first { $0.slot == selectedSlot } }

    func syncSequencerState() {
        var parameterResult = ov_rack_parameter_result()
        while ov_rack_read_parameter_result(&parameterResult) != 0 {
            if let pending = pendingSceneParameterHistory, pending.token == parameterResult.token {
                pendingSceneParameterHistory = nil
                if parameterResult.success != 0 && pending.epoch == ov_seq_scene_epoch() {
                    if let sound = pending.sound, pending.recordingSound {
                        sceneParameterHistory.recordSound(before: sound.before, after: sound.after)
                    } else {
                        sceneParameterHistory.acknowledge(undo: pending.undo)
                    }
                    if let route = pending.route,
                       let index = instruments.firstIndex(where: { $0.slot == route.before.slot }) {
                        route.apply(to: &instruments[index], undo: pending.undo)
                    }
                    if let sound = pending.sound,
                       let index = instruments.firstIndex(where: { $0.slot == sound.after.slot }) {
                        instruments[index].parameters = sound.after.parameters
                        instruments[index].cc = sound.after.cc
                        instruments[index].arpMode = sound.after.arpMode
                        instruments[index].latchMode = sound.after.latchMode
                        if sound.after.slot == selectedSlot { showSelectedInstrument() }
                    }
                    for edit in pending.edits {
                        guard let index = instruments.firstIndex(where: { $0.slot == edit.slot }) else { continue }
                        let value = pending.undo ? edit.before : edit.after
                        instruments[index].parameters[edit.parameter] = value
                        if edit.slot == selectedSlot { parameterValues[edit.parameter] = value }
                    }
                    if sceneHistoryJump != nil {
                        sceneHistoryJump?.remaining -= 1
                        advanceSceneHistoryJump()
                    }
                } else {
                    sceneHistoryJump = nil
                    errorMessage = "The parameter history operation was rejected because the scene or parameter changed."
                }
            }
        }
        syncExternalParameterHistory()
        while ov_seq_record_ready() != 0 {
            let revision = ov_seq_record_revision()
            var result: UInt32 = 0
            var epoch: UInt64 = 0
            var clip = ov_seq_clip()
            if ov_seq_read_completion(&clip, &result, &epoch) != 0 {
                if result == 1 && epoch == ov_seq_scene_epoch() && revision == ov_seq_cell_revision(clip.slot, clip.row) {
                    let pattern = SequencerPattern(core: clip)
                    do {
                        try pattern.validate()
                        if instruments.contains(where: { $0.slot == pattern.slot }) {
                            let cell = PatternCell(slot: pattern.slot, row: pattern.row)
                            let before = sequencerSnapshot(cell)
                            pianoRollHistories.removeValue(forKey: pattern.id)
                            patterns.removeAll { $0.id == pattern.id }
                            patterns.append(pattern)
                            sequencerHistory.record(SequencerHistoryEntry(before: [before],
                                after: [sequencerSnapshot(cell)], title: "Record · \(pattern.name)"))
                        }
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        let state = ov_seq_record_state()
        let beat = ov_seq_transport_beat()
        if transportBeat != beat { transportBeat = beat }
        let recordingCell = state == 0 ? nil : Int(state >> 3) - 1
        if recordingPattern != recordingCell { recordingPattern = recordingCell }
        if recordingPhase != state & 7 { recordingPhase = state & 7 }
        var phases: [Int: UInt32] = [:]
        for instrument in instruments {
            let slotState = ov_seq_record_state_for_slot(UInt32(instrument.slot))
            if slotState != 0 { phases[Int(slotState >> 3) - 1] = slotState & 7 }
        }
        if recordingPhases != phases { recordingPhases = phases }
        pendingRecordingKeyboardSlots = pendingRecordingKeyboardSlots.filter { slot in
            ov_seq_record_state_for_slot(UInt32(slot)) == 0 &&
                (0..<8).contains { ov_seq_pad_pending(UInt32(slot), UInt32($0)) != 0 }
        }
        var editResult = ov_seq_edit_result()
        while ov_seq_read_edit(&editResult) != 0 {
            if let pending = pendingPatternTransfer, pending.token == editResult.token {
                defer { pendingPatternTransfer = nil }
                if editResult.success != 0 && pending.transfer.epoch == ov_seq_scene_epoch() {
                    let transfer = pending.transfer
                    let sourceUnchanged = editResult.source_revision == ov_seq_cell_revision(UInt32(transfer.source.slot), UInt32(transfer.source.row))
                    let destinationUnchanged = editResult.target_revision == ov_seq_cell_revision(UInt32(transfer.destination.slot), UInt32(transfer.destination.row))
                    let sourceHistory = pianoRollHistories[transfer.source.id].flatMap {
                        $0.pattern == transfer.source ? $0 : nil
                    }
                    if !transfer.copying && sourceUnchanged { pianoRollHistories.removeValue(forKey: transfer.source.id) }
                    if !transfer.deleting && destinationUnchanged {
                        pianoRollHistories[transfer.destination.id] = sourceHistory?.retargeted(to: transfer.destination)
                    }
                    if sourceUnchanged && destinationUnchanged {
                        do {
                            var updated = patternDefaults
                            try updated.transfer(scene: sceneSessionKey,
                                source: PatternCell(slot: transfer.source.slot, row: transfer.source.row),
                                destination: transfer.destination, copying: transfer.copying, deleting: transfer.deleting)
                            _ = persistPatternDefaults(updated)
                        } catch {
                            errorMessage = "Could not move pattern defaults: \(error.localizedDescription)"
                        }
                    }
                    patterns = transfer.acknowledged(in: patterns,
                        sourceUnchanged: sourceUnchanged, destinationUnchanged: destinationUnchanged)
                    if sourceUnchanged && destinationUnchanged {
                        let action = transfer.deleting ? "Delete" : transfer.copying ? "Copy" : "Move"
                        sequencerHistory.record(SequencerHistoryEntry(before: pending.before,
                            after: pending.before.map { sequencerSnapshot($0.cell) },
                            title: "\(action) · \(transfer.source.name)", changesPatternDefaults: true))
                    } else {
                        errorMessage = "The pattern edit was superseded before its history could be saved."
                    }
                } else {
                    errorMessage = "The pattern edit was rejected because a cell, scene or recording changed. No patterns were modified."
                }
            } else if let pending = pendingSequencerHistory, pending.token == editResult.token {
                pendingSequencerHistory = nil
                let expected = pending.undo ? pending.entry.after : pending.entry.before
                let target = pending.undo ? pending.entry.before : pending.entry.after
                let revisions = [editResult.source_revision, editResult.target_revision]
                let unchanged = expected.enumerated().allSatisfy { index, snapshot in
                    ov_seq_cell_revision(UInt32(snapshot.cell.slot), UInt32(snapshot.cell.row)) == revisions[index]
                }
                if editResult.success != 0 && pending.epoch == ov_seq_scene_epoch() && unchanged {
                    if pending.entry.changesPatternDefaults {
                        do {
                            var updated = patternDefaults
                            for snapshot in target {
                                try updated.set(snapshot.patternDefault, scene: sceneSessionKey, cell: snapshot.cell)
                            }
                            _ = persistPatternDefaults(updated)
                        } catch {
                            errorMessage = "Could not restore pattern defaults: \(error.localizedDescription)"
                        }
                    }
                    for snapshot in target {
                        patterns.removeAll { $0.id == snapshot.cell.id }
                        if let pattern = snapshot.pattern { patterns.append(pattern) }
                        pianoRollHistories[snapshot.cell.id] = snapshot.pianoHistory
                    }
                    if pending.recordingNewEntry {
                        sequencerHistory.record(pending.entry)
                    } else {
                        sequencerHistory.acknowledge(pending.entry, undo: pending.undo)
                        if sequencerHistoryJump != nil {
                            sequencerHistoryJump?.remaining -= 1
                            advanceSequencerHistoryJump()
                        }
                    }
                } else {
                    sequencerHistoryJump = nil
                    errorMessage = "The sequencer history operation was rejected or superseded because a cell, scene or recording changed."
                }
            } else if let pending = pendingPianoPublication, pending.token == editResult.token {
                defer { pendingPianoPublication = nil }
                if editResult.success != 0 {
                    let epoch = ov_seq_scene_epoch()
                    let revisionMatches = editResult.source_revision == ov_seq_cell_revision(
                        UInt32(pending.replacement.slot), UInt32(pending.replacement.row))
                    if epoch == pending.epoch && revisionMatches {
                        patterns = pending.acknowledged(in: patterns, epoch: epoch, revisionMatches: revisionMatches)
                        pianoRollHistories[pending.replacement.id] = pending.editor
                    } else {
                        errorMessage = "The Piano Roll edit was superseded by a newer scene or pattern change."
                    }
                } else {
                    errorMessage = "The Piano Roll edit was rejected because the pattern, scene or recording changed."
                }
            }
        }
        var transport: [UInt32] = [state, ov_seq_record_progress(), ov_seq_record_remaining()]
        for instrument in instruments {
            let slot = UInt32(instrument.slot)
            let position = UInt64(bitPattern: ov_seq_position_ticks(slot))
            transport.append(contentsOf: [UInt32(ov_seq_active(slot) + 1), UInt32(ov_seq_pending(slot) + 1),
                                          ov_seq_stopping(slot), ov_seq_position(slot),
                                          UInt32(truncatingIfNeeded: position), UInt32(truncatingIfNeeded: position >> 32),
                                          ov_seq_record_state_for_slot(slot), ov_seq_record_progress_for_slot(slot),
                                          ov_seq_record_remaining_for_slot(slot)])
            for row in 0..<8 { transport.append(ov_seq_pad_pending(slot, UInt32(row))) }
        }
        if lastSequencerTransport != transport {
            lastSequencerTransport = transport
            sequencerRevision &+= 1
        }
        let generation = ov_rack_stop_generation()
        if generation != keyboardStopGeneration {
            keyboardStopGeneration = generation
            keyboardLock.clear()
        }
        ov_rack_collect()
        let failure = ov_rack_take_error()
        if failure != 0 {
            if ov_seq_recording_slot() < 0 && ov_seq_record_ready() == 0 { recordingPattern = nil }
            errorMessage = failure == 1 ? "The MIDI/control queue or note ownership capacity overflowed. Notes were stopped to prevent stuck notes."
                : failure == 3 ? "Not enough memory to create the requested instruments."
                : failure == 4 ? "An audio result queue is full. Let synchronization finish, then retry the operation."
                : "The audio rack rejected an invalid configuration."
        }
    }

    func syncRackState() {
        syncSequencerState()
        var captured = ov_scene_config()
        if !sceneSwitchPending && ov_rack_snapshot_read(&captured) != 0 {
            if pendingSceneName != nil { finishSceneSave(captured) }
        }
        guard pendingSceneName == nil else { return }
        let selectedArp = arpSelectedMode, selectedLatch = latchSelectedMode
        let selectedCCs = ccAssignments
        for index in instruments.indices {
            var c = instruments[index].coreConfig()
            guard ov_rack_read(UInt32(instruments[index].slot), &c) != 0 else { continue }
            if instruments[index].programIndex != Int(c.program) {
                // Custom banks must also work for instruments not open in the editor.
                let oldSlot = selectedSlot
                ov_rack_select(UInt32(instruments[index].slot))
                applyPresetData(for: Int(c.program))
                instruments[index].arpMode = arpSelectedMode
                instruments[index].latchMode = latchSelectedMode
                ov_rack_select(UInt32(oldSlot))
                arpSelectedMode = selectedArp; latchSelectedMode = selectedLatch
                ccAssignments = selectedCCs
            }
            var updated = instruments[index]
            updated.updateSound(c)
            if updated != instruments[index] { instruments[index] = updated }
        }
    }

    func rememberSelectedInstrument() {
        guard let index = instruments.firstIndex(where: { $0.slot == selectedSlot }) else { return }
        instruments[index].parameters = parameterValues
        instruments[index].cc = ccAssignments.map { $0 < 0 ? 255 : $0 }
        instruments[index].programIndex = bank * 128 + program
        instruments[index].sync = isArpSyncEnabled
        instruments[index].grid = arpSyncGrid
        instruments[index].arpMode = performanceMode(.arpMode)
        instruments[index].latchMode = performanceMode(.arpLatch)
    }

    func selectInstrument(_ slot: Int) {
        guard pendingSceneName == nil, pendingSceneParameterHistory == nil, activeParameterEdits.isEmpty,
              instruments.contains(where: { $0.slot == slot }) else { return }
        rememberSelectedInstrument()
        cancelMidiLearn()
        selectedSlot = slot
        ov_rack_select(UInt32(slot))
        showSelectedInstrument()
    }

    func showSelectedInstrument() {
        guard let instrument = selectedInstrument else { return }
        bank = instrument.programIndex / 128; program = instrument.programIndex % 128
        parameterValues = instrument.parameters
        ccAssignments = instrument.cc.map { $0 == 255 ? -1 : $0 }
        arpSelectedMode = instrument.arpMode; latchSelectedMode = instrument.latchMode
        isArpSyncEnabled = instrument.sync; arpSyncGrid = instrument.grid
        presetRevision &+= 1
    }

    @discardableResult
    func addInstrument(_ instrument: RackInstrument) -> Bool {
        guard pendingSceneName == nil else { return false }
        do {
            try instrument.validate()
            guard instruments.count < 16, !instruments.contains(where: { $0.slot == instrument.slot }) else {
                throw SceneError.invalid("A scene supports at most 16 instruments; this slot is already occupied.")
            }
            var c = instrument.coreConfig()
            guard ov_rack_add(UInt32(instrument.slot), &c) != 0 else {
                throw SceneError.invalid("Could not add instrument. Check available memory and the audio rack.")
            }
            rememberSelectedInstrument()
            instruments.append(instrument)
            selectedSlot = instrument.slot
            ov_rack_select(UInt32(selectedSlot))
            showSelectedInstrument()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func configureInstrument(_ instrument: RackInstrument, recordHistory: Bool = true) -> Bool {
        guard pendingSceneName == nil, pendingSceneParameterHistory == nil else { return false }
        do {
            try instrument.validate()
            guard let index = instruments.firstIndex(where: { $0.slot == instrument.slot }) else {
                throw SceneError.invalid("Could not find instrument.")
            }
            let previous = instruments[index]
            guard
                  ov_rack_configure(UInt32(instrument.slot), UInt32(instrument.channel),
                                    UInt32(instrument.lowNote), UInt32(instrument.highNote),
                                    Float(instrument.levelDB), Float(instrument.pan), instrument.muted ? 1 : 0) != 0 else {
                throw SceneError.invalid("Could not update instrument routing.")
            }
            instruments[index].name = instrument.name
            instruments[index].channel = instrument.channel
            instruments[index].lowNote = instrument.lowNote
            instruments[index].highNote = instrument.highNote
            instruments[index].levelDB = instrument.levelDB
            instruments[index].pan = instrument.pan
            instruments[index].muted = instrument.muted
            if recordHistory { sceneParameterHistory.record(SceneRouteEdit(before: previous, after: instruments[index])) }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func removeInstrument(_ slot: Int) {
        guard pendingPatternTransfer == nil, pendingPianoPublication == nil, pendingSequencerHistory == nil else { errorMessage = "Wait for the pending pattern edit."; return }
        guard recordingPattern == nil else { errorMessage = "Finish recording before removing an instrument."; return }
        guard pendingSceneName == nil, ov_rack_remove(UInt32(slot)) != 0 else { return }
        instruments.removeAll { $0.slot == slot }
        patterns.removeAll { $0.slot == slot }
        soloSlots.remove(slot)
        if selectedSlot == slot {
            selectedSlot = instruments.first?.slot ?? 0
            ov_rack_select(UInt32(selectedSlot))
            showSelectedInstrument()
        }
    }

    func toggleKeyboardChannel(_ channel: Int) {
        let next = keyboardChannelMask ^ (1 << (channel - 1))
        recordSceneValue(.keyboardChannels, before: Double(keyboardChannelMask), after: Double(next))
        keyboardChannelMask = next
        ov_keyboard_channels(keyboardChannelMask)
    }

    private func scenesFolder() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("OberVave Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func refreshSavedScenes() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: scenesFolder(),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var available: [SavedRackScene] = []
            var failures: [String] = []
            for url in urls where url.lastPathComponent.hasSuffix(".obscene.json") {
                do {
                    let document = try RackSceneDocument.read(from: url)
                    available.append(SavedRackScene(url: url, name: document.name))
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            savedScenes = available.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !failures.isEmpty { errorMessage = "Could not read some scenes:\n" + failures.joined(separator: "\n") }
        } catch { errorMessage = "Could not read the scene library: \(error.localizedDescription)" }
    }

    func saveScene(name: String, asNew: Bool = false) {
        syncRackState()
        guard pendingPatternTransfer == nil, pendingPianoPublication == nil, pendingSequencerHistory == nil else { errorMessage = "Wait for the pending pattern edit."; return }
        guard recordingPattern == nil else {
            errorMessage = "Finish pattern recording before saving the scene."; return
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 64 else {
            errorMessage = "Enter a scene name of 1 to 64 characters."; return
        }
        guard pendingSceneName == nil else { return }
        rememberSelectedInstrument()
        guard ov_rack_snapshot_request() != 0 else {
            errorMessage = "Could not request an audio scene snapshot."; return
        }
        pendingSceneName = clean
        pendingSceneURL = asNew ? nil : sceneFileURL
        sceneSaveMonitor.start { [weak self] in
            guard let self else { return true }
            self.syncRackState()
            return self.pendingSceneName == nil
        } onTimeout: { [weak self] in
            guard let self else { return }
            self.pendingSceneName = nil
            self.pendingSceneURL = nil
            self.errorMessage = "The audio engine did not provide a scene snapshot. Resume audio and try saving again."
        }
    }

    private func finishSceneSave(_ captured: ov_scene_config) {
        guard let name = pendingSceneName else { return }
        defer { pendingSceneName = nil; pendingSceneURL = nil }
        do {
            guard ov_seq_recording_slot() < 0 else { throw SceneError.invalid("Finish recording before saving the scene.") }
            let slots = withUnsafeBytes(of: captured.slots) { raw in
                Array(raw.bindMemory(to: ov_rack_slot.self))
            }
            var saved = instruments
            for index in saved.indices {
                let c = slots[saved[index].slot]
                guard c.present != 0 else { throw SceneError.invalid("The scene changed while saving; please try again.") }
                saved[index].updateSound(c.config)
            }
            let document = RackSceneDocument(name: name, instruments: saved, tempo: Int(captured.tempo),
                masterDB: masterLevelDB, masterPan: masterPan, keyboardMask: keyboardChannelMask,
                selectedSlot: instruments.isEmpty ? nil : selectedSlot, patterns: patterns)
            try document.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = try pendingSceneURL ?? scenesFolder().appendingPathComponent("\(UUID().uuidString).obscene.json")
            let newKey = url.standardizedFileURL.absoluteString
            var updated = patternDefaults
            if newKey != sceneSessionKey {
                try updated.copyScene(from: sceneSessionKey, to: newKey)
            }
            try updated.seedMissing(document.patterns ?? [], scene: newKey)
            guard persistPatternDefaults(updated) else {
                throw SceneError.invalid("Could not save the scene's pattern defaults.")
            }
            try encoder.encode(document).write(to: url, options: .atomic)
            if pendingSceneURL == nil, sceneFileURL != nil {
                var previous = currentSceneSession()
                previous.document.instruments = saved
                previous.document.tempo = Int(captured.tempo)
                sceneSessions[sceneSessionKey] = previous
            } else {
                sceneSessions.removeValue(forKey: sceneSessionKey)
            }
            sceneName = name; sceneFileURL = url
            sceneSessionKey = url.standardizedFileURL.absoluteString
            sceneStatus = "Saved \(name)"
            refreshSavedScenes()
        } catch { errorMessage = "Could not save scene: \(error.localizedDescription)" }
    }

    func loadScene(from url: URL) {
        guard pendingSceneName == nil else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let key = url.standardizedFileURL.absoluteString
            if key == sceneSessionKey { return }
            let saved = sceneSessions[key]
            let document = try saved?.document ?? RackSceneDocument.read(from: url)
            if saved == nil {
                var updated = patternDefaults
                try updated.seedMissing(document.patterns ?? [], scene: key)
                guard persistPatternDefaults(updated) else {
                    throw SceneError.invalid("Could not load the scene's pattern defaults.")
                }
            }
            let folder = try scenesFolder()
            let fileURL = url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL ? url : nil
            switchScene(to: saved ?? SceneSessionState(document: document, pianoRollHistories: [:],
                        pianoRollViewports: [:], fileURL: fileURL), key: key)
        } catch { errorMessage = "Could not load scene: \(error.localizedDescription)" }
    }

    private func currentSceneSession() -> SceneSessionState {
        let document = RackSceneDocument(name: sceneName, instruments: instruments, tempo: tempo,
            masterDB: masterLevelDB, masterPan: masterPan, keyboardMask: keyboardChannelMask,
            selectedSlot: instruments.isEmpty ? nil : selectedSlot, patterns: patterns)
        return SceneSessionState(document: document, pianoRollHistories: pianoRollHistories,
                                 pianoRollViewports: pianoRollViewports, fileURL: sceneFileURL,
                                 sequencerHistory: sequencerHistory, sceneParameterHistory: sceneParameterHistory)
    }

    func restoreSessionScene(_ key: String) {
        guard key != sceneSessionKey, let saved = sceneSessions[key], pendingSceneName == nil else { return }
        switchScene(to: saved, key: key)
    }

    private func switchScene(to next: SceneSessionState, key: String) {
        do {
            syncSequencerState()
            syncExternalParameterHistory(finish: true)
            guard pendingPatternTransfer == nil, pendingPianoPublication == nil, pendingSequencerHistory == nil,
                  pendingSceneParameterHistory == nil, activeParameterEdits.isEmpty, activeSceneValueEdits.isEmpty, recordingPattern == nil,
                  ov_seq_record_state() == 0, pendingSceneName == nil, !sceneSwitchPending else {
                throw SceneError.invalid("Finish recording and pending pattern edits before loading a scene.")
            }
            try next.document.validate()
            guard ov_rack_snapshot_request() != 0 else {
                throw SceneError.invalid("Could not request an audio scene snapshot.")
            }
            sceneSwitchPending = true
            sceneSwitchMonitor.start { [weak self] in
                guard let self else { return true }
                var captured = ov_scene_config()
                guard ov_rack_snapshot_read(&captured) != 0 else { return false }
                defer { self.sceneSwitchPending = false }
                do {
                    self.syncSequencerState()
                    self.syncExternalParameterHistory(finish: true)
                    guard self.recordingPattern == nil, ov_seq_record_state() == 0,
                          self.pendingPatternTransfer == nil, self.pendingPianoPublication == nil,
                          self.pendingSequencerHistory == nil, self.pendingSceneParameterHistory == nil,
                          self.activeParameterEdits.isEmpty, self.activeSceneValueEdits.isEmpty else {
                        throw SceneError.invalid("The scene changed while switching. Finish recording and try again.")
                    }
                    var previous = self.currentSceneSession()
                    let slots = withUnsafeBytes(of: captured.slots) { Array($0.bindMemory(to: ov_rack_slot.self)) }
                    for index in previous.document.instruments.indices {
                        let slot = slots[previous.document.instruments[index].slot]
                        guard slot.present != 0 else {
                            throw SceneError.invalid("The instrument list changed while switching. Try again.")
                        }
                        previous.document.instruments[index].updateSound(slot.config)
                    }
                    try previous.document.validate()
                    try self.applyScene(next.document)
                    self.sceneSessions[self.sceneSessionKey] = previous
                    self.sceneSessions.removeValue(forKey: key)
                    self.sceneSessionKey = key
                    self.pianoRollHistories = next.pianoRollHistories
                    self.pianoRollViewports = next.pianoRollViewports
                    self.sequencerHistory = next.sequencerHistory
                    self.sceneParameterHistory = next.sceneParameterHistory
                    self.sceneFileURL = next.fileURL
                } catch { self.errorMessage = "Could not switch scene: \(error.localizedDescription)" }
                return true
            } onTimeout: { [weak self] in
                self?.sceneSwitchPending = false
                self?.errorMessage = "The audio engine did not provide a scene snapshot. Resume audio and try again."
            }
        } catch { errorMessage = "Could not restore scene: \(error.localizedDescription)" }
    }

    private func applyScene(_ document: RackSceneDocument) throws {
        try document.validate()
        guard pendingPatternTransfer == nil, pendingPianoPublication == nil, pendingSequencerHistory == nil,
              pendingSceneParameterHistory == nil, activeParameterEdits.isEmpty, activeSceneValueEdits.isEmpty else { throw SceneError.invalid("Wait for the pending edit.") }
        guard recordingPattern == nil else { throw SceneError.invalid("Finish recording before loading a scene.") }
        var c = ov_scene_config()
        c.tempo = UInt32(document.tempo)
        withUnsafeMutableBytes(of: &c.slots) { raw in
            let slots = raw.bindMemory(to: ov_rack_slot.self)
            for instrument in document.instruments {
                slots[instrument.slot].present = 1
                slots[instrument.slot].config = instrument.coreConfig()
            }
        }
        let sequenceClips = (document.patterns ?? []).map { $0.coreClip() }
        let accepted = sequenceClips.withUnsafeBufferPointer {
            ov_rack_load_sequenced(&c, $0.baseAddress, UInt32($0.count))
        }
        guard accepted != 0 else {
            throw SceneError.invalid("Could not allocate this scene. The current scene has been kept.")
        }
        sequencerInteractionEpoch &+= 1
        pianoRollViewports.removeAll()
        pianoRollHistories.removeAll()
        sequencerHistory = SequencerHistory()
        sceneParameterHistory = SceneParameterHistory()
        instruments = document.instruments
        patterns = document.patterns ?? []
        soloSlots = []
        selectedSlot = document.selectedSlot ?? instruments.first?.slot ?? 0
        ov_rack_select(UInt32(selectedSlot))
        keyboardChannelMask = document.keyboardMask
        ov_keyboard_channels(document.keyboardMask)
        tempo = document.tempo
        restoringSceneHistory = true
        setMasterLevelDB(document.masterDB); setMasterPan(document.masterPan)
        restoringSceneHistory = false
        sceneName = document.name
        sceneStatus = "Loaded \(document.name)"
        showSelectedInstrument()
    }

    func newScene() {
        guard pendingSceneName == nil else { return }
        let empty = RackSceneDocument(name: "Untitled Scene", instruments: [], tempo: tempo,
            masterDB: masterLevelDB, masterPan: masterPan, keyboardMask: keyboardChannelMask, selectedSlot: nil)
        switchScene(to: SceneSessionState(document: empty, pianoRollHistories: [:],
                    pianoRollViewports: [:], fileURL: nil), key: UUID().uuidString)
    }
}

extension OberVaveModel {
    func pattern(slot: Int, row: Int) -> SequencerPattern? {
        patterns.first { $0.slot == slot && $0.row == row }
    }

    private func sequencerSnapshot(_ cell: PatternCell) -> SequencerCellSnapshot {
        let current = pattern(slot: cell.slot, row: cell.row)
        return SequencerCellSnapshot(cell: cell, pattern: current,
            pianoHistory: pianoRollHistories[cell.id].flatMap { $0.pattern == current ? $0 : nil },
            patternDefault: patternDefaults.value(scene: sceneSessionKey, cell: cell))
    }

    func applySequencerHistory(undo: Bool) {
        guard var entry = sequencerHistory.next(undo: undo) else { return }
        let expected = undo ? entry.after : entry.before
        let live = expected.map { sequencerSnapshot($0.cell) }
        guard zip(expected, live).allSatisfy({
            $0.pattern == $1.pattern && (!entry.changesPatternDefaults || $0.patternDefault == $1.patternDefault)
        }) else {
            errorMessage = "The pattern or its default has changed. Restore it before using sequencer history."
            return
        }
        if undo { entry.after = live } else { entry.before = live }
        submitSequencerHistory(entry, undo: undo, recordingNewEntry: false)
    }

    private func submitSequencerHistory(_ entry: SequencerHistoryEntry, undo: Bool, recordingNewEntry: Bool) {
        guard pendingSceneName == nil, !sceneSwitchPending, pendingPatternTransfer == nil,
              pendingPianoPublication == nil, pendingSequencerHistory == nil, ov_seq_record_state() == 0 else {
            errorMessage = "Finish recording and pending edits before changing sequencer history."
            return
        }
        let expected = undo ? entry.after : entry.before
        let replacement = undo ? entry.before : entry.after
        guard expected.count == replacement.count, (1...2).contains(expected.count),
              zip(expected, replacement).allSatisfy({ $0.cell == $1.cell }),
              expected.allSatisfy({ ov_seq_pad_pending(UInt32($0.cell.slot), UInt32($0.cell.row)) == 0 }) else {
            errorMessage = "The affected pattern cells are busy or invalid."
            return
        }
        var clips: [ov_seq_clip] = []
        var indices: [(Int?, Int?)] = []
        for (old, new) in zip(expected, replacement) {
            let oldIndex: Int?
            if let pattern = old.pattern { oldIndex = clips.count; clips.append(pattern.coreClip()) } else { oldIndex = nil }
            let newIndex: Int?
            if let pattern = new.pattern { newIndex = clips.count; clips.append(pattern.coreClip()) } else { newIndex = nil }
            indices.append((oldIndex, newIndex))
        }
        let epoch = ov_seq_scene_epoch()
        patternTransferToken &+= 1
        let accepted = clips.withUnsafeBufferPointer { buffer in
            let changes = expected.enumerated().map { index, snapshot in
                ov_seq_cell_change(slot: UInt32(snapshot.cell.slot), row: UInt32(snapshot.cell.row),
                    revision: ov_seq_cell_revision(UInt32(snapshot.cell.slot), UInt32(snapshot.cell.row)),
                    expected: indices[index].0.map { buffer.baseAddress!.advanced(by: $0) },
                    replacement: indices[index].1.map { buffer.baseAddress!.advanced(by: $0) })
            }
            return changes.withUnsafeBufferPointer {
                ov_seq_change_cells($0.baseAddress, UInt32($0.count), epoch, patternTransferToken)
            }
        }
        guard accepted != 0 else {
            errorMessage = "Could not queue the sequencer history operation."
            return
        }
        pendingSequencerHistory = PendingSequencerHistory(token: patternTransferToken, epoch: epoch,
            entry: entry, undo: undo, recordingNewEntry: recordingNewEntry)
    }

    @discardableResult
    func storePattern(_ pattern: SequencerPattern, expected: SequencerPattern? = nil) -> Bool {
        guard pendingSceneName == nil, pendingPatternTransfer == nil, pendingPianoPublication == nil,
              pendingSequencerHistory == nil else {
            errorMessage = "Wait for the pending scene or pattern operation."; return false
        }
        guard ov_seq_record_state() == 0 else {
            errorMessage = "Finish the pending recording before editing patterns."; return false
        }
        do {
            try pattern.validate()
            guard ov_seq_pad_pending(UInt32(pattern.slot), UInt32(pattern.row)) == 0 else {
                throw SceneError.invalid("Wait for the pending pad action before editing.")
            }
            let cell = PatternCell(slot: pattern.slot, row: pattern.row)
            let before = sequencerSnapshot(cell)
            if let expected, before.pattern != expected {
                throw SceneError.invalid("This pattern changed while the editor was open. Reopen it before saving.")
            }
            if before.pattern == pattern { return true }
            let after = SequencerCellSnapshot(cell: cell, pattern: pattern, pianoHistory: nil,
                                              patternDefault: before.patternDefault)
            submitSequencerHistory(SequencerHistoryEntry(before: [before], after: [after],
                                                        title: "Edit · \(pattern.name)"),
                                   undo: false, recordingNewEntry: true)
            return pendingSequencerHistory != nil
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func publishPianoPattern(expected: SequencerPattern, candidate: PianoRollEditBuffer,
                             epoch: UInt64, revision: UInt64) -> Bool {
        guard pendingSceneName == nil, pendingPatternTransfer == nil, pendingPianoPublication == nil,
              pendingSequencerHistory == nil else {
            errorMessage = "Wait for the pending scene or pattern operation."; return false
        }
        do {
            let replacement = candidate.pattern
            guard expected.id == replacement.id else { throw SceneError.invalid("A Piano Roll edit cannot change its cell.") }
            try replacement.validate()
            var oldClip = expected.coreClip()
            var newClip = replacement.coreClip()
            patternTransferToken &+= 1
            guard ov_seq_replace_pattern(&oldClip, &newClip, epoch, revision, patternTransferToken) != 0 else {
                throw SceneError.invalid("Could not queue the Piano Roll edit.")
            }
            pendingPianoPublication = PendingPianoPublication(token: patternTransferToken,
                epoch: epoch, replacement: replacement, editor: candidate)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func movePattern(_ transfer: PatternTransfer) {
        var move = transfer; move.copying = false
        submitPatternTransfer(move)
    }

    func copyPattern(_ transfer: PatternTransfer) {
        var copy = transfer; copy.copying = true
        submitPatternTransfer(copy)
    }

    private func submitPatternTransfer(_ transfer: PatternTransfer) {
        syncRackState()
        guard pendingPatternTransfer == nil, pendingPianoPublication == nil, pendingSequencerHistory == nil, pendingSceneName == nil,
              instruments.contains(where: { $0.slot == transfer.destination.slot }),
              recordingPhases[transfer.source.id] == nil && recordingPhases[transfer.destination.id] == nil else {
            errorMessage = "The source or destination is busy recording or editing."; return
        }
        do {
            _ = try transfer.applying(to: patterns)
            var source = transfer.source.coreClip()
            patternTransferToken &+= 1
            let mode: UInt32 = transfer.deleting ? 4 : (transfer.copying ? 1 : 0) | (transfer.replace ? 2 : 0)
            guard ov_seq_edit(&source, UInt32(transfer.destination.slot), UInt32(transfer.destination.row), mode,
                              transfer.epoch, transfer.sourceRevision, transfer.targetRevision, patternTransferToken) != 0 else {
                throw SceneError.invalid("Could not queue pattern transfer.")
            }
            let sourceCell = PatternCell(slot: transfer.source.slot, row: transfer.source.row)
            let cells = transfer.deleting || transfer.copying ? [transfer.deleting ? sourceCell : transfer.destination]
                : [sourceCell, transfer.destination]
            pendingPatternTransfer = PendingPatternTransfer(token: patternTransferToken, transfer: transfer,
                before: cells.map { sequencerSnapshot($0) })
        } catch { errorMessage = error.localizedDescription }
    }

    func deletePattern(_ pattern: SequencerPattern) {
        let revision = ov_seq_cell_revision(UInt32(pattern.slot), UInt32(pattern.row))
        submitPatternTransfer(PatternTransfer(source: pattern, destination: PatternCell(slot: pattern.slot, row: pattern.row),
                                               sourceRevision: revision, targetRevision: revision,
                                               epoch: ov_seq_scene_epoch(), deleting: true))
    }

    func deletePattern(_ transfer: PatternTransfer) {
        var deletion = transfer
        deletion.deleting = true
        deletion.destination = PatternCell(slot: transfer.source.slot, row: transfer.source.row)
        deletion.targetRevision = deletion.sourceRevision
        submitPatternTransfer(deletion)
    }

    func duplicatePattern(_ pattern: SequencerPattern) {
        guard let row = (0..<8).first(where: { self.pattern(slot: pattern.slot, row: $0) == nil }) else {
            errorMessage = "This instrument already has eight patterns."; return
        }
        copyPattern(PatternTransfer(source: pattern, destination: PatternCell(slot: pattern.slot, row: row),
                                    sourceRevision: ov_seq_cell_revision(UInt32(pattern.slot), UInt32(pattern.row)),
                                    targetRevision: ov_seq_cell_revision(UInt32(pattern.slot), UInt32(row)),
                                    epoch: ov_seq_scene_epoch(), copying: true))
    }

    func launchPattern(slot: Int, row: Int) {
        if ov_seq_launch(UInt32(slot), UInt32(row), UInt32(launchGrid)) == 0 {
            errorMessage = "Could not queue pattern launch."
        }
    }
    func launchRow(_ row: Int) {
        if ov_seq_launch_row(UInt32(row), UInt32(launchGrid)) == 0 {
            errorMessage = "Could not queue synchronized row launch."
        }
    }
    func recordPattern(slot: Int, row: Int) {
        syncRackState()
        guard pendingSequencerHistory == nil, pendingPatternTransfer == nil, pendingPianoPublication == nil else {
            errorMessage = "Wait for the pending pattern edit."; return
        }
        guard ov_seq_record_state_for_slot(UInt32(slot)) == 0 else {
            errorMessage = "This instrument is already recording."; return
        }
        guard let instrument = instruments.first(where: { $0.slot == slot }) else {
            errorMessage = "The recording instrument is unavailable."; return
        }
        if ov_seq_arm(UInt32(slot), UInt32(row), UInt32(recordMode.rawValue), UInt32(recordCountBars),
                      UInt32(instrument.recordBeats), recordOutput ? 1 : 0) == 0 {
            errorMessage = "Could not arm recording."
        } else { routeKeyboardForRecording(slot: slot) }
    }
    func finishPatternRecording() {
        if ov_seq_finish_record() == 0 { errorMessage = "Could not finish recording.";  }
    }
    func tapPattern(slot: Int, row: Int) {
        guard pendingSequencerHistory == nil, pendingPatternTransfer == nil, pendingPianoPublication == nil else {
            errorMessage = "Wait for the pending pattern edit."; return
        }
        guard let instrument = instruments.first(where: { $0.slot == slot }) else {
            errorMessage = "The recording instrument is unavailable."; return
        }
        let arming = pattern(slot: slot, row: row) == nil && ov_seq_record_state_for_slot(UInt32(slot)) == 0
        if ov_seq_tap(UInt32(slot), UInt32(row), UInt32(recordMode.rawValue), UInt32(recordCountBars),
                      UInt32(instrument.recordBeats), recordOutput ? 1 : 0, UInt32(launchGrid)) == 0 {
            errorMessage = "Could not apply the pattern tap."
        } else if arming { routeKeyboardForRecording(slot: slot) }
    }
    private func routeKeyboardForRecording(slot: Int) {
        pendingRecordingKeyboardSlots = pendingRecordingKeyboardSlots.filter { candidate in
            (0..<8).contains { ov_seq_pad_pending(UInt32(candidate), UInt32($0)) != 0 }
        }
        pendingRecordingKeyboardSlots.insert(slot)
        let slots = pendingRecordingKeyboardSlots.union(instruments.compactMap {
            ov_seq_record_state_for_slot(UInt32($0.slot)) != 0 ? $0.slot : nil
        })
        let mask = SequencerRecordingSelection.keyboardMask(slots: slots, instruments: instruments)
        if keyboardChannelMask != mask {
            keyboardChannelMask = mask
            ov_keyboard_channels(mask)
        }
    }
    func setRecordLength(slot: Int, bars: Int) {
        guard (0...64).contains(bars), let index = instruments.firstIndex(where: { $0.slot == slot }) else {
            errorMessage = "Invalid recording length."; return
        }
        instruments[index].setRecordBars(bars)
    }
    func stopColumn(_ slot: Int, arp: Bool) {
        if ov_seq_stop(UInt32(slot), arp ? 1 : 0) == 0 { errorMessage = "Could not stop the instrument.";  }
    }
    func soloColumn(_ slot: Int) {
        let enabled = !soloSlots.contains(slot)
        if ov_seq_solo(UInt32(slot), enabled ? 1 : 0) != 0 {
            if enabled { soloSlots.insert(slot) } else { soloSlots.remove(slot) }
        } else {
            errorMessage = "Could not change Solo.";
        }
    }
    func mixColumn(_ slot: Int, level: Double? = nil, pan: Double? = nil, mute: Bool? = nil) {
        guard var instrument = instruments.first(where: { $0.slot == slot }) else { return }
        if let level { instrument.levelDB = level }
        if let pan { instrument.pan = pan }
        if let mute { instrument.muted = mute }
        _ = configureInstrument(instrument, recordHistory: false)
    }
}

struct SequencerRecordModeControl: View {
    @ObservedObject var model: OberVaveModel
    @State private var showsModes = false

    var body: some View {
        Button { showsModes = true } label: {
            VStack(spacing: 2) {
                Text("Record mode").font(.caption.bold())
                Text(model.recordMode.title).font(.system(size: 9, design: .monospaced))
            }
            .padding(.horizontal, 10).frame(height: 44)
            .foregroundStyle(.white)
            .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsModes, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Record mode").font(.headline)
                Picker("Start", selection: $model.recordMode) {
                    ForEach(SequencerRecordMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented)
                if model.recordMode == .countIn {
                    Picker("Count-in", selection: $model.recordCountBars) {
                        Text("1 bar · 4 ticks").tag(1)
                        Text("2 bars · 8 ticks").tag(2)
                    }.pickerStyle(.segmented)
                }
                Picker("Capture", selection: $model.recordOutput) {
                    Text("Output · after ARP").tag(true)
                    Text("Input · before ARP").tag(false)
                }.pickerStyle(.segmented)
                Text(help).font(.caption).foregroundStyle(.secondary)
                Text("Wait for note always waits for the selected instrument's first note, even during playback. Immediate joins the next bar during playback and captures the pickup. Count-in counts full bars. Tap the recording pad again to finish at the end of the bar and play.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20).frame(width: 380)
            .disabled(model.recordingPattern != nil)
            .preferredColorScheme(.dark)
        }
    }

    private var help: String {
        switch model.recordMode {
        case .waitForNote: "Arm with +. The first played note starts the loop at beat one."
        case .countIn: "Counts one or two bars; the metronome button controls the sound. Playing during the count-in becomes a one-shot intro."
        case .immediate: "Start the loop immediately when the scene is stopped."
        }
    }
}

private struct SequencerRecordLengthControl: View {
    @ObservedObject var model: OberVaveModel
    let slot: Int
    @State private var showsLength = false
    private var bars: Double { model.instruments.first { $0.slot == slot }?.recordBars ?? 1 }
    private var lengthLabel: String { bars.formatted(.number.precision(.fractionLength(0...2))) + (bars == 1 ? " bar" : " bars") }

    var body: some View {
        Button(bars == 0 ? "FREE LENGTH" : lengthLabel) { showsLength = true }
            .font(.system(size: 10, design: .monospaced))
            .accessibilityLabel("Recording length for instrument \(slot + 1)")
            .popover(isPresented: $showsLength, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording length").font(.headline)
                    Picker("Length", selection: Binding(
                        get: { bars == 0 },
                        set: { model.setRecordLength(slot: slot, bars: $0 ? 0 : 1) }
                    )) {
                        Text("Fixed").tag(false)
                        Text("Free").tag(true)
                    }.pickerStyle(.segmented)
                    if bars > 0 {
                        Stepper(lengthLabel, value: Binding(
                            get: { max(1, Int(bars.rounded(.up))) }, set: { model.setRecordLength(slot: slot, bars: $0) }
                        ), in: 1...64)
                    }
                    Text(bars == 0
                        ? "Length grows one bar at a time. Tap again to finish at the end of the bar and play. There is no automatic length cutoff."
                        : "Recording ends automatically after \(lengthLabel) and starts the loop. One bar is four quarter notes. Tap earlier to finish at the end of the current bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20).frame(width: 300)
                .disabled(model.recordingPattern != nil || model.pendingSceneName != nil)
                .preferredColorScheme(.dark)
            }
    }
}

private struct SequencerNoteDiagram: View, Equatable {
    let layout: CircularNoteLayout

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(0, min(size.width, size.height) / 2 - 6)
            let spacing = radius * 0.65 / Double(max(1, layout.lanes))
            for arc in layout.arcs {
                let distance = arc.pickup ? radius * 0.2 : radius * 0.35 + (Double(arc.lane) + 0.5) * spacing
                var path = Path()
                path.addArc(center: center, radius: distance,
                            startAngle: .degrees(arc.start * 360 - 90),
                            endAngle: .degrees(arc.end * 360 - 90), clockwise: false)
                context.stroke(path, with: .foreground,
                               style: StrokeStyle(lineWidth: max(1, min(2, spacing * 0.7)),
                                                  lineCap: .round, dash: arc.pickup ? [1, 2] : []))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SequencerCellProgress: View {
    var position: Double
    var queued: Bool
    var stopping: Bool
    var recording: Bool
    var waiting: Bool
    var countRemaining = 0
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: queued || waiting ? [2, 3] : []))
                .opacity(0.35)
            if !waiting {
                Circle().trim(from: 0, to: max(0.002, min(1, position)))
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            if stopping || waiting {
                Image(systemName: stopping ? "stop.fill" : countRemaining > 0 ? "metronome" : "clock")
                    .font(.system(size: 8))
            } else if recording {
                Circle().frame(width: 4, height: 4)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if waiting && countRemaining > 0 {
                ForEach(0..<min(8, countRemaining), id: \.self) { beat in
                    Circle().frame(width: 3, height: 3).offset(y: -size / 2)
                        .rotationEffect(.degrees(Double(beat) * 45))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SequencerCellFrames: PreferenceKey {
    static var defaultValue: [PatternCell: CGRect] = [:]
    static func reduce(value: inout [PatternCell: CGRect], nextValue: () -> [PatternCell: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SequencerCellDrag {
    var transfer: PatternTransfer
    var point: CGPoint
    var target: PatternCell?
}

struct SequencerView: View {
    @ObservedObject var model: OberVaveModel
    @State private var editing: SequencerPattern?
    @State private var deleting: PatternTransfer?
    @State private var replacing: SequencerPattern?
    @State private var replacement: PatternTransfer?
    @State private var pianoRoll: SequencerPattern?
    @State private var menuPattern: SequencerPattern?
    @State private var afterMenu: (() -> Void)?
    @State private var heldSource: PatternTransfer?
    @State private var drag: SequencerCellDrag?
    @State private var copyHint: Int?
    @State private var frames: [PatternCell: CGRect] = [:]
    @State private var cellViewport = CGRect.zero
    @State private var horizontalViewport = CGRect.zero
    @State private var rootFrame = CGRect.zero
    @State private var meters = [Double](repeating: 0, count: 16)
    private var width: CGFloat { max(1, model.keyboardChannelWidth) }
    private var padHeight: CGFloat { width }
    private var historyBusy: Bool {
        model.pendingSequencerHistory != nil || model.sequencerHistoryJump != nil || model.pendingPatternTransfer != nil ||
            model.pendingPianoPublication != nil || model.pendingSceneName != nil ||
            model.sceneSwitchPending || !model.recordingPhases.isEmpty
    }

    @ViewBuilder
    private func sequencerHistoryMenu(undo: Bool) -> some View {
        let stack = undo ? model.sequencerHistory.undoStack : model.sequencerHistory.redoStack
        let entries = Array(stack.reversed())
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
            Button("\(index + 1). \(entry.title)") {
                model.jumpSequencerHistory(undo: undo, steps: index + 1)
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Launch", selection: $model.launchGrid) {
                    Text("FREE").tag(0); Text("BEAT").tag(1); Text("BAR").tag(2)
                }
                .pickerStyle(.segmented).frame(maxWidth: 290)
                Button { model.applySequencerHistory(undo: true) } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.sequencerHistory.undoStack.isEmpty || historyBusy)
                .contextMenu { sequencerHistoryMenu(undo: true) }
                Button { model.applySequencerHistory(undo: false) } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(model.sequencerHistory.redoStack.isEmpty || historyBusy)
                .contextMenu { sequencerHistoryMenu(undo: false) }
                Spacer()
                if !model.recordingPhases.isEmpty {
                    Button {
                        model.finishPatternRecording()
                    } label: {
                        Label(model.recordingPhases.count > 1 ? "FINISH ALL REC" : "FINISH REC",
                              systemImage: "record.circle.fill").foregroundStyle(.red)
                    }.buttonStyle(.bordered)
                }

                Text(model.pendingPatternTransfer == nil && model.pendingSequencerHistory == nil ? "DRAG CENTER: MOVE · HOLD: COPY · EDGES: SCROLL" : "APPLYING EDIT · WAITING FOR AUDIO")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(model.instruments) { instrument in
                                VStack(spacing: 6) {
                                    VStack(spacing: 2) {
                                        Text(instrument.name).lineLimit(1).font(.caption.bold())
                                        SequencerRecordLengthControl(model: model, slot: instrument.slot)
                                    }.frame(height: 54)
                                    ForEach(0..<8, id: \.self) { row in pad(instrument, row: row) }
                                }.frame(width: width)
                            }
                            VStack(spacing: 6) {
                                Text("ROW").font(.caption.bold()).frame(height: 54)
                                ForEach(0..<8, id: \.self) { row in
                                    Button {
                                        model.launchRow(row)
                                    } label: {
                                        Label("\(row + 1)", systemImage: "play.fill")
                                            .frame(width: 62, height: padHeight)
                                            .background(Color.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel("Launch row \(row + 1) synchronously")
                                }
                            }.frame(width: 70)
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { cellViewport = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { cellViewport = $0 }
                    })
                    Divider().padding(.vertical, 6)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(model.instruments) { instrument in mixer(instrument).frame(width: width) }
                        Button { model.stopAllPlayback() } label: {
                            VStack {
                                Image(systemName: "stop.fill")
                                Text("ALL")
                            }.font(.caption.bold()).frame(width: 70, height: 190)
                        }.buttonStyle(.plain).accessibilityLabel("Stop all playback")
                    }
                }
                .frame(width: CGFloat(model.instruments.count) * (width + 8) + 70)
            }
            .background(GeometryReader { proxy in
                Color.clear.onAppear { horizontalViewport = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { horizontalViewport = $0 }
            })
        }
        .padding(.horizontal, 12)
        .disabled(model.pendingSceneName != nil)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { rootFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { rootFrame = $0 }
        })
        .onPreferenceChange(SequencerCellFrames.self) { frames = $0 }
        .overlay(alignment: .topLeading) {
            if let drag, let layout = model.noteLayouts[drag.transfer.source.id] {
                VStack(spacing: 2) {
                    SequencerNoteDiagram(layout: layout).frame(width: 48, height: 48)
                    Label(drag.transfer.copying ? "COPY" : "MOVE",
                          systemImage: drag.transfer.copying ? "plus.square.on.square" : "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.caption2.bold())
                }
                .padding(6).foregroundStyle(.cyan).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .position(x: drag.point.x - rootFrame.minX, y: drag.point.y - rootFrame.minY - 38)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: model.sequencerInteractionEpoch) { _ in
            if drag != nil || replacement != nil || deleting != nil {
                model.errorMessage = "The scene changed. The pattern gesture was cancelled."
            }
            cancelGesture(); replacement = nil; deleting = nil; pianoRoll = nil; afterMenu = nil; menuPattern = nil
        }
        .onDisappear { cancelGesture() }
        .sheet(item: $editing) { pattern in
            SequencerPatternEditor(pattern: pattern) { model.storePattern($0, expected: pattern) }
        }
        .confirmationDialog(
            "Delete pattern?",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { model.deletePattern(deleting) }; deleting = nil
            }
        }
        .confirmationDialog(
            "Replace notes with a new recording?",
            isPresented: Binding(
                get: { replacing != nil }, set: { if !$0 { replacing = nil } })
        ) {
            Button("Record", role: .destructive) {
                if let replacing { model.recordPattern(slot: replacing.slot, row: replacing.row) }
            }
        } message: {
            Text(
                "Uses Record mode and this column's fixed/free length. Tap again to finish at the end of the bar and start the loop. Existing playback continues for monitoring."
            )
        }
        .confirmationDialog("Replace existing pattern?", isPresented: Binding(
            get: { replacement != nil }, set: { if !$0 { replacement = nil } })
        ) {
            Button("Replace", role: .destructive) {
                if var transfer = replacement {
                    transfer.replace = true
                    if transfer.copying { model.copyPattern(transfer) } else { model.movePattern(transfer) }
                }
                replacement = nil
            }
            Button("Cancel", role: .cancel) { replacement = nil }
        } message: {
            if let replacement {
                Text("Replace instrument \(replacement.destination.slot + 1), row \(replacement.destination.row + 1)? The destination pattern will be replaced; \(replacement.copying ? "the source will remain." : "the source cell will become empty.")")
            }
        }
        .sheet(item: $menuPattern, onDismiss: {
            let action = afterMenu; afterMenu = nil; action?()
        }) { pattern in
            VStack(spacing: 18) {
                Text("Pattern actions").font(.headline)
                Button("Edit Pattern") { dismissMenu { editing = pattern } }
                Button("Duplicate") { dismissMenu { model.duplicatePattern(pattern) } }
                Button(pattern.introEnabled ? "Disable Intro" : "Enable Intro") {
                    dismissMenu {
                        var changed = pattern; changed.introEnabled.toggle(); _ = model.storePattern(changed)
                    }
                }
                Button("Record Again…") { dismissMenu { replacing = pattern } }
                Button("Stop Column") { dismissMenu { model.stopColumn(pattern.slot, arp: false) } }
                Button("Delete", role: .destructive) {
                    let source = transferSource(pattern)
                    dismissMenu { deleting = source }
                }
                Button("Cancel", role: .cancel) { menuPattern = nil }
            }
            .padding(24).presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $pianoRoll) { pattern in
            PianoRollView(model: model, pattern: pattern) { pianoRoll = nil }
        }
        .onReceive(Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()) { _ in
            meters = (0..<16).map { slot in
                let peak = Double(ov_seq_take_level(UInt32(slot))) / 65535
                return max(max(0, min(1, (20 * log10(max(peak, 0.000001)) + 60) / 60)), meters[slot] - 0.08)
            }
        }
    }

    private func dismissMenu(perform action: @escaping () -> Void) {
        afterMenu = action; menuPattern = nil
    }

    private func pad(_ instrument: RackInstrument, row: Int) -> some View {
        let pattern = model.pattern(slot: instrument.slot, row: row)
        let active = Int(ov_seq_active(UInt32(instrument.slot))) == row
        let queued = Int(ov_seq_pending(UInt32(instrument.slot))) == row
        let recording = model.recordingPhases[instrument.slot * 8 + row] != nil
        let stopping = active && ov_seq_stopping(UInt32(instrument.slot)) != 0
        let phase = model.recordingPhases[instrument.slot * 8 + row] ?? 0
        let color = MIDIChannelColors.color(instrument.channel)
        let cell = PatternCell(slot: instrument.slot, row: row)
        let commandPending = ov_seq_pad_pending(UInt32(instrument.slot), UInt32(row)) != 0
        let finishing = recording && phase == 5
        let waiting = recording && (phase == 1 || phase == 2 || phase == 4) || (queued || commandPending) && !active
        let position: Double = Double(recording ? ov_seq_record_progress_for_slot(UInt32(instrument.slot)) :
            ov_seq_position(UInt32(instrument.slot))) / 65535
        let showCopyHint = copyHint == cell.id
        let highlighted = drag?.target == cell
        let visual = ZStack {
                if !recording, let pattern, let layout = model.noteLayouts[pattern.id] {
                    SequencerNoteDiagram(layout: layout).equatable()
                }
                if recording || active || queued || commandPending {
                    SequencerCellProgress(
                        position: position, queued: queued || finishing || commandPending, stopping: stopping || finishing,
                        recording: recording, waiting: waiting,
                        countRemaining: recording && phase == 2 ? Int(ov_seq_record_remaining_for_slot(UInt32(instrument.slot))) : 0,
                        size: max(1, width - 8))
                } else if pattern == nil {
                    Image(systemName: "plus")
                }
            }
            .padding(.horizontal, 5).frame(width: width, height: padHeight)
            .foregroundStyle(recording ? Color.red : color)
            .background(color.opacity(active ? 0.32 : pattern == nil ? 0.04 : 0.17), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(queued ? Color.white : color.opacity(0.45), lineWidth: queued ? 2 : 1))
            .contentShape(Rectangle())
        let interactive = visual
            .overlay {
                SequencerTouchSurface(editable: pattern != nil && !recording, epoch: model.sequencerInteractionEpoch,
                                      revision: ov_seq_cell_revision(UInt32(instrument.slot), UInt32(row)),
                                      onDown: { heldSource = pattern.map(transferSource) },
                                      onEffect: { effect, point in handleGesture(effect, cell: cell, point: point) },
                                      onCancel: { cancelGesture() })
                    .accessibilityHidden(true)
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(highlighted ? Color.cyan : .clear, lineWidth: 3).allowsHitTesting(false))
            .overlay(alignment: .topTrailing) {
                if showCopyHint {
                    Image(systemName: "plus.square.on.square").font(.caption).foregroundStyle(.cyan).allowsHitTesting(false)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SequencerCellFrames.self, value: [cell: proxy.frame(in: .global)])
            })
        return interactive.accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.tapPattern(slot: instrument.slot, row: row) }
        .accessibilityLabel(
            "\(instrument.name), row \(row + 1), \(recording ? "finish recording at end of bar and play loop" : active ? "stop at end of bar" : pattern?.name ?? "record pattern")\(queued ? ", queued" : active ? ", playing" : "")"
        )
        .accessibilityAction(named: "Pattern actions") { if let pattern { menuPattern = pattern } }
        .accessibilityAction(named: "Piano Roll") { if let pattern { pianoRoll = pattern } }
        .accessibilityAction(named: "Create Pattern") {
            if pattern == nil { editing = SequencerPattern(slot: instrument.slot, row: row, name: "Pattern \(row + 1)") }
        }
    }

    private func transferSource(_ pattern: SequencerPattern) -> PatternTransfer {
        let revision = ov_seq_cell_revision(UInt32(pattern.slot), UInt32(pattern.row))
        return PatternTransfer(source: pattern, destination: PatternCell(slot: pattern.slot, row: pattern.row),
                               sourceRevision: revision, targetRevision: revision, epoch: ov_seq_scene_epoch())
    }

    private func cancelGesture() {
        drag = nil; heldSource = nil; copyHint = nil
    }

    private func target(at point: CGPoint) -> PatternCell? {
        PatternGridHitTesting.target(at: point, cells: frames, verticalViewport: cellViewport,
                                     horizontalViewport: horizontalViewport, recordingCells: Set(model.recordingPhases.keys))
    }

    private func handleGesture(_ effect: PatternCellGesture.Effect, cell: PatternCell, point: CGPoint) {
        switch effect {
        case .tap:
            copyHint = nil
            model.tapPattern(slot: cell.slot, row: cell.row)
        case .copyReady:
            copyHint = cell.id
        case .beginDrag(let copying):
            guard var source = heldSource, source.source.id == cell.id,
                  model.recordingPhases[cell.id] == nil, model.pendingPatternTransfer == nil,
                  model.pendingSequencerHistory == nil else {
                model.errorMessage = "The pattern is not available for editing."; cancelGesture(); return
            }
            source.copying = copying
            drag = SequencerCellDrag(transfer: source, point: point, target: target(at: point))
        case .drag:
            guard PatternGridHitTesting.contains(point, cells: frames, verticalViewport: cellViewport,
                                                horizontalViewport: horizontalViewport) else { cancelGesture(); return }
            drag?.point = point
            drag?.target = target(at: point)
        case .drop:
            defer { cancelGesture() }
            guard let drag, let target = target(at: point), target.id != drag.transfer.source.id else { return }
            var transfer = drag.transfer
            transfer.destination = target
            transfer.targetRevision = ov_seq_cell_revision(UInt32(target.slot), UInt32(target.row))
            transfer.expectedDestination = model.pattern(slot: target.slot, row: target.row)
            if transfer.expectedDestination != nil { replacement = transfer }
            else if transfer.copying { model.copyPattern(transfer) }
            else { model.movePattern(transfer) }
        case .delete:
            deleting = heldSource; cancelGesture()
        case .edit:
            if let pattern = model.pattern(slot: cell.slot, row: cell.row) { pianoRoll = pattern }
            cancelGesture()
        case .menu:
            if model.recordingPhases[cell.id] == nil {
                if let pattern = model.pattern(slot: cell.slot, row: cell.row) { menuPattern = pattern }
                else { editing = SequencerPattern(slot: cell.slot, row: cell.row, name: "Pattern \(cell.row + 1)") }
            }
            cancelGesture()
        case .scroll:
            cancelGesture()
        }
    }

    private func mixer(_ instrument: RackInstrument) -> some View {
        VStack(spacing: 5) {
            Text(instrument.name).lineLimit(1).font(.caption2.bold())
            HStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: {
                            model.instruments.first { $0.slot == instrument.slot }?.levelDB ?? -48
                        }, set: { model.mixColumn(instrument.slot, level: $0) }), in: -48...0
                )
                .frame(width: 90).rotationEffect(.degrees(-90)).frame(width: max(20, width - 14), height: 96)
                .accessibilityLabel("\(instrument.name) volume")
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.white.opacity(0.06))
                        Capsule().fill(meters[instrument.slot] > 0.95 ? Color.red : Color.green)
                            .frame(height: max(0, proxy.size.height * meters[instrument.slot]))
                    }
                }.frame(width: 7, height: 90)
            }
            Text("\(Int(instrument.levelDB)) dB").font(.system(size: 9, design: .monospaced))
            SequencerPanKnob(value: instrument.pan) { model.mixColumn(instrument.slot, pan: $0) }
                .accessibilityLabel("\(instrument.name) pan")
            HStack(spacing: 2) {
                Button("M") { model.mixColumn(instrument.slot, mute: !instrument.muted) }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(instrument.muted ? Color.orange : Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                Button("S") { model.soloColumn(instrument.slot) }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(model.soloSlots.contains(instrument.slot) ? Color.yellow : Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
            }.buttonStyle(.plain).font(.caption.bold())
            Button {
                model.stopColumn(instrument.slot, arp: true)
            } label: {
                Label("ARP", systemImage: "stop.fill").font(.system(size: 9, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
            }.buttonStyle(.plain).accessibilityLabel("Stop \(instrument.name) arpeggiator")
        }
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SequencerPanKnob: View {
    let value: Double
    let change: (Double) -> Void
    @State private var origin: Double?
    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.cyan).frame(width: 2, height: 12).offset(y: -7)
                    .rotationEffect(.degrees(value * 135))
            }.frame(width: 32, height: 32)
            Text(value < -0.02 ? "L \(Int(-value * 100))" : value > 0.02 ? "R \(Int(value * 100))" : "CENTER")
                .font(.system(size: 8, design: .monospaced))
        }
        .gesture(
            DragGesture(minimumDistance: 0).onChanged {
                if origin == nil { origin = value }
                change(min(1, max(-1, (origin ?? value) - Double($0.translation.height) / 70)))
            }.onEnded { _ in origin = nil }
        )
        .onTapGesture(count: 2) { change(0) }
        .accessibilityElement().accessibilityValue("\(Int(value * 100))")
        .accessibilityAdjustableAction { direction in
            change(min(1, max(-1, value + (direction == .increment ? 0.05 : -0.05))))
        }
    }
}

private struct SequencerPatternEditor: View {
    @State var pattern: SequencerPattern
    let save: (SequencerPattern) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pitch = 60
    @State private var velocity = 100
    @State private var start = 0.0
    @State private var duration = 240.0
    @State private var output = true
    @State private var selectedNote: UInt64?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pattern") {
                    TextField("Name", text: $pattern.name)
                    Stepper(
                        "Length: \(Double(pattern.length) / 3840, specifier: "%.2f") bars",
                        value: Binding(get: { max(1, Int((pattern.length + 3839) / 3840)) }, set: { pattern.length = Int64($0) * 3840 }),
                        in: 1...Int(SequencerPattern.maxTicks / 3840))
                    Toggle("Loop", isOn: $pattern.loop)
                    Toggle("Play intro once", isOn: $pattern.introEnabled)
                    Stepper(
                        "Intro marker: \(Double(pattern.intro) / 960, specifier: "%.2f") beats before bar",
                        value: Binding(get: { Int(pattern.intro / 240) }, set: { pattern.intro = Int64($0) * 240 }), in: 0...48)
                    Picker("Playback quantization", selection: $pattern.quantize) {
                        Text("Original timing").tag(0)
                        Text("1/8").tag(480); Text("1/16").tag(240); Text("1/32").tag(120)
                        Text("1/8 triplet").tag(320); Text("1/16 triplet").tag(160)
                    }
                    Text(
                        "Negative note starts are intro. The zero marker is the first main-loop bar. Intro plays once; copies can disable it without deleting notes. Recording replaces notes after confirmation, while the current loop can keep playing."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Step input · \(rackNoteName(pitch))") {
                    Stepper("Pitch \(rackNoteName(pitch))", value: $pitch, in: 0...127)
                    ScrollView(.horizontal) {
                        HStack(spacing: 5) {
                            ForEach(0..<Int(min(256, pattern.length / 240)), id: \.self) { step in
                                let tick = Int64(step * 240)
                                let existing = pattern.notes.first { $0.pitch == pitch && $0.start == tick }
                                Button {
                                    if let existing { pattern.notes.removeAll { $0.id == existing.id } } else { appendNote(at: tick) }
                                } label: {
                                    Text("\(step + 1)").font(.caption.monospaced()).frame(width: 36, height: 38)
                                        .background(
                                            existing != nil ? Color.cyan : Color.white.opacity(step % 4 == 0 ? 0.15 : 0.06),
                                            in: RoundedRectangle(cornerRadius: 6)
                                        )
                                        .foregroundStyle(existing != nil ? Color.black : Color.white)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Stepper("Velocity \(velocity)", value: $velocity, in: 1...127)
                    Toggle("Bypass arpeggiator (recorded output)", isOn: $output)
                    LabeledContent("Start (beats)") {
                        TextField("Start", value: $start, format: .number).keyboardType(.numbersAndPunctuation).frame(width: 95)
                    }
                    LabeledContent("Duration (beats)") {
                        TextField("Duration", value: $duration, format: .number).keyboardType(.decimalPad).frame(width: 95)
                    }
                    HStack {
                        Button(selectedNote == nil ? "Add Note" : "Apply Note Edit") { applyNote() }
                        if selectedNote != nil { Button("New Note") { selectedNote = nil } }
                    }
                    if let message { Text(message).foregroundStyle(.orange) }
                }
                Section("Notes · \(pattern.notes.count)/1024") {
                    ForEach(pattern.notes.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }) { note in
                        Button {
                            selectedNote = note.id; pitch = note.pitch; velocity = note.velocity
                            start = Double(note.start) / 960; duration = Double(note.duration) / 960; output = note.output
                        } label: {
                            HStack {
                                Text(rackNoteName(note.pitch))
                                Text(
                                    "@ \(Double(note.start) / 960, specifier: "%.3f") · \(Double(note.duration) / 960, specifier: "%.3f") beats"
                                )
                                Spacer()
                                Text("V\(note.velocity)\(note.start < 0 ? " INTRO" : "")")
                            }.font(.caption.monospaced())
                        }
                        .swipeActions { Button("Delete", role: .destructive) { pattern.notes.removeAll { $0.id == note.id } } }
                    }
                }
            }
            .navigationTitle(pattern.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if save(pattern) { dismiss() } }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { duration = 0.25 }
    }
    private func appendNote(at tick: Int64) {
        guard pattern.notes.count < 1024 else { message = "Pattern note capacity reached."; return }
        guard (pattern.notes.map(\.id).max() ?? 0) < UInt64.max - 1 else { message = "Pattern note ID capacity reached."; return }
        let id = (pattern.notes.map(\.id).max() ?? 0) + 1
        pattern.notes.append(SequencerNote(id: id, start: tick, duration: 240, pitch: pitch, velocity: velocity, output: output))
    }
    private func applyNote() {
        guard start.isFinite, duration.isFinite, start >= -Double(pattern.intro) / 960,
            start < Double(pattern.length) / 960, duration >= 1.0 / 960, duration <= Double(SequencerPattern.maxTicks) / 960
        else {
            message = "Start must fit inside the intro/loop; duration must fit the supported tick range."; return
        }
        var changed = pattern
        guard selectedNote != nil || (changed.notes.map(\.id).max() ?? 0) < UInt64.max - 1 else {
            message = "Pattern note ID capacity reached."; return
        }
        let id = selectedNote ?? ((changed.notes.map(\.id).max() ?? 0) + 1)
        let note = SequencerNote(
            id: id, start: Int64((start * 960).rounded()), duration: Int64((duration * 960).rounded()),
            pitch: pitch, velocity: velocity, output: output)
        changed.notes.removeAll { $0.id == id }; changed.notes.append(note)
        do { try changed.validate(); pattern = changed; message = nil } catch { message = error.localizedDescription }
    }
}

struct SceneHistoryButton: View {
    @ObservedObject var model: OberVaveModel
    let undo: Bool

    private var entries: [SceneHistoryEntry] {
        Array((undo ? model.sceneParameterHistory.undoStack : model.sceneParameterHistory.redoStack).reversed())
    }

    private var busy: Bool {
        model.pendingSceneParameterHistory != nil || model.sceneHistoryJump != nil ||
        model.pendingSceneName != nil || model.sceneSwitchPending ||
        !model.activeParameterEdits.isEmpty || !model.activeSceneValueEdits.isEmpty ||
        !model.externalParameterGestures.isEmpty
    }

    var body: some View {
        Button { model.applySceneParameterHistory(undo: undo) } label: {
            Image(systemName: undo ? "arrow.uturn.backward" : "arrow.uturn.forward")
        }
        .disabled(entries.isEmpty || busy)
        .accessibilityLabel(undo ? "Undo scene edit" : "Redo scene edit")
        .contextMenu {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Button("\(index + 1). \(entry.title)") {
                    model.jumpSceneHistory(undo: undo, steps: index + 1)
                }
            }
        }
    }
}

struct RackSceneView: View {
    @ObservedObject var model: OberVaveModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftInstrument: RackInstrument?
    @State private var adding = false
    @State private var name = ""
    @State private var importsScene = false
    @State private var confirmsNew = false
    @State private var loadsScene: SavedRackScene?
    @State private var removesInstrument: RackInstrument?

    var body: some View {
        NavigationStack {
            List {
                Section("Scene") {
                    TextField("Scene name", text: $name)
                    HStack {
                        Button("Save Scene") { model.saveScene(name: name) }
                        Spacer()
                        Button("Save As New") { model.saveScene(name: name, asNew: true) }
                        Spacer()
                        Button("New Scene", role: .destructive) { confirmsNew = true }
                    }
                    .buttonStyle(.bordered)
                    if model.pendingSceneName != nil {
                        ProgressView("Saving scene…")
                    }
                    Button("Import Scene from Files") { importsScene = true }
                    if let status = model.sceneStatus { Text(status).foregroundStyle(.secondary) }
                    Text("Scenes store all sounds, MIDI channels, overlapping key zones, mixer levels, tempo and independent arpeggiator settings. Files are in On My iPad > OberVave > OberVave Scenes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Instruments (\(model.instruments.count)/16)") {
                    ForEach(model.instruments) { instrument in
                        HStack {
                            Button {
                                model.selectInstrument(instrument.slot)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(instrument.name).foregroundStyle(instrument.slot == model.selectedSlot ? .cyan : .primary)
                                    Text("CH \(instrument.channel)  |  \(rackNoteName(instrument.lowNote)) - \(rackNoteName(instrument.highNote))\(instrument.muted ? "  |  MUTE" : "")")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button("Edit") { adding = false; draftInstrument = instrument }
                                .buttonStyle(.bordered)
                            Button(role: .destructive) { removesInstrument = instrument } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.bordered)
                        }
                    }
                    Button {
                        adding = true
                        draftInstrument = model.newInstrumentDraft
                    } label: { Label("Add Instrument", systemImage: "plus.circle.fill") }
                        .disabled(model.instruments.count >= 16)
                    Text("128 voices with effects can exceed this iPad's CPU. Add only the instances you need. Mute silences a mixer strip; it does not unload the engine.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Saved Scenes") {
                    if model.savedScenes.isEmpty { Text("No saved scenes").foregroundStyle(.secondary) }
                    ForEach(model.savedScenes) { scene in
                        HStack {
                            Button(scene.name) { loadsScene = scene }
                            Spacer()
                            ShareLink(item: scene.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
                if !model.sceneSessions.isEmpty {
                    Section("Scenes in this session") {
                        ForEach(model.sceneSessions.keys.sorted(), id: \.self) { key in
                            if let scene = model.sceneSessions[key] {
                                Button("\(scene.document.name) · unsaved session") {
                                    model.restoreSessionScene(key)
                                    name = model.sceneName
                                }
                            }
                        }
                    }
                }
            }
            .disabled(model.pendingSceneName != nil)
            .navigationTitle("Scenes & Instruments")
            .disabled(model.sceneSwitchPending)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    SceneHistoryButton(model: model, undo: true)
                    SceneHistoryButton(model: model, undo: false)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { name = model.sceneName; model.refreshSavedScenes() }
            .onChange(of: model.sceneName) { name = $0 }
            .sheet(item: $draftInstrument) { instrument in
                RackInstrumentEditor(instrument: instrument, adding: adding) { edited in
                    adding ? model.addInstrument(edited) : model.configureInstrument(edited)
                }
            }
            .fileImporter(isPresented: $importsScene, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): model.loadScene(from: url)
                case .failure(let error): model.errorMessage = "Could not import scene: \(error.localizedDescription)"
                }
            }
            .confirmationDialog("Create a new scene? Current unsaved edits remain available during this session.", isPresented: $confirmsNew) {
                Button("New Empty Scene", role: .destructive) { model.newScene() }
            }
            .confirmationDialog("Load this scene? Current unsaved edits remain available during this session.", isPresented: Binding(
                get: { loadsScene != nil }, set: { if !$0 { loadsScene = nil } })) {
                if let scene = loadsScene {
                    Button("Load \(scene.name)") { model.loadScene(from: scene.url); loadsScene = nil }
                }
            }
            .confirmationDialog("Remove this instrument and its unsaved sound?", isPresented: Binding(
                get: { removesInstrument != nil }, set: { if !$0 { removesInstrument = nil } })) {
                if let instrument = removesInstrument {
                    Button("Remove \(instrument.name)", role: .destructive) {
                        model.removeInstrument(instrument.slot); removesInstrument = nil
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

}

private struct RackInstrumentEditor: View {
    @State var instrument: RackInstrument
    let adding: Bool
    let onSave: (RackInstrument) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var learnsLow: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section("Instrument") {
                    TextField("Name", text: $instrument.name)
                    LabeledContent("Engine", value: String(cString: ov_engine_name(UInt32(instrument.engine))))
                    Picker("MIDI Channel", selection: $instrument.channel) {
                        ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
                    }
                }
                Section("Keyboard Zone (inclusive)") {
                    KeyboardZoneRange(low: $instrument.lowNote, high: $instrument.highNote,
                                      color: MIDIChannelColors.color(instrument.channel))
                    HStack {
                        Button(learnsLow == true ? "CANCEL LOW" : "LEARN LOW") { toggleLearn(low: true) }
                            .tint(learnsLow == true ? .orange : .accentColor)
                        Spacer()
                        Button(learnsLow == false ? "CANCEL HIGH" : "LEARN HIGH") { toggleLearn(low: false) }
                            .tint(learnsLow == false ? .orange : .accentColor)
                    }
                    .buttonStyle(.bordered)
                    if learnsLow != nil {
                        Text("Play a note on MIDI channel \(instrument.channel) to set the \(learnsLow == true ? "low" : "high") boundary.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("Instruments on the same channel may overlap to create layers. Notes outside the zone are ignored; sustain, pitch bend and CC follow the channel.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Stereo Mixer") {
                    LabeledContent("Level", value: instrument.levelDB <= -48 ? "MUTE" : String(format: "%.1f dB", instrument.levelDB))
                    Slider(value: $instrument.levelDB, in: -48...0, step: 0.5)
                    LabeledContent("Pan", value: String(format: "%+.0f%%", instrument.pan * 100))
                    Slider(value: $instrument.pan, in: -1...1, step: 0.01)
                    Toggle("Mute", isOn: $instrument.muted)
                }
            }
            .navigationTitle(adding ? "Add Instrument" : "Instrument Routing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(adding ? "Add" : "Apply") { if onSave(instrument) { dismiss() } }
                }
            }
            .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
                guard let low = learnsLow else { return }
                let learned = ov_take_key_learn()
                guard learned != 0 else { return }
                setBoundary(Int(learned - 1), low: low)
                learnsLow = nil
            }
            .onChange(of: instrument.channel) { _ in cancelLearn() }
            .onDisappear { cancelLearn() }
        }
    }

    private func toggleLearn(low: Bool) {
        if learnsLow == low { cancelLearn() }
        else { learnsLow = low; ov_key_learn(UInt32(instrument.channel)) }
    }

    private func cancelLearn() {
        learnsLow = nil
        ov_key_learn(0)
    }

    private func setBoundary(_ note: Int, low: Bool) {
        if low { instrument.lowNote = min(note, instrument.highNote) }
        else { instrument.highNote = max(note, instrument.lowNote) }
    }
}

private struct KeyboardZoneRange: View {
    @Binding var low: Int
    @Binding var high: Int
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("LOW  \(rackNoteName(low)) [\(low)]")
                Spacer()
                Text("HIGH  \(rackNoteName(high)) [\(high)]")
            }
            .font(.caption.monospaced())
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 28)
                VStack(spacing: 8) {
                    Canvas { context, size in
                        let unit = size.width / 75
                        for black in [false, true] {
                            for note in 0...127 where KeyboardZoneLayout.isBlack(note) == black {
                                let x = Double(KeyboardZoneLayout.whiteIndex(note)) * unit
                                let rect = CGRect(x: black ? x - unit * 0.32 : x,
                                    y: 0, width: black ? unit * 0.64 : unit,
                                    height: black ? size.height * 0.62 : size.height)
                                let path = Path(rect)
                                let active = (low...high).contains(note)
                                context.fill(path, with: .color(active ? color.opacity(black ? 0.65 : 1) : black ? .black : .white))
                                context.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 0.5)
                            }
                        }
                    }
                    .frame(height: 48)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 8)
                        let start = KeyboardZoneLayout.position(low) * width
                        let end = KeyboardZoneLayout.position(high) * width
                        Capsule().fill(color).frame(width: max(2, end - start), height: 8).offset(x: start)
                        handle(low: true, width: width)
                        handle(low: false, width: width)
                    }
                    .frame(height: 44)
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 100)
            .coordinateSpace(name: "zoneRange")
        }
    }

    private func handle(low isLow: Bool, width: CGFloat) -> some View {
        let note = isLow ? low : high
        return Image(systemName: isLow ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 28, height: 24)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .offset(x: KeyboardZoneLayout.position(note) * width - 14, y: isLow ? -10 : 10)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("zoneRange"))
                .onChanged { value in
                    let note = KeyboardZoneLayout.note(at: (value.location.x - 14) / width)
                    if isLow { low = min(note, high) }
                    else { high = max(note, low) }
                })
            .accessibilityLabel(isLow ? "Low note" : "High note")
            .accessibilityValue(rackNoteName(note))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 1 : -1
                if isLow { low = max(0, min(high, low + delta)) }
                else { high = min(127, max(low, high + delta)) }
            }
    }
}

func rackNoteName(_ note: Int) -> String {
    ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][note % 12] + "\(note / 12 - 1)"
}
