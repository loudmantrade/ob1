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
The bounded completion FIFO only mirrors saved/cancelled/failed results to the UI;
UI polling never re-publishes or restarts the take. Overflow reports an error and does not publish a
success-shaped partial take. Scheduling is at 16-sample control resolution,
not per-sample voice synthesis. No UI timer schedules or records events.

`WaitForNote` arms without a deadline until the first routed live Note On;
in Output mode it instead waits for the first actual emitted Note On (direct
or generated ARP). The first live input primes the stopped master clock only
once, but ARP grid/latency wait is not captured as leading silence or deducted
from the take's ending. The first output defines tick zero and the full capture
deadline; later chord inputs never re-anchor the clock while waiting for ARP.
Wait remains armed during scene playback, across any number of bar boundaries.
Only a non-pattern note routed to the selected instrument can start it; its
actual first input/output note defines zero without an intro or resetting an
already active internal/external clock.
`Immediate` starts on arm when stopped. During scene playback it joins the
next bar, recording the pre-boundary region as intro. `CountIn` counts 4 or 8
quarter-note clicks; on a playing scene counting starts at its next bar and
the whole count is retained. The metronome is synthesized on the shared audio
clock. Column settings select fixed length or Free. Fixed length is
expressed in whole 4/4 bars (1–64); the compatible scene/API field
still stores quarters (bars × 4). Existing fractional-bar scenes are displayed
without changing their timing until explicitly edited. The pattern editor
also uses bars for loop length, retaining beat units for individual notes.
Free takes have
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
FIFO, independent of recorder availability. Each of the 16 logical instruments
has its own preallocated recorder and immutable publication destination; one
take per column is allowed. Simultaneous pad taps and additions before the
body starts arm independent takes. Wait groups share the first selected
instrument's Input/Output trigger and origin; count-in additions share the
original countStart/body boundary. Existing playback and external clocks are
never reset. Global Finish iterates all takes, whereas a recording-pad tap or
column Stop addresses only its slot. Per-slot coherent phase/cell snapshots,
progress and countdown APIs drive all recording indicators and edit guards.
The onscreen keyboard routes to the union of armed instruments' MIDI channels,
including multiple instruments sharing one channel; external routing is unchanged.

Each accepted take reserves an
entry before capture; unread results plus active reservations never exceed
16 and never get overwritten. A full FIFO rejects
the next arm with rack error 4 before changing any clip. Polling drains saved,
cancelled and failed results in order exactly once. Scene epochs prevent an
old completion from being applied to a newly loaded scene. Recording indicators
come only from audio-owned recorder state, not an optimistic tap or unread result.
An application-model-owned common-run-loop timer drains sequencer results and
samples transport every 40 ms, independently of SwiftUI body reevaluation.
The same persistent driver polls full synth/rack parameters at a separate
250 ms cadence; fast transport refresh never scans synth parameters. Published
recorder/status values update only when changed. No additional tap/view event
is needed to acknowledge a completed recording or edit. This timer mirrors
audio state only; it does not schedule notes or musical boundaries.

Circular MIDI cells render duration arcs clockwise from 12 o'clock. Sorted
distinct body pitches occupy up to eight radial lanes; larger pitch sets map
deterministically into adjacent groups and overlapping arcs within a lane merge.
Durations of a loop or longer use one full ring, wrapped notes split at zero,
and notes shorter than one degree receive a one-degree visibility floor.
Enabled pickup notes are dashed on a separate inner lane, never presented as
part of the repeating body. Static geometry is cached when immutable patterns
change; progress refreshes only draw the cached arcs and audio-owned positions.
Playing cells have a separate outer progress ring; queued launches are dashed,
queued Stops have a square marker. Recording is red, waiting/count-in uses a
clock (count-in adds metronome/countdown dots), and queued completion keeps red capture progress with a square until
the actual boundary. There are no text labels on completed pads.
Pad width is measured from the actual keyboard channel button and height equals
width. Progress rings, center drag regions and compact mixer columns fit that size.

### Transactional cell editing

MOVE/COPY/confirmed REPLACE/DELETE prepare immutable snapshots on control.
The audio command checks scene epoch, source and destination revisions,
source content and recording endpoint before changing either cell. Stale or
busy edits acknowledge failure with neither cell modified. Successful edits
stop affected active/pending players and their generated owners before retiring
snapshots; unrelated columns continue. Logical destination routing and pattern
identity are rebuilt, note content/settings are preserved, and copied patterns
remain independent and stopped. Scene JSON persists the acknowledged model.

An independent 16-entry edit-ack FIFO reserves capacity before command enqueue.
The model does not mutate on submission, and waits for acknowledgement before
save/load or another edit. Revisions on recording completions and edit acks
prevent delayed notifications from undoing a later recording or cell mutation.
Parameters/MIDI still use the existing bounded command stream without GUI locks.

One portable gesture state machine resolves all pad touch actions. Populated
single taps wait 240 ms; 450 ms is hold, 8 pt is the drag threshold. Direct
central drag MOVEs; tap+drag or hold+drag COPY; tap+stationary hold requests
DELETE on release; double tap opens the Piano Roll without
musical actions. Plain hold opens accessible Pattern actions on release.
Empty/recording short taps dispatch immediately. MIDI timing remains on audio;
the touch timer only resolves user intent. Drag starts within 23 pt of the
diagram center; pad edges/empty cells/gaps permit nested scroll views to scroll.
Leaving the viewport, interruption or scene change cancels; no auto-scroll is
performed during a drag. Drag bounds use the union of all pad frames intersected
with both scroll viewports, never the frame of a single ForEach column. This
keeps MOVE/COPY active across column gaps and after horizontal/vertical scrolling,
while excluding clipped cells from drop targets.
Source/destination highlighting and MOVE/COPY preview
remain separate from transport indicators. Occupied drops always confirm;
same-cell/off-grid drops are no-ops.

## Verification

### Piano Roll implementation in progress

Double-tapping a populated cell opens a full-screen Piano Roll with a Close
button, showing the notes, keyboard, timeline and playback position. Two
fingers pan and independently zoom the axes simultaneously. The editor cannot
be dismissed by a swipe. A stationary hold on empty space creates a note; drag empty space to
select a rectangle. Drag a note body to move the selection, its left edge to
change velocity, or its right edge to change duration. Tapping a note selects
it; tap then drag copies the selection, and tap then hold deletes it.
The light left strip marks velocity and the dark right strip marks duration.
Very short notes show an expanded, translucent touch target. Finger contact
area counts even when its centre is outside the note; the closest note wins,
with the topmost note breaking ties. Marker and lane touches retain priority.
The second touch must begin within 400 ms of the first tap; once a hold has
begun, its deletion eligibility does not expire while the finger stays down.
The hold deletes the selected group when its note is selected.
Leaving the editor during a one-finger gesture cancels its uncommitted edit;
the finger must be lifted before another edit can start.
Undo and Redo operate on whole gestures. Audio publication is revision-checked
and does not restart active or queued playback. Already-sounding notes retain
their original release times; future onsets use the new data.
Within the current scene, the Piano Roll history remains available after
closing and reopening the editor. Moving a pattern transfers its history;
copying it creates an independent copy of that history. Re-recording or
replacing a pattern through the numeric pattern editor clears its history.
The sequencer has a separate, per-scene history for recording, numeric edits,
MOVE, COPY and DELETE, limited to 32 actions. Its Undo and Redo buttons wait
for an audio acknowledgement before changing history. Restoring a deleted or
replaced pattern also restores its Piano Roll history; a later Piano Roll edit
that changes an affected pattern causes sequencer Undo/Redo to reject the
operation rather than overwrite that edit. Revert the Piano Roll change first.
When switching scenes during the session, their unsaved state, Piano Roll
histories, sequencer history and viewports can be restored from Scenes in this session, including
untitled and imported scenes. These session states are not saved to disk.
Switching waits for an audio-owned snapshot before replacing the scene; if the
audio engine is stopped or recording is active, switching is rejected rather
than saving a potentially stale session state.

The standalone synth screen also provides a separate, per-scene scene-edit
history, limited to 32 actions. A knob or slider gesture is one action;
individual parameter selections are separate actions, and a multi-control
reset is one action. Tempo, master level and pan, and keyboard channel
selection share that history. External MIDI CC,
channel pressure and pitch bend changes to synth parameters are grouped by
source, channel and controller until 500 ms of audio time without a matching
message. Pattern automation is excluded. Applying parameter history checks
the current audio values and scene epoch atomically; conflicts are rejected
without changing any parameter or restarting playback. If the external MIDI
event queue overflows, the parameter history is cleared and an error is shown
rather than preserving an incomplete history. This parameter history does not
yet cover presets, instrument management, all scene settings or mixer operations.

Copy/Paste retains relative timing and routing, with the most recent empty-grid
tap as the paste anchor (initially tick zero). Paste creates new note IDs and
rejects invalid destinations. Transpose and scale conform affect the selection,
or all notes when no notes are selected; nearest-scale ties choose the lower
pitch. Tapping a note also auditions it for approximately one sixth of a
second on that cell's instrument. The preview uses a separate output-stage
owner and bypasses the arpeggiator, so it plays the selected pitch without
starting a waiting recording or ending another source's held note. Its Note
Off is scheduled by the audio owner, not a UI timer.
Playback quantization is a separate, non-destructive setting for the entire
pattern, not the current selection; changing or disabling it retains the
recorded note timings. The separate Quantize Selection / All command stores
per-note version 5 overrides for start-only or start/end quantization at
25–100% strength; with no selection it applies to all notes. Choosing Off
restores original note timing even if the global setting is enabled. The Snap
menu accepts a custom grid of 1–3840 ticks; that same custom value is available
in both quantization menus. Visible subdivisions are thinned at low zoom.

Pattern schema version 4 supports up to 256 ordered step controller points,
including MIDI CC and 14-bit channel pitch bend. It retains legacy or version 3
region behavior explicitly and rejects unsupported automation types. Events
are routed to the pattern's instrument on the audio clock, with deterministic
ordering for equal ticks. Scene and immutable-snapshot round trips are covered.
The lower CC / Pitch Bend lane shares the timeline: tap to add a point, drag
an existing point, hold it to delete, or use Freehand to draw a bounded stroke.
CC defaults to modulation (CC1); the stepper selects any CC. Pitch bend is
displayed with its 8192 center line. Automation uses step interpolation.
Freehand strokes discard consecutive identical values without changing step
playback and remain a single undoable edit.
The Velocity lane edits the note nearest the touched onset; if that note is
selected, the same signed velocity delta applies to the selected group.
Re-recording retains automation;
if the new take cannot contain its points, publication fails instead of
silently discarding them.
The Regions command enables version 6 for the edited pattern, with numeric tick
positions for pattern start, loop start/end and tail end, and LOOP/ONE-SHOT.
The editor displays these markers and shades the non-triggering tail. Each
iteration has independently owned note releases, capped at its tail end.
Notes stored after loop end remain in the pattern and are not triggered.
Shortening rejects out-of-range note starts rather than deleting them.
Version 1/2 clips retain their original unbounded release behavior until a
marker is moved or Regions is applied. Either action converts the clip to
region semantics and can change its tail behavior. A fresh recording replaces
regions with legacy defaults. Marker handles have separate ruler rows, even
when markers coincide. Dragging uses the selected snap grid and applies on
release as one undoable edit; invalid moves do not change notes. Numeric positions accept
raw ticks or 4/4 bar:beat:tick notation. Pattern start may be positive or
negative, and Loop Start may be before or equal to Pattern Start. Notes and
automation between them are skipped on the initial pass but play on subsequent
loops; in ONE-SHOT they remain silent. Other non-triggering notes are retained.
Version 6 preserves this independent start alongside automation and
per-note quantization. Versions 3–5 keep their original start semantics.
Acceptance requires portable timing/ownership and scene-migration regressions,
the existing sequencer and AU suites, a signed iPad build, and the physical
iPad gesture/audio checklist from the implementation specification.

The shared count-in/recording/playback metronome uses the existing 25 ms synthesized
click on the audio owner. Click boundaries and accents use the same quarter index
as the header. Its atomic
enable flag mutes immediately and consumes muted beats so toggling on does not
replay an old click. Waiting alone does not trigger it. First beat is
1760 Hz and other quarters 1320 Hz, mixed after MIDI capture.
The global header's one-based bar/beat counter samples an audio-published
64-bit quarter index, continuing across concurrent loops and later takes.
When a recording starts an idle internal transport, its actual capture origin
defines 1:1 (the first emitted ARP note in Output/Wait mode), not the preceding
shared bar. Count-in starts at 1:1 and continues into the body. Joining an already
active transport never resets the counter; playback-only/external starts retain
the shared bar grid. The counter freezes
when no recording/player is active and Stop All resets it. Count-in participates
in the shared counter; per-pattern loop progress remains independent.

The production rack regression guards ordinary C++ `new`/`delete` during every
render call, including completion, retirement and cell transactions. It also
covers A/B/C takes without polling, reserved result capacity, stopped audio,
rapid edit commands, stale source/destination revisions, scene invalidation
and affected-only playback cleanup. Swift model tests cover gesture ambiguity,
cancellation, note geometry, independent copy edits, late acknowledgements and
JSON persistence. These checks do not substitute for physical touch/audio tests.

### Manual iPad acceptance (not automated)

1. In Wait, Count-in and Immediate modes, record A on part 1, tap to finish,
   keep playing until the bar end and confirm the pad becomes a diagram with
   progress, with no red recording indicator remaining.
2. Immediately record B on part 2 and C on part 3, without stopping A/B.
   Verify all three loop in sync and their rings follow their own lengths.
3. Check Input and Output recording with ARP/Latch and Sustain; confirm Output
   is not arpeggiated twice and Stop/record completion release notes as expected.
4. Compare a long note, short notes, a chord, cross-loop notes and an enabled
   pickup. Stop a cell: its static duration diagram should remain visible.
5. Drag from the central diagram onto an empty cell in the same column, then
   another column: MOVE clears only the source and preserves musical content.
6. Short-tap+drag and hold+drag: both show COPY before release and leave the
   source intact. Edit a copy and verify the source is unchanged.
7. Drop MOVE and COPY onto occupied cells. Cancel first (no change), then
   confirm replacement; only affected players stop, unrelated loops continue.
8. Short-tap+stationary hold: release opens destructive Delete confirmation.
   Cancel, then retry and confirm. Hold+drag must never request deletion.
9. Double tap: only the Piano Roll opens; playback must not toggle.
   Single populated tap dispatches after 240 ms; empty/recording taps are immediate.
10. Scroll horizontally/vertically from pad edges, empty cells and gaps.
    No unintended move or recording should occur. Reveal distant destinations
    before starting a drag (no drag auto-scroll).
11. Drop on the same cell or outside the visible cell viewport; interrupt a
    gesture or change scene during it. No partial edits should remain.
12. Try editing recorded cells and stale confirmations. They must be rejected
    without losing either valid pattern. Pause audio while submitting an edit:
    the UI must show pending, not false success; resume and verify acknowledgement.
13. Stop/restart individual cells, Stop All, save/reload and relaunch the app.
    Verify successful edits, sound parameters, KEY-LOCK and MIDI input survive.
14. Check VoiceOver pad activation and Pattern actions, and test the gesture
    thresholds/scroll trade-off on older iPads. Installation alone does not
    verify these physical interactions.

### Piano Roll physical iPad checklist (not yet verified)

1. Double-tap a populated cell during playback and verify no launch, stop or
   recording occurs. Close and reopen it; viewport and both zoom levels persist.
2. Tap notes to select and audition, including rapid taps and a pitch already
   sounding elsewhere. Verify brief previews and no stuck or silenced notes.
3. Hold empty space to create, tap empty space to clear, and drag in each
   direction to select a rectangle. Move, copy and delete individual/group
   notes; verify one Undo/Redo step per gesture.
4. Drag left edges vertically for velocity, right edges horizontally for
   duration, and bodies diagonally for pitch/time. Test short notes, zoom
   extremes, group limits and velocity/duration values.
5. Test transpose, scale directions, custom snap, start/end quantization and
   selected versus all-note operations; save and reload without losing originals.
6. Edit velocity, CC1, another CC and centered/full-range pitch bend; draw and
   delete points and freehand strokes, play them, undo, save and reload.
7. Drag and enter all four markers including negative and positive starts.
   Verify invalid edits are rejected, tail-only onsets stay silent, ONE-SHOT
   finishes and overlapping loop iterations release independently.
8. Pan and pinch each axis and both simultaneously from notes and lanes; cross
   fingers and add a second finger mid-edit. No edit may commit, and the
   remaining finger must not restart one until all fingers are lifted.
9. Exercise dense patterns on an older supported iPad while playback and other
   instruments run. Record A then B, test ARP Input/Output, KEY-LOCK, scene
   reload and live sound-design controls without glitches.

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
