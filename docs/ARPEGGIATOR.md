# Shared arpeggiator: extraction and compatibility gate

`native/Musical/Arpeggiator.h` contains a bounded C++17
`ArpeggiatorProcessor`, derived from the existing GPL-3.0-only OberVave
arpeggiator. It does not include DSP headers, patch structures, voices, platform
APIs or SwiftUI. The original implementation remains unchanged and is still
the production path in both iPad and AU.

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

Before switching production routing, implement an explicit native DSP bypass,
effective controller-modulated ARP settings, direct-voice handover, source
ownership and controller handling. Saved parameters must not be forced to Off.
The AU's independent adapter is a separate integration gate.

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
and multi-note Off. Voice allocation/audio equivalence is a later bypass gate,
not inferred from these event tests.
