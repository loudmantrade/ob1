# Shared arpeggiator: extraction and compatibility gate

`native/Musical/Arpeggiator.h` contains a bounded C++17
`ArpeggiatorProcessor`, derived from the existing GPL-3.0-only OberVave
arpeggiator. It does not include DSP headers, patch structures, voices, platform
APIs or SwiftUI. The original scheduler is still the production path in both
iPad and AU. Native-only guards allow an explicit external-note bypass; they
are inactive by default and do not change the hardware firmware build.

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

The original random generator is shared with DSP LFO state. The portable
processor has its own explicit seed; reference tests inject the original state
at each tick to compare exactly. Live extraction must choose and test the
compatibility bridge rather than claiming identical random sequences when DSP
random consumption differs.

The native engine has no active firmware sequencer (`seq_phase` and
`seq_starting` always return false). Those inactive firmware branches are not
reimplemented. Future pattern playback must use the shared transport and
explicit input/output stage flags, not resurrect that firmware sequencer.

Before switching production routing, implement effective controller-modulated
ARP settings, direct-voice handover, source ownership and controller handling.
The AU's independent adapter is a separate integration gate.

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

Remaining live-adapter work includes input-time versus render-time settings,
controller OVERRIDE and interpreted sustain delivery, resetting physical-key
pressure on fresh input, direct Off-mode voices, mode/transport handovers and
source ownership. These are deliberately not hidden inside the snapshot helper.

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
