# Native OberVave Audio Unit

OberVave AUv2 is a stereo software instrument for macOS 13 or later. It runs the
OberVave C synthesizer directly, without emulating the FM-1 CPU, and is separate
from the emulator-based FM-1 plug-in.

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

The build reuses the Apple AudioUnitSDK cached by the FM-1 plug-in build if
available, otherwise downloads the SDK at the commit pinned in
[CMakeLists.txt](CMakeLists.txt). `AUDIOUNIT_SDK` can point to an existing SDK
checkout for an offline build.

## Logic Pro

Restart Logic after installation. Create a **Software Instrument** track and
select **AU Instruments > OberVave > OberVave > Stereo**. If it is not listed,
use Logic's Plug-in Manager to rescan OberVave.

Select **Editor**, rather than **Controls**, in Logic's plug-in window to use
the iPad-style OB-1 panel. It uses the same SwiftUI control/layout definitions
as the iPad app: **OB-1**, **MORE**, and **EFFECTS** tabs, rotary knobs, option
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

MIDI notes, pitch bend, sustain, CC7, all-sound/all-notes-off, factory Program
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
[OberVave firmware license](../../fw/obervave/LICENSE). The Apple AudioUnitSDK
has its own Apache-2.0 license in its checkout. This native plug-in is not
covered solely by the emulator repository's license.
