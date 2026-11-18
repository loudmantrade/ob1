# Shared musical events

`native/Musical/Event.h` is a platform-independent C++17 value model. It has no
OberVave, SwiftUI, CoreMIDI or audio framework dependency and does not allocate.
This first increment defines a boundary, not a new clock or replacement queue.

## Units and identity

- `Time::frame` is an absolute unsigned 64-bit frame in the processing
  timeline. Platform adapters define its origin and sample rate. The native
  synth timeline uses 44,100 Hz; host offsets must be converted before entry.
- `Time::tick` is an optional signed musical position, 960 ticks per quarter.
  `hasTick=false` means the adapter has not assigned a musical position; zero
  by itself is not a missing-value sentinel. No new tempo clock is introduced.
- `withinBlock` converts absolute frame time into `BlockEvent::sampleOffset`.
  Blocks are half-open `[start, start + frames)`; an event at the end belongs
  to the next block. Comparison uses subtraction to avoid unsigned overflow.
  An empty block and late events return `OutsideBlock`, not offset zero.
- Source is a kind and a source-local identity (endpoint, pattern or processor).
  Kind distinguishes touch, external MIDI, host, arpeggiator, pattern and system
  events. A source ID of zero is permitted for a platform's current shared
  input; it does not imply per-device parsing/ownership is already implemented.
- `note` is a 64-bit ownership ID. Zero is unassigned at ingress. Processors
  must preserve the identity across On/Off and routing changes; pitch/channel
  alone do not identify overlapping notes.
- MIDI channels are zero-based. Routing is either channel matching or an
  explicit nonempty 16-bit logical instrument mask; these are not MIDI channel
  bits. The stage distinguishes original input from final generated output.
  Output recordings must replay at the output stage to avoid re-arpeggiation.
  The model does not itself implement that DSP bypass.

## MIDI conversion

`decodeMIDI` accepts channel voice messages and Clock/Start/Continue/Stop.
Note On with velocity zero becomes Note Off; explicit Note Off release velocity
is retained. Channel pressure/program messages have no second data byte.
Pitch Bend retains its 14-bit LSB/MSB bytes without reducing precision. Poly
pressure is distinct from channel pressure. Unsupported system messages and
out-of-range inputs return an explicit `EventError`; output is untouched on
failure. `encodeMIDI` validates the event before producing its MIDI bytes.
Validation does not invent source IDs or silently repair malformed routing.

## Ordering and scheduling

Received events retain FIFO ordering, including same-time On/Off and
controller changes. This is required for current Hold/Latch behavior and mixed
parameter/snapshot commands.

Only newly generated batches use `generatedBefore`: absolute frame first,
then Note Off, other messages, Note On. Equal-priority events are equivalent
and require stable insertion/order by the caller. The portable test uses
`stable_sort` off the realtime path as an oracle, not as the audio scheduler.
The comparator does not allocate. Future bounded processor queues must handle
capacity failure explicitly and perform owned-note cleanup.

The existing OberVave applies notes on 16-frame control boundaries; carrying a
sample offset does not make that DSP sample-accurate. AU host rate conversion,
32-bit rack deadline extension and transport discontinuities belong to their
adapters, not the MIDI value model.

## Tests

The `musical_events` CTest target is also runnable without Apple frameworks:

```sh
c++ -std=c++17 -Wall -Wextra -Werror native/Musical/check_events.cpp \
  -o /tmp/ob1-check-events
/tmp/ob1-check-events
```

Tests cover all channel statuses/channels/pitches and representative velocity
extremes, zero-velocity normalization, pressure/bend, invalid inputs, explicit
instrument/output context, signed musical time, 64-bit frame boundaries,
irregular block offsets and stable generated-event ordering.
