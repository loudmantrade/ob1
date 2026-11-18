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

## Standalone integration

The existing rack command queue retains raw MIDI/deadlines and now also keeps
source kind and connection-lifetime ID. At dispatch it decodes to an `Event`; `routeEvent` validates the
event and selects destinations through `Routing.h`. Channel targets preserve
splits/layers and only filter Note On by zone. Explicit instrument masks bypass
channel/zone selection and pin each delivered event to its logical slot.
Note On captures each delivered logical instrument in that instrument's
bounded ownership ledger. Note Off uses the captured destinations, independent
of current channel, zone, selection or incoming target-mask edits.

The rack's `SynthEngine::event` boundary carries source, pinned destination,
note ID and timing to adapters; the standalone OberVave adapter now runs
the extracted processor before the direct-voice DSP entry. Raw controllers and legacy CC maps retain their existing handling. Sustain
retains polarity/hysteresis but aggregates independent source/channel pedals;
one device's pedal-up cannot clear another device's pressed pedal. Keyboard Off and wheels now retain keyboard
source identity rather than being relabeled as external MIDI.

`processedFrames` extends the existing render/control counter to 64 bits; it
advances exactly once per existing control block, not on a UI timer or a new
clock. Events created by the legacy command adapter carry the **actual dispatch
boundary**, not an invented sample-accurate timestamp. The original 32-bit
scheduled deadlines and buffer behavior are unchanged, including wraparound.
User-constructed events can carry their requested musical/sample position.
Future processors must distinguish requested scheduling time from actual
emission time when making output recordings.

This public rack input boundary deliberately rejects output-stage events until
output replay/routing is implemented: replaying them through the current ARP would silently arpeggiate
them twice. Invalid/unsupported events report the rack's existing invalid-input
error. A failed engine delivery reports an error and requests the existing
bounded panic cleanup rather than leaving a possibly half-delivered layer held.

Live standalone note ownership now distinguishes source kind/ID, input channel,
pitch and nonzero note ID (zero retains ordinary MIDI retrigger semantics).
Each accepted On still retriggers; only the final pitch owner's Off reaches the
engine, and unmatched/duplicate Off is ignored. The ledger has 256 keys per
instrument; overflow uses the visible rack capacity error and Panic cleanup.
Channel/zone edits affect new notes immediately without stopping held voices.
The existing Key-Lock channel capture remains intact.

Ownership belongs to the actual instrument instance: Stop, program replacement,
slot removal/replacement and scene replacement clear it before retirement.
No pointers or old ownership transfer to a replacement in the same slot.
MIDI 1.0 does not identify separate repeated same-key presses from one source;
clients needing that distinction must preserve nonzero note IDs. There is no
new public MIDI output, feedback loop or pattern UI here. The extracted
arpeggiator is enabled for local standalone playback; output replay,
recording, external routing and the independent AU migration remain separate gates.

Additional rack tests compare event-adapter audio bit-for-bit with direct
legacy MIDI in all ARP/Latch modes. A mock engine verifies split/layer dispatch,
source and pinned-target context, keyboard releases after channel selection
changes, zero-velocity Off, explicit logical targeting, output-stage rejection,
32-bit deadline wrap with 64-bit delivery time, and failed-sink cleanup.

## Standalone MIDI connection ingress

`native/Musical/MIDIIngress.h` provides a portable byte parser and a bounded
64-connection producer-side registry. CoreMIDI connections and custom BLE
peripheral connections share this ID namespace. `ov_midi_source_open` returns
a nonzero, monotonically increasing process-lifetime ID, or zero on capacity/
ID exhaustion. IDs are not reused after close: a late callback cannot become
input for a new connection occupying the same registry slot.

CoreMIDI passes this integer token through `MIDIPortConnectSource` connection
context; no object pointer is retained or dereferenced by its callback.
Each connection has independent running status and partial-message state.
Realtime bytes do not disturb incomplete channel messages. System-common/
SysEx statuses clear running status; unsupported system data is not emitted
as channel voice input. The BLE timestamp parser remains per peripheral;
decoded messages now carry the same connection-lifetime identity model.
This identifies a connection, not a persistent CoreMIDI unique device ID.

The source-specific C byte/message APIs retain IDs through the existing
scheduled command queue. They reject unknown/closed IDs and invalid bytes;
queue overflow still uses the existing rack error/Panic path. Registry/parser
access is serialized by the existing producer-side parser mutex, never by
rendering. Musical scheduling, MIDI Clock selection and timestamp-to-deadline
conversion are unchanged. Legacy C APIs continue with source ID zero and an
independent legacy parser for compatibility.

Closing a source invalidates its ingress/parser state immediately and enqueues
an ordered audio-owner close command through the existing FIFO. That command
cancels this source's pending scheduled MIDI (including future Note Ons),
releases its captured physical keys and removes its pressed pedals. Other
sources' queued messages, notes and pedals remain intact. Pedal-up follows the
original captured instruments even after route edits. Note/pedal storage is
bounded, and cleanup performs no allocation or locking in render.

Disconnect is physical-key/pedal release, **not** global Panic: intentional
Latch remains latched; another connected pedal may keep Sustain active. If
enqueueing close fails, ingress is still closed and the existing explicit
overflow/Panic path stops notes and clears scheduled input on the next audio
boundary. CoreMIDI disconnect, BLE disconnect/setup failure and Bluetooth
shutdown all use this path. Physical endpoint/callback timing still requires
hardware validation; this does not add endpoint-specific MIDI Clock ownership.

The `midi_ingress` suite covers interleaved streams, running status, partial
messages, realtime/SysEx, single-byte channel messages, unknown/stale IDs,
reconnect reset, capacity and sink rejection. Rack tests verify IDs, FIFO
and parser isolation through the actual scheduled queue, all nine ARP modes,
same-pitch touch/device/channel overlap, explicit-mask and channel/zone edits,
captured pedal release, scheduled-input cancellation, scene/slot replacement,
intentional Latch, note capacity and queue-overflow disconnect cleanup. Physical multi-device
MIDI/BLE testing remains a separate hardware validation step.
