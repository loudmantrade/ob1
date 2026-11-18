// SPDX-License-Identifier: GPL-3.0-only
#include "../OberVave/ArpeggiatorAdapter.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

using namespace obervave;
namespace music = ob1::music;

struct Comparison {
    std::unique_ptr<Engine> legacy = std::make_unique<Engine>();
    std::unique_ptr<Engine> external = std::make_unique<Engine>();
    ArpeggiatorAdapter adapter {*external};
    uint64_t frame = 0, blocks = 0, nonzero = 0;
    uint64_t lastOutputFrame = 0;
    std::vector<music::Event> output;
    std::array<music::NoteID, 128> sounding {};
    static bool receive(void* context, const music::Event& event) noexcept
    {
        auto& self = *static_cast<Comparison*>(context);
        assert(music::validate(event) == music::EventError::None);
        assert(event.routing.stage == music::Stage::Output);
        assert(event.routing.target == music::Target::Instruments && event.routing.instruments == (1u << 7));
        assert(event.channel == 9 && event.source.kind == music::SourceKind::Arpeggiator &&
               event.source.id == 42 && event.note);
        auto& owner = self.sounding[event.data1];
        if (event.kind == music::Kind::NoteOn) {
            assert(!owner);
            owner = event.note;
        } else {
            assert(event.kind == music::Kind::NoteOff && owner == event.note);
            owner = 0;
        }
        self.output.push_back(event);
        return true;
    }
    explicit Comparison(ArpeggiatorAdapter::InputOwnership ownership =
                            ArpeggiatorAdapter::InputOwnership::LegacyPitch)
    {
        legacy->initialize();
        external->initialize();
        assert(adapter.attach(7, 9, 42, receive, this, ownership));
        assert(!adapter.attach());
    }
    void parameter(uint32_t p, uint8_t value)
    {
        legacy->apply_parameter(p, value);
        assert(adapter.parameter(p, value, {frame}));
        compareState();
    }
    void input(uint32_t status, uint32_t a, uint32_t b, bool fixed = false)
    {
        music::Event event {};
        assert(music::decodeMIDI(status, a, b, {}, {frame}, event) == music::EventError::None);
        assert(legacy->midi(status, a, b, fixed));
        legacy->engine_events();
        assert(adapter.input(event, fixed));
        compareState();
    }
    void compareState(uint32_t renderedFrames = 0)
    {
        if (legacy->vseq != external->vseq) {
            std::fprintf(stderr, "Voice triggers differ frame=%llu mode=%u (%u != %u)\n",
                static_cast<unsigned long long>(frame), legacy->live_p[0].v[P_ARP_MODE],
                legacy->vseq, external->vseq);
            std::abort();
        }
        assert(legacy->nheld[0] == adapter.processor().heldCount());
        assert(legacy->arp[0].note_count == adapter.processor().activeCount());
        assert(std::equal(std::begin(legacy->live_p[0].v), std::end(legacy->live_p[0].v),
                          std::begin(external->live_p[0].v)));
        assert(legacy->rnd_state == external->rnd_state);
        for (uint32_t v = 0; v < NV; ++v) {
            assert(legacy->vc[v].gate == external->vc[v].gate);
            assert(legacy->vc[v].note == external->vc[v].note);
            assert(legacy->vc[v].ae.level == external->vc[v].ae.level);
            assert(legacy->vc[v].fe.level == external->vc[v].fe.level);
            assert(legacy->vc[v].target16 == external->vc[v].target16);
        }
        assert(output.size() == legacy->arp_qw - legacy->arp_qr);
        for (const auto& event : output) {
            const auto& expected = legacy->arp_q[legacy->arp_qr++ % AQ];
            assert(event.kind == (expected.on ? music::Kind::NoteOn : music::Kind::NoteOff));
            assert(event.data1 == expected.note && event.data2 == expected.vel);
            assert(event.time.frame <= frame && event.time.frame >= lastOutputFrame);
            if (renderedFrames) {
                assert(event.time.frame > frame - renderedFrames);
                assert((event.time.frame - (frame - renderedFrames)) % CTL == 0);
            } else assert(event.time.frame == frame);
            lastOutputFrame = event.time.frame;
        }
        output.clear();
    }
    void render(uint32_t count = 1)
    {
        for (uint32_t block = 0; block < count; ++block) {
            renderBuffer(CTL);
        }
    }
    void renderBuffer(uint32_t frames)
    {
        assert(frames && frames <= HALF_FRAMES && frames % CTL == 0);
        int32_t reference[HALF_FRAMES * 2] {}, actual[HALF_FRAMES * 2] {};
        legacy->render_audio(reference, frames);
        assert(adapter.render(actual, frames, {frame}));
        frame += frames;
        for (uint32_t i = 0; i < frames * 2; ++i) nonzero += reference[i] != 0;
        if (!std::equal(reference, reference + frames * 2, actual)) {
            std::fprintf(stderr, "Adapter audio differs frame=%llu mode=%u voice=%u\n",
                static_cast<unsigned long long>(frame), legacy->live_p[0].v[P_ARP_MODE],
                legacy->live_p[0].v[P_MODE]);
            std::abort();
        }
        compareState(frames);
        blocks += frames / CTL;
    }
    void stop()
    {
        legacy->engine_transport_stop();
        assert(adapter.stop({frame}));
        compareState();
    }
    void route(uint32_t slot, uint8_t cc, uint8_t target, bool mod, bool overrideInput)
    {
        const uint8_t fields[] = {uint8_t(CS_CC0 + cc), target, uint8_t(mod), 0, 128, 80,
            uint8_t(overrideInput)};
        for (uint32_t f = 0; f < CONTROLLER_FIELDS; ++f)
            parameter(P_CTL1_SRC + slot * CONTROLLER_FIELDS + f, fields[f]);
    }
};

static void checkOutputFailure()
{
    struct Sink {
        std::array<music::NoteID, 128> notes {};
        uint32_t calls = 0, rejectAt = 2, accepted = 0;
        static bool receive(void* context, const music::Event& event) noexcept
        {
            auto& sink = *static_cast<Sink*>(context);
            if (++sink.calls == sink.rejectAt) return false;
            auto& note = sink.notes[event.data1];
            if (event.kind == music::Kind::NoteOn) {
                assert(!note);
                note = event.note;
            } else {
                assert(note == event.note);
                note = 0;
            }
            ++sink.accepted;
            return true;
        }
    } sink;
    auto engine = std::make_unique<Engine>();
    engine->initialize();
    ArpeggiatorAdapter adapter {*engine};
    assert(!adapter.attach(16) && !engine->externalArpeggiator[0]);
    assert(!adapter.attach(0, 16) && !engine->externalArpeggiator[0]);
    assert(!adapter.attach(0, 0, 0, nullptr, &sink));
    assert(adapter.attach(15, 15, 123, Sink::receive, &sink));
    assert(adapter.parameter(P_ARP_MODE, A_CHORD, {}));
    const auto input = [&](uint32_t pitch) {
        music::Event event {};
        assert(music::decodeMIDI(0x90, pitch, 100, {}, {}, event) == music::EventError::None);
        assert(adapter.input(event));
    };
    input(60); input(64); input(67);
    int32_t audio[CTL * 2] {};
    assert(!adapter.render(audio, CTL, {}) && adapter.faulted());
    assert(sink.accepted == 1 && sink.notes[60] && adapter.processor().activeCount() == 1);
    for (const auto& voice : engine->vc) assert(!voice.gate);
    assert(!adapter.attach()); // Cannot replace the destination while releases are pending.
    sink.rejectAt = sink.calls + 1;
    assert(!adapter.stop({16}) && adapter.faulted());
    assert(sink.notes[60] && adapter.processor().activeCount() == 1);
    sink.rejectAt = 0;
    assert(adapter.stop({16}) && !adapter.faulted());
    assert(!sink.notes[60] && !adapter.processor().activeCount());
    input(72);
    assert(adapter.render(audio, CTL, {16}));
    assert(sink.notes[72]);
    assert(adapter.stop({32}) && !sink.notes[72]);
    std::puts("PASS generated-output rejection: accepted-note ownership retained, failed Note Off retried, DSP gates released, destination immutable and Stop recovery");
}

static void checkSourceOwnership()
{
    for (uint8_t mode = 0; mode < NARPMODE; ++mode) {
        for (uint8_t latch = 0; latch < 3; ++latch) {
            auto engine = std::make_unique<Engine>();
            engine->initialize();
            ArpeggiatorAdapter adapter {*engine};
            assert(adapter.attach(0, 0, 0, nullptr, nullptr,
                                  ArpeggiatorAdapter::InputOwnership::SourceNotes));
            assert(adapter.parameter(P_ARP_MODE, mode, {}));
            assert(adapter.parameter(P_ARP_LATCH, latch, {}));
            music::Event midi {}, touch {};
            assert(music::decodeMIDI(0x90, 60, 100, {music::SourceKind::ExternalMIDI, 1}, {}, midi)
                   == music::EventError::None);
            touch = midi;
            touch.source = {music::SourceKind::TouchKeyboard, 1};
            assert(adapter.input(midi) && adapter.input(touch) && adapter.inputOwnerCount() == 2);
            int32_t audio[CTL * 2] {};
            assert(adapter.render(audio, CTL, {}));
            const auto sequence = engine->vseq;
            midi.kind = music::Kind::NoteOff; midi.data2 = 0; midi.time.frame = CTL;
            assert(adapter.input(midi) && adapter.inputOwnerCount() == 1);
            assert(adapter.processor().heldCount() == 1);
            // Stale source Off must not remove the other source's physical key.
            assert(adapter.input(midi) && engine->vseq == sequence);
            assert(adapter.render(audio, CTL, {CTL}));
            if (mode == A_OFF || mode >= A_CHORD) {
                assert(std::any_of(std::begin(engine->vc), std::end(engine->vc), [](const auto& voice) {
                    return voice.gate && voice.note == 60;
                }));
            }
            assert(adapter.releaseSource(touch.source, {CTL * 2}));
            assert(adapter.inputOwnerCount() == 0);
            assert(adapter.processor().heldCount() == (mode && latch ? 1u : 0u));
            assert(adapter.stop({CTL * 2}));
            for (const auto& voice : engine->vc) assert(!voice.gate);
            assert(!adapter.inputOwnerCount() && !adapter.processor().heldCount());
            touch.note = 7;
            assert(adapter.input(touch));
            touch.note = 8;
            assert(adapter.input(touch) && adapter.inputOwnerCount() == 2);
            touch.kind = music::Kind::NoteOff; touch.data2 = 0;
            assert(adapter.input(touch) && adapter.inputOwnerCount() == 1);
            music::Event pedal {};
            assert(music::decodeMIDI(0xB0, 64, 127, {}, {32}, pedal) == music::EventError::None);
            assert(adapter.input(pedal));
            touch.note = 7;
            assert(adapter.input(touch) && !adapter.inputOwnerCount());
            assert(adapter.processor().heldCount() == 1);
            pedal.data2 = 0;
            assert(adapter.input(pedal) && !adapter.processor().heldCount());
            touch.kind = music::Kind::NoteOn; touch.data2 = 100;
            assert(adapter.input(touch));
            music::Event panic {};
            assert(music::decodeMIDI(0xB0, 123, 0, {}, {32}, panic) == music::EventError::None);
            assert(adapter.input(panic) && !adapter.inputOwnerCount());
        }
    }
    auto engine = std::make_unique<Engine>();
    engine->initialize();
    ArpeggiatorAdapter adapter {*engine};
    assert(adapter.attach(0, 0, 0, nullptr, nullptr, ArpeggiatorAdapter::InputOwnership::SourceNotes));
    music::Event note {};
    assert(music::decodeMIDI(0x90, 60, 100, {}, {}, note) == music::EventError::None);
    for (uint32_t i = 0; i < music::NoteOwnership::capacity; ++i) {
        note.note = i + 1;
        assert(adapter.input(note));
    }
    note.note = music::NoteOwnership::capacity + 1;
    assert(!adapter.input(note) && adapter.faulted());
    assert(adapter.inputOwnerCount() == music::NoteOwnership::capacity);
    for (const auto& voice : engine->vc) assert(!voice.gate);
    assert(adapter.stop({}) && !adapter.inputOwnerCount() && !adapter.faulted());
    std::puts("PASS source-aware adapter: shared pitch across keyboard/MIDI and note IDs, unmatched release, source cleanup, Sustain/Latch, Panic/Stop and explicit capacity-fault recovery");
}

int main()
{
    checkSourceOwnership();
    checkOutputFailure();
    {
        Comparison c;
        music::Event invalid {};
        invalid.kind = music::Kind::NoteOn;
        invalid.data1 = 60; invalid.data2 = 100;
        invalid.routing.stage = music::Stage::Output;
        assert(!c.adapter.input(invalid));
        invalid.routing.stage = music::Stage::Input;
        invalid.data1 = 128;
        assert(!c.adapter.input(invalid));
        assert(!c.adapter.parameter(NPARAM, 0, {}));
        assert(!c.adapter.parameter(P_ARP_MODE, 255, {}));
        int32_t audio[CTL * 2] {};
        assert(!c.adapter.render(nullptr, CTL, {}));
        assert(!c.adapter.render(audio, 0, {}));
        assert(!c.adapter.render(audio, 1, {}));
        assert(!c.adapter.render(audio, HALF_FRAMES + CTL, {}));
        assert(!c.adapter.render(audio, CTL, {UINT64_MAX}));
        c.compareState();
        c.input(0x90, 60, 100); c.render(4);
        auto failed = std::make_unique<Engine>();
        failed->initialize();
        ArpeggiatorAdapter recovering {*failed};
        assert(recovering.attach());
        music::Event note {};
        assert(music::decodeMIDI(0x90, 60, 100, {}, {}, note) == music::EventError::None);
        assert(recovering.input(note));
        // A corrupt effective setting must surface failure and release DSP gates.
        failed->ctl_arp_sync_grid = 255;
        assert(!recovering.render(audio, CTL, {}) && recovering.faulted());
        for (const auto& voice : failed->vc) assert(!voice.gate);
        assert(!failed->arpeggiatorTick && !failed->controllerRendering);
        assert(!recovering.input(note) && !recovering.parameter(P_ARP_MODE, 0, {}));
        failed->ctl_arp_sync_grid = 0;
        assert(recovering.stop({CTL}));
        assert(recovering.input(note));
        assert(recovering.render(audio, CTL, {CTL}) && !recovering.faulted());
        auto engine = std::make_unique<Engine>();
        engine->initialize();
        assert(engine->set_external_arpeggiator(1, true));
        ArpeggiatorAdapter occupied {*engine};
        assert(!occupied.attach() && !engine->externalArpeggiator[0]);
    }
    uint64_t blocks = 0;
    for (const auto ownership : {ArpeggiatorAdapter::InputOwnership::LegacyPitch,
                                 ArpeggiatorAdapter::InputOwnership::SourceNotes})
      for (uint8_t voice = 0; voice < 4; ++voice)
        for (uint8_t mode = 1; mode < NARPMODE; ++mode)
            for (uint8_t latch = 0; latch < 3; ++latch) {
                Comparison c(ownership);
                c.parameter(P_MODE, voice);
                c.parameter(P_ARP_MODE, A_OFF);
                c.parameter(P_ARP_LATCH, latch);
                c.parameter(P_ARP_DIV, 6);
                c.parameter(P_GLIDE, 40);
                for (auto* e : {c.legacy.get(), c.external.get()}) e->ctl_ext_quarter = 768;
                c.input(0x90, 60, 100); c.input(0x90, 64, 80); c.render(8);
                c.input(0x80, 64, 0); c.render(8);
                c.parameter(P_ARP_MODE, mode); c.render(30);
                c.input(0x90, 67, 110); c.render(30);
                c.input(0xB0, 64, 127);
                c.input(0x80, 60, 0); c.input(0x80, 67, 0); c.render(20);
                c.parameter(P_ARP_MODE, A_OFF); c.render(8);
                c.input(0x90, 69, 90); c.render(8);
                c.input(0xB0, 64, 0); c.render(8);
                c.input(0x90, 72, 100); c.render(8);
                c.input(0x80, 72, 0); c.render(8);
                c.parameter(P_ARP_MODE, mode); c.render(40);
                for (auto* e : {c.legacy.get(), c.external.get()}) e->ctl_arp_restart = 1;
                c.render(4);
                c.input(0x80, 69, 0); c.render(20);
                c.parameter(P_ARP_LATCH, 0); c.render(20);
                c.input(0x90, 60, 100); c.render(20);
                c.stop(); c.render(8);
                c.input(0x90, 64, 100); c.render(20);
                c.input(0xB0, 123, 0); c.render(8);
                c.input(0x90, 67, 100); c.render(20);
                c.input(0xB0, 120, 0); c.render(8);
                c.stop();
                assert(c.nonzero);
                blocks += c.blocks;
            }
    std::printf("PASS native input adapter: %llu bit-identical stereo blocks across ARP Off/On handovers, all voice/ARP/Latch modes, Sustain, glide, Stop/rearm and Panic\n",
        static_cast<unsigned long long>(blocks));
    blocks = 0;
    for (uint8_t mode = 1; mode < NARPMODE; ++mode) {
        Comparison c;
        c.parameter(P_ARP_MODE, mode);
        c.parameter(P_ARP_LATCH, 2);
        c.parameter(P_ARP_DIV, 6);
        for (auto* e : {c.legacy.get(), c.external.get()}) e->ctl_ext_quarter = 768;
        c.route(0, 20, P_ARP_MODE, false, true);
        c.route(1, 21, P_ARP_LATCH, false, true);
        c.route(2, 22, P_ARP_GATE, true, true);
        c.route(3, 23, P_MODE, true, true);
        c.route(4, 24, P_ARP_MODE, true, true);
        c.route(5, 64, P_CUTOFF, false, true);
        c.route(6, 123, P_RESO, false, true);
        c.route(7, 20, P_ARP_LATCH, false, true);
        c.route(8, 74, P_RESO, false, true);
        c.input(0x90, 60, 100); c.input(0x90, 64, 100); c.render(20);
        for (const uint8_t value : {0, 127, 32, 96, 64, 0}) {
            c.input(0xB0, 64, 127); c.render(2);
            c.input(0xA0, 67, 80); c.input(0x90, 67, 100); c.render(8);
            assert(!c.external->poly_pressure_valid[67]);
            c.input(0xB0, 123, 0); c.render(8); // OVERRIDE does not panic.
            for (const uint8_t cc : {20, 21, 22, 23, 24}) {
                c.input(0xB0, cc, value); c.render(24);
            }
            c.input(0x80, 67, 0); c.render(8);
            c.input(0xB0, 64, 0); c.render(8);
            c.input(0xE0, 0, value); c.input(0xD0, value, 0);
            c.input(0xB0, 121, 0); c.render(8);
            c.input(0xB0, 74, value, true); c.render(4);
            c.input(0xB0, 73, value, true); c.render(4);
        }
        c.parameter(P_CTL6_SRC, CS_OFF);
        c.input(0xB0, 64, 127);
        c.input(0x80, 60, 0); c.input(0x80, 64, 0); c.render(20);
        c.input(0xB0, 64, 0); c.render(20);
        c.stop();
        blocks += c.blocks;
    }
    std::printf("PASS native controller adapter: %llu bit-identical stereo blocks, sequential VALUE/MOD routes, temporary mode changes, Sustain/Panic OVERRIDE, pressure, bend and reset controllers\n",
        static_cast<unsigned long long>(blocks));
    blocks = 0;
    for (uint32_t seed = 1; seed <= 8; ++seed) {
        Comparison c;
        uint32_t random = seed;
        for (auto* e : {c.legacy.get(), c.external.get()}) e->ctl_ext_quarter = 768;
        c.route(0, 20, P_ARP_MODE, false, false);
        c.route(1, 21, P_ARP_LATCH, true, true);
        c.route(2, 22, P_ARP_MODE, true, true);
        for (uint32_t operation = 0; operation < 2000; ++operation) {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5;
            const auto pitch = uint8_t(60 + (random >> 8) % 8);
            switch (random % 14) {
            case 0: case 1: case 2: c.input(0x90, pitch, 40 + (random >> 16) % 88); break;
            case 3: case 4: c.input(0x80, pitch, 0); break;
            case 5: c.parameter(P_ARP_MODE, (random >> 8) % NARPMODE); break;
            case 6: c.parameter(P_ARP_LATCH, (random >> 8) % 3); break;
            case 7: c.parameter(P_MODE, (random >> 8) % 4); break;
            case 8: c.input(0xB0, 64, (random >> 8) & 127); break;
            case 9: c.input(0xB0, 20 + (random >> 8) % 3, (random >> 16) & 127); break;
            case 10: c.input(0xB0, 121, 0); break;
            case 11: c.input(0xB0, 123, 0); break;
            case 12: c.stop(); break;
            case 13: c.parameter(P_ARP_GATE, (random >> 8) & 127); break;
            }
            if (random & 1) c.render(1 + (random >> 24) % 8);
        }
        c.stop();
        blocks += c.blocks;
    }
    std::printf("PASS deterministic mixed MIDI/parameter traces: %llu bit-identical stereo blocks across 16000 operations and rapid pre-render mode/controller/transport changes\n",
        static_cast<unsigned long long>(blocks));
    for (uint8_t mode = 1; mode < NARPMODE; ++mode) {
        Comparison c;
        c.frame = uint64_t(UINT32_MAX) - 31;
        c.lastOutputFrame = c.frame;
        c.parameter(P_ARP_MODE, mode);
        c.parameter(P_ARP_LATCH, 2);
        c.parameter(P_ARP_DIV, 6);
        for (auto* engine : {c.legacy.get(), c.external.get()}) {
            engine->eng_t = uint32_t(c.frame);
            engine->ctl_ext_quarter = 768;
            engine->ctl_arp_sync = 1;
            engine->ctl_arp_sync_grid = 3;
            engine->livePhaseAdjustment = true;
        }
        c.input(0x90, 60, 100); c.input(0x90, 64, 90);
        for (const int32_t advance : {0, 256, -512, -2048, 0}) {
            for (auto* engine : {c.legacy.get(), c.external.get()}) engine->phaseAdvance = advance;
            c.renderBuffer(HALF_FRAMES);
            c.renderBuffer(64);
        }
        c.stop();
    }
    std::puts("PASS adapter multi-tick renders and maximum buffers across DSP counter wrap, Master Sync and signed latency changes");
}
