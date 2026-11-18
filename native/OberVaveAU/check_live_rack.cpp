// SPDX-License-Identifier: GPL-3.0-only
#include <cassert>
#include <chrono>
#include <cstdio>
#include <vector>
#include "../../ios/OberVave/SynthRack.cpp"

namespace music = ob1::music;
static uint64_t compared = 0;

struct Output {
    std::vector<music::Event> events;
    static bool receive(void* context, const music::Event& event) noexcept
    {
        static_cast<Output*>(context)->events.push_back(event);
        return true;
    }
};

static void checkAudio()
{
    uint32_t previousSource = 0;
    for (uint32_t mode = 0; mode < rack::NARPMODE; ++mode)
        for (uint32_t latch = 0; latch < 3; ++latch)
            for (uint32_t voices = 0; voices <= rack::PDEF[rack::P_MODE].max; ++voices) {
                Output output;
                output.events.reserve(8192);
                auto live = std::make_unique<rack::NativeEngine<true>>(7, 3, Output::receive, &output);
                auto reference = std::make_unique<rack::NativeEngine<false>>();
                for (auto* engine : {static_cast<rack::SynthEngine*>(live.get()),
                                     static_cast<rack::SynthEngine*>(reference.get())}) {
                    engine->parameter(rack::P_ARP_MODE, mode);
                    engine->parameter(rack::P_ARP_LATCH, latch);
                    engine->parameter(rack::P_MODE, voices);
                }
                const uint8_t messages[][3] = {
                    {0x90, 60, 100}, {0x90, 64, 80}, {0x90, 67, 110}, {0xB0, 64, 127},
                    {0x80, 60, 0}, {0x90, 64, 0}, {0xE0, 1, 80}, {0xB0, 1, 90},
                    {0xD0, 70, 0}, {0xA0, 67, 100}, {0x90, 69, 100}, {0x80, 67, 0},
                    {0xB0, 64, 0}, {0x80, 69, 0}, {0xB0, 120, 0}
                };
                uint32_t frame = 0;
                for (const auto& bytes : messages) {
                    music::Event event {};
                    assert(music::decodeMIDI(bytes[0], bytes[1], bytes[2],
                        {music::SourceKind::ExternalMIDI, 10}, {frame}, event) == music::EventError::None);
                    live->controllerInput(bytes[0], bytes[1], bytes[2]);
                    reference->controllerInput(bytes[0], bytes[1], bytes[2]);
                    assert(live->event(event) && reference->event(event));
                    for (uint32_t block = 0; block < 64; ++block) {
                        frame += CTL;
                        rack::Timing timing {frame, 22032, double(frame) / 22032, 0};
                        int32_t expected[CTL * 2], actual[CTL * 2];
                        reference->render(timing, expected); live->render(timing, actual);
                        assert(std::equal(std::begin(expected), std::end(expected), std::begin(actual)));
                        assert(live->dsp.rnd_state == reference->dsp.rnd_state);
                        assert(!live->arpeggiator.faulted());
                        ++compared;
                    }
                }
                for (const auto& event : output.events) {
                    assert(event.source.kind == music::SourceKind::Arpeggiator && event.source.id);
                    assert(event.routing.stage == music::Stage::Output && event.routing.instruments == (1 << 7));
                    assert(event.channel == 3 && event.time.frame && event.time.frame % CTL == 0 && event.note);
                    if (event.kind == music::Kind::NoteOff) {
                        const auto on = std::find_if(output.events.begin(), output.events.end(),
                            [&](const auto& prior) {
                                return prior.kind == music::Kind::NoteOn && prior.note == event.note &&
                                    prior.source == event.source && prior.time.frame <= event.time.frame;
                            });
                        assert(on != output.events.end());
                    }
                }
                if (!output.events.empty()) {
                    assert(output.events.front().source.id > previousSource);
                    previousSource = output.events.front().source.id;
                }
            }
    assert(!ov_rack_take_error());
    std::printf("PASS live standalone adapter: %llu stereo/RNG blocks match legacy across every ARP/Latch/voice mode, generated slot/channel/lifetime ID/Off identity/control timestamps\n",
        static_cast<unsigned long long>(compared));
}

static void checkLifecycle()
{
    for (uint32_t voice = 0; voice < 4; ++voice) {
        auto live = std::make_unique<rack::NativeEngine<true>>();
        auto reference = std::make_unique<rack::NativeEngine<false>>();
        rack::SynthEngine* engines[] = {live.get(), reference.get()};
        auto parameter = [&](uint32_t p, uint8_t value) {
            for (auto* engine : engines) engine->parameter(p, value);
        };
        parameter(rack::P_MODE, voice);
        parameter(rack::P_CTL1_SRC, rack::CS_CC0 + 20);
        parameter(rack::P_CTL1_DST, rack::P_ARP_MODE);
        parameter(rack::P_CTL1_MIN, 0);
        parameter(rack::P_CTL1_MAX, 127);
        parameter(rack::P_CTL2_SRC, rack::CS_CC0 + 21);
        parameter(rack::P_CTL2_DST, rack::P_ARP_LATCH);
        parameter(rack::P_CTL2_DEPTH, 127);
        parameter(rack::P_CTL2_MODE, 1);
        uint32_t random = 0x7ab12934, frame = 0;
        const auto next = [&]() { random = random * 1664525u + 1013904223u; return random; };
        for (uint32_t operation = 0; operation < 4096; ++operation) {
            const auto value = next();
            uint32_t status = 0xB0, d1 = 1, d2 = (value >> 16) & 127;
            switch (value % 12) {
            case 0: status = 0x90; d1 = 60 + (value >> 8) % 8; d2 = 100; break;
            case 1: status = 0x80; d1 = 60 + (value >> 8) % 8; d2 = 0; break;
            case 2: d1 = 64; d2 = value & 256 ? 127 : 0; break;
            case 3: d1 = 20; break;
            case 4: d1 = 21; break;
            case 5: parameter(rack::P_ARP_MODE, (value >> 8) % rack::NARPMODE); break;
            case 6: parameter(rack::P_ARP_LATCH, (value >> 8) % 3); break;
            case 7: status = 0xE0; d1 = value & 127; break;
            case 8: status = 0xD0; d1 = d2; d2 = 0; break;
            case 9: status = 0xA0; d1 = 60 + (value >> 8) % 8; break;
            case 10: for (auto* engine : engines) engine->stop(); break;
            default: parameter(rack::P_ARP_GATE, d2); break;
            }
            music::Event event {};
            assert(music::decodeMIDI(status, d1, d2, {}, {frame}, event) == music::EventError::None);
            for (auto* engine : engines) {
                engine->boundary({frame});
                engine->controllerInput(status, d1, d2);
                assert(engine->event(event));
            }
            for (uint32_t block = 0; block < 4; ++block) {
                frame += CTL;
                rack::Timing timing {frame, 22032, double(frame) / 22032, 0};
                int32_t expected[CTL * 2], actual[CTL * 2];
                reference->render(timing, expected); live->render(timing, actual);
                assert(std::equal(std::begin(expected), std::end(expected), std::begin(actual)));
                assert(live->dsp.rnd_state == reference->dsp.rnd_state && !live->arpeggiator.faulted());
            }
        }
    }
    assert(!ov_rack_take_error());
    std::puts("PASS production parameter/controller lifecycle: 16384 mixed VALUE/MOD, UI, mode/Latch, Sustain, pressure, pitch bend, Stop/rearm operations and 65536 bit-exact stereo/RNG blocks");
}

static void checkClock()
{
    for (uint32_t division = 0; division < rack::NDIV; ++division)
        for (uint32_t grid = 0; grid <= 5; ++grid) {
            auto live = std::make_unique<rack::NativeEngine<true>>();
            auto reference = std::make_unique<rack::NativeEngine<false>>();
            rack::SynthEngine* engines[] = {live.get(), reference.get()};
            for (auto* engine : engines) {
                engine->parameter(rack::P_ARP_MODE, rack::A_UP);
                engine->parameter(rack::P_ARP_DIV, division);
                engine->sync(true, grid);
                for (uint32_t pitch : {60, 64, 67}) {
                    music::Event note {};
                    assert(music::decodeMIDI(0x90, pitch, 100, {}, {88192}, note) == music::EventError::None);
                    assert(engine->event(note));
                }
            }
            uint32_t frame = 88192;
            for (int32_t advance : {0, 441, -882, 22050, -22050, 0})
                for (uint32_t block = 0; block < 256; ++block) {
                    frame += CTL;
                    rack::Timing timing {frame, 22050, double(frame) / 22050, advance};
                    int32_t expected[CTL * 2], actual[CTL * 2];
                    reference->render(timing, expected); live->render(timing, actual);
                    assert(std::equal(std::begin(expected), std::end(expected), std::begin(actual)));
                    assert(live->arpeggiator.processor().counter() == reference->dsp.arp[0].cnt);
                    assert(!live->arpeggiator.faulted());
                }
        }
    assert(!ov_rack_take_error());
    std::puts("PASS production clock: all 7 divisions/6 start grids, signed live compensation and exact legacy audio/counter on 64512 stereo blocks");
}

static void render(uint32_t frames = CTL)
{
    float left[256], right[256];
    while (frames) {
        const auto count = std::min(frames, 256u);
        ov_render(left, right, count);
        for (uint32_t i = 0; i < count; ++i) assert(std::isfinite(left[i]) && std::isfinite(right[i]));
        frames -= count;
    }
}
static rack::OberVaveEngine& engine(uint32_t slot)
{
    return static_cast<rack::OberVaveEngine&>(*rack::scene->slots[slot]->engine);
}
static uint32_t held(uint32_t slot) { return engine(slot).arpeggiator.processor().heldCount(); }
static ov_instrument_config config(uint32_t channel, uint32_t mode)
{
    ov_instrument_config c {};
    c.engine = OV_ENGINE_OBERVAVE; c.channel = channel; c.high_note = 127; c.program = 17; c.grid = 2;
    for (uint32_t p = 0; p < rack::NPARAM; ++p) {
        c.parameters[p] = ov_rack_factory_parameter(17, p);
        c.cc[p] = ov_rack_default_cc(p);
    }
    c.parameters[rack::P_ARP_MODE] = mode;
    c.parameters[rack::P_ARP_LATCH] = 0;
    return c;
}

static void checkRack()
{
    ov_init();
    ov_scene_config scene {};
    scene.tempo = 120;
    const auto a = ov_midi_source_open(), b = ov_midi_source_open();
    assert(a && b);
    auto send = [&](uint32_t source, uint32_t status, uint32_t pitch, uint32_t velocity, uint32_t delay = 0) {
        assert(ov_midi_source_message_at(source, status, pitch, velocity, ov_audio_frame() + delay));
    };
    for (uint32_t mode = 0; mode < rack::NARPMODE; ++mode) {
        for (uint32_t slot = 0; slot < rack::capacity; ++slot) scene.slots[slot] = {1, config(slot + 1, mode)};
        assert(ov_rack_load(&scene)); render();
        for (uint32_t slot = 0; slot < rack::capacity; ++slot) {
            assert(engine(slot).dsp.externalArpeggiator[0]);
            send(a, 0x90 | slot, 60, 100);
            send(b, 0x90 | slot, 60, 90);
        }
        render(512);
        for (uint32_t slot = 0; slot < rack::capacity; ++slot) {
            assert(held(slot) == 1 && rack::scene->slots[slot]->noteOwners.count() == 2);
            assert(!engine(slot).dsp.nheld[0] && engine(slot).dsp.nq_r == engine(slot).dsp.nq_w);
            send(a, 0x80 | slot, 60, 0);
        }
        render();
        for (uint32_t slot = 0; slot < rack::capacity; ++slot) {
            assert(held(slot) == 1);
            assert(ov_rack_configure(slot, (slot + 1) % 16 + 1, 70, 90, 0, 0, 0));
        }
        render();
        for (uint32_t slot = 0; slot < rack::capacity; ++slot) send(b, 0x80 | slot, 60, 0);
        render();
        for (uint32_t slot = 0; slot < rack::capacity; ++slot) assert(!held(slot));
    }
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) scene.slots[slot] = {1, config(1, rack::A_HOLD_LEGATO)};
    assert(ov_rack_load(&scene)); render();
    ov_keyboard_note_on(60, 100, 1); send(a, 0x90, 60, 100); render();
    ov_keyboard_note_off(60, 1); render();
    assert(held(0) == 1);
    send(a, 0xB0, 64, 127); send(b, 0xB0, 64, 127);
    send(a, 0x80, 60, 0); render();
    assert(held(0) == 1);
    send(a, 0xB0, 64, 0); render(); assert(held(0) == 1);
    send(b, 0xB0, 64, 0); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) assert(!held(slot));

    send(a, 0x90, 60, 100); send(b, 0x90, 64, 100); render();
    send(a, 0x90, 67, 100, 1024);
    send(b, 0x90, 69, 100, 1024);
    assert(ov_midi_source_close(a)); render();
    assert(held(0) == 1 && rack::scheduledCount == 1);
    render(2048);
    assert(held(0) == 2);
    assert(ov_midi_source_close(b)); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) assert(!held(slot));
    ov_rack_select(0);
    ov_set_parameter(rack::P_ARP_LATCH, 1); render();
    ov_note_on(60, 100); ov_note_off(60); render();
    assert(held(0) == 1);
    ov_midi_message(0xFC, 0, 0); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) {
        assert(!held(slot) && !engine(slot).arpeggiator.processor().activeCount());
        for (const auto& voice : engine(slot).dsp.vc) assert(!voice.gate);
    }
    assert(engine(0).parameter(rack::P_ARP_LATCH) == 1);
    // VALUE route edits ARP mode through the same lifecycle as direct UI edits.
    ov_set_parameter(rack::P_CTL1_SRC, rack::CS_CC0 + 1);
    ov_set_parameter(rack::P_CTL1_DST, rack::P_ARP_MODE);
    ov_set_parameter(rack::P_CTL1_MIN, 0);
    ov_set_parameter(rack::P_CTL1_MAX, 127);
    ov_midi_message(0xB0, 1, 127); render();
    assert(engine(0).parameter(rack::P_ARP_MODE) == rack::NARPMODE - 1);
    ov_midi_message(0xB0, 1, 0); render();
    assert(engine(0).parameter(rack::P_ARP_MODE) == 0);
    // The extended emission timeline must not wrap with the legacy MIDI deadline.
    rack::clock.frame = UINT32_MAX - 15;
    rack::processedFrames = UINT64_C(0x1fffffff0);
    ov_set_parameter(rack::P_ARP_MODE, rack::A_UP);
    ov_note_on(60, 100); render(CTL * 2);
    assert(engine(0).currentTime.frame > UINT32_MAX && held(0) == 1);
    ov_all_notes_off(); render();
    assert(!held(0) && !ov_rack_take_error());
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) scene.slots[slot] = {1, config(slot + 1, rack::A_UP)};
    assert(ov_rack_load(&scene)); render();
    for (uint32_t slot = 0; slot < rack::capacity; ++slot) ov_midi_message(0x90 | slot, 60, 100);
    render();
    const auto start = std::chrono::steady_clock::now();
    render(44100);
    const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("PASS 16 production extracted arpeggiators render 1 second in %.3f seconds on this Mac\n", elapsed);
    const auto source = rack::nextArpeggiatorSource.load();
    rack::nextArpeggiatorSource.store(UINT32_MAX);
    assert(!ov_rack_load(&scene) && ov_rack_take_error() == 2);
    assert(held(0) == 1);
    rack::nextArpeggiatorSource.store(source);
    ov_all_notes_off(); render();
    assert(!held(0) && !ov_rack_take_error());
    music::Event owned {};
    assert(music::decodeMIDI(0x90, 60, 100, {music::SourceKind::Pattern, 1},
        {rack::processedFrames}, owned) == music::EventError::None);
    owned.routing = {music::Target::Instruments, 1, music::Stage::Input};
    for (uint32_t i = 0; i <= music::NoteOwnership::capacity; ++i) {
        owned.note = i + 1;
        rack::routeEvent(owned);
    }
    assert(ov_rack_take_error() == 1);
    render();
    assert(!held(0) && !rack::scene->slots[0]->noteOwners.count());
    const auto overflowSource = ov_midi_source_open();
    assert(overflowSource);
    send(overflowSource, 0x90, 60, 100); render();
    for (uint32_t i = 0; i < rack::queueSize; ++i) ov_set_parameter(rack::P_CUTOFF, 64);
    assert(!ov_midi_source_close(overflowSource) && ov_rack_take_error() == 1);
    render();
    assert(!held(0) && !engine(0).arpeggiator.processor().activeCount());
    ov_rack_collect();
    std::puts("PASS production extracted-ARP rack: 16 instances/all modes, no legacy held/FIFO activity, source/channel/touch ownership, captured routing, pedals, disconnect/scheduled cleanup, Latch, Stop/rearm, VALUE controls and 64-bit wrap");
}

int main()
{
    checkAudio();
    checkLifecycle();
    checkClock();
    checkRack();
}
