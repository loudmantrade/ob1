# Musical pattern data

`native/Musical/Pattern.h` implements the portable C++17 pattern **data and
editing model** (plan increment C6). It includes no DSP, SwiftUI, CoreMIDI,
file operations, allocation, locks or musical scheduler. It does not yet
enable sequencer playback, recording, scene persistence or an editing UI.

## Limits and musical units

- One `PatternStore` holds up to **16 patterns**, independently of MIDI
  channels and rack instrument slots. Deleted storage can be reused, but IDs
  are not reused within that store's lifetime.
- Each pattern holds up to **1,024 note records**. Equal-pitch/overlapping
  notes remain separate records, including notes with identical timing.
- Musical positions/durations use signed 64-bit integer ticks, **960 PPQ**,
  not floating point beats or audio/UI timers.
- Pattern length is 1 through **245,760 ticks** (256 quarters, or 64 bars
  of 4/4). Every note starts in `[0, length)`. Duration is 1 through 245,760
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

Full note identity in a future playback/recording system must include the
pattern/playback lifetime and loop occurrence, not just this record ID.
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
the beginning or disappears. Derived duration is clamped to 1…245,760 ticks,
so quantizing very short notes never yields zero/negative Note Ons.
Long notes keep their end past the pattern boundary; ends are not loop-wrapped.

`Pattern::timing(id, output)` returns this derived view without mutating any
original note data or IDs. Disabling quantization restores original timing
exactly. Changing grid/strength/ends never accumulates rounding error.
Canonical storage remains in original-time order; a future scheduler must
order derived events separately, using the existing generated-event rule
(Off before On at equal time), not assume quantized ends follow storage order.

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
A later scene/pattern codec must encode named fields, version/PPQ and counters,
decode into validated types off the audio thread, and preserve originals and
explicit routing/stage. The active prefix of `notes` is the format's content;
unused capacity is not. Unknown required versions fail explicitly rather than
being guessed. Unknown additive metadata can be handled by the future codec,
but unknown musical/routing semantics must not silently become defaults.

Create/edit/duplicate/restore are **control-thread editing operations**, not
realtime commands. They may shift/copy bounded arrays; snapshot validation may
scan ID pairs. Publish a separately owned immutable snapshot at an audio
boundary and retire the old one off-thread when the playback increment is
implemented. Do not retain store pointers across edits/replacement or mutate
this editor concurrently with rendering. This increment does not change the
existing audio queue, scene format, AU parameter IDs or live synth behavior.

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
