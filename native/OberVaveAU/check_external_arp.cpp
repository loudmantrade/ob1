// SPDX-License-Identifier: GPL-3.0-only
#include "../Musical/Arpeggiator.h"
#include "../OberVave/Engine.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <memory>

namespace music = ob1::music;
using namespace obervave;

struct AudioComparison {
    std::unique_ptr<Engine> legacy = std::make_unique<Engine>();
    std::unique_ptr<Engine> external = std::make_unique<Engine>();
    music::ArpeggiatorProcessor arp;
    music::ArpSettings settings;
    music::ArpClock clock;
    uint64_t frames = 0;
    uint64_t compared = 0;
    uint64_t nonzero = 0;

    auto sink()
    {
        return [this](const music::Event& e) {
            return external->external_note(0, e.data1, e.kind == music::Kind::NoteOn ? e.data2 : 0);
        };
    }

    AudioComparison(uint32_t voiceMode, uint32_t arpMode, uint32_t phase)
    {
        legacy->initialize(); external->initialize();
        for (auto* engine : {legacy.get(), external.get()}) {
            engine->apply_parameter(P_MODE, voiceMode);
            engine->apply_parameter(P_ARP_MODE, arpMode);
            engine->apply_parameter(P_ARP_LATCH, 2);
            engine->apply_parameter(P_ARP_DIV, 6);
            engine->apply_parameter(P_ARP_GATE, 64);
            engine->apply_parameter(P_ARP_OCT, 2);
            engine->apply_parameter(P_GLIDE, 40);
            engine->apply_parameter(P_LFO_PHASE, phase);
            engine->apply_parameter(P_LFO_PITCH, 30);
            engine->apply_parameter(P_LFO_RATE, 127);
            engine->apply_parameter(P_CHO_MIX, 40);
            engine->apply_parameter(P_DLY_MIX, 30);
            engine->apply_parameter(P_REV_MIX, 30);
            engine->ctl_ext_quarter = 768;
        }
        assert(external->set_external_arpeggiator(0, true));
        settings.mode = music::ArpMode(arpMode);
        settings.latch = music::Latch::Replace;
        settings.division = 6; settings.octaves = 2;
        clock.quarterFrames = 768;
        auto output = sink();
        assert(arp.configure(settings, {}, output) == music::ArpResult::Ok);
    }

    void input(uint32_t status, uint32_t a, uint32_t b)
    {
        music::Event e {};
        assert(music::decodeMIDI(status, a, b, {}, {frames}, e) == music::EventError::None);
        assert(legacy->midi(status, a, b, false, false));
        legacy->engine_events();
        if (music::isNote(e)) {
            assert(!external->midi(status, a, b, false, false));
        } else {
            assert(external->midi(status, a, b, false, false));
            external->engine_events();
        }
        auto output = sink();
        const auto result = arp.input(e, output);
        assert(result == music::ArpResult::Ok || result == music::ArpResult::Bypassed);
    }

    void render(uint32_t blocks)
    {
        for (uint32_t block = 0; block < blocks; ++block) {
            frames += CTL;
            clock.time = {frames};
            assert(arp.seed(legacy->rnd_state) == music::ArpResult::Ok);
            auto output = sink();
            assert(arp.tick(clock, output) == music::ArpResult::Ok);
            external->rnd_state = arp.randomState();
            int32_t reference[CTL * 2] {}, actual[CTL * 2] {};
            legacy->render_audio(reference, CTL);
            external->render_audio(actual, CTL);
            for (uint32_t i = 0; i < CTL * 2; ++i) {
                nonzero += reference[i] != 0;
                if (reference[i] != actual[i]) {
                    std::fprintf(stderr, "Audio differs: frame=%llu sample=%u arp=%u voices=%u lfo=%u (%d != %d)\n",
                        static_cast<unsigned long long>(frames), i, unsigned(settings.mode),
                        legacy->live_p[0].v[P_MODE], legacy->live_p[0].v[P_LFO_PHASE], reference[i], actual[i]);
                    std::abort();
                }
            }
            assert(legacy->vseq == external->vseq);
            assert(legacy->rnd_state == external->rnd_state);
            for (uint32_t i = 0; i < NV; ++i) {
                assert(legacy->vc[i].gate == external->vc[i].gate);
                assert(legacy->vc[i].ae.level == external->vc[i].ae.level);
                assert(legacy->vc[i].fe.level == external->vc[i].fe.level);
                assert(legacy->vc[i].o1.ph == external->vc[i].o1.ph);
            }
            assert(external->live_p[0].v[P_ARP_MODE] == unsigned(settings.mode));
            assert(!external->nheld[0] && !external->arp[0].note_count);
            legacy->arp_qr = legacy->arp_qw;
            ++compared;
        }
    }
};

static void checkAudio()
{
    uint64_t blocks = 0;
    for (uint32_t voice = 0; voice < 4; ++voice)
        for (uint32_t mode = 1; mode < NARPMODE; ++mode)
            for (uint32_t phase = 0; phase < 3; ++phase) {
                AudioComparison c(voice, mode, phase);
                c.input(0x90, 60, 100); c.input(0x90, 64, 80); c.input(0x90, 67, 110);
                c.render(120);
                c.input(0x80, 60, 0); c.render(12);
                c.input(0x90, 69, 90); c.render(120);
                c.input(0xB0, 64, 127);
                c.input(0x80, 64, 0); c.input(0x80, 67, 0);
                c.render(20);
                c.input(0xB0, 64, 0); c.render(20);
                c.input(0x80, 69, 0); c.render(120);
                // Latch Off must not interfere with externally held generated voices.
                c.legacy->apply_parameter(P_ARP_LATCH, 0);
                c.external->apply_parameter(P_ARP_LATCH, 0);
                c.settings.latch = music::Latch::Off;
                auto sink = c.sink();
                assert(c.arp.configure(c.settings, {c.frames}, sink) == music::ArpResult::Ok);
                c.render(120);
                c.input(0x90, 72, 100); c.render(40);
                c.legacy->engine_transport_stop();
                assert(c.arp.stop({c.frames}, sink) == music::ArpResult::Ok);
                c.external->engine_transport_stop();
                assert(c.external->externalArpeggiator[0]);
                c.render(120);
                assert(c.nonzero);
                blocks += c.compared;
            }
    std::printf("PASS explicit external-ARP bypass: %llu bit-identical stereo control blocks across all 4 voice modes, 8 ARP modes and 3 LFO phases, glide, sustain, Latch, effects and Stop\n",
        static_cast<unsigned long long>(blocks));
}

static void checkTransitions()
{
    auto e = std::make_unique<Engine>();
    e->initialize();
    e->apply_parameter(P_ARP_MODE, A_HOLD_LEGATO);
    e->apply_parameter(P_ARP_LATCH, 2);
    e->note_event_p(0, 1, 60, 100);
    e->note_event_p(1, 1, 67, 100);
    const auto patch = e->live_p[0];
    assert(!e->set_external_arpeggiator(NPART, true));
    assert(!e->external_note(0, 60, 100));
    assert(e->set_external_arpeggiator(0, true));
    assert(e->nq_w - e->nq_r == 1 && e->nq[e->nq_r % NQ].part == 1);
    e->engine_events();
    assert(!e->external_note(0, 128, 100) && !e->external_note(0, 60, 128));
    assert(!e->external_note(NPART, 60, 100));
    assert(e->external_note(0, 60, 100));
    const auto sequence = e->vseq;
    assert(e->set_external_arpeggiator(0, true));
    assert(e->vseq == sequence);
    e->ctl_sustain = 1;
    e->engine_events();
    // Neither raw note queues nor Sustain release may replace generated note ownership.
    e->note_event_p(0, 1, 72, 100);
    e->note_event_p(0, 0, 60, 0);
    e->ctl_sustain = 0;
    e->engine_events();
    assert(!e->nheld[0] && e->nheld[1] == 1 && e->vseq == sequence);
    for (uint32_t block = 0; block < 64; ++block) {
        int32_t audio[CTL * 2] {};
        e->render_audio(audio, CTL);
    }
    const auto gated = [&e](uint32_t pitch) {
        return std::any_of(std::begin(e->vc), std::end(e->vc), [pitch](const auto& voice) {
            return voice.part == 0 && voice.note == pitch && voice.gate;
        });
    };
    assert(gated(60));
    assert(e->external_note(0, 60, 0) && !gated(60));
    assert(std::equal(std::begin(patch.v), std::end(patch.v), std::begin(e->live_p[0].v)));
    // Resetting saved performance parameters is not a bypass implementation.
    assert(e->external_note(0, 64, 100));
    e->apply_parameter(P_ARP_MODE, A_OFF);
    e->apply_parameter(P_ARP_LATCH, 0);
    assert(gated(64));
    assert(e->external_note(0, 64, 0));
    assert(e->external_note(0, 65, 100));
    e->ctl_panic = 1;
    e->engine_events();
    assert(!gated(65) && e->externalArpeggiator[0]);
    e->apply_parameter(P_ARP_MODE, A_UP);
    assert(e->set_external_arpeggiator(0, false));
    assert(!e->external_note(0, 60, 100));
    assert(e->midi(0x90, 60, 100));
    e->engine_events();
    int32_t audio[CTL * 2] {};
    e->render_audio(audio, CTL);
    assert(e->arp[0].sounding && e->nheld[0] == 1);
    assert(e->live_p[0].v[P_ARP_MODE] == A_UP && e->nheld[1] == 0);
    e->nq_r = e->nq_w = UINT32_MAX - 5;
    for (uint32_t i = 0; i < NQ; ++i) e->note_event_p(i % NPART, 1, i, 100);
    assert(e->set_external_arpeggiator(0, true));
    assert(e->nq_w - e->nq_r == NQ * (NPART - 1) / NPART);
    uint32_t expected = 0;
    for (auto read = e->nq_r; read != e->nq_w; ++read) {
        while (expected % NPART == 0) ++expected;
        assert(e->nq[read % NQ].note == expected++);
    }
    e->initialize();
    assert(!e->externalArpeggiator[0]);
    std::puts("PASS bypass switching, validation, part isolation, pending-note cleanup, raw note rejection, saved patch preservation and reversible legacy path");
}

int main()
{
    checkAudio();
    checkTransitions();
}
