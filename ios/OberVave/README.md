# OberVave for iOS

The app icon uses cyan **OB** lettering on a dark synth-panel background.
Its opaque PNG resources are in `AppIcons`, registered for iPhone and iPad
through `Info.plist` (without requiring the asset catalog compiler).
Regenerate them on macOS with
`swift ios/OberVave/GenerateAppIcon.swift` from the repository root.

## Firmware source and licensing

The required OberVave DSP source subset is vendored in `../../fw/obervave/` from
<https://github.com/zvenson/obervave>, commit
`a1f660c4439583d33f72941bd184a7e187d11835` (version 3.5.2), with local
native-engine, timing and audio-block adaptations. It is included as ordinary
files so a fresh clone contains these adaptations without a separate checkout.
OberVave and the native ports are GPL-3.0-only; the upstream license,
attributions and third-party notices are preserved in
`../../LICENSE` and `../../fw/obervave/LICENSING.md`.
Hardware firmware, the emulator and the old benchmark app are not required
and have been removed. The original emulator's MIT notice is preserved in
`../../LICENSE-FM1-EMU`.

## Scenes and multitimbral rack

CoreMIDI ports and custom Bluetooth MIDI peripherals have separate runtime
connection IDs. CoreMIDI running status and incomplete messages are parsed
independently per connection, so interleaved inputs cannot complete one another's
messages. Reconnecting creates a fresh ID/parser. A disconnected source's
pending scheduled MIDI is cancelled and its captured physical keys/pedals are
released on the audio thread, without stopping other sources. Equal pitches
from different devices or the screen keyboard remain held until the final
owner releases. Pedals are independently aggregated, retaining the existing
polarity/hysteresis. Intentional Latch and other connected pedals can keep
notes sounding after a source disconnect; this is not global Panic.

Channel/zone edits apply immediately to new notes without cutting held notes:
their releases and pedal-up return to the original instruments. Scene, program
and slot replacement clear old ownership instead of transferring it to a new
instrument. Runtime ownership is bounded; overflow reports an error and stops
notes safely. MIDI Clock is unchanged.

Each standalone instrument now runs the extracted musical-event arpeggiator
outside the voice DSP, with generated notes using the native direct-voice
entry. The existing ARP modes, Latch, Sustain, controllers, start grids and
signed live compensation are preserved. Off-mode Mono/Unison key fallback is
also preserved. Legacy audio/RNG and production 16-instrument regressions are
documented in [the arpeggiator integration contract](../../docs/ARPEGGIATOR.md).
The AU retains its separate legacy scheduler for now; this does not add
pattern recording/playback or external MIDI output.

The top header contains a **square Stop icon** next to Tempo, grouped as the
global transport panel for future sequencer controls. It stops all instruments'
playback on one audio boundary, releases direct/ARP/Chord/Hold notes despite
Latch or Sustain, clears screen Key-Lock notes and cancels already scheduled
MIDI playback. It does not change modes, patches, tempo, sync or mixer settings.
Release envelopes and chorus/delay/reverb tails continue naturally; effects
are neither reset nor muted. New live input after Stop plays immediately.
There is no sequencer or external MIDI Stop transmission yet.

LFO Rate displays Hz to two decimal places, calculated from the DSP phase
increment table and the 44.1 kHz / 16-sample control rate. The parameter's
0-127 scale is nonlinear; correcting the readout does not change saved sounds.
All LFO controls are on **LFO / MOD**, not split between OB-1 and MORE:
waveform, rate, delay, phase, pitch/PWM depths and oscillator targets,
cutoff/volume depths, Legacy Wheel depth/switch, and the modulation matrix.
The controls at the top use the parameter's 0-127 scale (not a linear physical
percentage); the matrix below uses signed percentages. The page scrolls as
one unit and the control panels wrap to fit the available width.
PWM warns when a targeted oscillator has no pulse wave enabled.
With **Legacy Wheel** enabled (the default), Mod Wheel/CC1 independently adds
the same LFO to both oscillators' pitch and filter cutoff; it is not a master
scaling control for PWM or tremolo.

### Modulation matrix

The matrix on **LFO / MOD** provides eight independent routes per instrument. Each row has
editable SOURCE, DESTINATION and signed DEPTH (-100% to +100%). ZERO centers
the amount; RESET clears that row; CLEAR MATRIX clears all rows after confirmation
without changing the original patch modulation or the Legacy Wheel switch.

Sources: LFO, Mod Wheel/CC1, Velocity, Aftertouch, Filter Env, Amp Env, and
LFO x Wheel. Aftertouch uses channel pressure, with polyphonic key pressure
overriding it for the corresponding note. MIDI sources follow the instrument's
channel; raw CC1 remains a source even if its knob mapping is removed.
LFO (including per-voice phase/delay) is bipolar; wheel, velocity and envelopes
are unipolar. LFO x Wheel scales the LFO by the physical/on-screen wheel.

Any source can target OSC 1/2 pitch (24 semitones per route at full depth),
OSC 1/2 PWM (about 47 percentage points of pulse width), cutoff (96 semitones),
resonance (127 parameter units), volume (100% of envelope-scaled gain) or pan
(64 pan units). Negative depth reverses the effect. Routes add before clamping
to the destination's safe range. Volume modulation cannot bypass the amp
envelope; PWM requires a pulse wave and shows a warning otherwise.
Multiple routes may share a destination.

Existing dedicated LFO/envelope/velocity controls remain additive. Turn off
**LEGACY WHEEL -> PITCH + CUTOFF** when assigning CC1 freely to avoid the old
fixed vibrato/filter sweep. The original LFO-depth knobs still apply.

All routes and Legacy Wheel are saved in user presets and scenes. Old
65-parameter scenes/presets initialize the new routes to OFF with neutral
depth and keep Legacy Wheel ON, preserving their prior sound. New matrix
parameters have no automatic CC assignments. Scene JSON arrays now have 202
parameters/CC entries; old application versions cannot load new scenes.

### Controllers

**CONTROLLERS** provides 16 routes per instrument, saved in presets and scenes.
Inputs are CC0-127, 14-bit Pitch Bend, Channel Aftertouch and Poly Aftertouch.
Targets are all 65 original sound parameters, including envelopes, effects,
LFO and arpeggiator settings (not master mixer or routing configuration).

- **VALUE** writes the parameter through **MIN/MAX**, expressed as percentages
  of its full range. MIN greater than MAX reverses the response. VALUE changes
  are stored as the new base parameter values.
- **MOD** adds **DEPTH** (-100% to +100% of the full target range) without
  overwriting the base value. ZERO centers depth; disabling the route removes
  the offset. Multiple offsets sum before clamping. CC/pressure are unipolar;
  Pitch Bend is bipolar with an exact center. Discrete outputs use integer
  parameter steps. Envelope time/sustain changes follow the engine's normal
  segment/note update rules.
- Poly pressure MOD is per-note for voice parameters; shared effects, LFO and
  arpeggiator parameters use the last received pressure. Poly VALUE always
  writes the shared base parameter. A new Note On resets that note's pressure.
- **OVERRIDE** explicitly bypasses the input's old assignments/native action.
  For CC1 it also suppresses legacy vibrato/cutoff, but raw wheel/pressure
  remain available to matrix/custom routes. Without OVERRIDE, mappings coexist.
  This includes service CCs (bank, sustain, volume and panic/reset); use with
  care. Notes, Program Change, transport and the on-screen PANIC are unchanged.
- **LEARN** listens for the first controller on this instrument's MIDI channel,
  ignoring notes. It cancels after 15 seconds, on navigation/instrument selection
  changes, or with CANCEL. RESET resets one route; RESET ROUTES confirms before
  clearing all routes, preserving sound values and existing CC assignments.

Example: CC1 / MOD WHEEL -> LFO Rate, MOD, DEPTH +25%, OVERRIDE on. The wheel
then raises rate by up to a quarter of its parameter range, without the original
vibrato/cutoff action. Use VALUE with a narrower MIN/MAX to set absolute limits.
The existing per-preset CC assignments are also editable in this tab.
Old 65- and 90-parameter scenes/presets receive disabled controller routes.

In **MIDI Connections > Sustain Pedal**, **Invert Sustain polarity** supports
pedals/keyboards that send CC64 0 on press and 127 on release. Normal is the
default. After polarity correction, values 96-127 arm pedal-down and 0-31
release it; 32-95 retain the prior state (hysteresis). An UP without a preceding
DOWN does not clear Latch. State is independent per MIDI channel.
The last incoming raw CC64, MIDI channel and
interpreted DOWN/UP state are shown live, even with the connection sheet open.
Latch must survive DOWN and clears released notes only on DOWN-to-UP.
The polarity setting is saved on this iPad, applies to all channels, and is
not part of scenes or the AU. After changing it with notes released, cycle
the pedal once; the new interpretation applies to subsequent pedal messages.

The arpeggiator mode menu includes **CHORD**, **HOLD RETRIGGER** and
**HOLD LEGATO** in addition to
Up/Down/Up-Down/Random/Played. Chord triggers all chord notes together on
each rhythmic step, following Division, Gate, Octaves and first-note Master
Sync. Polyphony remains limited by the patch's voice mode and eight voices.
Both Hold modes play the chord continuously, without Gate/Division retriggers or octave
expansion. Its first chord follows first-note Master Sync; subsequent Note On
events immediately replace released notes with the keys physically down at
that moment plus the new key, even when Latch is Add. With Latch or Sustain
enabled, released keys continue sounding until a new key, Latch Off or Sustain
release; physically held keys remain. Without either, keys release normally.
Latch Off clears released Hold notes even if the pedal is still down.
**Hold Retrigger** restarts all chord notes on every chord update.
**Hold Legato** releases only removed notes and triggers only added notes;
common notes keep their voices, oscillator/filter state and envelopes, including
on Sustain release or Latch Off when some keys are still physically held.
The usual eight-voice limit and patch voice mode still apply.
The original saved Hold mode retains value 7 and means Hold Retrigger;
Hold Legato is appended as value 8. Both persist in scenes and user presets.
The default remembered Latch mode is **Replace** (Latch is not enabled
automatically). Explicitly saved Add selections remain Add. Existing arp mode
numbers are unchanged; Chord and Hold are appended and saved with scenes.

Saving waits for an audio-thread snapshot using a model-owned timer that
continues while the scene editor is presented. A progress indicator is shown
while editing is briefly disabled. Success or file-write failure unlocks the
editor; if audio does not provide a snapshot within five seconds, an explicit
error is reported and editing is restored.

The top **Scenes & Instruments** button opens the rack. A scene contains zero
to **16 independent synth instances**. **Add Instrument** allocates an OberVave
instance, initially on the first unused MIDI channel. Before adding it, choose
its name, channel (1-16), inclusive low/high MIDI notes, mixer level and pan.
**Edit** changes those settings later; **Remove** unloads that instance.
The keyboard zone editor shows the full MIDI keyboard (0-127) above a range
bar. Drag LOW/HIGH markers to the corresponding key positions; both endpoints
are inclusive and cannot cross. The channel color highlights the selected
range. **LEARN LOW / LEARN HIGH** arms a one-shot learn for the next external
Note On on that instrument's MIDI channel, including notes outside its current
zone. Note Off, zero-velocity Note On and on-screen keys do not trigger learn.
The note still reaches normal synth routing. Tap the active learn button to
cancel; closing the editor or changing channel also cancels it. Changes remain
a draft until **Add / Apply**; **Cancel** preserves the original routing.
Multiple instances may use the same channel and overlapping note ranges:
outside the overlap they form a split, inside it they form a layer.
Changing channel/range releases that instance's old held notes to avoid stuck
notes. Sustain, pitch bend, bank/program changes and CC maps follow the MIDI
channel; note ranges filter Note On, not controllers or needed Note Off.

Select an instrument in the top menu (or tap its name in the rack) to edit it
with the OB-1/MORE/EFFECTS/LFO / MOD/CONTROLLERS panel and preset library. Each instance has
its own eight voices, FX buffers, sound, CC map, ARP/Latch state, division,
Master Sync and Start Grid. The master clock, MIDI connections/input buffer,
audio device, latency compensation and master output are shared. Updating or
removing one instrument does not restart the others. MIDI Stop and PANIC
release every instance, preserving normal effect tails.

The scrollable left-hand instrument tabs provide direct access to every
instance with compact channel-number-only buttons. The bottom **+** button
opens the Add Instrument dialog directly (disabled at 16 instances).
The selected tab grows slightly and moves right. Each tab's
illumination follows that instance's stereo audio peak after its own level,
pan and mute (including FX tails, before the shared master output).
Brightness uses a -60 to 0 dB range with a short visual decay while retaining
the channel's color. Selection remains visible when the instrument is silent.

The on-screen keyboard has **16 channel buttons**. Cyan buttons are active;
any combination, including none, is allowed. Keys, pitch and modulation are
sent to every active channel and then pass through the same zone/layer router
as external MIDI. Releasing a key sends Note Off to its original channels,
even if the channel buttons changed while it was down.

**Save Scene** writes the complete configuration, not references to mutable
presets: sounds, remembered disabled ARP/Latch modes, channel/zones, CC maps,
per-instrument mixer/arp settings, tempo, master level/pan, selected editor
and keyboard channels. **Save As New** creates another file; Save updates the
loaded local file. **Saved Scenes** loads a scene after confirmation. **New
Scene** starts an empty rack. Scene loading replaces voices/FX rather than
seamlessly crossfading them, and does not restore sounding/held notes.
Scenes are versioned `.obscene.json` files in
**Files > On My iPad > OberVave > OberVave Scenes**. Use **Import Scene from
Files** or the share button to transfer them. Invalid versions, unknown engine
IDs and malformed/out-of-range configurations are reported without replacing
the current scene. Scene files are written atomically after an audio-thread
snapshot; they include pending UI parameter edits in FIFO order.

The mixer uses floating-point summation without automatic gain changes when
instances are added. Reduce individual levels or the AMP master level to
leave headroom for layers; red output meters indicate overload. Sixteen
instances are a capacity limit, not a guarantee of 128-voice realtime playback
on every iPad. CPU load depends on polyphony and FX. Mute silences a mixer
strip but continues its DSP; remove unused instruments to reclaim resources.

### Engine integration

`SynthRack.cpp` owns the shared clock, timestamp queue, MIDI routing, scene
lifecycle and stereo mixer. Its `SynthEngine` contract separates rendering,
parameters, MIDI, transport and sync from the shell; the `engines` registry
maps stable engine IDs to factories. `OberVaveEngine` adapts the same
non-copyable firmware `Engine` in `native/OberVave/Engine.h` used by the AU, with independent DSP state per
instance. Add future engines via this contract and registry, then supply their
parameter/state schema and editor (the current parameter schema/editor is
OberVave-specific). Unsupported IDs are rejected, never substituted.

Engines and complete scenes are allocated before enqueueing their installation.
The audio thread swaps ownership at control boundaries, without allocation,
deallocation, file access or mutex acquisition. Replaced instances/scenes are
reclaimed on the main thread. Scene persistence is separate from the audio
implementation in `SceneState.swift`; `RackScenes.swift` contains scene UI and
model integration. The standalone rack, transport and scene-file regressions
are included in the native AU CMake/CTest project, including Swift Codable
roundtrips against the production iPad core.
The engine adapter clears its output bus before each render: firmware mixing
is additive, so reusing uncleared caller memory introduces signal-correlated
noise. Regression tests compare clean and deliberately contaminated buffers
through silence, note playback and release.

## Arpeggiator output latency

In **MIDI Connections > Arpeggiator Audio Compensation**, automatic compensation
(enabled by default) estimates output delay from iOS `outputLatency` plus
`ioBufferDuration`, updating when the audio route/configuration is refreshed.
Manual correction is additive, from -500 to +500 ms in 0.1 ms steps, with a
numeric entry and reset button. Both settings persist across app launches.
Positive compensation advances the rhythm; negative compensation delays it.
MASTER SYNC must be enabled. Changes also shift already playing arpeggios by
the difference in compensation, so manual correction can be adjusted by ear.
The phrase is not restarted or re-quantized to the bar. A large backward change
postpones the next step; a large forward change emits at most one new note per
control tick instead of a burst of missed steps. Subsequent steps keep the new
offset and continue at the selected tempo and division.

For external timestamped MIDI Clock, the configured MIDI INPUT BUFFER is also
advanced out of the clock phase. This does not remove BLE arrival jitter or
allow a note received after its compensated boundary to play in the past: it
waits for the next grid line. The estimate does not measure USB/DAW buffering,
the synth patch's attack, or the complete acoustic path. Use the manual
correction to account for remaining delay by ear or from a recording.

For the separate native macOS AUv2 instrument for Logic Pro, see
[OberVave AU](../../native/OberVaveAU/README.md).

This prototype runs OberVave's existing C synthesizer directly on iOS. It does not emulate the
FM-1 processor or its hardware.

The app includes the native audio engine, the factory programs, an OB-1-inspired control panel,
an optional expandable on-screen keyboard, CoreMIDI input for USB MIDI, and a Bluetooth MIDI device
browser. The main OB-1 panel, OberVave extensions, and effects each occupy a full-screen swipeable
tab. Continuous parameters use rotary controls; two-state parameters use toggle buttons, while
selectors with three or more choices open an option menu. Bluetooth MIDI input is received
directly through the BLE MIDI GATT characteristic; both routes send note events to the existing
OberVave voice engine. Audio is rendered at 44.1 kHz by an `AVAudioSourceNode`.
Timestamped Bluetooth and CoreMIDI input events are scheduled on the audio timeline instead of
being applied together at the next render callback. The MIDI Connections screen provides a saved
0–50 ms input buffer (20 ms by default); increasing it gives delayed packets more scheduling
headroom at the cost of note latency.
Incoming MIDI data and on-screen performance controls disable the iOS idle timer; normal automatic
sleep is restored after two minutes without activity or when the app leaves the foreground.
Global tempo (40–240 BPM) is available on every page and drives tempo-synced modules, currently the
arpeggiator and delay. It follows incoming MIDI Clock (24 pulses per quarter note), including MIDI
Start/Continue reset. Clock tempo is median-filtered across recent quarter measurements and smoothed
to reject packet-arrival jitter; phase follows a gently corrected clock estimate rather than snapping
to each received pulse. On MIDI Stop or clock timeout, the last filtered external BPM is retained as
the new internal tempo. Tap Tempo averages all valid beat intervals in the current tap series; the
series resets after a pause longer than two seconds or an out-of-range interval.
Tap Tempo and the current BPM share the upper control row; tapping the BPM opens a slider and numeric
editor (40–240 BPM). A square AMP panel sits alongside the synth control blocks, with level and
stereo pan knobs, vertical left/right three-color output meters, and a vertical column of eight
per-voice envelope dots. Output meters read the post-mixer stereo signal; voice dots shift from
green through yellow to red as each voice's envelope level rises. Master level (0 dB to mute at
-48 dB) and pan are independent of the selected patch's volume and stereo settings.
To reduce realtime CPU load on complex polyphonic patches, the iOS build runs the reverb tank at
half rate and interpolates its output; oscillator anti-aliasing remains enabled.
The arpeggiator offers independent latch modes: Off, Add (released notes remain and new notes join
them), and Replace (released notes keep playing until the next note is pressed; then released notes
are discarded while still-held notes remain in the chord). Updating a latched chord does not restart
the current rhythmic phase.
Large ARP and LATCH buttons independently enable each feature (cyan when on,
dark when off). Their menus choose the arp algorithm or Add/Replace latch
mode without enabling a disabled feature. The selected mode is recalled when
re-enabled and is included when saving a user preset, even when disabled.
Releasing Sustain clears released notes from the latched chord without turning
Latch off. If no keys remain physically held, the arpeggio stops and its next
phrase is rearmed; otherwise it continues on the held keys without restarting
its rhythmic phase. Normal release and effect tails are preserved.
Incoming MIDI Stop (FC) releases all notes and clears all held/latched arpeggio
chords, including pending scheduled notes. Latch/ARP settings stay enabled,
but MIDI Clock or Start/Continue alone cannot restart a cleared chord; new
notes are needed. Release and effect tails decay normally. A master device
must send MIDI Stop, not merely stop transmitting clock; MMC SysEx is not
currently interpreted.
The arpeggiator's Velocity control uses the played keys' velocities at 0; values 1–127 set a fixed
velocity for every arpeggiated note. The ARPEGGIATOR panel's MASTER SYNC switch optionally aligns
the first arp note to the global tempo grid (internal tempo or incoming MIDI Clock); when enabled, newly
played notes wait for the next START GRID line. Choose 1/1, 1/2, 1/4, 1/8, 1/16, or 1/32 to
quantize only the first arp note; subsequent steps advance continuously at the master tempo using
ARP DIVISION, without re-aligning to beats or bars. Start quantization is rearmed after all
held/latched notes are cleared. Both sync
settings belong to the selected instance and are included in scenes.
MIDI pitch bend, sustain (CC 64), master volume (CC 7), panic (CC 120/123), and the OberVave
parameter CC map are handled on the audio thread. The six preset banks (A–F) each contain 128
programs. Bank Select uses the standard 14-bit CC 0/32 value; Program Change selects programs
1–128 in the UI (MIDI values 0–127). Bank A contains the factory programs; other empty slots use
the INIT sound until saved. Save replaces the current slot, New Preset chooses a bank and program,
and the reset action restores a factory program or clears a user slot back to INIT.
The MIDI MAP mode shows each control's assigned CC. Tap a control to learn the next incoming CC,
tap it again to cancel, double-tap to restore its default CC, or triple-tap to unassign it. Tap a
CC badge to choose a CC manually; one CC may control multiple parameters. User preset sounds and
CC assignments are saved locally and independently per program.
Factory parameter assignments include mod wheel (CC 1), glide (CC 5), cutoff (CC 74), resonance
(CC 71), attack (CC 73), and release (CC 72); remaining parameters use sequential assignments
starting at CC 20.
The on-screen keyboard opens as a compact bottom overlay (280-360 points tall,
adapting to the available height), with only 4-point top/bottom padding.
Keys fill the space below its controls rather than leaving unused vertical bands.
It uses the full screen width for its keys, with the
vertical pitch-bend and modulation wheels in a column on the left. It can display one to eight
octaves at a time, with horizontal scrolling when the selected range is wider than the screen.
Octave transpose buttons shift the displayed keyboard range up or down.
The iPad keyboard retains its transpose position and displayed octave count
when closed and reopened during the current app session.
The displayed range includes the next octave's C at the right edge, with no
duplicate C keys between octaves; transpose limits include this final note.
**KEY-LOCK** is off by default. When enabled, swipe down at least 20 points
and beyond the pressed key's lower edge within 0.45 seconds to hold that note
after lifting the finger. Touch that key again and lift the finger to release
it, without retriggering; the note keeps sounding throughout the touch.
A permanent 40-point strip below the keys provides room for the downward
gesture to finish above the physical screen edge, inside the existing overlay.
**RELEASE CHANNEL** clears keyboard locks on all selected MIDI channels;
**RELEASE ALL** clears keyboard locks across all channels. Both preserve the
KEY-LOCK toggle and send normal Note Off messages, without a synth/transport
reset. They are hidden when KEY-LOCK is off and disabled when there are no
applicable locks. Hiding them does not change the key height.
Locked notes remain highlighted across keyboard closing/reopening, scrolling
and transposition. Each MIDI channel has a fixed color shared by the instrument
sidebar, keyboard channel buttons, held keys and locked-note squares.
The sidebar's audio level changes the brightness without changing channel color.
Keys held on multiple active channels show side-by-side color bands.
A separate channel-colored strip on a dark backing at each locked key's
lower edge confirms KEY-LOCK immediately when the swipe succeeds, before
finger-up. It remains until unlock and is absent on ordinary held keys.
The strip shows locks on all channels, including unselected channels.
Multiple channel locks split the strip into their channel colors; only the
key's full-height highlighting is filtered by the selected channels.
Notes outside the visible viewport appear as small colored note-name squares
below the keys, one per active note/channel pair; tapping a square releases only
that pair, preserving the same pitch locked on other channels.
Turning KEY-LOCK off releases all keyboard-locked notes. PANIC, MIDI Stop and
scene replacement clear the locks; locks are live performance state, not saved
scene data. Note Off uses the channels captured at Note On, even after changing
the keyboard's channel buttons. Locks belong to individual note/channel pairs.
Highlighting and hidden-note squares show only locks on the keyboard's active
channels. Playing or releasing the same pitch on another channel leaves
inactive-channel locks sounding. A touch captures its channel selection until
finger-up; with several channels active, only their locks are released.
Turning KEY-LOCK off releases its locks across all channels.
Synth Sustain and ARP Latch still apply to
these Note Off messages normally; KEY-LOCK does not disable either feature.
The wheels send MIDI pitch bend and CC 1;
pitch bend returns to center on release, and both wheels reset when the keyboard closes.

The synth sources in `../../fw/obervave/firmware/src/` are included under GPL-3.0-only. The iOS
bridge intentionally starts with the sound engine and omits the FM-1 panel, flash storage, and
sequencer UI; those can be ported in later steps.

## Build and run

Open `OberVave.xcodeproj`, select an iPad or iPhone, choose a development signing team, then build
and run. Tap **MIDI Devices**, choose **Find Bluetooth MIDI**, and select **Connect** beside the
instrument. Put the instrument in Bluetooth pairing mode while scanning. USB MIDI sources are
connected automatically and are listed in the same MIDI connections screen. A Bluetooth device is
shown as connected only after OberVave subscribes to its BLE MIDI input characteristic. The
connection screen lists CoreMIDI input names and active BLE MIDI inputs.

## USB external instrument for a Mac DAW

Use macOS Inter-Device Audio and MIDI (IDAM). The USB Audio/MIDI interface is provided by
iPadOS/macOS, not by a custom USB driver in OberVave. This is not a generic USB peripheral mode
for Windows and does not require an Audio Unit plugin.

1. Connect iPad to Mac with a USB data cable. Unlock iPad and accept the trust prompt if needed.
2. On Mac, open **Audio MIDI Setup**, show **Audio Devices**, select iPad and click **Enable**.
   This step must be performed on Mac; OberVave cannot enable IDAM remotely.
3. Open OberVave. Under **MIDI Connections → USB DAW / Audio (IDAM)** check the current
   audio output, hardware format and engine state. The app follows the system output route
   and resumes the audio engine after route/configuration changes. Its synth remains at
   44.1 kHz internally; AVAudioEngine performs output sample-rate conversion when needed.
4. In the DAW, select the iPad MIDI destination for an external-instrument/MIDI track.
   OberVave automatically connects available CoreMIDI sources and accepts notes, pitch bend,
   CC, Bank/Program Change and MIDI Clock. No MIDI echo back to the DAW is enabled.
5. Select iPad as the DAW audio input and its stereo input pair as the instrument return.
   If the DAW requires one device for both recording and monitoring, create an Aggregate Device
   in Audio MIDI Setup combining iPad and your regular audio interface. Use the regular
   interface as the clock source and enable drift correction for iPad.
6. Enable input monitoring/recording for the stereo return. Send MIDI notes from the DAW;
   the AMP meters should respond and the return track should receive stereo audio.
   For arp sync, also enable the DAW's MIDI Clock output to iPad and MASTER SYNC in OberVave.

The playback audio session supports background audio, so switching away from OberVave or
locking iPad does not intentionally stop the instrument. System interruptions may pause audio;
the app resumes when iPadOS permits it. Use **Refresh Audio / Resume** if manual recovery is needed.
The existing **MIDI INPUT BUFFER** also applies to CoreMIDI/IDAM: lower it toward 0 ms for
USB playing latency, or compensate its configured delay in the DAW's external-instrument settings.
Only the iPad-to-Mac stereo audio return is used; incoming audio from the DAW is not processed.

macOS setup reference: [Set up audio devices in Audio MIDI Setup](https://support.apple.com/guide/audio-midi-setup/ams59f301fda/mac).
