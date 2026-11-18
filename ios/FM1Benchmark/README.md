# FM-1 iOS benchmark

This is a temporary native iOS benchmark for measuring the emulator on a physical device. It is
not a playable instrument: it renders 128-frame, 44.1 kHz blocks without sending them to audio
output. The firmware and scheduled input match the browser benchmark workload. Native AArch64 JIT
can be selected in the test settings; on iOS 17.4 and later it uses Apple's `MAP_JIT` mapping and
callback-based write-protection API. On older iOS versions or if the protected code cache cannot be
initialized, the emulator continues with the interpreter and the exported metrics report that no
native JIT code cache was active. The interpreter batches clock ticks across CPU-only micro-ops and
flushes them before bus accesses or scheduled events.

## Run on an iPad

1. Open `FM1Benchmark.xcodeproj` in Xcode and select the `FM1Benchmark` target.
2. In **Signing & Capabilities**, choose a team for automatic signing. A personal Apple ID team is
   sufficient for local device testing.
3. Select the connected iPad as the run destination and build/run.
4. Transfer a `.fwsc` package to the iPad's Files app (for example with AirDrop), choose it in the
   benchmark, configure the test, and run it.

## Configure and export a test

The app remembers the test settings between launches:

- CPU clock: 1–240 MHz.
- Measurement duration: 1–60 seconds, after warm-up.
- Warm-up: 0–60 seconds, added before the measurement duration. Warm-up blocks are excluded from
  render-time, frame, and short-block metrics. For example, a 6-second warm-up plus a 6-second
  measurement runs for about 12 emulated seconds and collects metrics during the last 6 seconds.
- Render block: 32, 64, 128, 256, 512, or 1024 frames. At 44.1 kHz, the deadline is
  `frames / 44100` seconds (128 frames is about 2.90 ms).
- Native JIT: on by default. The results include whether its code cache was initialized and how
  many blocks were compiled; compare JIT and interpreter runs with otherwise identical settings.
- Input scenario: comma-separated scheduled events, with time in milliseconds from boot. Supported
  forms are `ms:keyId` (press), `ms:keyId^` (release), `ms:keyId@velocity` (press with velocity),
  `ms:keyId~velocity` (pressure), and `ms:mHEX` (raw MIDI bytes, e.g. `800:m903c64`). Encoder and
  analog events are also supported: `ms:eN:clicks`, `ms:aN:value`, and `ms:pot:value`. Key and
  channel IDs are numeric. Events must fit within warm-up plus measurement duration. Leave the
  field empty to run without scripted input.

The defaults use 120 MHz, six seconds of measurement after a one-second warm-up, 128-frame blocks,
and `800:21,900:25,1000:28`. Scenario event times are relative to boot, so events during warm-up
can establish a steady workload for the measurement period.

After a successful run, use **Export metrics JSON…** and choose a destination in Files or share the
file. The JSON contains the firmware name and SHA-256, device and OS details, processor count,
thermal and Low Power Mode state, full test configuration, summary metrics for the measurement
period, and the per-block render times in microseconds. The summary reports measured real-time
speed, returned frames, short blocks, blocks exceeding the chosen deadline, and steady-state
p95/p99/max render durations.

## Initial iPad 7 result

On an iPad (7th generation, iOS 18.5), the native interpreter benchmark with OberVave 3.5.2 gave:

| Clock | Speed | Short blocks | Blocks over 2.90 ms | Steady render p95 / p99 / max |
|---|---:|---:|---:|---:|
| 120 MHz | 0.84x | 11 | 1,431 | 4,664 / 4,927 / 5,754 µs |
| 240 MHz | 0.47x | 5 | 1,441 | 9,338 / 10,055 / 20,184 µs |

Safari on the same iPad reported 0.7–0.9x at 120 MHz with a one-voice patch. These are not
strictly equivalent workloads: this native test uses its fixed three-key sequence, while Safari
was tested with the user's patch. Both paths were below real time at 120 MHz.
