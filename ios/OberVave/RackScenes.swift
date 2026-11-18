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
        let generation = ov_rack_stop_generation()
        if generation != keyboardStopGeneration {
            keyboardStopGeneration = generation
            keyboardLock.clear()
        }
        ov_rack_collect()
        let failure = ov_rack_take_error()
        if failure != 0 {
            errorMessage = failure == 1 ? "The MIDI/control queue overflowed. Notes were stopped to prevent stuck notes."
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
        guard pendingSceneName == nil, ov_rack_remove(UInt32(slot)) != 0 else { return }
        instruments.removeAll { $0.slot == slot }
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
                selectedSlot: instruments.isEmpty ? nil : selectedSlot)
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
        var c = ov_scene_config()
        c.tempo = UInt32(document.tempo)
        withUnsafeMutableBytes(of: &c.slots) { raw in
            let slots = raw.bindMemory(to: ov_rack_slot.self)
            for instrument in document.instruments {
                slots[instrument.slot].present = 1
                slots[instrument.slot].config = instrument.coreConfig()
            }
        }
        guard ov_rack_load(&c) != 0 else {
            throw SceneError.invalid("Could not allocate this scene. The current scene has been kept.")
        }
        instruments = document.instruments
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
                        Button("Save As New") {
                            model.saveScene(name: name, asNew: true)
                        }
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
