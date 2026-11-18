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
struct EventSink final : rack::SynthEngine {
    std::array<rack::music::Event, 64> received {};
    uint32_t count = 0, stops = 0;
    bool accepting = true;
    void parameter(uint32_t, uint8_t) override {}
    uint8_t parameter(uint32_t) const override { return 0; }
    void controllerInput(uint8_t, uint8_t, uint8_t) override {}
    bool controllerOverride(uint32_t) const override { return false; }
    bool event(const rack::music::Event& e) override
    {
        if (!accepting) return false;
        assert(count < received.size());
        received[count++] = e;
        return true;
    }
    void stop() override { ++stops; }
    void sync(bool, uint32_t) override {}
    void render(const rack::Timing&, int32_t* output) override { std::fill_n(output, CTL * 2, 0); }
    uint32_t voiceLevel(uint32_t) const override { return 0; }
};

static void checkEventBoundary()
{
    namespace music = ob1::music;
    ov_scene_config scene {};
    scene.tempo = 120;
    scene.slots[0] = {1, config(1, 48, 64)};
    scene.slots[1] = {1, config(1, 60, 84)};
    scene.slots[2] = {1, config(2, 48, 64)};
    assert(ov_rack_load(&scene));
    render();
    EventSink* sinks[3] {};
    for (uint32_t slot = 0; slot < 3; ++slot) {
        auto sink = std::make_unique<EventSink>();
        sinks[slot] = sink.get();
        rack::scene->slots[slot]->engine = std::move(sink);
    }
    ov_keyboard_note_on(60, 100, 1); render();
    assert(sinks[0]->count == 1 && sinks[1]->count == 1 && !sinks[2]->count);
    assert(sinks[0]->received[0].source.kind == music::SourceKind::TouchKeyboard);
    assert(sinks[0]->received[0].routing.instruments == 1 && sinks[1]->received[0].routing.instruments == 2);
    ov_keyboard_channels(2);
    ov_keyboard_note_off(60, 1); render();
    assert(sinks[0]->count == 2 && sinks[1]->count == 2 && !sinks[2]->count);
    assert(sinks[0]->received[1].source.kind == music::SourceKind::TouchKeyboard);
    assert(sinks[0]->received[1].kind == music::Kind::NoteOff);
    ov_keyboard_control(0xE0, 0, 64); render();
    assert(sinks[2]->count == 1 && sinks[2]->received[0].source.kind == music::SourceKind::TouchKeyboard);
    ov_midi_message(0x90, 50, 80); render();
    assert(sinks[0]->count == 3 && sinks[1]->count == 2);
    assert(sinks[0]->received[2].source.kind == music::SourceKind::ExternalMIDI);
    ov_midi_message(0x90, 50, 0); render();
    assert(sinks[0]->count == 4 && sinks[0]->received[3].kind == music::Kind::NoteOff);
    ov_midi_message(0x80, 50, 0); render();
    assert(sinks[0]->count == 4);

    music::Event targeted {};
    assert(music::decodeMIDI(0x90, 100, 100, {music::SourceKind::Pattern, 42},
        {rack::processedFrames, 960, true}, targeted) == music::EventError::None);
    targeted.routing = {music::Target::Instruments, 4, music::Stage::Input};
    targeted.note = 77;
    rack::routeEvent(targeted);
    assert(sinks[2]->count == 2 && sinks[0]->count == 4 && sinks[1]->count == 2);
    const auto& received = sinks[2]->received[1];
    assert(received.source == targeted.source && received.note == 77 && received.time.tick == 960);
    assert(received.channel == 0 && received.routing.instruments == 4);
    targeted.kind = music::Kind::NoteOff;
    rack::routeEvent(targeted);
    assert(sinks[2]->count == 3);
    targeted.routing.stage = music::Stage::Output;
    rack::routeEvent(targeted);
    assert(ov_rack_take_error() == 2 && sinks[2]->count == 3);
    targeted.routing.stage = music::Stage::Input;
    targeted.channel = 16;
    rack::routeEvent(targeted);
    assert(ov_rack_take_error() == 2 && sinks[2]->count == 3);

    rack::outputPosition = CTL;
    rack::clock.frame = UINT32_MAX - 15;
    rack::processedFrames = uint64_t(rack::clock.frame);
    const auto first = rack::processedFrames;
    ov_midi_message_at(0x90, 62, 100, 16);
    render(16);
    assert(sinks[0]->count == 4);
    render(16);
    assert(sinks[0]->count == 5 && sinks[1]->count == 3);
    assert(sinks[0]->received[4].time.frame == first + 32);
    assert(sinks[0]->received[4].time.frame > UINT32_MAX);
    ov_midi_message(0x80, 62, 0); render(16);
    const auto stops = sinks[0]->stops;
    sinks[0]->accepting = false;
    ov_midi_message(0x90, 60, 100); render(16);
    assert(ov_rack_take_error() == 2 && sinks[0]->stops == stops + 1);
    assert(!rack::scene->slots[0]->activeNotes[0][60]);
    ov_midi_message(0xFC, 0, 0); render(16);
    assert(sinks[0]->stops == stops + 2);
    ov_scene_config empty {};
    empty.tempo = 120;
    assert(ov_rack_load(&empty)); render();
    ov_rack_collect();
    std::puts("PASS shared event boundary: source identity, split/layer routing, captured keyboard releases, explicit logical targets, arp-output rejection, 32-bit deadline wrap and safe sink failure");
}
static void checkEventAdapter()
{
    namespace music = ob1::music;
    for (uint32_t mode = 0; mode < rack::NARPMODE; ++mode) {
        for (uint32_t latch = 0; latch < 3; ++latch) {
            auto direct = std::make_unique<rack::OberVaveEngine>();
            auto events = std::make_unique<rack::OberVaveEngine>();
            for (auto* engine : {direct.get(), events.get()}) {
                engine->parameter(rack::P_ARP_MODE, mode);
                engine->parameter(rack::P_ARP_LATCH, latch);
            }
            const auto send = [&](uint32_t status, uint32_t a, uint32_t b) {
                music::Event event {};
                assert(music::decodeMIDI(status, a, b, {music::SourceKind::TouchKeyboard, 0}, {}, event)
                    == music::EventError::None);
                event = music::forInstrument(event, 0);
                assert(events->event(event));
                direct->midi(status, a, b);
            };
            const uint8_t messages[][3] = {
                {0x90, 60, 100}, {0x90, 64, 80}, {0x90, 67, 110}, {0xB0, 64, 127},
                {0x80, 60, 0}, {0x90, 64, 0}, {0xE0, 1, 80}, {0xB0, 1, 90},
                {0xD0, 70, 0}, {0xA0, 67, 100}, {0x90, 69, 100}, {0x80, 67, 0},
                {0xB0, 64, 0}, {0x80, 69, 0}, {0xB0, 120, 0}
            };
            uint32_t frame = 0;
            for (const auto& message : messages) {
                send(message[0], message[1], message[2]);
                for (uint32_t block = 0; block < 64; ++block) {
                    frame += CTL;
                    rack::Timing timing {frame, 22032, double(frame) / 22032, 0};
                    int32_t reference[CTL * 2], actual[CTL * 2];
                    direct->render(timing, reference); events->render(timing, actual);
                    assert(std::equal(std::begin(reference), std::end(reference), std::begin(actual)));
                }
            }
        }
    }
    std::puts("PASS event adapter audio is bit-identical to legacy MIDI for every ARP/Latch mode, notes, bend, pressure, sustain and panic");
}
static void checkModulationMatrix()
{
    using namespace rack;
    auto engine = std::make_unique<OberVaveEngine>();
    auto& e = engine->dsp;
    e.apply_parameter(P_VINTAGE, 0);
    e.apply_parameter(P_ARP_MODE, A_OFF);
    e.apply_parameter(P_LFO_DELAY, 0);
    e.ev_note_on(0, 60, 127);
    uint32_t card = 0;
    while (card < NV && !e.vc[card].gate) ++card;
    assert(card < NV);
    auto& voice = e.vc[card];
    voice.fe = {e.E_SUS, ENV_ONE};
    voice.ae = {e.E_SUS, ENV_ONE};
    e.apply_parameter(P_FS, 127);
    e.apply_parameter(P_AS, 127);
    e.block_globals(&e.pt[0]);
    e.midi(0xB0, 1, 127);
    e.midi(0xD0, 127, 0);
    for (uint32_t source = 1; source < NMODSRC; ++source) {
        for (uint32_t destination = 0; destination < NMODDST; ++destination) {
            for (const auto amount : {0, 64, 128}) {
                e.apply_parameter(P_MOD1_SRC, source);
                e.apply_parameter(P_MOD1_DST, destination);
                e.apply_parameter(P_MOD1_AMT, amount);
                int32_t result[NMODDST] {};
                e.modulation_values(&voice, 32767, result);
                for (uint32_t d = 0; d < NMODDST; ++d)
                    assert(result[d] == (d == destination ? (amount - 64) * 32767 / 64 : 0));
            }
        }
    }
    // Per-note pressure overrides channel pressure only on the matching key.
    e.apply_parameter(P_MOD1_SRC, MS_PRESSURE);
    e.apply_parameter(P_MOD1_DST, MD_CUTOFF);
    e.apply_parameter(P_MOD1_AMT, 128);
    e.midi(0xA0, 61, 0);
    int32_t pressure[NMODDST] {};
    e.modulation_values(&voice, 0, pressure);
    assert(pressure[MD_CUTOFF] == 32767);
    e.midi(0xA0, 60, 32);
    std::fill_n(pressure, NMODDST, 0);
    e.modulation_values(&voice, 0, pressure);
    assert(pressure[MD_CUTOFF] == 32 * 32767 / 127);
    e.midi(0xB0, 121, 0);
    assert(e.ctl_mod == 0 && e.ctl_pressure == 0 && !e.poly_pressure_valid[60]);
    for (uint32_t slot = 0; slot < MOD_SLOTS; ++slot) {
        e.apply_parameter(P_MOD1_SRC + slot * 3, MS_VELOCITY);
        e.apply_parameter(P_MOD1_DST + slot * 3, MD_PITCH1);
        e.apply_parameter(P_MOD1_AMT + slot * 3, 128);
    }
    int32_t sum[NMODDST] {};
    e.modulation_values(&voice, -32768, sum);
    assert(sum[MD_PITCH1] == MOD_SLOTS * 32767);
    for (uint32_t slot = 0; slot < MOD_SLOTS; ++slot)
        e.apply_parameter(P_MOD1_SRC + slot * 3, MS_OFF);
    e.apply_parameter(P_WHEEL_LEGACY, 0);
    e.block_globals(&e.pt[0]);
    const auto original = voice;
    e.voice_block(&voice, card);
    const auto neutral = voice;
    for (uint32_t destination = 0; destination < NMODDST; ++destination) {
        voice = original;
        e.apply_parameter(P_MOD1_SRC, MS_VELOCITY);
        e.apply_parameter(P_MOD1_DST, destination);
        e.apply_parameter(P_MOD1_AMT, 128);
        e.voice_block(&voice, card);
        if (destination == MD_PITCH1) assert(voice.inc1 > neutral.inc1 && voice.inc2 == neutral.inc2);
        if (destination == MD_PITCH2) assert(voice.inc2 > neutral.inc2 && voice.inc1 == neutral.inc1);
        if (destination == MD_PWM1) assert(voice.pw1 > neutral.pw1 && voice.pw2 == neutral.pw2);
        if (destination == MD_PWM2) assert(voice.pw2 > neutral.pw2 && voice.pw1 == neutral.pw1);
        if (destination == MD_CUTOFF || destination == MD_RESO)
            assert(std::memcmp(&voice.lc, &neutral.lc, sizeof(voice.lc)) != 0);
        if (destination == MD_VOLUME) assert(voice.amp1 == neutral.amp1 * 2);
        if (destination == MD_PAN) assert(voice.gl < neutral.gl && voice.gr > neutral.gr);
        e.apply_parameter(P_MOD1_SRC, MS_OFF);
        voice = original;
        e.voice_block(&voice, card);
        assert(std::memcmp(&voice, &neutral, sizeof(voice)) == 0);
    }
    e.midi(0xB0, 1, 127);
    e.block_globals(&e.pt[0]);
    assert(e.pt[0].wheel_q == 0 && e.ctl_mod == 127);
    e.apply_parameter(P_WHEEL_LEGACY, 1);
    e.block_globals(&e.pt[0]);
    assert(e.pt[0].wheel_q == 127);
    // Extreme sums remain bounded in every filter and destination.
    for (uint32_t filter = 0; filter < NFTYPE; ++filter) {
        e.apply_parameter(P_FTYPE, filter);
        for (uint32_t destination = 0; destination < NMODDST; ++destination) {
            for (const auto amount : {0, 128}) {
                for (uint32_t slot = 0; slot < MOD_SLOTS; ++slot) {
                    e.apply_parameter(P_MOD1_SRC + slot * 3, MS_VELOCITY);
                    e.apply_parameter(P_MOD1_DST + slot * 3, destination);
                    e.apply_parameter(P_MOD1_AMT + slot * 3, amount);
                }
                int32_t audio[CTL * 2] {};
                e.engine_audio(audio, CTL);
                for (auto sample : audio) assert(sample >= -32768 && sample <= 32767);
            }
        }
    }
    std::puts("PASS matrix: all source/destination/sign combinations, poly/channel pressure, sum, actual oscillator/filter/amp/pan changes, disable restores, legacy wheel and extreme limits");
}
static void checkControllers()
{
    using namespace rack;
    auto engine = std::make_unique<OberVaveEngine>();
    auto& e = engine->dsp;
    auto route = [&](uint32_t slot, uint8_t source, uint8_t target, uint8_t mode,
                     uint8_t low = 0, uint8_t high = 128, uint8_t depth = 64, uint8_t overrideInput = 1) {
        const uint8_t fields[] = {source, target, mode, low, high, depth, overrideInput};
        for (uint32_t f = 0; f < CONTROLLER_FIELDS; ++f)
            e.apply_parameter(P_CTL1_SRC + slot * CONTROLLER_FIELDS + f, fields[f]);
    };
    auto offset = [&]() {
        auto patch = e.live_p[0];
        e.controller_offsets(patch);
        return patch;
    };
    for (uint32_t cc = 0; cc < 128; ++cc) {
        for (uint32_t target = 0; target < CONTROLLER_TARGETS; ++target) {
            route(0, CS_CC0 + cc, target, 0);
            e.midi(0xB0, cc, 0);
            assert(e.live_p[0].v[target] == 0);
            e.midi(0xB0, cc, 127);
            assert(e.live_p[0].v[target] == PDEF[target].max);
        }
    }
    route(0, CS_CC0 + 1, P_CUTOFF, 0, 96, 32);
    e.midi(0xB0, 1, 0);
    assert(e.live_p[0].v[P_CUTOFF] == 95);
    e.midi(0xB0, 1, 127);
    assert(e.live_p[0].v[P_CUTOFF] == 32);
    route(0, CS_BEND, P_LFO_RATE, 0);
    e.midi(0xE0, 0, 0); assert(e.live_p[0].v[P_LFO_RATE] == 0);
    e.midi(0xE0, 0, 64); assert(e.live_p[0].v[P_LFO_RATE] == 64 && e.ctl_bend == 0);
    e.midi(0xE0, 127, 127); assert(e.live_p[0].v[P_LFO_RATE] == 127);
    for (const auto source : {CS_PRESSURE, CS_POLY}) {
        route(0, source, P_CHO_MIX, 0);
        e.midi(source == CS_PRESSURE ? 0xD0 : 0xA0, source == CS_PRESSURE ? 127 : 60, 127);
        assert(e.live_p[0].v[P_CHO_MIX] == 127);
    }
    e.apply_parameter(P_CUTOFF, 64);
    route(0, CS_CC0 + 1, P_CUTOFF, 1, 0, 128, 96);
    e.midi(0xB0, 1, 127);
    assert(offset().v[P_CUTOFF] == 127 && e.live_p[0].v[P_CUTOFF] == 64);
    e.apply_parameter(P_CTL1_DEPTH, 32);
    assert(offset().v[P_CUTOFF] == 1 && e.live_p[0].v[P_CUTOFF] == 64);
    e.apply_parameter(P_CTL1_DEPTH, 64);
    assert(offset().v[P_CUTOFF] == 64);
    route(0, CS_BEND, P_CUTOFF, 1, 0, 128, 96);
    e.midi(0xE0, 0, 0); assert(offset().v[P_CUTOFF] == 1);
    e.midi(0xE0, 0, 64); assert(offset().v[P_CUTOFF] == 64);
    e.midi(0xE0, 127, 127); assert(offset().v[P_CUTOFF] == 127);
    route(0, CS_CC0 + 1, P_CUTOFF, 1, 0, 128, 80);
    route(15, CS_CC0 + 1, P_CUTOFF, 1, 0, 128, 80);
    assert(offset().v[P_CUTOFF] == 126);
    e.apply_parameter(P_CTL16_SRC, CS_OFF);
    assert(offset().v[P_CUTOFF] == 95);
    e.midi(0xB0, 1, 0);
    assert(offset().v[P_CUTOFF] == 64);
    // Override bypasses built-in CC mappings and actions, but not raw modulation sources.
    for (const auto cc : {1u, 7u, 64u, 120u, 121u, 123u}) {
        route(0, CS_CC0 + cc, P_CUTOFF, 0, 0, 128, 64, 1);
        e.ctl_panic = 0;
        e.ctl_sustain = 0;
        e.midi(0xB0, cc, 127);
        assert(e.live_p[0].v[P_CUTOFF] == 127);
        assert(!e.ctl_panic && !e.ctl_sustain);
        if (cc == 7) assert(e.ctl_cc7 == 127);
    }
    route(0, CS_CC0 + 64, P_CUTOFF, 0, 0, 128, 64, 0);
    e.midi(0xB0, 64, 127); assert(e.ctl_sustain == 1);
    e.apply_parameter(P_CTL1_OVERRIDE, 1); assert(e.ctl_sustain == 0);
    route(0, CS_BEND, P_CUTOFF, 0, 0, 128, 64, 0);
    e.midi(0xE0, 127, 127); assert(e.ctl_bend == 8191);
    e.apply_parameter(P_CTL1_OVERRIDE, 1); assert(e.ctl_bend == 0);
    route(0, CS_CC0 + 1, P_CUTOFF, 1, 0, 128, 128);
    e.midi(0xB0, 1, 127);
    e.block_globals(&e.pt[0]); assert(e.pt[0].wheel_q == 0 && e.ctl_mod == 127);
    // Poly pressure modulates each voice independently; global destinations use the latest pressure.
    route(0, CS_POLY, P_O1_PW, 1, 0, 128, 80);
    e.apply_parameter(P_O1_PW, 64);
    e.midi(0xA0, 60, 127);
    e.midi(0xA0, 64, 0);
    e.controllerBase = e.live_p[0];
    e.controllerRendering = true;
    auto note = e.vc[0];
    note.note = 60;
    auto patch = e.live_p[0];
    e.controller_offsets(patch, &note); assert(patch.v[P_O1_PW] == 95);
    note.note = 64;
    e.controller_offsets(patch, &note); assert(patch.v[P_O1_PW] == 64);
    e.controllerRendering = false;
    e.apply_parameter(P_CTL1_SRC, CS_OFF);
    e.apply_parameter(P_ARP_MODE, A_OFF);
    e.apply_parameter(P_ARP_LATCH, 0);
    e.apply_parameter(P_CUTOFF, 64);
    route(0, CS_CC0 + 1, P_CUTOFF, 1, 0, 128, 32);
    e.midi(0xB0, 1, 127);
    int32_t audio[CTL * 2] {};
    e.render_audio(audio, CTL);
    assert(e.live_p[0].v[P_CUTOFF] == 64 && !e.controllerRendering);
    e.apply_parameter(P_CTL1_SRC, CS_OFF);
    e.render_audio(audio, CTL);
    assert(e.live_p[0].v[P_CUTOFF] == 64);
    e.midi(0xB0, 121, 0);
    assert(!e.controllerSeen[CS_CC0 + 1]);
    double polyEnergy[2] {};
    for (uint32_t test = 0; test < 2; ++test) {
        auto polyEngine = std::make_unique<OberVaveEngine>();
        auto& p = polyEngine->dsp;
        p.apply_parameter(P_MODE, M_POLY);
        p.apply_parameter(P_ARP_MODE, A_OFF);
        p.apply_parameter(P_ARP_LATCH, 0);
        p.apply_parameter(P_O1_LVL, 0); p.apply_parameter(P_O2_LVL, 0); p.apply_parameter(P_NOISE, 0);
        p.apply_parameter(P_AA, 0);
        p.apply_parameter(P_CTL1_SRC, CS_POLY);
        p.apply_parameter(P_CTL1_DST, P_O1_LVL);
        p.apply_parameter(P_CTL1_MODE, 1);
        p.apply_parameter(P_CTL1_DEPTH, 128);
        p.midi(0x90, 60, 100); p.midi(0x90, 64, 100);
        p.midi(0xA0, 60, test ? 127 : 0); p.midi(0xA0, 64, 0);
        for (uint32_t block = 0; block < 64; ++block) {
            p.render_audio(audio, CTL);
            for (const auto sample : audio) polyEnergy[test] += std::abs(double(sample));
        }
        assert(p.live_p[0].v[P_O1_LVL] == 0);
    }
    assert(polyEnergy[0] == 0 && polyEnergy[1] > 0);
    std::puts("PASS Controllers: every CC/target, exact min/max/inversion, 14-bit bend, pressure, signed offsets, slot16, overrides, base preservation, per-note poly and reset");
}
int main()
{
    checkEventAdapter();
    checkControllers();
    checkModulationMatrix();
    {
        auto engine = std::make_unique<rack::OberVaveEngine>();
        auto& e = engine->dsp;
        double previousHz = 0;
        for (uint32_t rate = 0; rate < 128; ++rate) {
            e.apply_parameter(rack::P_LFO_RATE, rate);
            e.pt[0].lfo_ph = 0;
            uint32_t wraps = 0, ticks = 0;
            while (wraps < 2) {
                const auto before = e.pt[0].lfo_ph;
                e.lfo_tick(&e.pt[0]);
                wraps += e.pt[0].lfo_ph < before;
                ++ticks;
            }
            const double hz = ov_lfo_rate_hz(rate);
            const double cycles = wraps + double(e.pt[0].lfo_ph) / 4294967296.0;
            const double measured = cycles * FS / (double(ticks) * CTL);
            assert(std::abs(measured - hz) < 1e-10);
            assert(hz > previousHz);
            previousHz = hz;
        }
        std::puts("PASS LFO frequency readout matches two measured DSP phase cycles at all 128 rates");
    }
    for (auto mode : {rack::A_HOLD, rack::A_HOLD_LEGATO}) {
        auto engine = std::make_unique<rack::OberVaveEngine>();
        auto& e = engine->dsp;
        e.apply_parameter(rack::P_MODE, rack::M_POLY);
        e.apply_parameter(rack::P_ARP_MODE, mode);
        e.apply_parameter(rack::P_ARP_LATCH, 2);
        e.ev_note_on(0, 60, 100); e.ev_note_on(0, 64, 90); e.ev_note_on(0, 67, 80);
        e.arp_tick(0);
        uint32_t common = 0;
        while (common < NV && !(e.vc[common].gate && e.vc[common].note == 60)) ++common;
        assert(common < NV);
        e.vc[common].ae.stage = e.E_SUS;
        e.vc[common].ae.level = 123456;
        e.vc[common].fe.level = 234567;
        auto previous = e.vc[common];
        auto starts = e.vseq;
        e.ev_note_off(0, 64); e.ev_note_off(0, 67);
        e.ev_note_on(0, 69, 110); e.arp_tick(0);
        assert(e.arp[0].note_count == 2);
        if (mode == rack::A_HOLD_LEGATO) {
            assert(e.vseq == starts + 1);
            assert(std::memcmp(&previous, &e.vc[common], sizeof(previous)) == 0);
        } else {
            assert(e.vseq == starts + 2);
        }
        for (auto& voice : e.vc) assert(!voice.gate || voice.note == 60 || voice.note == 69);
        starts = e.vseq;
        e.ev_note_on(0, 60, 50); e.arp_tick(0);
        assert(e.vseq == starts + (mode == rack::A_HOLD_LEGATO ? 0u : 2u));
        if (mode == rack::A_HOLD_LEGATO)
            assert(std::memcmp(&previous, &e.vc[common], sizeof(previous)) == 0);
        e.ev_note_off(0, 69);
        e.ev_sustain_up(0); e.arp_tick(0);
        assert(e.arp[0].note_count == 1 && e.arp[0].notes[0] == 60);
        if (mode == rack::A_HOLD_LEGATO)
            assert(std::memcmp(&previous, &e.vc[common], sizeof(previous)) == 0);
        e.ev_note_off(0, 60);
        e.apply_parameter(rack::P_ARP_LATCH, 0); e.arp_tick(0);
        assert(!e.arp[0].sounding && !e.arp[0].note_count);
        for (auto& voice : e.vc) assert(!voice.gate);
    }
    std::puts("PASS Hold Retrigger restarts all voices; Hold Legato preserves common voice/envelope state, starts only additions and releases only removals");
    {
        auto engine = std::make_unique<rack::OberVaveEngine>();
        auto& e = engine->dsp;
        e.apply_parameter(rack::P_MODE, rack::M_POLY);
        e.apply_parameter(rack::P_ARP_MODE, rack::A_CHORD);
        e.apply_parameter(rack::P_ARP_LATCH, 2);
        e.apply_parameter(rack::P_ARP_OCT, 1);
        e.apply_parameter(rack::P_ARP_GATE, 32);
        e.ev_note_on(0, 60, 100); e.ev_note_on(0, 64, 90); e.ev_note_on(0, 67, 80);
        e.arp_tick(0);
        assert(e.arp[0].note_count == 3 && e.arp[0].sounding);
        for (auto note : {60, 64, 67}) {
            bool gated = false;
            for (auto& voice : e.vc) gated |= voice.gate && voice.note == note;
            assert(gated);
        }
        e.arp[0].cnt = e.arp[0].gate_at;
        e.arp_tick(0);
        assert(!e.arp[0].sounding && !e.arp[0].note_count);
        e.ev_note_off(0, 60); e.ev_note_off(0, 64); e.ev_note_off(0, 67);
        auto steps = e.ui_arp_step;
        for (uint32_t i = 0; i < e.arp[0].period / CTL + 1; ++i) e.arp_tick(0);
        assert(e.ui_arp_step > steps);
        for (uint32_t i = 0; i < e.arp[0].period / CTL + 1 && !e.arp[0].sounding; ++i) e.arp_tick(0);
        assert(e.arp[0].note_count == 3);
        e.apply_parameter(rack::P_ARP_MODE, rack::A_HOLD);
        e.arp_tick(0);
        assert(e.arp[0].note_count == 3);
        steps = e.ui_arp_step;
        for (int i = 0; i < 10000; ++i) e.arp_tick(0);
        assert(e.ui_arp_step == steps && e.arp[0].note_count == 3);
        e.ev_note_on(0, 62, 100); e.ev_note_on(0, 65, 100); e.arp_tick(0);
        assert(e.nheld[0] == 2 && e.arp[0].note_count == 2);
        e.ev_note_off(0, 62); e.ev_note_off(0, 65);
        e.ctl_sustain = 1;
        e.apply_parameter(rack::P_ARP_LATCH, 0); e.arp_tick(0);
        assert(!e.arp[0].sounding && !e.nheld[0]);
        e.ev_note_on(0, 70, 100); e.arp_tick(0); e.ev_note_off(0, 70);
        assert(e.nheld[0] == 1);
        e.ctl_sustain = 0; e.ev_sustain_up(0); e.arp_tick(0);
        assert(!e.arp[0].sounding && !e.nheld[0]);
        e.apply_parameter(rack::P_ARP_LATCH, 1);
        e.ev_note_on(0, 72, 100); e.arp_tick(0); e.ev_note_off(0, 72);
        e.ev_note_on(0, 74, 100); e.arp_tick(0);
        assert(e.nheld[0] == 1 && e.held[0][0].note == 74);
        e.parts_off(0);
        assert(!e.arp[0].note_count && !e.arp[0].sounding);
        for (auto mode : {rack::A_CHORD, rack::A_HOLD, rack::A_HOLD_LEGATO}) {
            e.apply_parameter(rack::P_ARP_MODE, mode);
            e.apply_parameter(rack::P_ARP_OCT, 2);
            e.ctl_arp_sync = 1; e.ctl_arp_sync_grid = 0;
            e.hostClock = true; e.hostFrame = e.eng_t; e.hostBeat = 0.5;
            e.ev_note_on(0, 60, 100); e.ev_note_on(0, 64, 100);
            e.arp_tick(0);
            assert(!e.arp[0].sounding);
            e.hostBeat = 0; e.arp_tick(0);
            assert(e.arp[0].note_count == (mode == rack::A_CHORD ? 4u : 2u));
            e.ev_note_off(0, 60);
            e.ev_sustain_up(0); e.arp_tick(0);
            assert(e.nheld[0] == 1 && e.held[0][0].note == 64);
            if (mode != rack::A_CHORD) assert(e.arp[0].note_count == 1 && e.arp[0].notes[0] == 64);
            e.parts_off(0);
        }
        std::puts("PASS Chord simultaneous rhythmic notes; Hold continuous chord, physical-key replacement even in Add, Latch/Sustain release and panic");
    }
    ov_key_learn(2);
    ov_midi_message(0x90, 60, 100);
    ov_midi_message(0x81, 60, 0);
    ov_midi_message(0x91, 60, 0);
    ov_keyboard_note_on(61, 100, 2);
    assert(ov_take_key_learn() == 0);
    ov_midi_byte(0x91); ov_midi_byte(0); ov_midi_byte(100);
    ov_midi_byte(127); ov_midi_byte(100);
    assert(ov_take_key_learn() == 1);
    assert(ov_take_key_learn() == 0);
    ov_key_learn(16);
    ov_midi_message_at(0x9F, 127, 100, 1000);
    assert(ov_take_key_learn() == 128);
    ov_key_learn(1); ov_key_learn(0);
    ov_midi_message(0x90, 60, 100);
    assert(ov_take_key_learn() == 0);
    std::puts("PASS key learn filters channel, Note Off, zero velocity and screen keys; captures first external note including 0/127; cancels");
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
    for (auto mode : {rack::A_UP, rack::A_CHORD, rack::A_HOLD, rack::A_HOLD_LEGATO}) {
        for (auto latch : {1u, 2u}) for (bool inverted : {false, true}) {
            ov_all_notes_off(); render();
            ov_set_sustain_inverted(inverted);
            ov_rack_select(0);
            ov_set_parameter(rack::P_ARP_MODE, mode);
            ov_set_parameter(rack::P_ARP_LATCH, latch);
            ov_set_arp_sync(0);
            ov_midi_message(0x90, 60, 100);
            ov_midi_message(0x80, 60, 0);
            render();
            assert(dsp(0).nheld[0] == 1);
            for (auto value : {0u, 31u, 32u, 63u, 64u, 95u}) {
                ov_midi_message(0xB0, 64, inverted ? 127 - value : value);
                render(16);
                assert(!dsp(0).ctl_sustain && dsp(0).nheld[0] == 1);
            }
            auto starts = dsp(0).vseq;
            auto down = inverted ? 31u : 96u;
            ov_midi_message(0xB0, 64, down); render(16);
            assert(ov_sustain_input() == (0x10000 | down));
            assert(dsp(0).ctl_sustain && dsp(0).nheld[0] == 1);
            assert(dsp(0).live_p[0].v[rack::P_ARP_LATCH] == latch);
            if (dsp(0).arp_is_hold(mode)) assert(dsp(0).vseq == starts);
            ov_midi_message(0xB0, 64, down); render(16);
            assert(dsp(0).nheld[0] == 1);
            for (auto value : {127u, 95u, 64u, 63u, 32u, 95u}) {
                ov_midi_message(0xB0, 64, inverted ? 127 - value : value);
                render(16);
                assert(dsp(0).ctl_sustain && dsp(0).nheld[0] == 1);
            }
            ov_midi_message(0xB1, 64, inverted ? 127 : 0); render(16);
            assert(dsp(0).ctl_sustain && dsp(0).nheld[0] == 1);
            ov_midi_message(0xB0, 64, inverted ? 96 : 31); render(16);
            assert(!dsp(0).ctl_sustain && !dsp(0).nheld[0]);
            assert(!dsp(0).arp[0].sounding);
            assert(dsp(0).live_p[0].v[rack::P_ARP_LATCH] == latch);
            ov_midi_message(0x90, 62, 100); ov_midi_message(0x80, 62, 0); render(16);
            ov_midi_message(0xB0, 64, inverted ? 127 : 0); render(16);
            assert(dsp(0).nheld[0] == 1);
        }
    }
    ov_all_notes_off(); render();
    ov_set_sustain_inverted(0);
    std::puts("PASS rack Sustain Add/Replace and all arp modes: unarmed/repeated UP ignored, DOWN >=96, middle values retain state, UP <=31 clears only armed channel, normal/inverted polarity and raw CC64");
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
    ov_rack_select(5);
    ov_set_parameter_cc(rack::P_MOD_DEPTH, 255);
    ov_midi_message(0xB5, 1, 91);
    ov_midi_message(0xD5, 73, 0);
    ov_midi_message(0xA5, 53, 62);
    render();
    assert(dsp(5).ctl_mod == 91 && dsp(5).ctl_pressure == 73);
    assert(dsp(5).poly_pressure_valid[53] && dsp(5).poly_pressure[53] == 62);
    assert(dsp(5).live_p[0].v[rack::P_MOD_DEPTH] == 0);
    for (uint32_t i = 0; i < 16; ++i) if (i != 5)
        assert(!dsp(i).ctl_mod && !dsp(i).ctl_pressure && !dsp(i).poly_pressure_valid[53]);
    ov_set_parameter(rack::P_MOD1_SRC, rack::MS_WHEEL);
    ov_set_parameter(rack::P_MOD1_DST, rack::MD_CUTOFF);
    ov_set_parameter(rack::P_MOD1_AMT, 128);
    render();
    int32_t wheel[rack::NMODDST] {};
    dsp(5).modulation_values(&dsp(5).vc[0], 0, wheel);
    assert(wheel[rack::MD_CUTOFF] == 91 * 32767 / 127);
    ov_set_parameter(rack::P_MOD1_SRC, rack::MS_OFF);
    ov_set_parameter_cc(rack::P_MOD_DEPTH, ov_rack_default_cc(rack::P_MOD_DEPTH));
    ov_rack_select(0);
    render();
    std::puts("PASS MIDI rack wheel and channel/poly aftertouch are isolated by instrument channel; raw wheel source works with CC1 knob mapping removed");
    ov_rack_select(5);
    ov_set_parameter(rack::P_CTL1_SRC, rack::CS_CC0 + 1);
    ov_set_parameter(rack::P_CTL1_DST, rack::P_CUTOFF);
    ov_set_parameter(rack::P_CTL1_MIN, 32);
    ov_set_parameter(rack::P_CTL1_MAX, 96);
    ov_set_parameter(rack::P_CTL1_OVERRIDE, 1);
    render();
    ov_controller_learn(1);
    ov_midi_message(0xB4, 1, 0); render();
    assert(!ov_controller_learned());
    ov_midi_message(0x85, 17, 0); render();
    assert(!ov_controller_learned());
    ov_midi_message(0xB5, 1, 127);
    ov_midi_message(0xD5, 100, 0); render();
    assert(ov_controller_learned() == rack::CS_CC0 + 1 && !ov_controller_learned());
    assert(dsp(5).live_p[0].v[rack::P_CUTOFF] == 95 && dsp(5).live_p[0].v[rack::P_MOD_DEPTH] == 0);
    ov_controller_learn(1); ov_controller_learn(0);
    ov_midi_message(0xE5, 0, 64); render(); assert(!ov_controller_learned());
    assert(ov_rack_snapshot_request());
    render();
    ov_scene_config controllersSnapshot {};
    assert(ov_rack_snapshot_read(&controllersSnapshot));
    assert(controllersSnapshot.slots[5].config.parameters[rack::P_CUTOFF] == 95);
    assert(controllersSnapshot.slots[5].config.parameters[rack::P_CTL1_SRC] == rack::CS_CC0 + 1);
    assert(controllersSnapshot.slots[4].config.parameters[rack::P_CTL1_SRC] == 0);
    ov_set_parameter(rack::P_CTL1_SRC, 0); ov_rack_select(0); render();
    std::puts("PASS rack Controllers channel isolation, original-map override, snapshot persistence, channel-filtered one-shot MIDI Learn, ignored notes and cancellation");
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
    checkEventBoundary();
}
