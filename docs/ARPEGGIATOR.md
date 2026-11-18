# Shared arpeggiator: extraction and compatibility gate

`native/Musical/Arpeggiator.h` contains a bounded C++17
`ArpeggiatorProcessor`, derived from the existing GPL-3.0-only OberVave
arpeggiator. It does not include DSP headers, patch structures, voices, platform
APIs or SwiftUI. The standalone iPad rack now uses it for production; the AU
retains its independently validated original scheduler. Native-only guards
allow an explicit external-note bypass; it is enabled by the standalone
adapter and does not change the hardware firmware build.

## Contract

- Settings retain the existing serialized mode values: Off 0, Up 1, Down 2,
  Up/Down 3, Random 4, Played 5, Chord 6, Hold Retrigger 7, Hold Legato 8.
  Latch values remain Off 0, Add 1 and Replace 2. Division indexes retain
  their quarter-note divisors (1, 2, 3, 4, 6, 8, 12). Octave 0 follows the
  existing clamp to one octave; 1-4 expand as before.
- `configure`, `input`, `tick` and `stop` run on the processing owner thread.
  They return explicit errors; no allocation, locks, worker thread, file I/O,
  UI timer or unbounded queue is used. A caller supplies a synchronous sink
  returning whether it accepted each output event.
- There are 16 held-key entries with the original oldest-key eviction and
  repeat-pitch replacement semantics. Chord generation deduplicates octave
  overlaps and skips notes beyond 127; single-note modes clamp at 127.
  Output is bounded by the MIDI pitch space.
- Output events have pinned logical instrument routing, the arpeggiator source,
  output stage, caller-provided time and nonzero generated note IDs. A matching
  Off carries the same ID. Hold Legato retains IDs of common notes and sends
  only removed-note Offs/new-note Ons. Destination/channel changes require
  an empty held/output state.
- The legacy same-pitch held-key semantics are intentionally retained here.
  This is not yet a replacement for the future multi-source ownership router.
  Generated IDs are unique within a processor lifetime; processor/source
  lifetime identity must also be retained by routing during replacement.
- `ArpClock` is a view of the existing transport, not another clock. It supplies
  quarter length, compensated master bar phase, absolute event time and the
  existing signed latency adjustment. Tick cadence is explicitly 16 frames.
  First-note grid and running-phase compensation reproduce the native engine.
  Tempo/phase conversion and host-buffer offsets stay in the platform adapter.
  This extraction does not claim sub-control-block sample accuracy.
- The sink receives actual releases on gate, chord membership, mode changes,
  sustain release, Latch Off and Stop, not planned future gate deadlines.
  Successful events can therefore feed a later recorder directly.
- A rejected output latches an error and prevents further musical processing.
  Accepted Note Ons remain tracked. `stop` retries all outstanding Offs,
  retaining only those still rejected, so a failed sink cannot silently erase
  ownership. The integrating router must report the error and use its panic/
  destination-cleanup path. Invalid arguments leave the previous settings
  unchanged. Zero random seeds and invalid clocks are rejected.
- Start/Continue/Clock are passed back as `Bypassed`: the existing transport
  interprets them. They cannot recreate held notes cleared by Stop. Pedal input
  is an already-interpreted logical CC64 state; standalone polarity/hysteresis
  and controller OVERRIDE must remain ahead of this processor.

## Deliberate integration boundary

Off-mode notes update held-key state and return `Bypassed`; the caller must
deliver those notes through normal synth handling. The processor does not own
direct (non-arpeggiated) voices. Enabling ARP must release/hand over those voices
in the adapter, matching legacy `voices_release_part`, without emitting spurious
arpeggiated notes into a recorder.

`lastHeld(pitch)` exposes the most recent remaining held key without exposing
mutable storage. It includes Sustain-retained keys and follows repeat-pitch
replacement and bounded oldest-key eviction. It returns `false` without
changing `pitch` when empty. This is a pitch-order view, not source ownership.

The original random generator is shared with DSP LFO state. The portable
processor has its own explicit seed; reference tests inject the original state
at each tick to compare exactly. Live extraction must choose and test the
compatibility bridge rather than claiming identical random sequences when DSP
random consumption differs.

The native engine has no active firmware sequencer (`seq_phase` and
`seq_starting` always return false). Those inactive firmware branches are not
reimplemented. Future pattern playback must use the shared transport and
explicit input/output stage flags, not resurrect that firmware sequencer.

The native adapter is connected at the standalone rack boundary, including
source-owned captured routes and local generated-output bypass. The AU's
independent adapter is still a separate integration gate.

## Explicit native DSP bypass

`Engine::set_external_arpeggiator(part, enabled)` is an audio-owner operation,
not a saved parameter. It releases that part's previous voices and clears its
legacy held/scheduler state and pending raw notes. Other parts' pending notes
retain FIFO order, including across ring-counter wrap. Repeating the current
setting is a no-op. Saved ARP/Latch values and effects are not overwritten.
Disabling restores normal legacy handling; initializing resets the mode.

While enabled, `external_note(part, pitch, velocity)` directly triggers a voice
or releases it (`velocity == 0`, with the generated-note release semantics).
It validates part, pitch, velocity and ownership mode and returns acceptance.
The caller owns musical note IDs, recording and generated-event ordering.
The old note interception, sustain-release cleanup and scheduler cannot
re-arpeggiate or release these notes. Panic/transport Stop still release voices,
without disabling the bypass. The normal `midi` entry rejects raw notes with
`false` in external mode; the rack adapter propagates this rejection.

This is a low-level DSP capability, not live extracted-ARP routing. Do not feed
generated notes through the raw MIDI entry.

### Direct notes while ARP is Off

`external_direct_note(part, pitch, velocity, hasHeld, lastHeld)` is a separate
entry for ordinary physical input with the external scheduler enabled and
the current part's ARP mode Off. It does not update a second DSP held-key list.
The caller first updates the portable processor's held state and supplies
`lastHeld` for release. Direct Note On clears that key's stale poly-pressure
state, just like fresh raw input; generated `external_note` does not.

Direct release reuses the same `voice_release_held` implementation as legacy
DSP input. In Mono/Unison the last remaining key resumes with the existing
glide/legato semantics instead of releasing the group or retriggering it.
Generated Note Off deliberately never uses this fallback.

The caller must interpret Sustain first: defer direct releases while held
by the pedal; on pedal release, remove unheld keys before delivering their
releases in original held-key order. This API does not independently implement
Sustain, controller OVERRIDE, recording, or input routing. Invalid arguments,
non-external ownership or an enabled ARP mode return `false` before mutation.
The adapter below uses this entry for production standalone direct/generated
handovers; AU input dispatch is still unchanged.

## Effective-patch control-boundary bridge

`Engine::render_audio_with_arpeggiator` optionally supplies a synchronous,
non-throwing callback and caller-owned context for that render call only.
Each externally owned part invokes it at the original `arp_tick` position:
after input processing and before LFO/global/voice processing. The effective
controller-modulated patch is already installed. No callback pointer/context
is retained after rendering. The ordinary `render_audio` entry remains the
legacy/manual-bypass path; neither platform enables this callback yet.

`native/OberVave/ArpeggiatorContext.h` maps the active part's effective patch,
sync/grid settings, quarter length, compensated master phase and signed
latency adjustment into portable `ArpSettings`/`ArpClock`. It rejects reads
outside rendering or for a part not in external mode. It does not own the
processor, notes, routing, or another clock.

The callback offset follows the existing DSP scheduler's `eng_t` convention:
it is 16 at the first tick, then 32, and so on. It is **not** a zero-based
output-buffer sample index. A caller supplies the corresponding 64-bit time
from its existing timeline; subtracting the render-start DSP counter remains
valid across 32-bit wrap. Future platform routing must explicitly translate
this legacy scheduler timestamp convention rather than pass a block-end
offset to `withinBlock`.

The test adapter reads effective settings, configures the portable processor,
seeds it from the same DSP instance's RNG immediately before ticking, and
writes back the resulting RNG state before LFO/voice synthesis. Generated
voice starts therefore use the same effective patch and RNG ordering as the
legacy scheduler, without reading randomness from a reference instance.

Callback rejection returns `false` from rendering, releases that part's voices,
and suppresses further callbacks for it in that render call. Other parts keep
processing; base parameters and callback lifetime are restored normally.
The caller must report failure and clean up its processor's outstanding
ownership before resuming; releasing DSP gates alone does not clear a
recorder or external destination's note ledger.

Input-time versus render-time settings, controller OVERRIDE, interpreted sustain
and direct/generated handovers belong to the adapter below, not this snapshot
helper. Standalone routing/ownership integration is described below.

## Native MIDI adapter

`native/OberVave/ArpeggiatorAdapter.h` combines one existing native `Engine`
(part 0) with one portable processor. The iPad rack instantiates it for each
instrument; the AU does not. The engine must be initialized before `attach`; attachment releases
old part-0 notes and refuses an engine already using any external-ARP owner.
The engine must outlive the adapter. There is no hot migration of already
held keys from an old scheduler or implicit ownership transfer on destruction.

After attachment, route all notes/controllers through `input`, sound and
controller-route edits through `parameter`, audio through `render`, and
transport stop through `stop`. Do not bypass these entry points to change
musical state. The caller still supplies the existing clock/host/latency
fields and an absolute render-start frame; render accepts positive multiples
of 16 up to `HALF_FRAMES`. It adds no queue, clock, allocation, or lock.
Neither it nor the DSP callback claims sample accuracy finer than 16 frames.
Start/Continue/Clock interpretation remains with the platform transport.

- Input uses the saved base patch, as legacy immediate MIDI did; rendering uses
  the effective temporary patch. The portable `settingsView` restores these
  views without mistaking each restoration for a user parameter change.
  Explicit `cleanupUnheld` and `restart` preserve the distinct legacy cleanup
  and restart operations. Generated note IDs survive temporary view changes.
- VALUE controller routes apply parameter edits sequentially in the existing
  slot order through a shared `controller_input_with_parameters` helper.
  MOD routes remain temporary. Pedal input is taken from the resulting logical
  DSP sustain state (including OVERRIDE and part HOLD), never from raw CC64
  values alone. Standalone pedal polarity/hysteresis remains upstream.
- Ordinary Off-mode notes use the direct entry with the portable held-key list.
  Pedal releases first remove unheld keys, then release removed pitches in
  held order with Mono/Unison fallback. Enabling ARP releases old direct voices
  at the same scheduler boundary as legacy. Chord/Hold modes and generated
  releases retain their original semantics. Fresh physical On resets pressure
  even with ARP enabled; generated On does not.
- The adapter processes interpreted controllers, optional legacy fixed CC
  mappings, Bend/Aftertouch, Reset Controllers, Panic, restart and Stop/rearm.
  Stop clears sounding/held notes but not saved mode/Latch parameters.
- Invalid events/parameters/render sizes return `false` before mutation.
  Processing failures latch `faulted`, release DSP voices and refuse further
  input/rendering. After the invalid engine state is corrected, explicit Stop
  clears processor ownership and permits recovery. The caller must surface
  these failures; this experimental class has no platform UI notification.

`attach(instrument, channel, sourceID, sink, context)` optionally connects a
synchronous generated-event receiver. Instrument/channel are validated and
pinned for the adapter lifetime; reattachment or destination replacement is
rejected even after Stop. `sourceID` must identify this processor lifetime
uniquely within the caller's routing domain, not merely its current slot.
Together with nonzero note IDs it distinguishes output ownership across
processor instances. The adapter does not generate global lifetime IDs itself.
The existing no-argument attach remains an internal-only path.

The receiver gets actual generated On/Off events with `Stage::Output`, the
pinned instrument mask/channel, `SourceKind::Arpeggiator`, the supplied source
ID and matching note IDs. Common Hold Legato notes retain identity. Direct
Off-mode physical notes are deliberately not mislabeled as ARP output.
Events keep scheduler emission order/time, including synchronous cleanup from
input, parameter edits and Stop. No speculative future gate deadlines are sent.
The same-time ordering rules remain those documented for live Hold input.

The receiver must be bounded, allocation-free and non-blocking in production.
Returning `false` means **no side effects/acceptance** for that event; it must
not partially fan out and then reject. The receiver reserves/accepts its output
before the adapter applies the validated event to local DSP, and must not also
dispatch it to the same DSP. Local synthesis still occurs exactly once.
This synchronous acceptance boundary is not a queue or a complete rack bus;
recording/output backends will supply their own bounded transaction policy.

On rejection the processor retains only accepted On ownership and unaccepted
Offs, the adapter faults and releases local gates. Stop retries outstanding
Offs with their original destination/source/note identity and current stop
time. It stays faulted if any receiver rejects again. The caller must retain
the adapter and receiver context until cleanup succeeds, or explicitly panic
and reconcile the destination before retiring them. There is no success-shaped
fallback or implicit dropping of pending external ownership.

### Physical input ownership

The optional final `attach` argument `InputOwnership::SourceNotes` enables
the portable `native/Musical/NoteOwnership.h` ledger for this destination.
`LegacyPitch` remains the compatibility default. The standalone rack uses
the same ledger **before** the adapter, across captured logical destinations,
and therefore leaves the adapter-local ledger disabled: filtering the same
Off twice would strand ownership in the inner ledger. Direct clients without
a rack owner can opt into `SourceNotes`.

The ledger holds up to 256 physical owners keyed by source kind/ID, input
channel, pitch and note ID. Each accepted On retriggers as before; repeating
the same key replaces its captured On without growing storage. Distinct
nonzero IDs allow overlapping notes from the same source; zero retains
traditional same-source/channel/pitch replacement behavior. A matching Off
removes only its owner and reaches the synth/ARP held list only when it was
the final physical owner of that pitch. Unmatched/duplicate/stale Offs are
recognized no-ops, not a release of another source's note.

Sustain and Latch remain downstream: the ledger tracks physical presses, not
pedal-retained voices. Successful Stop or interpreted Panic clears owners.
Sustain release does not resurrect physically released owners. No MIDI source
is invented by this layer: the caller must supply real endpoint identities and
consistent On/Off note IDs. Standalone CoreMIDI/BLE ingress now supplies
connection-lifetime IDs through the rack queue and uses the ledger at the
live routing boundary. Legacy C callers still use source zero and
cannot distinguish separate devices through that compatibility path alone.

`releaseSource(source, time)` removes a disconnected source's physical owners,
using each accepted On's captured channel, note ID and routing. Other sources'
same-pitch keys remain held. It behaves like releasing keys, so Sustain/Latch
may intentionally retain the resulting notes; it is not destination Panic.
This destination-local ledger does not replace rack-wide captured routing:
the rack must still deliver each Off/source cleanup to its original instruments
after selection, channel, zone or scene edits.

Invalid input fails before mutation. Capacity overflow returns `Full` in the
portable core; adapter overflow explicitly faults and releases local gates,
retaining owner state until successful Stop. A rejected downstream final Off
remains owned for retry. Source cleanup can make partial progress: accepted
releases are removed, the rejected release and remaining owners stay pending.
The portable callback must reject without side effects and must not re-enter
the same ledger. The adapter's own processing failure requires Stop, not
blindly retrying a partially processed input.

Standalone rack/key-lock/scene and captured disconnect cleanup are enabled;
independent AU integration/validation remains outstanding.

## Live standalone integration

The standalone header's icon-only square Stop button calls the ordered
`ov_rack_stop_all` transport command. Unlike selecting ARP Off, it releases all
direct and generated voices across all 16 instruments, clears physical/pedal
ownership and pending scheduled MIDI, and retains every sound/ARP parameter.
The model clears Key-Lock notes without disabling Key-Lock; keyboard input
capture is reset before enqueueing Stop. Generated Offs use the adapter's
existing Stop sink and preserve source/note/destination identity. FX memory is
untouched, rendering continues, and natural release/chorus/delay/reverb tails
are preserved. Later FIFO edits/live input can play immediately. Queue failure
reports an error and uses existing Panic cleanup. Tests require unchanged FX
memory at Stop and audible tails afterward, in addition to all-mode,
all-instrument cleanup, FIFO/rearm and overflow behavior.

`SynthRack.cpp` constructs one `NativeEngine<true>` per logical instrument and
attaches its processor to the initial slot/channel with a monotonically
allocated, non-reused processor-lifetime source ID. ID exhaustion rejects engine
creation without replacing a working scene. Routing edits preserve held notes;
captured physical Offs still reach the original processor. Slot, program and
scene replacement stop the outgoing processor before retirement.

The rack already splits controller learning, raw VALUE handling, Sustain
interpretation and user CC maps. VALUE callbacks and CC maps now use
`ArpeggiatorAdapter::parameter`; the subsequent event uses `controllers=false`
to avoid applying VALUE twice or overwriting interpreted Sustain with raw CC64.
Effective MOD settings and shared RNG remain scoped to the existing DSP control
boundary. Parameter/Stop times are assigned by the audio owner, never read
unsafely from a producer-side engine constructor.

`Timing::timeline` carries the 64-bit control boundary independently of the
legacy 32-bit MIDI deadline. Adapter render starts one CTL earlier; callback
offset CTL therefore emits at the actual current boundary, including across
32-bit wrap. Local generated events bypass the old scheduler and use direct
voice entry. Off-mode physical notes retain Mono/Unison fallback. There is no
new external MIDI endpoint or output-recording subscription yet; the optional
synchronous native receiver remains the output integration boundary.

`NativeEngine<false>` and `OB1_RACK_ARP_REFERENCE` exist for legacy regression
oracles only. The old DSP-state rack/transport tests retain that reference;
`ipad_live_arpeggiator` runs the **actual default production** engine/factory.
It checks 103,680 stereo/RNG blocks across every ARP/Latch/voice combination,
65,536 blocks from 16,384 mixed lifecycle operations and 64,512 clock blocks
across every division/start grid with signed live compensation. All are
bit-exact against the legacy backend. Actual 16-instrument routing tests cover
source/touch overlap, captured channel/zone edits, pedals, disconnect and
scheduled cancellation, Stop/Latch/rearm, VALUE changes, capacity/queue failure,
source-ID exhaustion and 64-bit timing. Legacy held arrays and input FIFO stay
unused in the production scheduler. Physical iPad/MIDI performance and the
independent AU scheduler migration are not inferred from these Mac tests.

## Tests

Portable tests without any Apple or OberVave dependency:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  native/Musical/check_arpeggiator.cpp -o /tmp/ob1-check-arp
/tmp/ob1-check-arp
```

The `musical_arpeggiator` CTest target additionally compiles the original
engine as an oracle. At each input/configuration/tick/Stop boundary it drains
the original emitted event queue and compares ordered Note On/Off, pitch,
velocity and emission boundary with the extracted processor. It also checks
held/output counts, counters and random state. The oracle is ticked directly
to isolate musical scheduling from oscillator/voice behavior.

Coverage includes all eight enabled modes, every division, octave values
0/1/2/4, gate values 0/1/63/126/127, played/fixed velocities, all grids,
Add/Replace/Off, repeated pedal states, chord updates, common Hold Legato
identities, mode changes, tempo changes, positive/negative/repeated latency
changes, host phase jumps, high notes, duplicate octaves, held-key eviction,
and transport Stop/rearm. Separate portable tests verify independent seeded
random reproduction, invalid input and sink failure during both chord On
and multi-note Off.

The additional `external_arpeggiator` CTest target compares 66,432 rendered
16-frame stereo blocks sample-for-sample between the legacy scheduler and
the portable processor driving the explicit bypass. It covers all four voice
modes, all eight enabled ARP modes and all three LFO phase modes, with glide,
Sustain/Latch/chord changes, Hold Legato common notes, effects and Stop.
It also compares voice trigger counters, gates, envelopes, oscillator phases
and shared RNG state. This uses explicit per-tick RNG synchronization, not
an assumption that independent random generators stay aligned.

Separate handover tests cover invalid calls, enable/disable/idempotency,
raw-note rejection, saved patch preservation, pending-note filtering and
counter wrap, part isolation, parameter edits, Sustain, Panic and restored
legacy playback. Live platform routing remains an integration gate.

The same 66,432-block matrix is also run through the effective-patch callback.
An additional 20,352 stereo blocks compare signed temporary modulation of
ARP mode/Latch/division/octaves/gate/velocity and voice-start parameters,
including mono/unison selection, detune, spread, glide and LFO phase.
Tests change tempo, host phase and signed latency while notes are held and
check that the saved base patch is restored after every render. Callback
contract tests cover per-part order, multiple control ticks in one render,
64-bit timestamps over DSP counter wrap, scoped lifetime and partial failure.

Direct Off-mode tests additionally compare 8,064 rendered stereo blocks across
all four voice modes, all Latch settings and glide on/off. They cover ordered
Mono/Unison fallback, repeated notes, Sustain-deferred release and pedal cleanup,
physical-key pressure reset and invalid-call rejection. Portable tests cover
the last-held view through eviction, replacement, sustain and Stop. These are
low-level lifecycle tests, not certification of a live platform adapter.

The `arpeggiator_adapter` suite adds full input/parameter/render comparisons:
all voice/ARP/Latch modes, Off/On transitions, sequential VALUE/MOD routes,
Sustain/Panic OVERRIDE, optional fixed CC, pressure reset, transport/restart and
fault recovery. It also runs 16,000 deterministic mixed operations, including
several input/parameter changes before a render. Audio, voice gates/targets,
envelopes, trigger counters, held/active counts, base patch and per-instance
RNG state are checked against the legacy engine throughout. Invalid inputs,
render bounds and conflicting attachment are tested separately.
The adapter comparisons cover 75,000 stereo control blocks in the main
scenario matrices, including maximum-size/multi-tick render buffers over
32-bit DSP counter wrap with Master Sync and signed latency changes.
They now also compare every emitted output On/Off against the legacy recording
trace, checking order, pitch/velocity, monotonic 64-bit time, pinned destination,
source lifetime ID and matching note ownership. Failure tests reject part of
a chord and then reject its cleanup Off, verifying retained ownership,
repeatable Stop cleanup, local gate release, immutable destination and recovery.
The additional `note_ownership` suite covers same-pitch source kind/endpoint/
channel/note-ID isolation, repeat retrigger, captured source cleanup, partial
rejection/retry, capacity and validation. Source-aware adapter tests cover all
ARP/Latch modes, held voices after another source releases, Sustain, Panic and
overflow recovery. The complete 29,184-block single-source lifecycle matrix is
also run with `SourceNotes` enabled against legacy audio, while the legacy
mixed trace retains its intentionally different unmatched-Off behavior.
