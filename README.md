# OberVave Native

Native OberVave synthesizer for iPad and macOS Audio Unit hosts. The DSP runs
directly as C++: no FM-1 CPU emulator, JIT, firmware package or physical
synthesizer is required.

## Applications

- **[iPad app](ios/OberVave/README.md)**: scenes with up to 16 independent
  synth instances, MIDI channel routing and key zones, per-instance arpeggiators,
  shared tempo/MIDI clock, audio latency compensation, and a multichannel
  on-screen keyboard with channel-colored key locks.
- **[macOS AUv2](native/OberVaveAU/README.md)**: a stereo instrument for Logic
  and other Audio Unit hosts, with the shared SwiftUI synth panel, host
  automation, presets and tempo synchronization.

Both use the same eight-voice OberVave engine and effects at an internal
44.1 kHz sample rate. The AU is a single synth instance; the scene rack belongs
to the standalone iPad app.

## Build and test

### iPad

Open `ios/OberVave/OberVave.xcodeproj` in Xcode, choose your signing team and
a physical device, then build and run. The deployment target is iOS 16.
For a compile-only device build without signing:

```sh
xcodebuild -project ios/OberVave/OberVave.xcodeproj \
  -target OberVave -configuration Release -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO build
```

### macOS Audio Unit

Requires macOS 13+, Xcode command-line tools, CMake 3.21+ and Ninja.
Build and run all six native test suites without replacing an installed AU:

```sh
NO_INSTALL=1 ARCH=x86_64 tools/build_obervave_au.sh
```

Omit `NO_INSTALL=1` to also install and run Apple's AU validator. Use
`ARCH=arm64` for Apple silicon; each build supports one architecture.
The Cocoa editor test requires a logged-in graphical session.
The pinned Apple AudioUnitSDK is downloaded by CMake on the first build;
`AUDIOUNIT_SDK` can point to an existing checkout for offline builds.
Rust, Cargo and the old FM-1 plugin build are not required.

## Source layout

- `ios/OberVave/`: standalone app, scene rack and shared SwiftUI controls.
- `native/OberVave/`: shared native engine adapter.
- `native/Musical/`: portable musical event types and regression tests;
  see the [event contract](docs/MUSICAL_EVENTS.md) and
  [incremental architecture plan](docs/MUSICAL_ENGINE_PLAN.md).
- `native/OberVaveAU/`: AU wrapper, editor bridge and regression tests.
- `fw/obervave/`: required OberVave DSP headers, factory patches, generated
  tables and upstream attribution; hardware firmware code is not included.
- `tools/build_obervave_au.sh`: native AU build, test and installation entry point.

This standalone development line originated in
[fm1-emu](https://github.com/joakimeriksson/fm1-emu), but does not contain or
depend on its emulator. Earlier emulator work remains in Git history.
See the [source provenance](fw/obervave/README.md) for the OberVave base version.

## License

The native applications and OberVave DSP are **GPL-3.0-only**; see [LICENSE](LICENSE).
OberVave is by zvenson; the original upstream attribution is preserved in
[LICENSING.md](fw/obervave/LICENSING.md).
The historical emulator's MIT notice is retained in
[LICENSE-FM1-EMU](LICENSE-FM1-EMU), not as a replacement for the GPL.
Apple AudioUnitSDK is a separate dependency under its own Apache-2.0 license.
