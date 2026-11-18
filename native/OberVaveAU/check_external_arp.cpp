// SPDX-License-Identifier: GPL-3.0-only
#include "../Musical/Arpeggiator.h"
#include "../OberVave/ArpeggiatorContext.h"
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
    bool useCallback = false;
    uint32_t callbacks = 0;
    music::ArpSettings effectiveSettings {};

    auto sink()
    {
        return [this](const music::Event& e) {
            return external->external_note(0, e.data1, e.kind == music::Kind::NoteOn ? e.data2 : 0);
        };
    }

    static bool tick(void* context, Engine& engine, uint32_t part, uint32_t offset) noexcept
    {
        auto& self = *static_cast<AudioComparison*>(context);
        assert(&engine == self.external.get() && part == 0 && offset == CTL);
        ArpeggiatorContext current {};
        if (!arpeggiator_context(engine, part, {self.frames - CTL + offset}, current)) return false;
        self.effectiveSettings = current.settings;
        self.clock = current.clock;
        auto output = self.sink();
        if (self.arp.configure(current.settings, current.clock.time, output) != music::ArpResult::Ok ||
            self.arp.seed(engine.rnd_state) != music::ArpResult::Ok ||
            self.arp.tick(current.clock, output) != music::ArpResult::Ok) return false;
        engine.rnd_state = self.arp.randomState();
        ++self.callbacks;
        return true;
    }

    AudioComparison(uint32_t voiceMode, uint32_t arpMode, uint32_t phase, bool callback = false)
        : useCallback(callback)
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
            if (!useCallback) {
                clock.time = {frames};
                assert(arp.seed(legacy->rnd_state) == music::ArpResult::Ok);
                auto output = sink();
                assert(arp.tick(clock, output) == music::ArpResult::Ok);
                external->rnd_state = arp.randomState();
            }
            int32_t reference[CTL * 2] {}, actual[CTL * 2] {};
            legacy->render_audio(reference, CTL);
            if (useCallback) assert(external->render_audio_with_arpeggiator(actual, CTL, tick, this));
            else external->render_audio(actual, CTL);
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

static void checkAudio(bool callback)
{
    uint64_t blocks = 0;
    for (uint32_t voice = 0; voice < 4; ++voice)
        for (uint32_t mode = 1; mode < NARPMODE; ++mode)
            for (uint32_t phase = 0; phase < 3; ++phase) {
                AudioComparison c(voice, mode, phase, callback);
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
                assert(c.callbacks == (callback ? c.compared : 0));
                blocks += c.compared;
            }
    std::printf("PASS %s: %llu bit-identical stereo control blocks across all 4 voice modes, 8 ARP modes and 3 LFO phases, glide, sustain, Latch, effects and Stop\n",
        callback ? "effective-patch callback" : "explicit external-ARP bypass", static_cast<unsigned long long>(blocks));
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

static void checkEffectiveControllers()
{
    uint64_t blocks = 0;
    for (uint32_t mode = 1; mode < NARPMODE; ++mode) {
        AudioComparison c(M_UNISON, mode, LP_SYNC, true);
        c.input(0x90, 60, 100); c.input(0x90, 64, 80); c.input(0x90, 67, 110);
        const uint8_t targets[] = {P_ARP_DIV, P_ARP_OCT, P_ARP_GATE, P_ARP_VEL,
            P_MODE, P_UNI_DET, P_SPREAD, P_GLIDE, P_LFO_PHASE, P_CUTOFF, P_RESO,
            P_ARP_MODE, P_ARP_LATCH};
        for (auto* engine : {c.legacy.get(), c.external.get()}) {
            engine->ctl_arp_sync = 1;
            engine->ctl_arp_sync_grid = 3;
            engine->livePhaseAdjustment = true;
            for (uint32_t slot = 0; slot < std::size(targets); ++slot) {
                const uint8_t fields[] = {uint8_t(CS_CC0 + 20 + slot), targets[slot], 1,
                    0, 128, uint8_t(targets[slot] == P_ARP_LATCH ? 0 : (slot % 2 ? 80 : 48)), 1};
                for (uint32_t f = 0; f < CONTROLLER_FIELDS; ++f)
                    engine->apply_parameter(P_CTL1_SRC + slot * CONTROLLER_FIELDS + f, fields[f]);
            }
        }
        const auto base = c.external->live_p[0];
        c.render(40);
        for (const uint8_t value : {127, 32, 96, 0, 64, 127, 0}) {
            for (uint32_t slot = 0; slot < std::size(targets); ++slot) {
                for (auto* engine : {c.legacy.get(), c.external.get()})
                    engine->controller_input(0xB0, 20 + slot, value);
                c.input(0xB0, 20 + slot, value);
                c.render(24);
                const auto& e = *c.external;
                assert(std::equal(std::begin(base.v), std::end(base.v), std::begin(e.live_p[0].v)));
                if (slot == 2 && value == 127) assert(c.effectiveSettings.gate != c.settings.gate);
            }
            for (auto* engine : {c.legacy.get(), c.external.get()}) {
                engine->phaseAdvance = value > 64 ? 256 : -512;
                engine->ctl_ext_quarter = value > 64 ? 1200 : 768;
                engine->hostClock = true;
                engine->hostBeat = value / 32.0;
                engine->hostTempo = 60.0 * FS / engine->ctl_ext_quarter;
                engine->hostFrame = engine->eng_t;
            }
            c.render(40);
            assert(c.clock.time.frame == c.frames && c.clock.hasMasterPhase);
            assert(c.clock.advanceFrames == c.external->phaseAdvance);
            assert(c.clock.quarterFrames == c.external->quarter_len());
        }
        for (auto* engine : {c.legacy.get(), c.external.get()})
            for (uint32_t slot = 0; slot < std::size(targets); ++slot)
                engine->apply_parameter(P_CTL1_SRC + slot * CONTROLLER_FIELDS, CS_OFF);
        c.render(40);
        c.input(0x80, 60, 0); c.input(0x80, 64, 0); c.input(0x80, 67, 0);
        blocks += c.compared;
    }
    std::printf("PASS effective controller bridge: %llu bit-identical stereo blocks with signed temporary ARP/voice-start modulation, restored base patch, shared DSP RNG, tempo, host phase and latency changes\n",
        static_cast<unsigned long long>(blocks));
}

static void checkCallbackContract()
{
    auto engine = std::make_unique<Engine>();
    engine->initialize();
    ArpeggiatorContext unused {};
    assert(!arpeggiator_context(*engine, 0, {}, unused));
    assert(!arpeggiator_context(*engine, NPART, {}, unused));
    assert(engine->set_external_arpeggiator(0, true));
    assert(engine->set_external_arpeggiator(1, true));
    assert(!arpeggiator_context(*engine, 0, {}, unused));
    struct Probe {
        uint32_t calls[NPART] {};
        bool reject = false;
        uint64_t start = uint64_t(UINT32_MAX) - 31;
        static bool tick(void* context, Engine& engine, uint32_t part, uint32_t offset) noexcept
        {
            auto& probe = *static_cast<Probe*>(context);
            ++probe.calls[part];
            assert(offset % CTL == 0 && offset <= 64);
            assert(offset == probe.calls[part] * CTL);
            ArpeggiatorContext current {};
            assert(arpeggiator_context(engine, part, {probe.start + offset}, current));
            assert(current.clock.time.frame == probe.start + offset);
            assert(engine.eng_t == uint32_t(probe.start + offset));
            assert(current.settings.mode == music::ArpMode(engine.pt[part].p->v[P_ARP_MODE]));
            if (part == 0 && probe.reject) {
                assert(engine.external_note(part, 60, 100));
                return false;
            }
            return true;
        }
    } probe;
    engine->eng_t = uint32_t(probe.start);
    int32_t audio[128] {};
    assert(engine->render_audio_with_arpeggiator(audio, 64, Probe::tick, &probe));
    assert(probe.calls[0] == 4 && probe.calls[1] == 4);
    for (uint32_t part = 2; part < NPART; ++part) assert(!probe.calls[part]);
    assert(!engine->arpeggiatorTick && !engine->arpeggiatorContext && !engine->controllerRendering);
    probe.calls[0] = probe.calls[1] = 0;
    probe.start += 64;
    probe.reject = true;
    const auto patch = engine->live_p[0];
    assert(!engine->render_audio_with_arpeggiator(audio, 64, Probe::tick, &probe));
    assert(probe.calls[0] == 1 && probe.calls[1] == 4);
    for (const auto& voice : engine->vc) assert(voice.part != 0 || !voice.gate);
    assert(std::equal(std::begin(patch.v), std::end(patch.v), std::begin(engine->live_p[0].v)));
    assert(!engine->arpeggiatorTick && !engine->arpeggiatorContext && !engine->controllerRendering);
    engine->render_audio(audio, 64);
    assert(probe.calls[0] == 1 && probe.calls[1] == 4);
    std::puts("PASS control-boundary callback: per-part order/offsets, 64-bit time across DSP counter wrap, scoped lifetime, explicit failure, failed-part cleanup and independent other parts");
}

static void checkDirectVoices()
{
    uint64_t checked = 0;
    for (uint32_t mode = 0; mode < 4; ++mode)
        for (const uint8_t glide : {0, 60})
            for (uint32_t latch = 0; latch < 3; ++latch) {
                auto legacy = std::make_unique<Engine>();
                auto external = std::make_unique<Engine>();
                music::ArpeggiatorProcessor keys;
                music::ArpSettings settings;
                settings.latch = music::Latch(latch);
                const auto noGenerated = [](const music::Event&) { std::abort(); return false; };
                auto sink = noGenerated;
                assert(keys.configure(settings, {}, sink) == music::ArpResult::Ok);
                uint8_t last = 99;
                assert(!keys.lastHeld(last) && last == 99);
                for (auto* engine : {legacy.get(), external.get()}) {
                    engine->initialize();
                    engine->apply_parameter(P_MODE, mode);
                    engine->apply_parameter(P_ARP_MODE, A_OFF);
                    engine->apply_parameter(P_ARP_LATCH, latch);
                    engine->apply_parameter(P_GLIDE, glide);
                }
                assert(external->set_external_arpeggiator(0, true));
                const auto release = [&](uint32_t pitch) {
                    uint8_t lastHeld = 0;
                    const bool hasHeld = keys.lastHeld(lastHeld);
                    assert(external->external_direct_note(0, pitch, 0, hasHeld, lastHeld));
                };
                const auto compare = [&]() {
                    for (uint32_t block = 0; block < 24; ++block) {
                        int32_t reference[CTL * 2] {}, actual[CTL * 2] {};
                        legacy->render_audio(reference, CTL);
                        external->render_audio(actual, CTL);
                        assert(std::equal(std::begin(reference), std::end(reference), std::begin(actual)));
                        assert(legacy->vseq == external->vseq && legacy->rnd_state == external->rnd_state);
                        for (uint32_t v = 0; v < NV; ++v) {
                            assert(legacy->vc[v].gate == external->vc[v].gate);
                            assert(legacy->vc[v].note == external->vc[v].note);
                            assert(legacy->vc[v].target16 == external->vc[v].target16);
                            assert(legacy->vc[v].ae.level == external->vc[v].ae.level);
                        }
                        ++checked;
                    }
                    assert(legacy->nheld[0] == keys.heldCount());
                    assert(!external->nheld[0]);
                };
                bool sustain = false;
                const auto note = [&](uint8_t pitch, uint8_t velocity) {
                    music::Event event {};
                    assert(music::decodeMIDI(0x90, pitch, velocity, {}, {}, event) == music::EventError::None);
                    legacy->poly_pressure_valid[pitch] = external->poly_pressure_valid[pitch] = 1;
                    assert(legacy->midi(0x90, pitch, velocity, false, false));
                    legacy->engine_events();
                    assert(keys.input(event, sink) == music::ArpResult::Bypassed);
                    if (velocity) {
                        uint8_t held = 0;
                        assert(keys.lastHeld(held) && held == pitch);
                        assert(external->external_direct_note(0, pitch, velocity, true, held));
                        assert(!external->poly_pressure_valid[pitch]);
                    } else if (!sustain) release(pitch);
                    compare();
                };
                note(60, 100); note(64, 80); note(67, 110);
                note(64, 0); note(67, 0); // Mono/Unison return to 60 without retrigger.
                note(60, 100); // Repeated pitch replaces its held-key position.
                note(60, 0);
                music::Event pedal {};
                assert(music::decodeMIDI(0xB0, 64, 127, {}, {}, pedal) == music::EventError::None);
                assert(legacy->midi(0xB0, 64, 127, false, false));
                legacy->engine_events();
                assert(keys.input(pedal, sink) == music::ArpResult::Ok);
                sustain = true;
                note(60, 100); note(64, 90); note(67, 80);
                note(60, 0); note(67, 0);
                pedal.data2 = 0;
                assert(legacy->midi(0xB0, 64, 0, false, false));
                legacy->engine_events();
                assert(keys.input(pedal, sink) == music::ArpResult::Ok);
                sustain = false;
                release(60); release(67);
                compare();
                note(64, 0);
                assert(!external->external_direct_note(NPART, 60, 100, false));
                assert(!external->external_direct_note(0, 128, 100, false));
                assert(!external->external_direct_note(0, 60, 128, false));
                assert(!external->external_direct_note(0, 60, 0, true, 128));
                external->apply_parameter(P_ARP_MODE, A_UP);
                assert(!external->external_direct_note(0, 60, 100, false));
                external->apply_parameter(P_ARP_MODE, A_OFF);
                assert(external->set_external_arpeggiator(0, false));
                assert(!external->external_direct_note(0, 60, 100, false));
            }
    std::printf("PASS direct Off-mode voices: %llu bit-identical stereo blocks, all voice modes/Latch settings, glide, ordered mono fallback, repeated notes, Sustain cleanup, physical-key pressure reset and invalid-call rejection\n",
        static_cast<unsigned long long>(checked));
}

int main()
{
    checkAudio(false);
    checkAudio(true);
    checkEffectiveControllers();
    checkCallbackContract();
    checkTransitions();
    checkDirectVoices();
}
