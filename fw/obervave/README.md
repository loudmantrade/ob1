# OberVave DSP source subset

Source: <https://github.com/zvenson/obervave>, version 3.5.2, commit
`a1f660c4439583d33f72941bd184a7e187d11835`.

Only the native applications' required source is retained:

- `firmware/src/obv_dsp.h`: DSP primitives.
- `firmware/src/obv_params.h`: parameter definitions.
- `firmware/src/obv_patches.h`: factory patches.
- `firmware/src/obv_fx.h`: effects.
- `firmware/src/obv_engine.h`: synth voices and arpeggiator.
- `firmware/gen/obv_tables.h`: precomputed DSP tables.

Local adaptations support per-instance C++ engine state, shared host clock
integration, live arpeggiator latency compensation, and actual-frame-count
effect processing. These modified files are ordinary tracked source files,
not a submodule. No external firmware checkout is needed to build.

Hardware HAL, bootloader, firmware packaging, screen/UI, browser simulator,
and their assets and tools have been removed from this subset.
The generated DSP tables are checked in, so building the native apps does not
require the removed upstream table generator.

The source is GPL-3.0-only; the full license is in [../../LICENSE](../../LICENSE).
[LICENSING.md](LICENSING.md) is the original upstream attribution document:
its paths describe the original full firmware repository, including components
not distributed in this subset.
