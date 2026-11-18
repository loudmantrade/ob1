// SPDX-License-Identifier: GPL-3.0-only
#include <cassert>
#include <cstdio>
#include <memory>
#include "../../ios/OberVave/SynthRack.cpp"

namespace music = ob1::music;
static void render(uint32_t frames = CTL)
{
    float left[CTL], right[CTL];
    for (uint32_t i = 0; i < frames; i += CTL) ov_render(left, right, CTL);
}
static rack::NativeEngine<true>& engine(uint32_t slot)
{
    return static_cast<rack::NativeEngine<true>&>(*rack::scene->slots[slot]->engine);
}
static bool gate(uint32_t slot)
{
    for (const auto& voice : engine(slot).dsp.vc) if (voice.gate) return true;
    return false;
}
static ov_instrument_config config(uint32_t arp = 0)
{
    ov_instrument_config result {};
    result.engine = OV_ENGINE_OBERVAVE;
    result.channel = 1; result.high_note = 127; result.level_db = -6;
    result.sync = 1;
    rack::patch_t patch {};
    rack::patch_from_factory(&patch, rack::program(0));
    for (uint32_t p = 0; p < rack::NPARAM; ++p) {
        result.parameters[p] = patch.v[p]; result.cc[p] = 255;
    }
    result.parameters[rack::P_ARP_MODE] = arp;
    result.parameters[rack::P_ARP_LATCH] = 0;
    return result;
}
static ov_seq_clip clip(uint32_t slot, uint32_t row, uint32_t output = 1)
{
    ov_seq_clip result {};
    result.slot = slot; result.row = row; result.length = 960;
    result.loop = result.intro_enabled = 1; result.count = 1;
    std::copy_n("Test clip", 10, result.name);
    result.notes[0] = {1, 0, 480, 60, 100, output};
    return result;
}
static void checkRack()
{
    auto scene = std::make_unique<ov_scene_config>();
    auto patterns = std::make_unique<std::array<ov_seq_clip, rack::capacity>>();
    scene->tempo = 120;
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) {
        scene->slots[slot] = {1, config(rack::A_UP)};
        (*patterns)[slot] = clip(slot, 0);
    }
    assert(ov_rack_load_sequenced(scene.get(), patterns->data(), patterns->size()));
    render();
    assert(ov_seq_launch_row(0, 0)); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) {
        assert(ov_seq_active(slot) == 0 && gate(slot));
        assert(engine(slot).arpeggiator.inputOwnerCount() == 0);
        assert(engine(slot).arpeggiator.processor().activeCount() == 0);
        assert(engine(slot).parameter(rack::P_ARP_MODE) == rack::A_UP);
        assert(rack::players[slot].origin == rack::players[0].origin);
    }
    // Failed preparation is transactional: no scene command or live clip changes.
    const auto* previous = rack::scene.get();
    (*patterns)[5].notes[0].duration = 0;
    assert(!ov_rack_load_sequenced(scene.get(), patterns->data(), patterns->size()));
    assert(ov_rack_take_error() == 2); render();
    assert(rack::scene.get() == previous && ov_seq_active(5) == 0);
    (*patterns)[5] = clip(4, 0);
    assert(!ov_rack_load_sequenced(scene.get(), patterns->data(), patterns->size()));
    assert(ov_rack_take_error() == 2);
    assert(ov_seq_solo(0, 1)); render();
    assert(rack::soloMask == 1 && gate(1));
    assert(rack::scene->slots[0]->leftGain > 0 && rack::scene->slots[1]->leftGain == 0 &&
        rack::scene->slots[1]->rightGain == 0);
    assert(ov_rack_configure(0, 1, 0, 127, -12, 1, 0)); render();
    assert(rack::scene->slots[0]->leftGain == 0 && rack::scene->slots[0]->rightGain > 0);
    assert(ov_rack_configure(0, 1, 0, 127, -12, 1, 1)); render();
    assert(rack::scene->slots[0]->leftGain == 0 && rack::scene->slots[0]->rightGain == 0 && gate(0));
    assert(ov_rack_configure(0, 1, 0, 127, -6, 0, 0)); render();
    assert(ov_seq_stop(1, 1)); render();
    assert(gate(1) && ov_seq_active(1) == 0 && engine(1).parameter(rack::P_ARP_MODE) == rack::A_UP);
    assert(ov_seq_stop(0, 0)); render();
    assert(ov_seq_active(0) == -1 && !gate(0) && gate(1));
    assert(ov_rack_stop_all()); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot)
        assert(!gate(slot) && ov_seq_active(slot) == -1 && ov_seq_pending(slot) == -1);
    assert(ov_seq_launch_row(0, 1)); render();
    assert(ov_seq_pending(1) == 0);
    assert(ov_rack_stop_all()); render();
    assert(ov_seq_pending(1) == -1);
    assert(ov_seq_solo(0, 0));
    assert(ov_seq_launch(3, 0, 0)); render(2048);
    const auto sequencePeak = rack::snapshots[3].sequencerPeak.load();
    assert(sequencePeak > 0);
    ov_rack_take_level(3);
    assert(ov_seq_take_level(3) == sequencePeak && ov_seq_take_level(3) == 0);
    // Program replacement and deletion release clip ownership as well as gates.
    ov_rack_select(3); ov_select_program(1); render();
    assert(ov_seq_active(3) == -1);
    assert(ov_seq_launch(4, 0, 0)); render();
    assert(ov_seq_delete(4, 0)); render();
    assert(ov_seq_active(4) == -1 && !rack::clips[4][0] && !gate(4));
    ov_midi_message(0xFA, 0, 0); render();
    assert(rack::musicalPosition.value % (3840 * music::tickUnit) <=
        int64_t(CTL) * 960 * music::tickUnit / rack::clock.length() + 1);
    ov_midi_message(0xFC, 0, 0); render();
    assert(ov_rack_load(scene.get())); render();
    assert(!rack::clips[0][0] && rack::soloMask == 0);
    assert(!ov_rack_take_error());
    std::puts("PASS production launcher: all 16 logical instruments, ARP output bypass, row atomic boundary, transactional load rejection, independent Stop/Solo/meters, Stop All cancels queues, program/delete/scene lifecycle");
}

static void checkRecording()
{
    auto scene = std::make_unique<ov_scene_config>();
    scene->tempo = 120; scene->slots[0] = {1, config()};
    auto pattern = std::make_unique<ov_seq_clip>(clip(0, 0));
    assert(ov_rack_load_sequenced(scene.get(), pattern.get(), 1)); render();
    rack::musicalPosition.value = 3500 * music::tickUnit;
    rack::processedFrames = uint64_t(3500) * rack::clock.length() / 960;
    rack::clock.frame = uint32_t(rack::processedFrames);
    assert(ov_seq_record(0, 0, 1, 1)); render();
    ov_note_on(60, 100); render();
    render(1024);
    ov_midi_message(0xB0, 64, 127); ov_note_off(60); render();
    assert(rack::recorder.data.count == 0);
    render(1024);
    ov_midi_message(0xB0, 64, 0); render();
    assert(rack::recorder.data.count == 1);
    const auto offDuration = rack::recorder.data.notes[0].duration;
    assert(offDuration > 80);
    assert(ov_seq_finish_record()); render();
    assert(ov_seq_record_ready() && ov_seq_read_record(pattern.get()));
    assert(pattern->count == 1 && pattern->intro > 0 && pattern->notes[0].start < 0);
    assert(pattern->notes[0].duration == offDuration && pattern->notes[0].output);
    assert(ov_seq_set_clip(pattern.get())); render();
    assert(ov_seq_record(0, 0, 0, 1)); render();
    ov_note_on(64, 100); render();
    assert(ov_rack_stop_all()); render();
    assert(ov_seq_read_record(pattern.get()) && pattern->count == 1 && !pattern->notes[0].output);
    assert(ov_seq_recording_slot() == -1);
    // Recorded output must stay audible even with an enabled, empty ARP.
    pattern->notes[0].output = 1; pattern->notes[0].start = 0; pattern->notes[0].duration = 480;
    pattern->intro = 0;
    assert(ov_seq_set_clip(pattern.get()));
    ov_set_parameter(rack::P_ARP_MODE, rack::A_UP);
    assert(ov_seq_launch(0, 0, 0)); render();
    assert(gate(0) && engine(0).arpeggiator.processor().activeCount() == 0);
    assert(ov_rack_stop_all()); render();
    assert(!gate(0) && !ov_rack_take_error());
    std::puts("PASS production recording: actual output Off after Sustain release, negative pickup, mailbox roundtrip, input recording, Stop finalizes gates and output replay bypasses saved ARP mode");
}

int main()
{
    ov_init(); checkRack(); checkRecording(); ov_rack_collect();
}
