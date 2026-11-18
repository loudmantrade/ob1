import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CryptoKit

private let defaultScenario = "800:21,900:25,1000:28"
private let supportedQuanta = [32, 64, 128, 256, 512, 1024]

private struct BenchmarkConfiguration: Codable {
    let clockMHz: Int
    let durationSeconds: Int
    let warmupMilliseconds: Int
    let quantumFrames: Int
    let nativeJit: Bool
    let scenario: String
}

private struct BenchmarkMetrics: Codable {
    let speedRealtime: Double
    let emulatedMilliseconds: UInt32
    let wallMilliseconds: UInt32
    let audioFrames: UInt64
    let shortBlocks: UInt32
    let blocksOverDeadline: UInt32
    let deadlineMicroseconds: UInt32
    let p95Microseconds: UInt32
    let p99Microseconds: UInt32
    let maxMicroseconds: UInt32
    let renderTimesMicroseconds: [UInt32]
    let nativeJitActive: Bool
    let nativeJitCompiledBlocks: UInt32
}

private struct BenchmarkRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let firmware: String
    let firmwareSHA256: String
    let device: String
    let operatingSystem: String
    let activeProcessorCount: Int
    let thermalStateBefore: String
    let thermalStateAfter: String
    let lowPowerModeEnabled: Bool
    let configuration: BenchmarkConfiguration
    let metrics: BenchmarkMetrics
}

private struct MetricsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ContentView: View {
    @AppStorage("benchClockMHz") private var clockMHz = 120
    @AppStorage("benchDurationSeconds") private var durationSeconds = 6
    @AppStorage("benchWarmupMilliseconds") private var warmupMilliseconds = 1_000
    @AppStorage("benchQuantumFrames") private var quantumFrames = 128
    @AppStorage("benchNativeJit") private var nativeJit = true
    @AppStorage("benchScenario") private var scenario = defaultScenario

    @State private var firmware: Data?
    @State private var firmwareName = "No firmware selected"
    @State private var importing = false
    @State private var running = false
    @State private var exporting = false
    @State private var exportDocument: MetricsDocument?
    @State private var exportName = "fm1-benchmark"
    @State private var record: BenchmarkRecord?
    @State private var result = "Choose a .fwsc firmware package to begin."
    @State private var errorMessage: String?

    private var validConfiguration: Bool {
        (1...240).contains(clockMHz)
            && (1...60).contains(durationSeconds)
            && (0...60_000).contains(warmupMilliseconds)
            && supportedQuanta.contains(quantumFrames)
            && scenario.utf8.count <= 4_096
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Firmware") {
                    Button("Choose .fwsc…") {
                        importing = true
                    }
                    Text(firmwareName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Test configuration") {
                    HStack {
                        Text("CPU clock")
                        Spacer()
                        TextField("MHz", value: $clockMHz, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("MHz")
                            .foregroundStyle(.secondary)
                    }

                    Stepper("Measurement duration: \(durationSeconds) seconds", value: $durationSeconds, in: 1...60)

                    Stepper(
                        "Warm-up: \(String(format: "%.2f", Double(warmupMilliseconds) / 1_000)) seconds",
                        value: $warmupMilliseconds,
                        in: 0...60_000,
                        step: 250
                    )

                    Picker("Render block", selection: $quantumFrames) {
                        ForEach(supportedQuanta, id: \.self) { frames in
                            Text("\(frames) frames").tag(frames)
                        }
                    }

                    Toggle("Enable native JIT", isOn: $nativeJit)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Input scenario")
                        TextField("800:21,900:21^", text: $scenario, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(2...5)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Events: ms:keyId to press, ms:keyId^ to release, ms:keyId@velocity, or ms:m903c64 for MIDI bytes. Separate events with commas; leave empty for no input.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(running ? "Testing…" : "Run benchmark") {
                        runBenchmark()
                    }
                    .disabled(running || firmware == nil || !validConfiguration)

                    if !validConfiguration {
                        Text("Use 1–240 MHz, a measurement duration of 1–60 seconds, and a warm-up of up to 60 seconds.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Result") {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    if record != nil {
                        Button("Export metrics JSON…", systemImage: "square.and.arrow.up") {
                            prepareExport()
                        }
                        .disabled(running)
                    }
                }

                Section {
                    Text("The test renders audio blocks without sending them to audio output. Native JIT uses Apple's protected MAP_JIT write callback API (iOS 17.4 and later); if it is unavailable, the emulator stays on the interpreter and the result reports that no native code cache was initialized.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("FM-1 iOS Benchmark")
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [UTType(filenameExtension: "fwsc") ?? .data],
                allowsMultipleSelection: false,
                onCompletion: importFirmware
            )
            .fileExporter(
                isPresented: $exporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: exportName,
                onCompletion: { outcome in
                    if case let .failure(error) = outcome {
                        errorMessage = error.localizedDescription
                    }
                }
            )
            .alert("Benchmark failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func importFirmware(_ outcome: Result<[URL], Error>) {
        do {
            guard let url = try outcome.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            firmware = try Data(contentsOf: url)
            firmwareName = url.lastPathComponent
            record = nil
            result = "Ready. Configure the test and run it."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runBenchmark() {
        guard let firmware, validConfiguration else { return }
        running = true
        record = nil
        result = "Running…"
        let configuration = BenchmarkConfiguration(
            clockMHz: clockMHz,
            durationSeconds: durationSeconds,
            warmupMilliseconds: warmupMilliseconds,
            quantumFrames: quantumFrames,
            nativeJit: nativeJit,
            scenario: scenario
        )
        let maxSamples = (durationSeconds * 1_000 * 44_100 + quantumFrames * 1_000 - 1)
            / (quantumFrames * 1_000) + 2
        let inputScenario = Data(scenario.utf8)
        let device = UIDevice.current.model
        let operatingSystem = UIDevice.current.systemVersion
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let thermalBefore = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        let lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        DispatchQueue.global(qos: .userInitiated).async {
            let firmwareHash = SHA256.hash(data: firmware)
                .map { String(format: "%02x", $0) }
                .joined()
            var sampleTimes = [UInt32](repeating: 0, count: maxSamples)
            let benchmark = firmware.withUnsafeBytes { packageBytes in
                inputScenario.withUnsafeBytes { scriptBytes in
                    sampleTimes.withUnsafeMutableBufferPointer { samples in
                        guard let packageBase = packageBytes.bindMemory(to: UInt8.self).baseAddress,
                              let sampleBase = samples.baseAddress,
                              packageBytes.count <= Int(UInt32.max),
                              scriptBytes.count <= Int(UInt32.max) else {
                            return fm1_ios_bench(nil, 0, 0, 0, 0, 0, 0, nil, 0, nil, 0)
                        }
                        return fm1_ios_bench(
                            packageBase,
                            UInt32(packageBytes.count),
                            UInt32(configuration.clockMHz),
                            UInt32(configuration.durationSeconds),
                            UInt32(configuration.warmupMilliseconds),
                            UInt32(configuration.quantumFrames),
                            configuration.nativeJit ? 1 : 0,
                            scriptBytes.bindMemory(to: UInt8.self).baseAddress,
                            UInt32(scriptBytes.count),
                            sampleBase,
                            UInt32(samples.count)
                        )
                    }
                }
            }

            let samples = Array(sampleTimes.prefix(Int(benchmark.sample_count)))
            DispatchQueue.main.async {
                running = false
                guard benchmark.status == 0 else {
                    errorMessage = Self.message(for: benchmark.status)
                    result = "Benchmark failed."
                    return
                }
                guard benchmark.sample_count == samples.count else {
                    errorMessage = "The benchmark returned an invalid metrics sample count."
                    result = "Benchmark failed."
                    return
                }
                let metrics = BenchmarkMetrics(
                    speedRealtime: Double(benchmark.speed_milli_x) / 1_000,
                    emulatedMilliseconds: benchmark.emulated_ms,
                    wallMilliseconds: benchmark.wall_ms,
                    audioFrames: benchmark.audio_frames,
                    shortBlocks: benchmark.short_quanta,
                    blocksOverDeadline: benchmark.over_deadline,
                    deadlineMicroseconds: benchmark.deadline_us,
                    p95Microseconds: benchmark.p95_us,
                    p99Microseconds: benchmark.p99_us,
                    maxMicroseconds: benchmark.max_us,
                    renderTimesMicroseconds: samples,
                    nativeJitActive: benchmark.native_jit_active != 0,
                    nativeJitCompiledBlocks: benchmark.native_jit_compiled_blocks
                )
                record = BenchmarkRecord(
                    id: UUID(),
                    timestamp: Date(),
                    firmware: firmwareName,
                    firmwareSHA256: firmwareHash,
                    device: device,
                    operatingSystem: operatingSystem,
                    activeProcessorCount: processorCount,
                    thermalStateBefore: thermalBefore,
                    thermalStateAfter: Self.thermalStateName(ProcessInfo.processInfo.thermalState),
                    lowPowerModeEnabled: lowPowerModeEnabled,
                    configuration: configuration,
                    metrics: metrics
                )
                result = Self.summary(metrics, configuration: configuration)
            }
        }
    }

    private func prepareExport() {
        guard let record else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            exportDocument = MetricsDocument(data: try encoder.encode(record))
            exportName = "fm1-benchmark-\(Int(record.timestamp.timeIntervalSince1970))"
            exporting = true
        } catch {
            errorMessage = "Could not encode the benchmark metrics: \(error.localizedDescription)"
        }
    }

    private static func summary(_ metrics: BenchmarkMetrics, configuration: BenchmarkConfiguration) -> String {
        let jitStatus = !configuration.nativeJit
            ? "off"
            : metrics.nativeJitActive ? "active" : "unavailable; interpreter fallback"
        return """
        Speed: \(String(format: "%.2fx", metrics.speedRealtime))
        Clock / duration / warm-up: \(configuration.clockMHz) MHz / \(configuration.durationSeconds) s / \(String(format: "%.2f", Double(configuration.warmupMilliseconds) / 1_000)) s
        Block: \(configuration.quantumFrames) frames (\(String(format: "%.2f", Double(metrics.deadlineMicroseconds) / 1_000)) ms deadline)
        Measured emulation: \(metrics.emulatedMilliseconds) ms in \(metrics.wallMilliseconds) ms
        Native JIT: \(jitStatus); compiled blocks: \(metrics.nativeJitCompiledBlocks)
        Frames returned: \(metrics.audioFrames)
        Short blocks: \(metrics.shortBlocks)
        Blocks over deadline: \(metrics.blocksOverDeadline)
        Measured block durations: \(metrics.renderTimesMicroseconds.count)
        Steady render p95 / p99 / max: \(metrics.p95Microseconds) / \(metrics.p99Microseconds) / \(metrics.maxMicroseconds) µs
        """
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func message(for status: UInt32) -> String {
        switch status {
        case 1: "The firmware package could not be loaded."
        case 2: "The emulated machine halted."
        case 3: "The emulator stopped making progress."
        case 4: "The benchmark timed out."
        case 5: "Invalid configuration or input scenario. Check event syntax and ensure all event times are within warm-up plus measurement duration."
        default: "The emulator trapped while running the benchmark."
        }
    }
}
