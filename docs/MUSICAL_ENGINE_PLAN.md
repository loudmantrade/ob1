# Musical engine implementation plan

Specification: [development requirements](../.ai/to-do.MD).
Baseline: `master` at `ca75825`; implementation branch: `feat/musical-event-engine`.

## Verified current architecture

- The standalone target is iOS/iPadOS 16+, C++17 and Swift 5. The native AUv2
  target is macOS 13+. The standalone application owns a 16-slot rack; the AU
  owns one `obervave::Engine`, not a rack. Both synthesize at 44,100 Hz with
  16-sample control blocks. The AU resamples to the host rate.
- `ios/OberVave/SynthRack.cpp` owns `SynthEngine`, its factory, instruments,
  channel/split/layer routing, a shared `Clock`, and rendering. Logical slots
  and MIDI channels are different: several slots can share a channel.
- UI and MIDI producers submit to the existing 4,096-command bounded queue.
  Producer locking is outside rendering. The audio consumer never acquires
  that mutex. Scheduled commands use a separate fixed array, stable insertion
  by 32-bit frame deadline, and wrap-aware comparisons. MIDI is applied at
  control boundaries. Existing mixed command FIFO ordering is significant for
  parameter edits, scene snapshots and routing changes; do not replace it.
- Instruments/scenes are constructed off the audio thread, swapped by commands,
  and retired through the existing list for main-thread collection. Keep this
  ownership model for future immutable pattern snapshots.
- The standalone clock follows filtered MIDI Clock or internal 40-240 BPM.
  Its quarter length is rounded to a multiple of 48 frames to preserve legacy
  division behavior. Start/Continue establish clock phase; Stop clears notes
  and queued events, not ARP/Latch settings. Silence in MIDI Clock eventually
  falls back to the last tempo. The AU instead uses host beat/tempo/transport
  callbacks and its own fixed-capacity MIDI queue. Do not introduce a second
  free-running sequencer clock.
- CoreMIDI input and the custom BLE parser enter the rack through the existing
  C MIDI APIs. Timestamps are converted to frame deadlines with configurable
  lookahead. CoreMIDI and BLE connections now receive distinct non-reused
  runtime IDs; CoreMIDI connection context selects independent byte-parser
  state. The command queue preserves these IDs. Disconnect currently closes
  ingress, not queued/sounding notes; audio-owner cleanup with captured rack
  destinations is still pending. External MIDI output and endpoint-level
  feedback protection are not implemented.
- Keyboard Note On captures its channel mask; Note Off uses the captured
  channels rather than the current selection. SwiftUI `KeyboardLockState`
  retains locked note/channel pairs. Source identity survives `rack::send`;
  complete source-aware captured routing must preserve Key-Lock gestures and
  controller timing.
- `native/OberVave/Engine.h` wraps the vendored DSP per instance, handles raw
  controllers, signed temporary modulation and latency compensation.
  Controller routes can change effective ARP/Latch settings while sounding;
  extraction must consume effective settings, not merely UI snapshots.
- `fw/obervave/firmware/src/obv_engine.h` owns held notes (16 per part), sustain,
  latch and the legacy arpeggiator. Its modes are Off=0, Up=1, Down=2,
  Up/Down=3, Random=4, Played=5, Chord=6, Hold Retrigger=7, Hold Legato=8.
  First-note grid, running phase compensation, gate releases, chord replacement
  and Hold Legato differences must be compared, not reconstructed from labels.
  `arp_post` is an existing 64-event recording queue, but currently drops on
  overflow and is not a sufficient final recording bus. Generated events are
  emitted at direct voice trigger/release sites. Preserve that as the reference.
- Voice allocation, mono/unison behavior, envelopes, oscillators and effects
  remain inside DSP. A new external-arpeggiator mode must bypass both internal
  note interception and scheduling without overwriting saved ARP parameters.
- Scene JSON is version 1 with strict validation and atomic writing after a
  model-owned audio snapshot monitor. Sound arrays now have 202 entries; known
  65/90-entry files migrate explicitly. AU IDs 0-208 are published and must stay
  stable. Patterns/routing will be additive versioned fields; unsupported data
  must fail validation before current playback is replaced.

## Incremental delivery and gates

Each numbered increment is separately implemented, tested and committed.
Before starting the next increment, verify the previous commit and a clean
working tree. Do not merge or push feature work without an explicit request.

### A. Preparation and event boundary

1. Commit the user specification and this evidence-based plan. Baseline:
   all five current CTest suites pass on the Intel development Mac.
2. Introduce a dependency-free C++17 event representation and portable tests:
   MIDI validation/normalization, source and routing context, note ownership
   identifiers, integer musical ticks, absolute frames and explicit block
   offsets. Preserve received FIFO order. Define generated same-time ordering
   separately so live Hold input is not silently reordered.
3. Introduce routing infrastructure at the existing rack boundary. Retain the
   command queue, channel/zone/layer behavior, controller routing and captured
   keyboard destinations. Test explicit instrument targeting, note ownership
   and cleanup without changing the synth algorithm. Integrate only verified
   behavior; do not expose unfinished sequencer/output features in the UI.

### B. Extracted arpeggiator

4. Implement a bounded, engine-independent processor using explicit settings
   and the shared timeline. Retain the legacy implementation as the oracle.
   Compare emitted On/Off traces, including velocity and exact legacy
   control-boundary timestamps, all modes/divisions/grids, sustain/latch
   transitions, randomized seeds, rapid mode changes and latency changes.
5. Add a reversible external-event bypass to the native engine, with saved
   parameters untouched. Compare audio and voice behavior with the legacy path.
   Switch standalone processing only after parity; preserve current AU until
   its independent adapter is validated.

### C. Patterns and recording

6. Add a validated, bounded pattern model: integer PPQ ticks (960 per quarter),
   stable note IDs, original timing plus optional quantization, length/loop,
   velocity and explicit logical destination context.
7. Add audio-thread playback with absolute timeline conversion, no accumulated
   rounded-interval drift, exact event offsets and explicit arp bypass for
   recorded output. Keep the 16-sample DSP limitation explicit.
8. Add input/output recording with matching ownership. Capture actual emitted
   releases (including early replacement/Stop), not planned gate times.
   Finalize open notes on stop/loop/recording termination. Reject overflow
   explicitly and release owned notes safely.
9. Add backwards-compatible scene/pattern persistence and snapshot replacement;
   validate on the control thread, swap at a boundary, retire off-thread.

### D. External MIDI

10. Add CoreMIDI destination discovery and a bounded timestamped output backend,
    plus a mock destination for portable tests. Platform sends must not add
    unbounded work to DSP.
11. Add Internal/External/Both/Disabled routing and destination/channel state.
    Preserve the destination of every emitted Note On for its Note Off across
    disconnect, channel edits, transport and scene changes. Propagate source
    endpoint identity and prevent feedback; no implicit MIDI echo.

### E. User interface

12. Add pattern management, recording modes and routing controls using the
    existing navigation/visual language.
13. Implement Step Editor and Piano Roll against the same immutable note data.
    Safe live edits use existing command/snapshot discipline, not UI timers
    for musical scheduling. Preserve keyboard and synth controls.

### F. Stabilization

14. Cross-feature tests, AU host integration, scene migration, timestamp/loop/
    seek/tempo/Stop edge cases and physical endpoint checks.
15. Measure representative load on available hardware; report hardware, audio
    buffers, active voices/FX and scenarios. Never infer older-iPad performance
    or host MIDI-output support from a portable unit test.

## Validation and release discipline

- Existing macOS build: `NO_INSTALL=1 ARCH=x86_64 tools/build_obervave_au.sh`.
  Existing suites: `native_au`, `ipad_transport`, `ipad_rack`,
  `ipad_scene_files`, `editor`. The editor requires a graphical login.
- Add portable event tests to the existing CTest entry point, also runnable
  with an ordinary C++17 compiler without Apple frameworks.
- Small pure-core changes run their focused test first. Changes to live
  routing/engine boundaries additionally run all affected legacy suites and
  compile both the AU and signed iPad target. Do not install unfinished paths.
- Use the existing iPad `xcodebuild` command and existing AU validator where
  applicable. Physical MIDI and actual host-output checks are separate from
  mocked tests. Report all unverified scenarios explicitly.
- New processing uses bounded storage; no allocation, deallocation, blocking,
  file operations or UI work on the audio thread. State publication and queue
  overflow have explicit failure/cleanup behavior. Continuous parameter
  changes remain prompt; structural swaps must not debounce sound editing.
- At each increment record its scope, test results and commit SHA in the
  progress report. Final delivery includes the chronological commit list,
  format/routing documentation, measured performance and remaining limitations.

## Current delivery status

Baseline inspection, the portable event representation/tests and the first
standalone event-routing boundary are complete. See
[the event contract and integration limits](MUSICAL_EVENTS.md). Source context
now survives the existing queue and logical destination selection is explicit.
Standalone source-owned captured note routing and ordered disconnect cleanup
are enabled; output-stage routing is not yet enabled. The independent
[arpeggiator core](ARPEGGIATOR.md) and legacy event-comparison tests are
implemented; production still uses the original DSP arpeggiator.
The reversible native DSP bypass is implemented and compared against the
legacy audio/voice path; it is disabled by default and not enabled by either
platform adapter. An optional control-boundary callback and effective
ARP/clock snapshot bridge are implemented and audio-tested with temporary
controller modulation and per-instance RNG synchronization. The experimental
native MIDI adapter now preserves input-time/render-time settings, sequential
VALUE/MOD controller handling, logical Sustain/OVERRIDE, direct/generated
handovers, pressure, restart, Panic and Stop/rearm in legacy audio comparisons.
Its direct Off-mode entry uses the portable held list for Mono/Unison fallback.
Neither platform instantiates it yet. The adapter now publishes accepted
generated output to an optional synchronous receiver with a pinned logical
instrument/channel, explicit processor-lifetime source ID and matching note
IDs. Receiver rejection retains outstanding ownership for Stop retries and
faults/releases local DSP gates. Rack/key-lock/scene integration and the
independent AU remain production gates.
An opt-in bounded physical-input ownership ledger now isolates same-pitch
source/channel/note IDs, retains the final owner and supports captured source
release and explicit overflow/rejection cleanup. Standalone connection IDs
and independent ingress parsers are wired through the existing queue.
The live standalone rack now enables this ledger independently of the new
arpeggiator adapter: channel/zone edits preserve held notes, final-owner Off
uses the captured instrument, disconnect cancels that source's scheduled MIDI
and releases its captured keys/pedals without stopping other sources.
Sustain aggregates independent pedals and survives routing edits; intentional
Latch is retained on physical-source release. Slot/scene/program replacement
clears instance-local ownership. Capacity and queue failure use visible
error/Panic cleanup. Actual-rack regressions cover all nine ARP modes,
same-pitch sources/channels, route edits, scheduled cancellation, replacement
and overflow. Neither platform enables the new adapter yet. Pattern playback/recording,
pattern UI and external MIDI output are not yet implemented.
