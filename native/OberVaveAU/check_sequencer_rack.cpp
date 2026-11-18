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
    ov_midi_message(0x90, 67, 100); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot)
        assert(engine(slot).arpeggiator.processor().heldCount() > 0);
    assert(ov_seq_launch_row(0, 0)); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) {
        assert(ov_seq_active(slot) == 0 && gate(slot));
        assert(engine(slot).arpeggiator.inputOwnerCount() == 0);
        assert(engine(slot).arpeggiator.processor().activeCount() == 0);
        assert(engine(slot).arpeggiator.processor().heldCount() == 0);
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

static void checkPadRecording()
{
    auto scene = std::make_unique<ov_scene_config>();
    scene->tempo = 120; scene->slots[0] = {1, config()}; scene->slots[1] = {1, config()};
    auto result = std::make_unique<ov_seq_clip>();
    auto take = [&](uint32_t expected) {
        assert(ov_seq_record_ready() && ov_seq_record_result() == expected);
        assert(ov_seq_read_record(result.get()) && !ov_seq_record_ready());
    };
    auto stop = [&] { assert(ov_rack_stop_all()); render(); };
    assert(ov_rack_load(scene.get())); render();
    assert(ov_seq_arm(0, 0, 0, 1, 1, 1)); render();
    assert(ov_seq_record_phase() == 1 && ov_seq_recording_slot() == 0 && !rack::clips[0][0]);
    render(rack::clock.length() * 8);
    assert(ov_seq_record_phase() == 1 && !ov_seq_record_ready());
    // Neither a pattern on another column nor its generated output is a first live note.
    auto backing = std::make_unique<ov_seq_clip>(clip(1, 0));
    backing->notes[0].pitch = 48;
    assert(ov_seq_set_clip(backing.get())); assert(ov_seq_launch(1, 0, 0)); render();
    assert(ov_seq_record_phase() == 1);
    ov_note_on(60, 100); render();
    assert(ov_seq_record_phase() == 3 && rack::recorder.origin % (3840 * music::tickUnit) == 0);
    render(1024); ov_note_off(60); render();
    render(rack::clock.length());
    assert(ov_seq_recording_slot() == -1 && ov_seq_active(0) == 0);
    assert(rack::clips[0][0] && rack::clips[0][0]->pattern.data().notes[0].start == 0);
    assert(rack::clips[0][0]->pattern.data().length == 960);
    // Autoplay happens on audio before the UI even reads its completion mailbox.
    assert(rack::players[0].clip == &rack::clips[0][0]->pattern);
    take(1);
    assert(result->count == 1 && result->notes[0].start == 0 && result->length == 960);
    stop();

    assert(ov_seq_arm(0, 1, 0, 1, 0, 1)); render();
    assert(ov_seq_finish_record()); render();
    take(2);
    assert(!rack::clips[0][1] && ov_seq_active(0) == -1);
    assert(ov_seq_arm(0, 1, 2, 1, 0, 1)); render();
    assert(ov_seq_record_phase() == 3 && rack::recorder.freeLength);
    ov_note_on(64, 100); render(2048); ov_note_off(64); render(2048);
    assert(ov_seq_record_length() == 3840);
    assert(ov_seq_finish_record()); render();
    assert(ov_seq_record_phase() == 5 && !ov_seq_record_ready() && !rack::clips[0][1]);
    const auto finishAt = rack::recorder.stopAt;
    assert(finishAt == rack::recorder.origin + 3840 * music::tickUnit);
    assert(ov_seq_finish_record()); render();
    assert(rack::recorder.stopAt == finishAt);
    ov_note_on(67, 100); render(1024); ov_note_off(67); render();
    while (rack::recorder.running) render();
    assert(ov_seq_active(0) == 1 && rack::clips[0][1]);
    assert(rack::players[0].origin == finishAt);
    take(1);
    assert(result->length == 3840 && result->count == 2 && result->intro == 0);
    const auto length = result->length;
    assert(rack::players[0].clip->data().length == length);
    stop();
    assert(ov_seq_arm(0, 6, 2, 1, 6, 0)); render();
    assert(ov_seq_finish_record()); render();
    assert(rack::recorder.stopAt == rack::recorder.origin + 3840 * music::tickUnit);
    assert(ov_seq_record_phase() == 5 && !ov_seq_record_ready());
    while (rack::recorder.running) render();
    take(1);
    assert(result->length == 3840 && ov_seq_active(0) == 6);
    stop();
    assert(ov_seq_arm(0, 5, 2, 1, 0, 1)); render();
    ov_note_on(64, 100); render();
    // Advance the same audio clocks without synthesizing five minutes of unchanged DSP.
    const auto elapsed = rack::clock.length() * 600;
    rack::musicalPosition.advance(elapsed, rack::clock.length());
    rack::clock.frame += elapsed; rack::processedFrames += elapsed;
    render();
    assert(ov_seq_record_phase() == 3 && !ov_seq_record_ready());
    const auto overnight = FS * 60u * 60u * 15u;
    rack::musicalPosition.advance(overnight, rack::clock.length());
    rack::clock.frame += overnight; rack::processedFrames += overnight;
    const auto beforeWrap = rack::musicalPosition.value;
    render();
    assert(rack::musicalPosition.value >= beforeWrap && ov_seq_record_phase() == 3);
    ov_note_off(64); render();
    assert(ov_seq_finish_record()); render();
    assert(ov_seq_record_phase() == 5);
    while (rack::recorder.running) render();
    take(1);
    assert(result->length >= 600 * 960 && result->length % 3840 == 0 && result->notes[0].duration > 256 * 960);
    assert(ov_seq_active(0) == 5);
    stop();

    // Count-in on a stopped scene emits audible clicks without any playing notes.
    assert(ov_seq_arm(0, 2, 1, 2, 1, 1)); render();
    assert(ov_seq_record_phase() == 2 && ov_seq_record_remaining() == 8);
    assert(rack::clickFrames > 0);
    double clickEnergy = 0;
    for (uint32_t i = 0; i < CTL; ++i) clickEnergy += std::abs(rack::output[0][i]);
    assert(clickEnergy > 0);
    ov_note_on(67, 100); render(2048); ov_note_off(67); render();
    assert(rack::recorder.data.intro > 3840 && rack::recorder.data.notes[0].start < 0);
    const auto body = rack::recorder.origin;
    while (rack::musicalPosition.value < body) render();
    assert(ov_seq_record_phase() == 3 && ov_seq_record_remaining() == 0);
    ov_note_on(72, 100); render(1024); ov_note_off(72); render();
    render(rack::clock.length());
    take(1);
    assert(ov_seq_active(0) == 2 && result->count == 2 && result->intro > 3840);
    assert(result->notes[0].start < 0 && result->notes[1].start >= 0);
    // The just-recorded pickup is retained, but is not repeated by automatic looping.
    for (const auto& note : rack::players[0].active) if (note.used) assert(note.on.data1 != 67);
    stop();

    for (uint32_t mode : {0u, 2u, 1u}) {
        assert(ov_seq_launch(1, 0, 0)); render();
        assert(ov_seq_arm(0, 3, mode, 1, 1, 0)); render();
        const auto bar = 3840 * music::tickUnit;
        assert(!rack::recorder.waiting && rack::recorder.origin % bar == 0);
        if (mode == 1) {
            assert(rack::recorder.origin - rack::recorder.countStart == bar);
            assert(rack::recorder.countStart >= rack::musicalPosition.value);
        } else {
            assert(rack::recorder.origin - rack::musicalPosition.value < bar);
        }
        ov_note_on(60, 100); render(1024); ov_note_off(60); render();
        stop();
        take(2); // Stopping before the body cancels, without replacing existing cells.
        assert(!rack::clips[0][3] && ov_seq_active(1) == -1);
    }
    // Overflow cannot publish a partial take or start its loop.
    assert(ov_seq_arm(0, 4, 2, 1, 0, 0)); render();
    rack::recorder.overflow = true;
    assert(ov_seq_finish_record()); render();
    take(3);
    assert(!rack::clips[0][4] && ov_seq_active(0) == -1 && ov_rack_take_error() == 1);
    assert(!ov_seq_arm(0, 0, 3, 1, 4, 1) && ov_rack_take_error() == 2);
    assert(!ov_seq_arm(0, 0, 1, 3, 4, 1) && ov_rack_take_error() == 2);
    assert(!ov_seq_arm(0, 0, 1, 1, 257, 1) && ov_rack_take_error() == 2);
    assert(!ov_rack_take_error());
    std::puts("PASS pad recording: empty-cell arm, first live note at zero, fixed-length auto-publish/play without UI, free-length second-tap looping, 8 audible count-in ticks/pickup, scene-aligned modes, cancellation/Stop and overflow");
}

static void checkLaunchHandover()
{
    auto scene = std::make_unique<ov_scene_config>();
    scene->tempo = 120;
    for (uint32_t slot = 0; slot < 2; ++slot) {
        scene->slots[slot] = {1, config(rack::A_UP)};
        scene->slots[slot].config.parameters[rack::P_ARP_LATCH] = 1;
    }
    auto pattern = std::make_unique<ov_seq_clip>(clip(0, 0));
    pattern->intro = 240; pattern->notes[0].start = -240; pattern->notes[0].duration = 480;
    assert(ov_rack_load_sequenced(scene.get(), pattern.get(), 1)); render();
    ov_midi_message(0x90, 67, 100); render(); ov_midi_message(0x80, 67, 0); render();
    assert(engine(0).arpeggiator.processor().heldCount() && engine(1).arpeggiator.processor().heldCount());
    assert(ov_seq_launch(0, 0, 2)); render();
    assert(ov_seq_pending(0) == 0 && engine(0).arpeggiator.processor().heldCount());
    while (ov_seq_active(0) < 0) render();
    assert(rack::players[0].previous < rack::players[0].origin);
    assert(!engine(0).arpeggiator.processor().heldCount() && !engine(0).arpeggiator.processor().activeCount());
    assert(engine(1).arpeggiator.processor().heldCount());
    assert(engine(0).parameter(rack::P_ARP_MODE) == rack::A_UP && engine(0).parameter(rack::P_ARP_LATCH) == 1);
    assert(gate(0));
    assert(ov_rack_stop_all()); render();
    // Input-stage clips hand over from live ARP, then feed only their own notes into it.
    pattern->intro = 0; pattern->notes[0].start = 0; pattern->notes[0].output = 0;
    assert(ov_seq_set_clip(pattern.get())); render();
    ov_midi_message(0x90, 69, 100); render();
    assert(ov_seq_launch(0, 0, 0)); render();
    assert(engine(0).arpeggiator.processor().heldCount() == 1);
    uint8_t pitch = 0;
    assert(engine(0).arpeggiator.processor().heldPitch(0, pitch) && pitch == 60);
    assert(engine(1).arpeggiator.processor().heldCount() == 1);
    assert(ov_rack_stop_all()); render();
    // Recording completion goes through the same actual-launch handover.
    assert(ov_seq_arm(0, 1, 2, 1, 1, 1)); render();
    ov_midi_message(0x90, 64, 100); render();
    render(rack::clock.length());
    assert(ov_seq_active(0) == 1 && !engine(0).arpeggiator.processor().heldCount());
    assert(engine(1).arpeggiator.processor().heldCount());
    assert(ov_seq_record_result() == 1 && ov_seq_read_record(pattern.get()));
    assert(ov_rack_stop_all()); render();
    assert(!ov_rack_take_error());
    std::puts("PASS launch handover: queued ARP plays until pickup starts, then only its logical column stops; row, Input/Output and record-autoplay preserve ARP/Latch modes and other columns");
}

static void checkPadTapTransitions()
{
    auto scene = std::make_unique<ov_scene_config>();
    scene->tempo = 120; scene->slots[0] = {1, config(rack::A_UP)};
    scene->slots[0].config.parameters[rack::P_ARP_LATCH] = 1;
    scene->slots[1] = {1, config(rack::A_UP)};
    scene->slots[1].config.parameters[rack::P_ARP_LATCH] = 1;
    auto result = std::make_unique<ov_seq_clip>();
    assert(ov_rack_load(scene.get())); render();
    auto tap = [&] { assert(ov_seq_tap(0, 0, 0, 1, 0, 1, 0)); render(); };
    tap();
    assert(ov_seq_record_phase() == 1 && ov_seq_recording_row() == 0);
    ov_midi_message(0x90, 60, 100); render(2048); ov_midi_message(0x80, 60, 0); render();
    tap();
    assert(ov_seq_record_phase() == 5 && !ov_seq_record_ready());
    const auto finishAt = rack::recorder.stopAt;
    tap();
    assert(rack::recorder.stopAt == finishAt);
    while (rack::recorder.running) render();
    assert(ov_seq_recording_slot() == -1 && ov_seq_recording_row() == -1);
    assert(ov_seq_active(0) == 0 && ov_seq_record_ready());
    assert(rack::players[0].origin == finishAt);
    // The UI can still think this pad is recording; audio must treat its next tap as playback Stop.
    tap();
    assert(ov_seq_active(0) == 0 && ov_seq_stopping(0));
    const auto stopAt = rack::players[0].pendingStart;
    tap();
    assert(rack::players[0].pendingStart == stopAt);
    while (ov_seq_active(0) >= 0) render();
    assert(rack::musicalPosition.value >= stopAt && !ov_seq_stopping(0));
    assert(!engine(0).arpeggiator.processor().heldCount() && !gate(0));
    assert(engine(1).arpeggiator.processor().heldCount() && gate(1));
    assert(ov_seq_record_result() == 1 && ov_seq_read_record(result.get()));
    assert(result->length == 3840 && !ov_rack_take_error());
    tap();
    assert(ov_seq_active(0) == 0 && !ov_seq_stopping(0));
    assert(ov_rack_stop_all()); render();
    for (uint32_t output : {0u, 1u}) {
        result->count = 1; result->notes[0] = {1, 0, 8000, 64, 100, output};
        assert(ov_seq_set_clip(result.get())); render();
        tap();
        if (!output) assert(engine(0).arpeggiator.processor().heldCount());
        tap(); assert(ov_seq_stopping(0));
        while (ov_seq_active(0) >= 0) render();
        assert(!engine(0).arpeggiator.processor().heldCount() && !gate(0));
        for (const auto& note : rack::players[0].active) assert(!note.used);
    }
    assert(!ov_rack_take_error());
    std::puts("PASS audio-owned short taps: empty arm, recording finish queues once, record-to-loop before mailbox read, stale UI tap stops playback at bar, repeated taps preserve deadline, restart and Input/Latch release");
}

static void checkConsecutiveTakes()
{
    auto scene = std::make_unique<ov_scene_config>();
    scene->tempo = 120;
    for (uint32_t slot = 0; slot < 3; ++slot) scene->slots[slot] = {1, config()};
    assert(ov_rack_load(scene.get())); render();
    const auto epoch = ov_seq_scene_epoch();
    std::array<int64_t, 3> origins {};
    for (uint32_t slot = 0; slot < 3; ++slot) {
        assert(ov_seq_tap(slot, 0, 2, 1, 0, 1, 0)); render();
        while (ov_seq_record_phase() != 3) render();
        ov_note_on(60 + slot, 100); render(2048); ov_note_off(60 + slot); render();
        assert(ov_seq_tap(slot, 0, 2, 1, 0, 1, 0)); render();
        assert(ov_seq_record_phase() == 5);
        while (rack::recorder.running) render();
        assert(ov_seq_record_phase() == 0 && ov_seq_recording_slot() == -1);
        origins[slot] = rack::players[slot].origin;
        for (uint32_t previous = 0; previous <= slot; ++previous) {
            assert(ov_seq_active(previous) == 0 && rack::players[previous].origin == origins[previous]);
        }
    }
    auto result = std::make_unique<ov_seq_clip>();
    for (uint32_t slot = 0; slot < 3; ++slot) {
        uint32_t status = 0; uint64_t generation = 0;
        assert(ov_seq_read_completion(result.get(), &status, &generation));
        assert(status == 1 && generation == epoch && result->slot == slot && result->count == 1);
    }
    assert(!ov_seq_record_ready() && !ov_rack_take_error());
    // Reserve capacity before capture; unread results cannot be overwritten even by cancellation.
    for (uint32_t i = 0; i < rack::completionCapacity; ++i) {
        assert(ov_rack_stop_all()); render();
        assert(ov_seq_arm(0, 1, 0, 1, 0, 1)); render();
        assert(ov_seq_finish_record()); render();
        assert(ov_seq_recording_slot() == -1);
    }
    assert(ov_seq_arm(0, 1, 0, 1, 0, 1)); render();
    assert(ov_seq_recording_slot() == -1 && ov_rack_take_error() == 4);
    for (uint32_t i = 0; i < rack::completionCapacity; ++i) {
        assert(ov_seq_record_result() == 2 && ov_seq_read_record(result.get()));
        assert(result->slot == 0 && result->row == 1);
    }
    assert(!ov_seq_record_ready());
    assert(ov_seq_arm(0, 1, 0, 1, 0, 1)); render();
    assert(ov_seq_recording_slot() == 0);
    assert(ov_rack_load(scene.get())); render();
    uint32_t status = 0; uint64_t generation = 0;
    assert(ov_seq_read_completion(result.get(), &status, &generation));
    assert(status == 2 && generation != ov_seq_scene_epoch());
    assert(!ov_seq_record_ready() && !ov_rack_take_error());
    std::puts("PASS consecutive A/B/C takes without UI polling: independent players, FIFO exactly once, reserved completion capacity, explicit backpressure and scene epochs");
}

static void checkPatternMove()
{
    auto scene = std::make_unique<ov_scene_config>();
    scene->tempo = 120;
    for (uint32_t slot = 0; slot < 3; ++slot) scene->slots[slot] = {1, config(rack::A_UP)};
    auto source = std::make_unique<ov_seq_clip>(clip(0, 0, 0));
    auto other = std::make_unique<ov_seq_clip>(clip(2, 0));
    assert(ov_rack_load_sequenced(scene.get(), source.get(), 1)); render();
    assert(ov_seq_set_clip(other.get())); assert(ov_seq_launch(0, 0, 0)); assert(ov_seq_launch(2, 0, 0)); render();
    const auto unrelatedOrigin = rack::players[2].origin;
    auto move = [&](uint32_t target, uint64_t revision, uint64_t token) {
        assert(ov_seq_edit(source.get(), target, 1, 0, ov_seq_scene_epoch(),
            ov_seq_cell_revision(0, 0), revision, token)); render();
        ov_seq_edit_result result {};
        assert(ov_seq_read_edit(&result) && result.token == token);
        assert(!ov_seq_read_edit(&result));
        return result.success;
    };
    assert(!move(1, ov_seq_cell_revision(1, 1) + 1, 1));
    assert(rack::clips[0][0] && !rack::clips[1][1] && ov_seq_active(0) == 0);
    assert(move(1, ov_seq_cell_revision(1, 1), 2));
    assert(!rack::clips[0][0] && rack::clips[1][1] && ov_seq_active(0) == -1 && ov_seq_active(1) == -1);
    const auto& moved = rack::clips[1][1]->pattern.data();
    assert(moved.id == 10 && moved.notes[0].routing.instruments == (1u << 1));
    assert(moved.notes[0].start == 0 && moved.notes[0].duration == 480);
    assert(ov_seq_active(2) == 0 && rack::players[2].origin == unrelatedOrigin);
    assert(!gate(0) && !engine(0).arpeggiator.processor().heldCount());
    assert(!ov_rack_take_error());
    assert(ov_rack_stop_all()); render();
    std::puts("PASS transactional MOVE: stale destination rejection, cross-column retarget, affected-only Stop, immutable publication and acknowledgement");
}

int main()
{
    ov_init(); checkRack(); checkRecording(); checkPadRecording(); checkLaunchHandover(); checkPadTapTransitions(); checkConsecutiveTakes(); checkPatternMove(); ov_rack_collect();
}
