// SPDX-License-Identifier: GPL-3.0-only
#include <cassert>
#include <cstdio>
#include <chrono>
#include "../../ios/OberVave/SynthRack.cpp"

static float renderedPeak = 0;
static double render(uint32_t n = 256)
{
    float left[256], right[256];
    double energy = 0;
    renderedPeak = 0;
    while (n) {
        const auto count = std::min(n, 256u);
        ov_render(left, right, count);
        for (uint32_t i = 0; i < count; ++i) {
            assert(std::isfinite(left[i]) && std::isfinite(right[i]));
            energy += double(left[i]) * left[i] + double(right[i]) * right[i];
            renderedPeak = std::max(renderedPeak, std::max(std::abs(left[i]), std::abs(right[i])));
        }
        n -= count;
    }
    return energy;
}
static rack::Engine& dsp(uint32_t slot)
{
    return static_cast<rack::OberVaveEngine&>(*rack::scene->slots[slot]->engine).dsp;
}
static ov_instrument_config config(uint32_t channel, uint32_t low = 0, uint32_t high = 127)
{
    ov_instrument_config c {};
    c.engine = OV_ENGINE_OBERVAVE; c.channel = channel; c.low_note = low; c.high_note = high;
    c.program = 17; c.grid = 2;
    for (uint32_t p = 0; p < OV_RACK_PARAMETERS; ++p) {
        c.parameters[p] = ov_rack_factory_parameter(17, p);
        c.cc[p] = ov_rack_default_cc(p);
    }
    c.parameters[rack::P_ARP_MODE] = rack::A_UP;
    c.parameters[rack::P_ARP_LATCH] = 1;
    return c;
}
int main()
{
    // The adapter must overwrite caller memory, not mix into stale stack samples.
    auto cleanEngine = std::make_unique<rack::OberVaveEngine>();
    auto dirtyEngine = std::make_unique<rack::OberVaveEngine>();
    int32_t clean[CTL * 2], dirty[CTL * 2];
    for (uint32_t block = 0; block < 1200; ++block) {
        if (block == 20) {
            cleanEngine->midi(0x90, 60, 100);
            dirtyEngine->midi(0x90, 60, 100);
        }
        if (block == 600) {
            cleanEngine->midi(0x80, 60, 0);
            dirtyEngine->midi(0x80, 60, 0);
        }
        std::fill_n(clean, CTL * 2, 0);
        for (uint32_t i = 0; i < CTL * 2; ++i)
            dirty[i] = i & 1 ? 0x13572468 : -0x13572468;
        rack::Timing timing {(block + 1) * CTL, 22050, double((block + 1) * CTL) / 22050, 0};
        cleanEngine->render(timing, clean);
        dirtyEngine->render(timing, dirty);
        assert(std::equal(std::begin(clean), std::end(clean), std::begin(dirty)));
        if (block < 20) for (int32_t sample : dirty) assert(sample == 0);
    }
    cleanEngine.reset();
    dirtyEngine.reset();
    std::puts("PASS engine output is independent of dirty caller buffers: silence, note attack/sustain and release/FX tail");
    ov_init();
    ov_scene_config s {}; s.tempo = 120;
    for (uint32_t i = 0; i < 16; ++i) { s.slots[i].present = 1; s.slots[i].config = config(i + 1); }
    assert(ov_rack_load(&s));
    render();
    for (uint32_t i = 0; i < 16; ++i) ov_midi_message(0x90 | i, 48 + i, 100);
    render();
    for (uint32_t i = 0; i < 16; ++i) {
        assert(dsp(i).nheld[0] == 1);
        assert(dsp(i).held[0][0].note == 48 + i);
        assert(dsp(i).arp[0].sounding);
        assert(dsp(i).eng_t == rack::clock.frame);
        assert(&dsp(i).fx_mem[0] != &dsp((i + 1) % 16).fx_mem[0]);
    }
    auto invalid = s;
    invalid.slots[2].config.engine = 9999;
    assert(!ov_rack_load(&invalid));
    assert(ov_rack_take_error() == 2);
    render();
    assert(dsp(2).nheld[0] == 1);
    assert(!ov_rack_add(16, &s.slots[0].config));
    ov_rack_take_error();
    std::puts("PASS 16 engines, unique MIDI channels, separate voices/FX, invalid scenes leave playback intact");

    ov_midi_message_at(0x90, 90, 100, ov_audio_frame() + 10000);
    ov_midi_message(0xFC, 0, 0);
    render(12000);
    for (uint32_t i = 0; i < 16; ++i) {
        assert(dsp(i).nheld[0] == 0 && !dsp(i).arp[0].sounding);
        assert(dsp(i).live_p[0].v[rack::P_ARP_LATCH] == 1);
    }
    assert(rack::scheduledCount == 0);
    std::puts("PASS common Stop flushes pending notes and stops all independent arpeggiators, retaining Latch");

    ov_scene_config zones {}; zones.tempo = 120;
    zones.slots[0] = {1, config(1, 0, 64)};
    zones.slots[1] = {1, config(1, 60, 127)};
    assert(ov_rack_load(&zones));
    render();
    ov_midi_message(0x90, 50, 100);
    ov_midi_message(0x90, 60, 100);
    ov_midi_message(0x90, 80, 100);
    render();
    assert(dsp(0).nheld[0] == 2 && dsp(1).nheld[0] == 2);
    assert(dsp(0).held[0][0].note == 50 && dsp(1).held[0][1].note == 80);
    ov_rack_select(0);
    ov_set_parameter(rack::P_ARP_DIV, rack::D_4);
    ov_rack_select(1);
    ov_set_parameter(rack::P_ARP_DIV, rack::D_32T);
    render();
    const auto steps0 = dsp(0).ui_arp_step, steps1 = dsp(1).ui_arp_step;
    render(22050);
    assert(dsp(1).ui_arp_step - steps1 > dsp(0).ui_arp_step - steps0);
    assert(ov_rack_configure(0, 2, 0, 127, -6, -1, 0));
    render();
    assert(!dsp(0).nheld[0] && dsp(1).nheld[0]);
    std::puts("PASS overlapping zones layer notes, per-instance divisions run independently, rerouting releases notes");

    ov_all_notes_off(); render();
    ov_keyboard_channels(3);
    ov_note_on(60, 100); render();
    assert(dsp(0).nheld[0] == 1 && dsp(1).nheld[0] == 1);
    ov_keyboard_channels(4);
    ov_note_off(60);
    // Sustain release clears latched keys on both original keyboard channels.
    ov_midi_message(0xB0, 64, 127); ov_midi_message(0xB1, 64, 127); render();
    ov_midi_message(0xB0, 64, 0); ov_midi_message(0xB1, 64, 0); render();
    assert(!dsp(0).nheld[0] && !dsp(1).nheld[0]);
    std::puts("PASS keyboard broadcasts selected channels and releases original destinations after channel changes");

    ov_all_notes_off(); render();
    ov_rack_select(0); ov_set_parameter(rack::P_ARP_LATCH, 0);
    ov_rack_select(1); ov_set_parameter(rack::P_ARP_LATCH, 0);
    ov_keyboard_note_on(60, 100, 1); render();
    assert(dsp(1).nheld[0] == 1 && dsp(0).nheld[0] == 0);
    ov_keyboard_channels(2);
    ov_keyboard_note_on(60, 100, 2); render();
    assert(dsp(0).nheld[0] == 1 && dsp(1).nheld[0] == 1);
    ov_keyboard_note_off(60, 2); render();
    assert(dsp(0).nheld[0] == 0 && dsp(1).nheld[0] == 1);
    assert(rack::keyboardHeld[60].load() == 1);
    ov_keyboard_note_on(60, 100, 2); render();
    ov_keyboard_channels(4);
    ov_keyboard_note_off(60, 2); render();
    assert(dsp(0).nheld[0] == 0 && dsp(1).nheld[0] == 1);
    ov_keyboard_note_off(60, 1); render();
    assert(!dsp(0).nheld[0] && !dsp(1).nheld[0]);
    std::puts("PASS scoped keyboard release preserves the same held pitch on inactive channels and captures touch destinations");

    // Exact live latency direction and one-shot delta, on the production engine.
    ov_all_notes_off(); render();
    ov_rack_select(0); ov_set_arp_sync(1); ov_set_arp_sync_grid(5);
    ov_set_parameter(rack::P_ARP_DIV, rack::D_4);
    ov_midi_message(0x91, 60, 100);
    for (uint32_t i = 0; i < 1000 && !dsp(0).arp[0].sounding; ++i) render(16);
    assert(dsp(0).arp[0].sounding);
    const auto before = dsp(0).arp[0].cnt;
    ov_set_arp_audio_latency_ms(10); render(16);
    assert(dsp(0).arp[0].cnt == before + 441 + 16);
    const auto adjusted = dsp(0).arp[0].cnt;
    render(16); assert(dsp(0).arp[0].cnt == adjusted + 16);
    ov_set_arp_audio_latency_ms(-500); render(16);
    assert(dsp(0).delayedFrames[0] < 0);
    ov_set_arp_audio_latency_ms(0);
    std::puts("PASS live compensation shifts running arp without recurring phase correction");

    // Arbitrary frame counts may not advance some instances faster than others.
    render(1); render(7); render(63); render(185);
    assert(dsp(0).eng_t == dsp(1).eng_t);
    // Saving must include earlier commands, not whichever UI values happened to be polled.
    ov_rack_select(0);
    ov_set_parameter(rack::P_CUTOFF, 91);
    ov_set_parameter_cc(rack::P_CUTOFF, 19);
    assert(ov_rack_configure(0, 3, 10, 100, -12, 0.25, 0));
    assert(ov_rack_snapshot_request());
    ov_scene_config captured {};
    assert(!ov_rack_snapshot_read(&captured));
    render(256);
    assert(ov_rack_snapshot_read(&captured));
    assert(captured.slots[0].config.parameters[rack::P_CUTOFF] == 91);
    assert(captured.slots[0].config.cc[rack::P_CUTOFF] == 19);
    assert(captured.slots[0].config.channel == 3);
    assert(captured.slots[0].config.low_note == 10 && captured.slots[0].config.high_note == 100);
    assert(captured.slots[0].config.level_db == -12 && captured.slots[0].config.pan == 0.25);
    assert(ov_rack_load(&captured)); render();
    assert(dsp(0).live_p[0].v[rack::P_CUTOFF] == 91);
    const auto untouchedSteps = dsp(1).ui_arp_step;
    const auto untouchedPhase = dsp(1).arp[0].cnt;
    auto added = config(4);
    assert(ov_rack_add(15, &added)); render();
    assert(dsp(1).ui_arp_step == untouchedSteps);
    assert(dsp(1).arp[0].cnt == untouchedPhase); // No chord in the loaded scene.
    assert(ov_rack_remove(15)); render();
    assert(rack::scene->slots[0] && rack::scene->slots[1] && !rack::scene->slots[15]);
    std::puts("PASS FIFO scene snapshots include pending edits and full routing/mixer state; add/remove leaves other instances intact");

    // Timestamped MIDI must be held until its boundary, with shared clock filtering.
    ov_midi_message_at(0x92, 60, 100, ov_audio_frame() + 512);
    render(256); assert(dsp(0).nheld[0] == 0);
    render(256); assert(dsp(0).nheld[0] == 1);
    ov_all_notes_off(); render();
    ov_midi_message(0xFA, 0, 0); render(16);
    for (uint32_t t = 0; t < 49; ++t) {
        ov_midi_message(0xF8, 0, 0); render(928);
    }
    assert(ov_midi_clock_active());
    assert(ov_tempo() >= 118 && ov_tempo() <= 120);
    assert(dsp(0).ctl_ext_quarter == dsp(1).ctl_ext_quarter);
    const auto externalBPM = ov_tempo();
    auto externalScene = captured;
    externalScene.tempo = 200;
    assert(ov_rack_load(&externalScene)); render(16);
    ov_midi_message(0xFC, 0, 0); render(16);
    assert(!ov_midi_clock_active() && ov_tempo() == externalBPM);
    std::puts("PASS timestamp scheduling, common filtered MIDI clock, external tempo retained across scene-load/Stop");

    ov_scene_config empty {}; empty.tempo = 111;
    assert(ov_rack_load(&empty)); render();
    assert(render(4096) == 0 && ov_tempo() == 111);
    empty.slots[0] = {1, config(1)};
    empty.slots[0].config.muted = 1;
    empty.slots[0].config.pan = -1;
    assert(ov_rack_load(&empty)); render();
    ov_midi_message(0x90, 60, 100);
    assert(render(4096) == 0);
    assert(ov_rack_take_level(0) == 0);
    assert(ov_rack_take_level(1) == 0);
    assert(ov_rack_configure(0, 1, 0, 127, 0, -1, 0));
    assert(render(4410) > 0.000001);
    assert(ov_rack_take_level(0) > 0);
    assert(ov_rack_take_level(0) == 0);
    assert(ov_rack_take_level(1) == 0);
    // At a control-aligned boundary the rack peak must match the actual post-pan audio.
    while (rack::outputPosition != CTL) render(1);
    ov_rack_take_level(0);
    render(4096);
    const auto expectedPeak = uint32_t(std::min(renderedPeak, 1.f) * 65535);
    assert(ov_rack_take_level(0) == expectedPeak);
    assert(ov_rack_take_level(0) == 0);
    for (float sample : rack::output[1]) assert(sample == 0);
    std::puts("PASS empty scene is silent while common tempo runs; muted engines produce no startup leak, unmute/pan render real audio");
    render(4096);
    assert(ov_rack_remove(0)); render();
    assert(ov_rack_take_level(0) == 0);
    assert(ov_rack_take_level(16) == 0);
    std::puts("PASS instance meters match post-level/pan/mute audio, isolate slots, clear on read/removal");

    for (uint32_t i = 0; i < 48; ++i) {
        assert(ov_rack_load(i % 2 ? &s : &zones)); render();
        ov_rack_collect();
    }
    assert(ov_rack_load(&s)); render();
    for (uint32_t i = 0; i < 16; ++i) ov_midi_message(0x90 | i, 60, 100);
    render();
    const auto start = std::chrono::steady_clock::now();
    render(44100);
    const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("PASS transactional scene reload/lifecycle, arbitrary blocks; 16-arp render 1 second in %.3f seconds on this Mac\n", elapsed);
    assert(ov_rack_take_error() == 0);
    ov_rack_collect();
}
