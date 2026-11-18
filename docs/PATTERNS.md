# Musical pattern data

`native/Musical/Pattern.h` implements the portable C++17 pattern **data and
editing model** (plan increment C6). It includes no DSP, SwiftUI, CoreMIDI,
file operations, allocation or locks. `Sequencer.h` supplies portable playback
and recording, integrated with the standalone rack, SEQ tab and additive scene
JSON fields. See [the standalone guide](../ios/OberVave/README.md#seq-pattern-launcher-and-mixer).

## Limits and musical units

- One `PatternStore` holds up to **16 patterns**, independently of MIDI
  channels and rack instrument slots. Deleted storage can be reused, but IDs
  are not reused within that store's lifetime.
- Each pattern holds up to **1,024 note records**. Equal-pitch/overlapping
  notes remain separate records, including notes with identical timing.
- Musical positions/durations use signed 64-bit integer ticks, **960 PPQ**,
  not floating point beats or audio/UI timers.
- Pattern length/duration is 1 through **2^38 ticks**. Fixed recording presets
  remain 1–256 quarters; free recording does not stop at that preset limit.
  Every note starts in `[-intro, length)`; intro is 0–11,520 ticks.
  Negative starts are one-shot pickup notes; `introEnabled=false` skips them
  without deleting the data. Duration is 1 through 2^38
  ticks, independently of pattern length: a note can cross a loop boundary
  or extend over multiple iterations of a short pattern.
- The model does not assume 4/4 for scheduling; "64 bars" only illustrates
  capacity. One-tick patterns, odd lengths and integer triplet timing are valid.
- Names use up to **96 UTF-8 bytes**, with a terminating NUL in snapshots.
  Empty/whitespace-only names, control characters, embedded NUL, malformed/
  overlong UTF-8, surrogate code points and out-of-range Unicode are rejected.
  Multilingual names and emoji are supported; there is no silent truncation.

All limits are explicit validation errors, not silent trimming/eviction.

## Notes, routing and identity

`PatternNote` contains:

| Field | Meaning |
|---|---|
| `id` | Stable, nonzero 64-bit note-record ID within this pattern |
| `start`, `duration` | Original performed/edited timing in integer PPQ ticks |
| `pitch` | MIDI note 0–127 |
| `velocity` | Note On velocity 1–127; zero is invalid, not deletion |
| `channel` | Zero-based MIDI channel, independent of logical destination |
| `routing` | Existing `Routing`: channel target or explicit instrument mask, Input/Output stage |

Routing reuses the validation from `Musical/Event.h`. A nonempty logical
instrument mask can select one or several instruments without confusing
instrument slots with MIDI channels. Channel routing has a zero mask. The
explicit stage preserves the distinction between input performances intended
to pass through ARP and recorded output intended to bypass it. A pattern can
contain both; the model never forces a saved patch's ARP parameter to Off.
No external endpoint configuration is invented by this model; endpoint routing
belongs to the separate output-backend increment.

Notes are stored canonically by **original start, then note ID**. Each accepted
add allocates a fresh ID; its incoming `PatternNote::id` is ignored. Edits use
the explicit ID argument and preserve it, even when reordering notes.
Deletion does not rewind the next-ID counter. Invalid edits leave the record,
ordering and counters unchanged. Adding at capacity returns `Full`; ID
exhaustion returns `IDExhausted` before wrapping. The maximum integer ID is
reserved as the exhausted counter state.

`PatternStore` supports create, erase, rename, duplicate, length/loop/
quantization changes and note add/edit/erase. Lookup by missing ID/slot returns
null, while failed mutations return `PatternError`. Successful create/add/
duplicate assigns its output ID; failure leaves the caller's output unchanged.
Names need not be unique. Duplicating creates a new pattern ID and independently
copies notes, routing, quantization, loop and note-ID high-water mark. Note
IDs are preserved **within the copy**, not made globally unique.

Playback identity includes a non-reused runtime Note On ID within the column
player, not just the editable note-record ID. Replacement stops captured
owners before retiring immutable clip storage.
Restoring an old snapshot is a new document lifetime, not a way to hot-rewind
ownership IDs while old notes are sounding.

Shortening a pattern rejects any note whose original start would be outside
the new length. It never silently deletes or truncates notes. Cross-boundary
durations remain valid. Quantized timing is recalculated from originals at
the new length.

## Non-destructive quantization

`PatternQuantization` controls an optional derived timing view:

- `grid=0` disables quantization. Otherwise the grid is 1–3,840 ticks (a
  whole note). Straight, triplet and custom integer grids are allowed.
- `strength=0…100` moves toward the nearest grid by that percentage.
- `ends=false` quantizes only the start, preserving original duration.
  `ends=true` quantizes the original start **and original end**, then derives
  the duration from their difference.

Half-grid ties round forward. Percentage rounding is nearest tick, with ties
away from the original position. A start cannot quantize past the pattern's
last tick: if its nearest grid is outside the pattern, the last grid strictly
inside the pattern is used. Thus a near-end note never wraps unexpectedly to
the beginning or disappears. Derived duration is clamped to 1…2^38 ticks,
so quantizing very short notes never yields zero/negative Note Ons.
Long notes keep their end past the pattern boundary; ends are not loop-wrapped.

`Pattern::timing(id, output)` returns this derived view without mutating any
original note data or IDs. Disabling quantization restores original timing
exactly. Changing grid/strength/ends never accumulates rounding error.
Canonical storage remains in original-time order. The player releases due
notes before emitting new notes at a control boundary, rather than assuming
quantized ends follow storage order. `timingAt(index, output)` is constant-time
for playback; the editable-ID lookup remains linear.

## Snapshots and versioning

`PatternData` and `PatternStoreData` are trivially copyable, bounded **in-memory
snapshots**, with schema version **1** (fixed 960 PPQ), counters and explicit
active-note/pattern counts. Empty store slots have pattern ID zero. Active
patterns must validate in full, including unique note IDs, canonical order,
IDs below the next-ID high-water mark, lengths, routing, names and quantization.
Store restore also rejects duplicate pattern IDs, inconsistent counts and
invalid store counters. A malformed later slot cannot partially replace
earlier working patterns: restore validates the entire snapshot before copying.

These are not a serialized struct ABI: **never write raw C++ object bytes**
to a scene/file. Padding, bool representation and endianness are not a format.
The standalone codec uses pattern schema version 2 with fixed 960 PPQ,
explicitly migrates version 1, and rejects unsupported versions. It
decodes validated types off audio, and preserves originals and explicit stage.
Logical routing is pinned to the cell's column. Each whole-cell publication is
a new document lifetime; its next editing ID is reconstructed above all saved
IDs. Playback IDs do not rewind. The active prefix of `notes` is the content;
unused capacity is not. Unknown required versions fail explicitly rather than
being guessed. Unknown additive metadata can be handled by the future codec,
but unknown musical/routing semantics must not silently become defaults.

Create/edit/duplicate/restore are **control-thread editing operations**, not
realtime commands. They may shift/copy bounded arrays; snapshot validation may
scan ID pairs. Publish a separately owned immutable snapshot at an audio
boundary and retire the old one off-thread, as the rack now does. Do not retain
store pointers across edits/replacement or mutate this editor concurrently
with rendering. Scene pattern fields are additive; AU parameter IDs and the
independent AU scheduler are unchanged.

## Playback and recording

The standalone grid is 16 columns by eight rows, distinct from the reusable
16-entry `PatternStore`. Scenes publish all 128 possible cells atomically with
the instruments. Players and the single recorder belong to the audio owner.
Fractional 960-PPQ conversion retains division remainders across control
blocks; tempo and external phase come from the existing rack clock.
Launch bar size is currently four quarter notes. The shared row downbeat is
chosen late enough for the longest enabled pickup. Each column's current
clip continues until its replacement's pickup begins.
At that actual launch boundary the rack stops the column's live arpeggiator
before delivering the pattern's first notes, including row launches and
recording auto-play. Queuing alone does not interrupt it. ARP/Latch modes,
FX memory and other logical columns (including shared MIDI channels) survive.

Output events bypass ARP without changing saved parameters and share bounded
pitch ownership with generated ARP events. Recording output observes actual
ARP releases and direct releases after Sustain, not precomputed gate times.
Recording finalizes open notes on completion/Stop and sorts originals. A
control-thread-preallocated destination receives the recorder's validated,
canonical data on audio, replacing the immutable cell without allocation or
quadratic snapshot validation. Automatic/manual completion queues main-loop
playback on that same audio boundary, skipping pickup already performed.
The one-result mailbox only mirrors the saved/cancelled/failed result to the UI;
UI polling never re-publishes or restarts the take. Overflow reports an error and does not publish a
success-shaped partial take. Scheduling is at 16-sample control resolution,
not per-sample voice synthesis. No UI timer schedules or records events.

`WaitForNote` arms without a deadline until the first routed live Note On;
`Immediate` starts on arm when stopped. During scene playback both join the
next bar, recording the pre-boundary region as intro. `CountIn` counts 4 or 8
quarter-note clicks; on a playing scene counting starts at its next bar and
the whole count is retained. The metronome is synthesized on the shared audio
clock. Column settings select fixed quarters or free length. Free takes have
no 256-quarter deadline; their displayed length grows in complete 3,840-tick
bars. A second tap requests the current body's bar end instead of immediately
finalizing. The recorder keeps capturing until that immutable deadline and
starts the loop at it, even if the UI has not polled. Fixed length is an upper
limit on that deadline. Body lengths and held-note releases use the exact
musical deadline, not the slightly later control-block time. Stopping
before the body cancels the take. Global/column Stop never auto-starts it.

The short-pad-tap command chooses recording completion, playback Stop, launch
or empty-cell recording on the audio owner, never from a captured SwiftUI pad
state. Thus a take already looping but not yet read from the mailbox stops on
the next tap rather than sending another recording action. Playing-pad Stop
is bar-queued, idempotent and releases input-stage Latch as well as output
owners. Confirmation dialogs are only for explicit destructive menu actions.

Completion delivery is a preallocated 16-entry single-producer/single-consumer
FIFO, independent of recorder availability. Each accepted take reserves an
entry before capture; unread results never get overwritten. A full FIFO rejects
the next arm with rack error 4 before changing any clip. Polling drains saved,
cancelled and failed results in order exactly once. Scene epochs prevent an
old completion from being applied to a newly loaded scene. Recording indicators
come only from audio-owned recorder state, not an optimistic tap or unread result.

## Verification

`musical_patterns` is registered in the existing CTest suite. It can also run
independently of Apple frameworks:

```sh
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  native/Musical/check_pattern.cpp -o /tmp/ob1-check-patterns
/tmp/ob1-check-patterns
```

Tests cover:

- Full channel/pitch ranges and logical-layer/Input/Output routing.
- Note overlap, canonical reordering, deletion/re-addition and cross-loop notes.
- Exact length/name/note/counter/capacity/version limits and transactional errors.
- UTF-8 and self-referencing name edits/duplication.
- Independent copies, complete snapshot round-trip and late-slot atomic rejection.
- Non-reused pattern/note IDs through deletion, restoration and exhaustion.
- Quantization against an independent rounding oracle, including loop edges,
  short notes, every strength extreme and straight/triplet/custom grids.
- **20,000 deterministic mixed note edits** against a separate vector oracle.

Audio playback/tempo-drift, output bypass, recorder open-note finalization,
filesystem round-trips and physical-device UI behavior are not inferred from
these data-model tests; they belong to the subsequent implementation gates.
