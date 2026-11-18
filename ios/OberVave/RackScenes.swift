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
    var newInstrumentDraft: RackInstrument? {
        guard let slot = (0..<16).first(where: { candidate in
            !instruments.contains { $0.slot == candidate }
        }) else { return nil }
        let channel = (1...16).first { candidate in !instruments.contains { $0.channel == candidate } } ?? 1
        return .oberVave(slot: slot, channel: channel)
    }

    var selectedInstrument: RackInstrument? { instruments.first { $0.slot == selectedSlot } }

    func syncRackState() {
        if ov_seq_record_ready() != 0 {
            let result = ov_seq_record_result()
            var clip = ov_seq_clip()
            if ov_seq_read_record(&clip) != 0 {
                recordingPattern = nil
                if result == 1 {
                    let pattern = SequencerPattern(core: clip)
                    do {
                        try pattern.validate()
                        if instruments.contains(where: { $0.slot == pattern.slot }) {
                            patterns.removeAll { $0.id == pattern.id }
                            patterns.append(pattern)
                        }
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        sequencerRevision &+= 1
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
                : "The audio rack rejected an invalid configuration."
        }
        var captured = ov_scene_config()
        if ov_rack_snapshot_read(&captured) != 0 {
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
        guard pendingSceneName == nil, instruments.contains(where: { $0.slot == slot }) else { return }
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

    func configureInstrument(_ instrument: RackInstrument) -> Bool {
        guard pendingSceneName == nil else { return false }
        do {
            try instrument.validate()
            guard let index = instruments.firstIndex(where: { $0.slot == instrument.slot }),
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
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func removeInstrument(_ slot: Int) {
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
        keyboardChannelMask ^= 1 << (channel - 1)
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
            try encoder.encode(document).write(to: url, options: .atomic)
            sceneName = name; sceneFileURL = url
            sceneStatus = "Saved \(name)"
            refreshSavedScenes()
        } catch { errorMessage = "Could not save scene: \(error.localizedDescription)" }
    }

    func loadScene(from url: URL) {
        guard pendingSceneName == nil else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let document = try RackSceneDocument.read(from: url)
            let folder = try scenesFolder()
            try applyScene(document)
            sceneFileURL = url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL ? url : nil
        } catch { errorMessage = "Could not load scene: \(error.localizedDescription)" }
    }

    private func applyScene(_ document: RackSceneDocument) throws {
        try document.validate()
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
        instruments = document.instruments
        patterns = document.patterns ?? []
        soloSlots = []
        selectedSlot = document.selectedSlot ?? instruments.first?.slot ?? 0
        ov_rack_select(UInt32(selectedSlot))
        keyboardChannelMask = document.keyboardMask
        ov_keyboard_channels(document.keyboardMask)
        tempo = document.tempo
        setMasterLevelDB(document.masterDB); setMasterPan(document.masterPan)
        sceneName = document.name
        sceneStatus = "Loaded \(document.name)"
        showSelectedInstrument()
    }

    func newScene() {
        guard pendingSceneName == nil else { return }
        do {
            let empty = RackSceneDocument(name: "Untitled Scene", instruments: [], tempo: tempo,
                masterDB: masterLevelDB, masterPan: masterPan, keyboardMask: keyboardChannelMask, selectedSlot: nil)
            try applyScene(empty)
            sceneFileURL = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

extension OberVaveModel {
    func pattern(slot: Int, row: Int) -> SequencerPattern? {
        patterns.first { $0.slot == slot && $0.row == row }
    }

    @discardableResult
    func storePattern(_ pattern: SequencerPattern) -> Bool {
        guard pendingSceneName == nil else { return false }
        guard recordingPattern == nil else { errorMessage = "Finish recording before editing patterns."; return false }
        do {
            try pattern.validate()
            var clip = pattern.coreClip()
            guard ov_seq_set_clip(&clip) != 0 else { throw SceneError.invalid("Could not publish pattern to the audio engine.") }
            patterns.removeAll { $0.id == pattern.id }
            patterns.append(pattern)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func deletePattern(_ pattern: SequencerPattern) {
        guard recordingPattern == nil else { errorMessage = "Finish recording before deleting patterns."; return }
        guard ov_seq_delete(UInt32(pattern.slot), UInt32(pattern.row)) != 0 else {
            errorMessage = "Could not delete the pattern."; return
        }
        patterns.removeAll { $0.id == pattern.id }
    }

    func duplicatePattern(_ pattern: SequencerPattern) {
        guard let row = (0..<8).first(where: { self.pattern(slot: pattern.slot, row: $0) == nil }) else {
            errorMessage = "This instrument already has eight patterns."; return
        }
        var copy = pattern; copy.row = row
        copy.name = String((pattern.name + " Copy").prefix(24))
        _ = storePattern(copy)
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
        guard recordingPattern == nil else { errorMessage = "Finish the current recording first."; return }
        guard let instrument = instruments.first(where: { $0.slot == slot }) else {
            errorMessage = "The recording instrument is unavailable."; return
        }
        if ov_seq_arm(UInt32(slot), UInt32(row), UInt32(recordMode.rawValue), UInt32(recordCountBars),
                      UInt32(instrument.recordBeats), recordOutput ? 1 : 0) != 0 {
            recordingPattern = slot * 8 + row
        } else {
            errorMessage = "Could not arm recording."
        }
    }
    func finishPatternRecording() {
        if ov_seq_finish_record() == 0 { errorMessage = "Could not finish recording.";  }
    }
    func setRecordLength(slot: Int, beats: Int) {
        guard (0...256).contains(beats), let index = instruments.firstIndex(where: { $0.slot == slot }) else {
            errorMessage = "Invalid recording length."; return
        }
        instruments[index].recordBeats = beats
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
        _ = configureInstrument(instrument)
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
                Text("During scene playback, Wait for note and Immediate join the next bar and capture the pickup. Count-in counts full bars. Tap the recording pad again to finish and play.")
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
        case .countIn: "Audible metronome counts one or two bars. Playing during the count-in becomes a one-shot intro."
        case .immediate: "Start the loop immediately when the scene is stopped."
        }
    }
}

private struct SequencerRecordLengthControl: View {
    @ObservedObject var model: OberVaveModel
    let slot: Int
    @State private var showsLength = false
    private var beats: Int { model.instruments.first { $0.slot == slot }?.recordBeats ?? 4 }

    var body: some View {
        Button(beats == 0 ? "FREE LENGTH" : "\(beats) beats") { showsLength = true }
            .font(.system(size: 10, design: .monospaced))
            .accessibilityLabel("Recording length for instrument \(slot + 1)")
            .popover(isPresented: $showsLength, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording length").font(.headline)
                    Picker("Length", selection: Binding(
                        get: { beats == 0 },
                        set: { model.setRecordLength(slot: slot, beats: $0 ? 0 : 4) }
                    )) {
                        Text("Fixed").tag(false)
                        Text("Free").tag(true)
                    }.pickerStyle(.segmented)
                    if beats > 0 {
                        Stepper("\(beats) quarter notes", value: Binding(
                            get: { max(1, beats) }, set: { model.setRecordLength(slot: slot, beats: $0) }
                        ), in: 1...256)
                    }
                    Text(beats == 0
                        ? "Record until you tap the pad again. There is no 256-beat automatic cutoff."
                        : "Recording ends automatically after \(beats) beats and starts the loop. Tap earlier to finish manually.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20).frame(width: 300)
                .disabled(model.recordingPattern != nil || model.pendingSceneName != nil)
                .preferredColorScheme(.dark)
            }
    }
}

struct SequencerView: View {
    @ObservedObject var model: OberVaveModel
    @State private var editing: SequencerPattern?
    @State private var deleting: SequencerPattern?
    @State private var replacing: SequencerPattern?
    @State private var meters = [Double](repeating: 0, count: 16)
    private let width: CGFloat = 110
    private let padHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Launch", selection: $model.launchGrid) {
                    Text("FREE").tag(0); Text("BEAT").tag(1); Text("BAR").tag(2)
                }
                .pickerStyle(.segmented).frame(maxWidth: 290)
                Spacer()
                if model.recordingPattern != nil {
                    Button {
                        model.finishPatternRecording()
                    } label: {
                        Label("FINISH REC", systemImage: "record.circle.fill").foregroundStyle(.red)
                    }.buttonStyle(.bordered)
                }
                Text("HOLD PAD TO EDIT / RECORD").font(.caption2.monospaced()).foregroundStyle(.secondary)
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
        }
        .padding(.horizontal, 12)
        .disabled(model.pendingSceneName != nil)
        .sheet(item: $editing) { pattern in
            SequencerPatternEditor(pattern: pattern) { model.storePattern($0) }
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
                "Uses Record mode and this column's fixed/free length. Finishing starts loop playback. Existing playback continues for monitoring."
            )
        }
        .onReceive(Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()) { _ in
            meters = (0..<16).map { slot in
                let peak = Double(ov_seq_take_level(UInt32(slot))) / 65535
                return max(max(0, min(1, (20 * log10(max(peak, 0.000001)) + 60) / 60)), meters[slot] - 0.08)
            }
        }
    }

    private func pad(_ instrument: RackInstrument, row: Int) -> some View {
        let pattern = model.pattern(slot: instrument.slot, row: row)
        let active = Int(ov_seq_active(UInt32(instrument.slot))) == row
        let queued = Int(ov_seq_pending(UInt32(instrument.slot))) == row
        let recording = model.recordingPattern == instrument.slot * 8 + row
        let phase = ov_seq_record_phase()
        let color = MIDIChannelColors.color(instrument.channel)
        return Button {
            if recording {
                model.finishPatternRecording()
            } else if pattern != nil {
                model.launchPattern(slot: instrument.slot, row: row)
            } else {
                model.recordPattern(slot: instrument.slot, row: row)
            }
        } label: {
            VStack(spacing: 3) {
                HStack {
                    Image(
                        systemName: recording
                            ? "record.circle.fill" : queued ? "clock" : active ? "play.fill" : pattern == nil ? "plus" : "square.grid.2x2")
                    if let pattern {
                        Text(pattern.name).lineLimit(1).font(.caption.bold())
                    }
                }
                if recording {
                    Text(phase == 1 ? "WAIT FOR NOTE" : phase == 2 ? "COUNT \(ov_seq_record_remaining())"
                        : phase == 4 ? "BAR \(ov_seq_record_remaining())" : "REC · TAP TO LOOP")
                        .font(.system(size: 9, design: .monospaced))
                } else if let pattern {
                    Text("\(pattern.notes.count) notes\(pattern.introEnabled && pattern.intro > 0 ? " · INTRO" : "")")
                        .font(.system(size: 9, design: .monospaced))
                }
                if active {
                    ProgressView(value: Double(ov_seq_position(UInt32(instrument.slot))), total: 65535).tint(color)
                }
            }
            .padding(.horizontal, 5).frame(width: width, height: padHeight)
            .foregroundStyle(recording ? Color.red : active ? Color.black : color)
            .background(active ? color : color.opacity(pattern == nil ? 0.04 : 0.17), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(queued ? Color.white : color.opacity(0.45), lineWidth: queued ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(instrument.name), row \(row + 1), \(recording ? "finish recording and play loop" : pattern?.name ?? "record pattern")\(queued ? ", queued" : active ? ", playing" : "")"
        )
        .contextMenu {
            if let pattern {
                Button("Edit Pattern", systemImage: "pencil") { editing = pattern }
                Button("Duplicate", systemImage: "doc.on.doc") { model.duplicatePattern(pattern) }
                Button(pattern.introEnabled ? "Disable Intro" : "Enable Intro") {
                    var changed = pattern; changed.introEnabled.toggle(); _ = model.storePattern(changed)
                }
                Button("Record Again…", systemImage: "record.circle") { replacing = pattern }
                Button("Stop Column", systemImage: "stop.fill") { model.stopColumn(instrument.slot, arp: false) }
                Button("Delete", role: .destructive) { deleting = pattern }
            } else {
                Button("Create Pattern") { editing = SequencerPattern(slot: instrument.slot, row: row, name: "Pattern \(row + 1)") }
            }
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
                .frame(width: 90).rotationEffect(.degrees(-90)).frame(width: 38, height: 96)
                .accessibilityLabel("\(instrument.name) volume")
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.white.opacity(0.06))
                        Capsule().fill(meters[instrument.slot] > 0.95 ? Color.red : Color.green)
                            .frame(height: max(0, proxy.size.height * meters[instrument.slot]))
                    }
                }.frame(width: 7, height: 90)
                Text("\(Int(instrument.levelDB))").font(.caption2.monospaced()).frame(width: 28)
            }
            SequencerPanKnob(value: instrument.pan) { model.mixColumn(instrument.slot, pan: $0) }
                .accessibilityLabel("\(instrument.name) pan")
            HStack(spacing: 4) {
                Button("M") { model.mixColumn(instrument.slot, mute: !instrument.muted) }
                    .tint(instrument.muted ? .orange : .gray)
                Button("S") { model.soloColumn(instrument.slot) }
                    .tint(model.soloSlots.contains(instrument.slot) ? .yellow : .gray)
            }.buttonStyle(.bordered).font(.caption.bold())
            Button {
                model.stopColumn(instrument.slot, arp: true)
            } label: {
                Label("ARP", systemImage: "stop.fill").font(.caption2.bold())
            }.buttonStyle(.bordered).accessibilityLabel("Stop \(instrument.name) arpeggiator")
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
                        "Length: \(Double(pattern.length) / 960, specifier: "%.2f") beats",
                        value: Binding(get: { max(1, Int(pattern.length / 960)) }, set: { pattern.length = Int64($0) * 960 }),
                        in: 1...Int(SequencerPattern.maxTicks / 960))
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
            }
            .disabled(model.pendingSceneName != nil)
            .navigationTitle("Scenes & Instruments")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
            .confirmationDialog("Replace the current scene? Unsaved edits will be lost.", isPresented: $confirmsNew) {
                Button("New Empty Scene", role: .destructive) { model.newScene() }
            }
            .confirmationDialog("Load this scene? Unsaved edits will be lost.", isPresented: Binding(
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
