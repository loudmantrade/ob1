// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AudioToolbox
import AudioUnit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private let programID = AudioUnitParameterID(kOberVaveProgram)
private let masterID = AudioUnitParameterID(kOberVaveMaster)
private let panID = AudioUnitParameterID(kOberVavePan)
private let syncID = AudioUnitParameterID(kOberVaveSync)
private let gridID = AudioUnitParameterID(kOberVaveGrid)

struct AUDragSurface: NSViewRepresentable {
    let onStart: () -> Void
    let onChange: (CGPoint, CGSize) -> Void
    let onEnd: () -> Void

    final class MouseView: NSView {
        var actions: AUDragSurface
        private var start: CGPoint?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        init(_ actions: AUDragSurface) {
            self.actions = actions
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            actions.onStart()
            mouseDragged(with: event)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = convert(event.locationInWindow, from: nil)
            actions.onChange(point, CGSize(width: point.x - start.x, height: point.y - start.y))
        }
        override func mouseUp(with event: NSEvent) { finish() }
        func finish() {
            if start != nil { start = nil; actions.onEnd() }
        }
    }
    func makeNSView(context: Context) -> MouseView { MouseView(self) }
    func updateNSView(_ view: MouseView, context: Context) { view.actions = self }
    static func dismantleNSView(_ view: MouseView, coordinator: ()) { view.finish() }
}

@MainActor
final class OberVaveModel: ObservableObject {
    let unit: AudioUnit
    @Published private var values = Array(repeating: Float(0), count: Int(kOberVaveParameterCount))
    @Published var errorMessage: String?
    private var maxima = Array(repeating: 127, count: Int(kOberVaveParameterCount))
    private var gestures = Set<AudioUnitParameterID>()
    let programNames: [String]

    init(unit: AudioUnit) {
        self.unit = unit
        var strings: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout.size(ofValue: strings))
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterValueStrings,
            kAudioUnitScope_Global, programID, &strings, &size)
        if status == noErr, let strings {
            programNames = strings.takeRetainedValue() as? [String] ?? []
        } else {
            programNames = []
        }
        for id in maxima.indices {
            var info = AudioUnitParameterInfo()
            size = UInt32(MemoryLayout.size(ofValue: info))
            let result = AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo,
                kAudioUnitScope_Global, UInt32(id), &info, &size)
            if result == noErr {
                maxima[id] = Int(info.maxValue)
                if info.flags.contains(.flag_CFNameRelease) { info.cfNameString?.release() }
            } else { report(result, "Read parameter definition") }
        }
        report(status, "Read factory programs")
        if programNames.isEmpty { errorMessage = "The audio unit did not provide factory program names." }
        refresh()
    }

    var program: Int { Int(values[Int(programID)]) }
    var masterLevelDB: Double { values[Int(masterID)] <= 0 ? -48 : max(-48, 20 * log10(Double(values[Int(masterID)]))) }
    var masterPan: Double { Double(values[Int(panID)]) }
    var isArpSyncEnabled: Bool { values[Int(syncID)] != 0 }
    var arpSyncGrid: Int { min(5, max(0, Int(values[Int(gridID)]))) }
    func parameterValue(_ parameter: SynthParameter) -> Int { Int(values[Int(parameter.audioUnitID)]) }
    func parameterMax(_ parameter: SynthParameter) -> Int { maxima[Int(parameter.audioUnitID)] }
    func setParameter(_ parameter: SynthParameter, value: Int) { set(parameter.audioUnitID, Float(value)) }
    var controllerContext: Int { 0 }
    func armControllerLearn(_ armed: Bool) {
        var value: UInt32 = armed ? 1 : 0
        report(AudioUnitSetProperty(unit, UInt32(kOberVaveControllerLearn), kAudioUnitScope_Global,
            0, &value, UInt32(MemoryLayout.size(ofValue: value))), "Arm controller learn")
    }
    func takeControllerLearn() -> Int {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        report(AudioUnitGetProperty(unit, UInt32(kOberVaveControllerLearn), kAudioUnitScope_Global,
            0, &value, &size), "Read controller learn")
        return Int(value)
    }
    func performanceMode(_ parameter: SynthParameter) -> Int {
        Int(values[Int(parameter == .arpMode ? kOberVaveArpSelection : kOberVaveLatchSelection)])
    }
    func selectPerformanceMode(_ parameter: SynthParameter, value: Int) {
        set(UInt32(parameter == .arpMode ? kOberVaveArpSelection : kOberVaveLatchSelection), Float(value))
        refresh()
    }
    func togglePerformance(_ parameter: SynthParameter) {
        setParameter(parameter, value: parameterValue(parameter) == 0 ? performanceMode(parameter) : 0)
    }
    func setMasterLevelDB(_ value: Double) { set(masterID, value <= -48 ? 0 : Float(pow(10, value / 20))) }
    func setMasterPan(_ value: Double) { set(panID, Float(value)) }
    func setArpSyncEnabled(_ value: Bool) { set(syncID, value ? 1 : 0) }
    func setArpSyncGrid(_ value: Int) { set(gridID, Float(value)) }
    func selectProgram(_ index: Int) { set(programID, Float(index)); refresh() }
    func noteOn(_ note: UInt32) { midi(0x90, note, 100) }
    func noteOff(_ note: UInt32) { midi(0x80, note, 0) }
    func setPitchBend(_ value: Int) { let bend = UInt32(value + 8192); midi(0xE0, bend & 127, bend >> 7) }
    func setModWheel(_ value: Int) { midi(0xB0, 1, UInt32(value)) }
    func panic() {
        var value: UInt32 = 1
        report(AudioUnitSetProperty(unit, UInt32(kOberVavePanic), kAudioUnitScope_Global,
                                   0, &value, UInt32(MemoryLayout.size(ofValue: value))), "Panic")
    }
    func editParameter(_ parameter: SynthParameter, editing: Bool) {
        edit(parameter.audioUnitID, editing: editing)
    }
    func editOutput(pan: Bool, editing: Bool) { edit(pan ? panID : masterID, editing: editing) }
    private func edit(_ id: AudioUnitParameterID, editing: Bool) {
        let parameter = AudioUnitParameter(mAudioUnit: unit, mParameterID: id,
            mScope: kAudioUnitScope_Global, mElement: 0)
        if editing {
            if gestures.insert(id).inserted { notify(.beginParameterChangeGesture, parameter) }
        } else if gestures.remove(id) != nil { notify(.endParameterChangeGesture, parameter) }
    }

    func report(_ status: OSStatus, _ action: String) {
        if status != noErr { errorMessage = "\(action) failed (\(status))." }
    }
    func refresh() {
        var next = values
        for id in next.indices {
            let status = AudioUnitGetParameter(unit, UInt32(id), kAudioUnitScope_Global, 0, &next[id])
            if status != noErr { report(status, "Read parameter"); return }
        }
        if next != values { values = next }
    }
    private func notify(_ type: AudioUnitEventType, _ parameter: AudioUnitParameter) {
        var event = AudioUnitEvent()
        event.mEventType = type
        event.mArgument.mParameter = parameter
        report(AUEventListenerNotify(nil, nil, &event), "Notify host")
    }
    private func set(_ id: AudioUnitParameterID, _ value: Float) {
        let parameter = AudioUnitParameter(mAudioUnit: unit, mParameterID: id,
            mScope: kAudioUnitScope_Global, mElement: 0)
        let discrete = !gestures.contains(id)
        if discrete { notify(.beginParameterChangeGesture, parameter) }
        let status = AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
        report(status, "Set parameter")
        if status == noErr {
            values[Int(id)] = value
            notify(.parameterValueChange, parameter)
        }
        if discrete { notify(.endParameterChangeGesture, parameter) }
    }
    private func midi(_ status: UInt32, _ d1: UInt32, _ d2: UInt32) {
        var event = OberVaveKeyboardEvent(status: status, data1: d1, data2: d2)
        report(AudioUnitSetProperty(unit, UInt32(kOberVaveKeyboard), kAudioUnitScope_Global,
            0, &event, UInt32(MemoryLayout.size(ofValue: event))), "Play keyboard")
    }
    func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "aupreset") ?? .propertyList]
        panel.nameFieldStringValue = "OberVave.aupreset"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var state: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout.size(ofValue: state))
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo,
            kAudioUnitScope_Global, 0, &state, &size)
        report(status, "Read preset")
        guard status == noErr, let state else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: state.takeRetainedValue(),
                format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = "Save preset: \(error.localizedDescription)" }
    }
    func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "aupreset") ?? .propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let state = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            var property = Unmanaged.passRetained(state as CFPropertyList)
            defer { property.release() }
            let status = AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &property, UInt32(MemoryLayout.size(ofValue: property)))
            report(status, "Load preset")
            if status == noErr { refresh() }
        } catch { errorMessage = "Load preset: \(error.localizedDescription)" }
    }
}

@MainActor
final class OutputMeterModel: ObservableObject {
    @Published private(set) var left = 0.0
    @Published private(set) var right = 0.0
    @Published private(set) var voiceLevels = Array(repeating: 0.0, count: 8)
    @Published private(set) var tempo = 120
    @Published private(set) var hostClock = false
    func refresh(_ model: OberVaveModel) {
        var meter = OberVaveMeters()
        var size = UInt32(MemoryLayout.size(ofValue: meter))
        let status = AudioUnitGetProperty(model.unit, UInt32(kOberVaveMeters),
            kAudioUnitScope_Global, 0, &meter, &size)
        model.report(status, "Read meters")
        guard status == noErr else { return }
        left = max(Double(meter.left), left * 0.78)
        right = max(Double(meter.right), right * 0.78)
        voiceLevels = withUnsafeBytes(of: meter.voices) { Array($0.bindMemory(to: Float.self)).map(Double.init) }
        tempo = Int(meter.tempo.rounded())
        hostClock = meter.hostClock != 0
    }
}

@MainActor
struct OberVaveEditor: View {
    @StateObject private var model: OberVaveModel
    @StateObject private var meters = OutputMeterModel()
    @State private var screen = OberVaveScreen.main
    @State private var showsKeyboard = false
    init(unit: AudioUnit) { _model = StateObject(wrappedValue: OberVaveModel(unit: unit)) }
    var body: some View {
        VStack(spacing: 8) {
            header
            if screen == .modulation {
                SynthControlPanel.ModulationMatrixView(model: model)
            } else if screen == .controllers {
                ControllersView(model: model)
            } else {
                panels
            }
            HStack(spacing: 8) {
                ForEach(OberVaveScreen.allCases, id: \.self) { item in
                    Button { screen = item } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(screen == item ? Color.black : Color.white.opacity(0.75))
                            .background(screen == item ? Color.cyan : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).accessibilityLabel(item.title)
                }
            }.padding(.horizontal, 12).padding(.bottom, 6)
            if showsKeyboard {
                TouchKeyboardView(model: model, onClose: { showsKeyboard = false })
                    .frame(height: 320)
            }
        }
        .padding(.top, 10)
        .frame(minWidth: 1100, minHeight: 760)
        .background(Color(red: 0.055, green: 0.075, blue: 0.11))
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()) { _ in
            model.refresh()
            meters.refresh(model)
        }
        .alert("OberVave", isPresented: Binding(get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("OB-1").font(.system(size: 24, weight: .black, design: .rounded)).tracking(2)
                Text("OBERVAVE · NATIVE AU")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(1.2).foregroundStyle(.cyan)
            }
            Button { model.selectProgram(max(0, model.program - 1)) } label: {
                Image(systemName: "chevron.left")
            }.accessibilityLabel("Previous program")
            Picker("FACTORY", selection: Binding(get: { model.program }, set: { model.selectProgram($0) })) {
                ForEach(Array(model.programNames.enumerated()), id: \.offset) { index, name in
                    Text(String(format: "%02d  %@", index + 1, name)).tag(index)
                }
            }.labelsHidden().frame(width: 220).accessibilityLabel("Factory program")
            Button { model.selectProgram(min(model.programNames.count - 1, model.program + 1)) } label: {
                Image(systemName: "chevron.right")
            }.accessibilityLabel("Next program")
            Spacer(minLength: 0)
            Button(action: model.savePreset) { Label("SAVE", systemImage: "square.and.arrow.down") }
            Button(action: model.loadPreset) { Label("LOAD", systemImage: "folder") }
            Button(action: model.panic) { Text("PANIC") }
            Button { showsKeyboard.toggle() } label: { Image(systemName: "pianokeys") }
                .accessibilityLabel("On-screen keyboard")
            VStack(spacing: 1) {
                Text("\(meters.tempo)").font(.system(size: 15, weight: .bold, design: .monospaced))
                Text(meters.hostClock ? "HOST BPM" : "BPM")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
            }.foregroundStyle(.cyan).frame(width: 65)
        }
        .buttonStyle(.bordered)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12).frame(height: 62)
    }
    private var sections: [SynthControlSection] {
        switch screen {
        case .main: SynthControlLayouts.ob1
        case .more: SynthControlLayouts.extensions
        case .effects: SynthControlLayouts.effects
        case .modulation: []
        case .controllers: []
        }
    }
    private var panels: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 24
            let count = screen == .main ? 5 : 3
            let cellWidth = (width - CGFloat(count - 1) * 12) / CGFloat(count)
            let items = (screen == .main ? [ControlPanelItem.amp] : []) + sections.map(ControlPanelItem.section)
            let rows = stride(from: 0, to: items.count, by: count).map {
                Array(items[$0..<min($0 + count, items.count)])
            }
            VStack(spacing: 10) {
                HStack {
                    Rectangle().fill(Color.cyan).frame(width: 4)
                    Text(screen == .main ? "ANALOG POLYSYNTH" : screen == .more ? "OBERVAVE EXTENSIONS" : "EFFECTS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                    Spacer()
                    Text("PATCH \(String(format: "%02d", model.program + 1))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }.frame(height: 18)
                ScrollView {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(row) { item in
                                    panel(item).frame(width: cellWidth).frame(minHeight: 265)
                                }
                            }
                        }
                    }.frame(width: width, alignment: .topLeading).padding(.bottom, 8)
                }
            }.padding(.horizontal, 12)
        }
    }
    @ViewBuilder private func panel(_ item: ControlPanelItem) -> some View {
        switch item {
        case .amp: SynthMasterOutputPanel(model: model, meters: meters)
        case .section(let section): SynthControlPanel(section: section, model: model)
        }
    }
}

@_cdecl("OberVaveCreateView")
@MainActor
func createOberVaveView(_ unit: AudioUnit) -> UnsafeMutableRawPointer {
    let view = NSHostingView(rootView: OberVaveEditor(unit: unit))
    view.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
    view.autoresizingMask = [.width, .height]
    return Unmanaged.passRetained(view).toOpaque()
}
