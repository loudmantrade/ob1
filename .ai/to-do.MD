# OB1 — Real-Time Musical Event Architecture, Arpeggiator Extraction, Pattern Sequencer and MIDI Output

You are working on the **OB1** synthesizer project:

Repository: `loudmantrade/ob1`  
Primary branch: `master`

## Project context

OB1 is a native synthesizer application for iPadOS with a related macOS Audio Unit implementation.

The project already contains:

- A modified OberVave synthesis engine derived from GPLv3 sources.
- Up to 16 independently managed synthesizer instances in the iPad application.
- A `SynthEngine` abstraction and engine factory registry.
- Multitimbral MIDI routing, keyboard splits and layers.
- Independent presets, parameters, effects and arpeggiator states.
- Shared clock, transport handling and MIDI event queues.
- A touch keyboard supporting multiple MIDI channels and KEY-LOCK.
- Existing external MIDI input support.
- A macOS AUv2 implementation with host tempo synchronization.
- Scene serialization and regression tests.

The repository has recently been cleaned up. Do not reintroduce the original FM1 CPU emulator, firmware execution environment or removed benchmark infrastructure.

**The objective is to evolve OB1 into a real-time multitimbral musical workstation while preserving the current synthesizer functionality and architecture.**

This work must be incremental, independently testable and carefully committed.

---

# 1. Mandatory rules

## 1.1 Inspect before modifying

Before implementing anything:

1. Inspect the current `master` code, not historical branches.
2. Read the root README and relevant platform READMEs.
3. Study the existing `SynthEngine`, `SynthRack`, `Engine`, MIDI routing, clock, arpeggiator and scene persistence code.
4. Identify all existing scheduling and event-queue facilities that can be reused.
5. Identify the exact current platform targets and capabilities.
6. Inspect existing tests and build scripts.
7. Record a concise implementation plan in `docs/MUSICAL_ENGINE_PLAN.md`.

Do not assume that a feature is missing merely because it was mentioned in this specification. Reuse existing implementations wherever possible.

Do not replace working architecture without demonstrating a concrete necessity.

Before beginning each implementation phase, verify that
all commits from the previous phase are complete and that
the working tree is clean. Never combine unfinished work
from different phases into a single commit.

## 1.2 Preserve existing functionality

All existing behavior must remain functional:

- Up to 16 independent instruments.
- MIDI channels, splits and layers.
- Current OberVave sound generation.
- Presets and user banks.
- Scene loading/saving and compatibility.
- Parameter automation and MIDI controllers.
- Pitch bend, sustain and modulation.
- Existing arpeggiator modes.
- Latch and HOLD behavior.
- External MIDI synchronization.
- DAW transport synchronization.
- Audio latency compensation.
- KEY-LOCK functionality.
- Touch keyboard note routing.
- Existing Audio Unit behavior.

Preserve backward compatibility with previously saved scenes and presets.

Do not change the fundamental sound character of existing patches.

## 1.3 Explicit exclusions

**DO NOT implement:**

- A complete replacement of the current synth GUI.
- Unrelated DSP optimizations or refactoring.

The architecture should remain extensible, but do not build speculative systems for these features.

Preserve existing MIDI functionality and compatibility. Extend the internal musical event model only as required for arpeggiator extraction, pattern sequencing, recording, and external MIDI routing. Avoid speculative features and unnecessary abstractions.

---

# 2. Git workflow — critical requirement

**Every independently completed feature must be committed separately.**

Never accumulate all changes into one large commit.

Before starting:

- Verify the active branch and working-tree state.
- Do not overwrite or discard uncommitted user changes.
- Create a dedicated feature branch from the intended baseline.
- Never force-push or rewrite existing history.
- Do not squash unrelated implementation commits.

For each functional increment:

1. Implement one clearly scoped feature.
2. Add or update its tests.
3. Build all affected targets where supported.
4. Execute the relevant regression tests.
5. Inspect the diff for accidental changes.
6. Stage only files belonging to this increment.
7. Create a descriptive Git commit.
8. Continue to the next increment.

Use Conventional Commits, for example:

```text
docs: document musical event architecture
refactor: introduce shared musical event model
feat: add real-time event processing pipeline
feat: implement shared arpeggiator processor
feat: support arpeggiator output recording
feat: add pattern playback engine
feat: add CoreMIDI output routing
feat: add pattern editor
test: cover transport and scheduling edge cases
```

These are examples, not a mandatory exact commit list.

A commit must represent one completed, coherent functionality or narrowly scoped refactor.

Do not commit a feature that is known to be broken simply to satisfy the commit rule.

If an increment is blocked by an unavailable macOS/iPadOS build environment, perform every available static or portable test, report the unverified checks explicitly, and do not claim full validation.

At the end of each increment, report:

- Feature implemented.
- Files changed.
- Tests executed and their results.
- Commit SHA.
- Any remaining limitations.

**Never wait until the end of the entire project to commit.**

---

# 3. Introduce a shared musical event processing layer

Create a reusable, platform-independent musical event layer between event sources and audio/MIDI destinations.

Conceptual architecture:

```text
EVENT SOURCES
    |
    +-- Touch Keyboard
    +-- External MIDI Input
    +-- DAW Host Input
    +-- Pattern Sequencer
    |
    v
MUSICAL EVENT ROUTER
    |
    +-- Channel / Instrument Routing
    +-- Arpeggiator Processing
    +-- Timing / Quantization
    +-- Event Transformations
    |
    v
PROCESSED EVENT BUS
    |
    +-- Internal DSP Rack
    +-- Pattern Recorder
    +-- External MIDI Output
```

Important requirements:

- Do not unnecessarily replace the existing MIDI queue.
- Extend existing infrastructure where appropriate.
- Preserve current multitimbral routing.
- Preserve the distinction between logical instruments and MIDI channels.
- Allow multiple instruments to receive events from one source.
- Allow a single source to target multiple destinations.
- Avoid duplicate Note On/Off events.
- Preserve note ownership across routing changes.
- Prevent MIDI feedback loops.
- Ensure standard MIDI compatibility.
- Avoid circular event routing.

The musical event layer must not depend on SwiftUI.

Prefer C++ for reusable, real-time event processing where it fits the current architecture.

### Event data

Introduce a well-defined internal event representation supporting at least:

- Note On.
- Note Off.
- Velocity.
- MIDI channel.
- Source identity.
- Destination identity/routing context.
- Pitch Bend.
- Control Change.
- Channel Pressure where already supported.
- Transport events.
- Musical timestamps.
- Sample offsets.

Define explicit ordering rules for simultaneous events, especially Note Off/Note On pairs at the same timestamp.

---

# 4. Move arpeggiator scheduling outside DSP

This is a major objective.

The current OberVave DSP contains arpeggiator functionality tightly coupled to its internal voice generation.

Introduce a reusable, real-time `ArpeggiatorProcessor` in the musical event layer.

The external arpeggiator should:

- Receive incoming MIDI notes.
- Maintain its own held-note state.
- Generate scheduled Note On/Off events.
- Produce events independently of the DSP engine.
- Support internal instruments and external MIDI destinations.
- Use the shared musical clock.
- Support multiple independent instances, one per relevant instrument/part.
- Work without any dependency on OberVave-specific patch structures.

## Existing behavior to preserve

Preserve the semantics of existing OberVave arpeggiator functionality:

- Up.
- Down.
- Up/Down.
- Random.
- Played order.
- Chord.
- Hold Retrigger.
- Hold Legato.
- Existing octave expansion.
- Division.
- Gate.
- Latch Add / Replace behavior.
- Sustain interaction.
- Master Sync.
- Start Grid.
- Tempo synchronization.
- MIDI Stop and Panic behavior.

Inspect actual enum values and implementation before reproducing them. Do not assume documentation examples are exhaustive.

Preserve existing parameter values and their serialization behavior.

### HOLD LEGATO

This mode needs special care.

When chord membership changes:

- Preserve notes that remain in the chord.
- Release only removed notes.
- Trigger only newly added notes.
- Avoid unnecessary retriggering of envelopes.
- Preserve behavior during Sustain release and Latch changes.

Do not emulate Hold Legato by restarting the entire chord.

### Engine integration

Initially retain the original OberVave DSP arpeggiator as a reference implementation.

Add an explicit mode allowing OberVave to receive externally generated arpeggiator notes without applying its own arpeggiation again.

Do not simply force saved patch parameters to `ARP OFF` and corrupt their stored configuration.

Keep DSP voice allocation, envelopes, portamento, mono/legato synthesis behavior and sound generation inside the synthesis engine.

The shared arpeggiator owns musical note generation, not DSP voice allocation.

### Migration

Provide compatibility tests comparing the original internal arpeggiator against the extracted implementation.

Include:

- MIDI event sequences.
- Generated note order.
- Note timing.
- Gate durations.
- Sustain behavior.
- Latch changes.
- Tempo changes.
- Transport Start/Stop.
- Notes held during transport changes.
- Random mode reproducibility where applicable.

Do not remove the legacy internal arpeggiator until compatibility is demonstrated.

Make the transition reversible during development.

---

# 5. Pattern sequencer

Introduce a real-time pattern sequencer that operates on musical events rather than audio recordings.

Each pattern must contain independently editable MIDI note events.

The sequencer should support the existing multitimbral rack and future engine types without knowing their DSP implementations.

## Basic pattern capabilities

Implement:

- Pattern creation.
- Pattern deletion.
- Pattern renaming.
- Pattern duplication.
- Pattern length.
- Looping.
- Tempo-synchronized playback.
- Note pitch.
- Start position.
- Duration.
- Velocity.
- Track/instrument routing.
- Pattern start/stop.
- Pattern playback position.
- Pattern persistence.

Use a versioned pattern format with forward-compatible serialization rules.

Use a stable musical time representation, such as beat positions or PPQ ticks, with explicit conversion to audio sample time.

Do not base note scheduling on UI timers.

## Multiple patterns and instruments

Support independent patterns associated with logical instrument parts.

Patterns should be able to target:

- One internal instrument.
- Multiple internal instruments via explicit routing.
- External MIDI destinations.

Do not confuse MIDI channel number with rack instrument identity.

Do not hardcode OberVave parameter assumptions into sequencer data.

## Recording

Support real-time recording of MIDI note events.

Track Note On/Off ownership and matching carefully.

Preserve actual performance timing before quantization.

Provide optional non-destructive quantization.

Handle:

- Overlapping notes.
- Repeated notes.
- Notes extending beyond pattern boundaries.
- Recording while looping.
- Transport interruption.
- Pattern changes.
- Note cleanup on stop.

---

# 6. Arpeggiator output recording

**This is a required feature and one of the main motivations for the architecture change.**

The pattern recorder must be able to record notes generated by the arpeggiator, rather than merely recording the keys initially held by the user.

Example:

```text
Input held chord:
C4 E4 G4

Arpeggiator:
UP, 1/8 notes

Recorded output:
C4 E4 G4 C4 E4 G4 ...
```

The recorded pattern must contain actual generated note events with their own:

- Note On positions.
- Note Off positions.
- Durations.
- Velocities.
- Routing information.

The resulting pattern must play correctly even after the user releases the source chord and disables the arpeggiator.

## Two recording modes

Provide two clearly distinguishable modes.

### Record Output (primary)

Record post-arpeggiator musical events.

This should be the main workflow.

### Record Input

Record original keyboard/MIDI input before arpeggiator processing.

This allows later playback through an active arpeggiator.

## Critical behavior

Prevent double processing.

When playing a pattern containing already generated arpeggiator notes, the pattern must be able to bypass the arpeggiator.

Use explicit event routing or processing flags rather than relying on accidental behavior.

A pattern should be able to contain recorded arpeggiator output without losing its note structure.

Ensure Note Off events are recorded correctly, including those produced by stop, gate or chord changes.

Do not record an audio waveform; this feature records MIDI/musical events.

The recorder must capture the final emitted musical events
after arpeggiator scheduling, including early note termination,
gate changes, chord replacement and transport-triggered releases.

Use stable event/note ownership so every recorded Note On
has a corresponding Note Off, including during loop boundaries,
transport interruption and pattern recording termination.

The recorded pattern must reproduce the actual audible
note sequence rather than merely the arpeggiator's intended
step sequence.

---

# 7. Pattern editing UI

Build a practical, touch-friendly pattern editing interface for iPadOS.

Reuse the existing visual language of OB1 rather than creating an unrelated UI framework.

Provide two complementary editing views.

## Step Editor

Suitable for rhythm and short repeating sequences.

Support:

- Configurable step resolution.
- Note placement/removal.
- Velocity editing.
- Step activation.
- Pattern length.
- Playback cursor.
- Basic per-step gate/duration.
- Looping.
- Editing while stopped.
- Safe editing during playback.

## Piano Roll

Suitable for melodies, chords and arpeggiator output.

Support:

- Display of note pitch and musical position.
- Note creation/deletion.
- Dragging notes.
- Duration editing.
- Velocity editing.
- Horizontal scrolling.
- Vertical note-range scrolling.
- Grid snapping.
- Adjustable quantization resolution.
- Playback cursor.
- Zoom or equivalent usable range adjustment.

Do not introduce advanced DAW features unless needed for the core workflow.

Both views must edit the same underlying pattern data.

## UI behavior

- Preserve the existing synth editor.
- Allow moving between synth and pattern editing.
- Avoid blocking audio rendering during editing.
- Avoid writing pattern files from the audio thread.
- Keep the interface usable on older iPads.
- Do not allow rapid gestures to cause stuck notes.

---

# 8. External MIDI output

Extend existing CoreMIDI functionality to support MIDI transmission.

The touch keyboard, arpeggiator and sequencer must be able to send events to external destinations.

Support destinations including, where available:

- USB MIDI.
- Bluetooth MIDI.
- CoreMIDI virtual destinations.
- Network MIDI endpoints exposed by the operating system.

Do not invent unsupported platform capabilities.

Use the actual CoreMIDI APIs appropriate for the current iPadOS deployment target.

## Routing options

Provide configurable routing per instrument/part:

- Internal only.
- External only.
- Internal + External.
- Disabled.

For external routing, support:

- Destination selection.
- MIDI channel selection.
- Basic routing enable/disable.
- Appropriate Note Off behavior.
- Port disappearance/reconnection handling.

Preserve existing internal keyboard channel-selection behavior.

Allow multiple sources to share a destination intentionally.

## Critical requirements

- Avoid MIDI feedback loops.
- Handle output disconnection gracefully.
- Prevent stuck notes when changing destinations.
- Preserve Note Off routing to the destination that received Note On.
- Support standard CC and Pitch Bend transmission.
- Send timestamped MIDI events where supported.
- Do not use UI-thread timing for scheduled playback.
- Handle Stop/Panic coherently.

---

# 9. Shared musical transport

Extend the existing clock rather than introducing competing independent clocks.

The shared transport must support:

- Internal tempo.
- External MIDI clock.
- DAW host tempo where available.
- Start/Stop.
- Continue where supported.
- Musical beat position.
- Pattern looping.
- Arpeggiator grid synchronization.
- Pattern playback synchronization.
- Tempo changes.
- Transport position changes.
- Audio latency considerations.

Arpeggiators and sequencers must use the same musical timeline.

The transport should support reliable conversion between:

- Musical position.
- Audio frame position.
- MIDI event timestamp.

Use a clearly defined timeline origin and handling for discontinuities.

Do not accumulate timing drift through repeated rounded interval calculations.

## Scheduling accuracy

Aim for sample-accurate event scheduling where the destination and DSP interfaces permit it.

Maintain explicit sample offsets within audio processing blocks.

Respect the existing OberVave control-block timing limitations instead of claiming sample accuracy that the DSP cannot deliver.

If required, introduce a compatible event-offset adapter while retaining the current DSP behavior.

Handle:

- Variable host buffer sizes.
- Odd buffer boundaries.
- Tempo changes.
- Loop boundaries.
- Playback seeks.
- Clock interruption.
- Rapid Stop/Start.

The musical scheduler must remain independent of SwiftUI timers and dispatch delays.

---

# 10. Touch keyboard integration

Preserve the existing touch keyboard, channel colors, splits/layers interaction and KEY-LOCK functionality.

Do not redesign the keyboard as part of this task.

Integrate its event output with the common musical event processing layer.

The keyboard should be able to control:

- Internal synth instances.
- Shared arpeggiators.
- Pattern recording.
- External MIDI destinations.

## KEY-LOCK

Preserve the existing gesture and note/channel locking semantics.

A locked note must continue functioning as a held musical note for the arpeggiator.

Changing keyboard channel selection must not send Note Off to the wrong channel or destination.

Turning KEY-LOCK off must release the correct notes and update the arpeggiator's held-note state.

Maintain existing behavior when closing or reopening the keyboard.

## Explicitly deferred

Do not implement:

- Per-note pitch movement.
- Per-note pressure movement.
- Glissando redesign.
- Alternative keyboard layouts.
- New velocity gesture systems.

These belong to a later phase.

---

# 11. Real-time safety and concurrency

This is a critical requirement for all new code.

The audio rendering path must avoid:

- Heap allocation.
- Memory deallocation.
- Blocking mutex acquisition.
- File operations.
- Network operations.
- UI calls.
- Unbounded waiting.
- Uncontrolled container growth.

Prefer bounded queues and preallocated data structures.

Use the existing architecture for passing commands into the audio thread and retiring old objects outside it.

The pattern editor should produce validated state updates that are installed safely at audio processing boundaries.

Do not place SwiftUI ObservableObject operations inside DSP rendering.

Handle queue overflow explicitly and safely.

Avoid changing the current audio scheduling model unless necessary.

Do not introduce background worker threads solely for theoretical performance benefits.

### Real-time parameter control and state ownership

Preserve immediate, responsive real-time control of all synthesis and performance parameters during audio playback.

Sound-design operations, including oscillator settings, filters, envelopes, modulation matrix, effects, arpeggiator parameters and MIDI controller assignments, must remain editable while notes are sounding.

UI interactions and MIDI automation should deliver parameter changes through the existing thread-safe real-time control mechanisms whenever possible.

Do not introduce unnecessary buffering, debouncing, confirmation steps, transport stops or audible delays in parameter updates.

The UI must not directly mutate audio-thread-owned state in an unsafe manner. However, this restriction must not prevent live sound editing or real-time performance control.

Distinguish between:
- **Continuous parameter updates:** applied promptly at appropriate audio/control boundaries.
- **Structural changes:** such as replacing patterns, scenes or engine instances, which may require safe state swapping.
- **Musical events:** such as Note On/Off, controller changes and transport events, which must preserve their intended timing.

Reuse the existing parameter-control and event-queue architecture unless changes are demonstrably necessary.

Any new synchronization mechanism must preserve or improve existing control responsiveness, and must not introduce audible artifacts or regressions during live sound design.

---

# 12. Scene and pattern persistence

Integrate pattern data into the existing project/scene model without breaking existing files.

Requirements:

- Versioned serialization.
- Backward compatibility.
- Preservation of existing scenes.
- Safe default values for newly introduced settings.
- Rejection of malformed or unsupported data.
- Atomic file writing.
- Clear error reporting.
- No file I/O on the audio thread.

Consider separate reusable pattern files and references from scenes, but prioritize self-contained scene portability and predictable behavior.

Document the chosen storage model and its implications.

Do not silently drop unknown engine identifiers or incompatible pattern data.

---

# 13. Audio Unit considerations

The repository currently contains a macOS AUv2 implementation and an iPad standalone application.

Do not assume all platforms share the same rack implementation.

First inspect which functionality is genuinely shared.

The new musical event processor, arpeggiator and sequencer core should be reusable by future AU/AUv3/VST3 integrations.

For the current macOS AUv2:

- Preserve existing host transport synchronization.
- Preserve host automation compatibility.
- Preserve existing preset state.
- Avoid changing published parameter identifiers.
- Retain the currently validated synth behavior.

Integrate reusable features only where practical without destabilizing the existing AU.

Do not turn this task into an AUv3 or VST3 development project.

Document any platform-specific integration remaining.

Do not claim host MIDI output works until it has been tested with a host that supports it.

---

# 14. Testing strategy

Add automated tests for each major functional increment.

At minimum, cover:

### Musical event routing

- Correct MIDI channel routing.
- Multiple instrument destinations.
- Note On/Off pairing.
- Destination changes while notes are held.
- Duplicate-note handling.
- MIDI feedback prevention.

### Arpeggiator

- Every supported mode.
- Correct note order.
- Gate timing.
- Division.
- Octave expansion.
- Sustain.
- Latch Add/Replace.
- Hold Retrigger.
- Hold Legato.
- External clock synchronization.
- Start Grid.
- Tempo changes.
- Transport Stop and Panic.

### Sequencer

- Pattern creation and deletion.
- Recording input events.
- Recording arpeggiator output.
- Correct Note Off matching.
- Pattern looping.
- Quantization.
- Playback without re-arpeggiation.
- Pattern persistence.
- Scene backward compatibility.

### Timing

- Different audio buffer sizes.
- Block boundary events.
- Sample offsets.
- Loop wraparound.
- Transport seeks.
- Tempo changes.
- Rapid Stop/Start.

### External MIDI

Where automated testing is possible:

- Routing.
- Output event ordering.
- Destination change behavior.
- Note cleanup.
- Clock/timestamp propagation.

Use a mock MIDI output destination for portable tests.

Do not require physical MIDI hardware for core logic validation.

Keep hardware integration tests separately documented.

---

# 15. Implementation order

Follow this general dependency order, adjusting only when the actual codebase requires it.

## Phase A — Architecture and preparation

- Inspect current implementation.
- Document architecture and migration.
- Add baseline regression tests where necessary.
- Define shared musical events.
- Introduce routing infrastructure.

Commit each completed increment separately.

## Phase B — Shared arpeggiator

- Implement independent arpeggiator processor.
- Reproduce existing modes.
- Integrate with the shared transport.
- Add OberVave external-arpeggiator bypass.
- Add compatibility regression tests.
- Switch appropriate standalone routing to the shared arpeggiator.

Do not remove legacy code prematurely.

Commit each completed increment separately.

## Phase C — Sequencer and recording

- Implement pattern data model.
- Implement real-time pattern playback.
- Implement input recording.
- Implement post-arpeggiator output recording.
- Prevent double arpeggiation.
- Integrate pattern state with scenes.

Commit each completed increment separately.

## Phase D — External MIDI

- Add MIDI output backend.
- Add destination discovery and selection.
- Add routing options.
- Connect keyboard output.
- Connect arpeggiator output.
- Connect sequencer output.
- Test Note Off and Stop behavior.

Commit each completed increment separately.

## Phase E — UI

- Add pattern management.
- Add recording controls.
- Add Step Editor.
- Add Piano Roll.
- Add routing configuration UI.
- Integrate with existing OB1 navigation.

Commit each completed increment separately.

## Phase F — Integration and stabilization

- Cross-feature regression testing.
- Older-iPad performance evaluation.
- Verify external clock and DAW synchronization.
- Verify scene migration.
- Update documentation.
- Document deferred work.

Commit independent fixes separately.

---

# 16. Performance requirements

OB1 must remain usable on older supported iPads.

Do not assume abundant CPU or memory.

Avoid allocating full sequencer or MIDI-processing resources for all 16 instrument slots when unused.

Prefer lightweight inactive states and preallocated runtime capacity.

Benchmark representative scenarios:

1. One OberVave instance with arpeggiator.
2. Several instances with separate arpeggiators.
3. Several patterns playing simultaneously.
4. Simultaneous pattern recording and playback.
5. Multiple destinations, including MIDI output.
6. All 16 rack slots occupied.

Document measured results. Do not invent performance measurements.

Do not weaken real-time safety to gain UI convenience.

---

# 17. Completion criteria

The work is complete when the supported application can:

1. Continue operating as the existing 16-instance OberVave synthesizer.
2. Generate arpeggiated notes outside the DSP engine.
3. Preserve existing arpeggiator modes and behavior.
4. Record generated arpeggiator notes into a pattern.
5. Replay the pattern without the source chord or active arpeggiator.
6. Record ordinary MIDI keyboard performance.
7. Edit recorded patterns through Step Editor and Piano Roll.
8. Synchronize sequencer and arpeggiators with the shared transport.
9. Route MIDI events to internal instruments and supported external MIDI endpoints.
10. Preserve existing keyboard KEY-LOCK behavior.
11. Save and restore pattern/scene state correctly.
12. Pass the relevant automated regression tests.
13. Preserve compatibility with the existing Audio Unit.
14. Have every completed functional increment represented by its own meaningful Git commit.

## Final deliverables

Provide:

- Summary of architecture changes.
- Updated technical documentation.
- Description of the event routing pipeline.
- Description of the new arpeggiator and sequencer.
- Pattern file format documentation.
- External MIDI routing documentation.
- Test results.
- Known limitations.
- List of deferred features.
- **Chronological list of all implementation commits with SHA and purpose.**

Integration of additional synthesis engines is outside the scope of this delivery.

---

# 18. Working instructions

Proceed autonomously through the implementation where the requirements and current code are clear.

Do not stop after writing a plan.

Do not ask for approval for ordinary implementation details.

However, preserve existing behavior and avoid destructive repository operations.

If a requirement conflicts with the existing architecture or would break saved user data, document the conflict and choose the least disruptive compatible solution.

Do not silently remove existing features.

Keep code comments in English.

After each completed feature, run its relevant tests and create its individual Git commit before proceeding.

**Begin by inspecting the current `master` implementation, verifying the working tree and preparing the implementation plan. Then implement the features incrementally with separate commits.**