# Native OberVave Audio Unit

OberVave AUv2 is a stereo software instrument for macOS 13 or later. It runs the
OberVave C synthesizer directly, without emulating the FM-1 CPU.

## Build, test and install

Requires Xcode command-line tools, CMake 3.21+ and Ninja. From the repository root:

```sh
ARCH=x86_64 tools/build_obervave_au.sh
```

The script builds a Release component, signs it ad hoc, runs the integration
tests, installs it to `~/Library/Audio/Plug-Ins/Components/OberVave.component`,
and runs Apple's AU validator. Existing FM-1 components are not changed.
`NO_INSTALL=1` skips installation and system AU validation.
`SIGN_IDENTITY` optionally selects a signing identity.

The build downloads the Apple AudioUnitSDK at the commit pinned in
[CMakeLists.txt](CMakeLists.txt). `AUDIOUNIT_SDK` can point to an existing SDK
checkout for an offline build. No emulator or Rust build is required.
`BUILD_DIR` overrides the default `target/obervave-au` output directory.

## Logic Pro

The shared panel's LFO Rate readout uses the actual DSP phase increment,
displayed in Hz to two decimal places, not a linear conversion of MIDI values.
Existing parameter values, automation and sounds are unchanged.
All LFO controls are grouped on **LFO / MOD**: waveform, rate, delay, phase,
pitch/PWM depths and oscillator targets, cutoff/volume depths, Legacy Wheel
depth/switch, and the matrix. OB-1 and MORE no longer contain separate LFO
blocks. The page scrolls as one unit; its top control panels wrap to fit.
PWM warns when its target has no pulse wave. Controls follow host automation
and MIDI updates; moving them does not change parameter IDs or sounds.

The **LFO / MOD** page includes a fully editable eight-slot matrix shared with the iPad app,
not only a routing display. Choose each route's source/destination and depth
from -100% to +100%; ZERO centers depth, RESET clears one route and CLEAR MATRIX
clears all routes after confirmation. Sources are LFO, Mod Wheel/CC1, Velocity,
Aftertouch (channel or per-note poly pressure), Filter Env, Amp Env, and
LFO x Wheel. Destinations are OSC 1/2 pitch, OSC 1/2 PWM, cutoff, resonance,
volume and pan. The LFO source respects its voice phase and delay.
LFO x Wheel provides wheel-controlled LFO depth. Other wheel/envelope sources
are unipolar; negative depth reverses their effect. Routes sum with the existing
patch modulation. Per-route full-depth ranges are 24 semitones for pitch,
about 47 percentage points for PWM, 96 semitones for cutoff, 127 resonance
units, 100% envelope-scaled volume and 64 pan units. PWM needs a pulse wave;
volume cannot bypass the amp envelope.

Disable **LEGACY WHEEL -> PITCH + CUTOFF** for freely assigned CC1 without its
original fixed vibrato/filter sweep. This switch defaults ON for compatibility.
All eight routes and the switch are exposed to host automation and included
in AU project/preset state. Existing parameter IDs 0-71 are unchanged; matrix
triplets (source/destination/amount) occupy 72-95 and Legacy Wheel is 96.
Amount is stored as 0-128, with 64 neutral and endpoints -100%/+100%.
Loading an older preset clears the new routes and restores Legacy Wheel ON
even if this instance previously had a custom matrix.

### Controllers

The shared **CONTROLLERS** tab adds 16 freely assignable routes: CC0-127,
14-bit Pitch Bend, Channel Aftertouch and Poly Aftertouch can target any of
the 65 sound parameters (including LFO, envelopes, effects and arpeggiator).
**VALUE** writes a parameter through MIN/MAX percentages, including inverted
ranges. **MOD** adds a signed DEPTH (-100% to +100% of the full parameter
range), preserving the base value; ZERO centers depth. Offsets sum and clamp.
Bend MOD is bipolar with an exact center; CC/pressure are unipolar.
Discrete outputs use integer steps. Envelope settings follow normal engine
segment/note updates. Poly MOD is per-note for voice settings; global FX/LFO/arp
use the last pressure. Poly VALUE updates the shared base value.

**OVERRIDE** bypasses the input's fixed/native action and old CC assignment,
including CC1's legacy vibrato/filter sweep. Raw wheel/pressure still feed
matrix routes. Without OVERRIDE, original and custom assignments coexist.
Override service CCs (sustain, volume, panic/reset) only deliberately; notes,
Program Change, DAW transport and the editor PANIC are not remapped.
**LEARN** captures the first incoming controller, not a note, with a 15-second
timeout and CANCEL. The AU listens on all MIDI channels as before.
RESET clears one route; RESET ROUTES asks for confirmation and preserves
sound values. For example, CC1 -> LFO Rate / MOD / DEPTH +25% / OVERRIDE on
redirects the wheel from vibrato to the LFO rate.

All 112 route fields are automatable at IDs 97-208; IDs 0-96 remain unchanged.
Routes persist in AU projects/presets. Older states clear the new routes.
Program selection resets routes to the selected program's defaults.

Restart Logic after installation. Create a **Software Instrument** track and
select **AU Instruments > OberVave > OberVave > Stereo**. If it is not listed,
use Logic's Plug-in Manager to rescan OberVave.

Select **Editor**, rather than **Controls**, in Logic's plug-in window to use
the iPad-style OB-1 panel. It uses the same SwiftUI control/layout definitions
as the iPad app: **OB-1**, **MORE**, **EFFECTS**, **LFO / MOD**, and **CONTROLLERS** tabs, rotary knobs, option
menus, the AMP panel with stereo meters and eight voice LEDs, and an expandable
on-screen keyboard with pitch/modulation wheels. The minimum editor size is
1100 x 760 points; control panels scroll when necessary.

The Factory Program menu selects a factory sound; all patch
parameters, master volume/pan, arpeggiator master sync and start grid are
available to the host. Knob drags send begin/change/end automation events.
Host automation, MIDI CC changes and restored projects update the visible
controls. Project/preset state includes edited patch values,
not just the factory program number. Each instance has independent voices,
patch data and effects. **SAVE** and **LOAD** use standard `.aupreset` files.
The host's own preset/project saving remains available. **PANIC** sends
all-sound-off to this instance.
The ARPEGGIATOR panel has separate large **ARP** and **LATCH** enable buttons:
cyan means enabled and dark means disabled. The menus below them choose the
arp algorithm or Add/Replace latch mode without changing the enable state.
Re-enabling recalls the selected mode. Selected modes are saved even when
disabled, using two appended AU parameters; existing parameter IDs and old
project/preset compatibility are preserved.
The arp menu also provides **CHORD** (all notes together on each rhythmic step,
with Gate and Octaves), **HOLD RETRIGGER** and **HOLD LEGATO** (continuous chord, no periodic retrigger or
octave expansion). Hold replaces released notes on each new Note On, retaining
the keys still physically held, independently of Add/Replace. Latch or Sustain
keeps released Hold notes sounding; Latch Off or Sustain release clears those
released notes. Latch Off does so even while Sustain is down.
First-note Master Sync applies to both modes. Existing mode values are preserved.
Hold Retrigger restarts every note when the chord changes; Hold Legato preserves
common voices and envelopes, releases removed notes and triggers only additions.
Sustain release and Latch Off also preserve common physically held notes in
Legato mode. The patch voice mode and eight-voice limit still apply.
The old Hold value 7 remains Hold Retrigger; Hold Legato is appended as value 8.
Both are exposed to host automation and saved in AU presets/project state.
The default remembered Latch selection is Replace, without enabling Latch;
explicitly saved Add settings are retained.
Switching Latch to Off clears released, latched notes and stops their arpeggio
(with the patch's normal release/effect tails). Physically held keys or notes
held by the sustain pedal continue normally.
Releasing Sustain (CC64) clears released notes from the latched chord without
disabling Latch. With no physically held keys the arpeggio stops and rearms for
the next phrase; otherwise it continues using only the held keys without
restarting its rhythmic phase. Normal release and effect tails are preserved.

Stopping the DAW transport releases every sounding note, clears held/latched
arpeggio chords and discards pending MIDI notes. Latch/ARP enable settings and
selected modes are retained; playback cannot restart the old chord. Release
and effect tails decay normally. Live keyboard input remains available while
the transport is stopped. Transport detection requires the host's AU transport
callback (as provided by Logic).
Starting playback does not reset voices or effect tails. AU Reset, which hosts
can issue when starting their render timeline, clears pending host MIDI events
but preserves the running synthesizer, effect buffers and resampler history.
An actual playing-to-stopped transport transition still releases notes as
described above; initializing a new audio configuration resets the DSP.

MIDI notes, channel/polyphonic aftertouch, modulation wheel, pitch bend, sustain, CC7, all-sound/all-notes-off, factory Program
Change and the firmware's fixed CC assignments are supported. The iPad's
custom MIDI Learn mappings and saved user-bank library are not imported.
Unlike the standalone iPad app, the AU receives MIDI devices through Logic;
there is no Bluetooth/device-connection screen or separate AU user-bank store.

Arpeggiator and delay tempo follow the host's beat/tempo callback at 40-240 BPM;
without a supported host tempo they use the internal 120 BPM default.
Arp Master Sync aligns the arpeggio's first note to the host beat grid;
Arp Start Grid selects 1/1 through 1/32. The bar grid assumes 4/4.
The start grid is consulted only while waiting for the first note. Once playing,
the arpeggiator advances continuously at the master's tempo without re-aligning
to quarters, bars or host phase jumps. Releasing all held/latched notes rearms
start quantization for the next phrase.
Arp Division still determines subsequent steps. Disabling Arp Master Sync
allows immediate free starts. No external MIDI Clock or MMC routing is needed.

The internal DSP rate is 44.1 kHz. Host rates from 22.05 to 192 kHz are
accepted, with stereo resampling when necessary. Reported algorithmic latency
is zero at 44.1 kHz, otherwise 16 internal samples (about 0.363 ms). MIDI
events are applied on the next 16-sample DSP control boundary, adding up to
about 0.363 ms of timing quantization. The audio interface/Logic buffer still
affects live monitoring latency.

This replaces the external iPad/USB audio path: do not use External Instrument
or the previously measured 4188-sample external-path correction on this track.

## Validation

```sh
ctest --test-dir target/obervave-au --output-on-failure
auval -v aumu Obv1 Obvv
```

The integration test loads the built bundle directly and covers audio at
22.05/44.1/48/88.2/96/192 kHz, irregular render sizes, MIDI offsets,
instance isolation, cross-instance state restoration, master pan, reported
latency, the editor's MIDI queue/meters and host-synced arpeggio starts at
90/120/180 BPM. A second AppKit test opens the actual Cocoa editor, switches
tabs, plays a key, drags a knob, checks automation notifications, and captures
panel PNGs in the build directory. This UI test requires a logged-in macOS
graphical session.

## License

The native adapter and OberVave synthesizer are GPL-3.0-only; see the
[OberVave license](../../LICENSE). The Apple AudioUnitSDK
has its own Apache-2.0 license in its checkout. The historical emulator's MIT
notice in `../../LICENSE-FM1-EMU` does not replace the native application's GPL.
