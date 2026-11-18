// SPDX-License-Identifier: GPL-3.0-only
#include "Arpeggiator.h"
#include <cassert>
#include <cstdio>
#include <vector>
#ifdef OB1_ARP_REFERENCE
#include "../OberVave/Engine.h"
#include <memory>
#endif

using namespace ob1::music;

struct Recorder {
    std::vector<Event> events;
    std::array<NoteID, 128> sounding {};
    uint32_t rejectAt = 0, calls = 0;
    bool operator()(const Event& e)
    {
        if (++calls == rejectAt) return false;
        assert(validate(e) == EventError::None);
        assert(e.source.kind == SourceKind::Arpeggiator && e.routing.stage == Stage::Output && e.note);
        if (e.kind == Kind::NoteOn) {
            assert(!sounding[e.data1]);
            sounding[e.data1] = e.note;
        } else {
            assert(e.kind == Kind::NoteOff && sounding[e.data1] == e.note);
            sounding[e.data1] = 0;
        }
        events.push_back(e);
        return true;
    }
};

static Event note(uint8_t pitch, bool on = true, uint8_t velocity = 100, Time time = {})
{
    Event e {};
    e.kind = on ? Kind::NoteOn : Kind::NoteOff;
    e.data1 = pitch; e.data2 = on ? velocity : 0; e.time = time;
    return e;
}

static Event pedal(bool down, Time time = {})
{
    Event e {};
    e.kind = Kind::ControlChange;
    e.data1 = 64; e.data2 = down ? 127 : 0; e.time = time;
    return e;
}

static void checkPortable()
{
    ArpeggiatorProcessor arp;
    Recorder out;
    ArpSettings settings;
    settings.mode = ArpMode::Up;
    assert(arp.destination(15, 15) == ArpResult::Ok);
    assert(arp.configure(settings, {}, out) == ArpResult::Ok);
    for (const uint8_t pitch : {67, 60, 64}) assert(arp.input(note(pitch), out) == ArpResult::Ok);
    assert(arp.destination(0, 0) == ArpResult::InvalidInput);
    ArpClock clock;
    clock.quarterFrames = 256;
    for (uint32_t i = 0; i < 13; ++i) {
        clock.time = {16 * i, Tick(i), true};
        assert(arp.tick(clock, out) == ArpResult::Ok);
    }
    const uint8_t expected[] {60, 64, 67, 60};
    uint32_t ons = 0;
    for (const auto& e : out.events) {
        assert(e.channel == 15 && e.routing.instruments == 0x8000 && e.time.hasTick);
        if (e.kind == Kind::NoteOn) {
            assert(ons < 4 && e.data1 == expected[ons]);
            assert(e.time.frame == ons * 64);
            ++ons;
        }
    }
    assert(ons == 4);
    assert(arp.stop({208}, out) == ArpResult::Ok);
    for (auto id : out.sounding) assert(!id);

    settings.mode = ArpMode::HoldLegato;
    settings.latch = Latch::Replace;
    assert(arp.configure(settings, {}, out) == ArpResult::Ok);
    assert(arp.input(note(60), out) == ArpResult::Ok);
    assert(arp.input(note(64), out) == ArpResult::Ok);
    assert(arp.tick(clock, out) == ArpResult::Ok);
    const auto common = out.sounding[64];
    assert(common);
    assert(arp.input(note(60, false), out) == ArpResult::Ok);
    assert(arp.input(note(67), out) == ArpResult::Ok);
    out.events.clear();
    assert(arp.tick(clock, out) == ArpResult::Ok);
    assert(out.events.size() == 2 && out.events[0].kind == Kind::NoteOff && out.events[0].data1 == 60);
    assert(out.events[1].kind == Kind::NoteOn && out.events[1].data1 == 67);
    assert(out.sounding[64] == common);
    assert(arp.input(pedal(true), out) == ArpResult::Ok);
    assert(arp.input(note(67, false), out) == ArpResult::Ok);
    settings.latch = Latch::Off;
    assert(arp.configure(settings, {}, out) == ArpResult::Ok);
    assert(arp.tick(clock, out) == ArpResult::Ok);
    assert(!out.sounding[67] && out.sounding[64] == common);
    assert(arp.input(note(64, false), out) == ArpResult::Ok);
    assert(arp.input(pedal(false), out) == ArpResult::Ok);
    assert(arp.tick(clock, out) == ArpResult::Ok);
    assert(!arp.activeCount() && !arp.heldCount());
    const auto valid = settings;
    settings.grid = 6;
    assert(arp.configure(settings, {}, out) == ArpResult::InvalidInput && arp.settings().grid == valid.grid);
    assert(arp.seed(0) == ArpResult::InvalidInput);
    clock.quarterFrames = 0;
    assert(arp.tick(clock, out) == ArpResult::InvalidInput);
    auto invalid = note(128);
    assert(arp.input(invalid, out) == ArpResult::InvalidInput);

    // At most 16 held keys, with the same oldest-key eviction as the reference.
    settings = valid;
    settings.mode = ArpMode::Chord; settings.octaves = 4;
    assert(arp.configure(settings, {}, out) == ArpResult::Ok);
    for (uint8_t pitch = 40; pitch < 70; ++pitch) assert(arp.input(note(pitch), out) == ArpResult::Ok);
    assert(arp.heldCount() == 16);
    clock.quarterFrames = 256;
    assert(arp.tick(clock, out) == ArpResult::Ok);
    assert(arp.activeCount() <= 64 && !out.sounding[40]);
    // Rejection halfway through a release retains exactly the undelivered Off.
    out.rejectAt = out.calls + 3;
    assert(arp.stop({}, out) == ArpResult::OutputRejected && arp.activeCount() == 1);
    assert(arp.tick(clock, out) == ArpResult::Faulted);
    out.rejectAt = 0;
    assert(arp.stop({}, out) == ArpResult::Ok && !arp.activeCount());
    for (auto id : out.sounding) assert(!id);
    // Rejection halfway through a chord tracks only the accepted Note Ons.
    assert(arp.input(note(60), out) == ArpResult::Ok);
    out.rejectAt = out.calls + 3;
    assert(arp.tick(clock, out) == ArpResult::OutputRejected && arp.activeCount() == 2);
    assert(arp.input(note(61), out) == ArpResult::Faulted);
    out.rejectAt = 0;
    assert(arp.stop({}, out) == ArpResult::Ok);
    for (auto id : out.sounding) assert(!id);
    for (const auto kind : {Kind::Start, Kind::Continue, Kind::Clock}) {
        Event transport {};
        transport.kind = kind;
        assert(arp.input(transport, out) == ArpResult::Bypassed);
        assert(!arp.heldCount());
    }
    // Independent seeded processors are reproducible without a DSP random source.
    for (const uint32_t seed : {1u, 42u, 0x9E3779B9u, UINT32_MAX}) {
        ArpeggiatorProcessor a, b;
        Recorder left, right;
        settings.mode = ArpMode::Random;
        assert(a.seed(seed) == ArpResult::Ok && b.seed(seed) == ArpResult::Ok);
        assert(a.configure(settings, {}, left) == ArpResult::Ok);
        assert(b.configure(settings, {}, right) == ArpResult::Ok);
        for (const uint8_t pitch : {60, 64, 67}) {
            assert(a.input(note(pitch), left) == ArpResult::Ok);
            assert(b.input(note(pitch), right) == ArpResult::Ok);
        }
        for (uint32_t i = 0; i < 128; ++i) {
            clock.time.frame = i * 16;
            assert(a.tick(clock, left) == ArpResult::Ok && b.tick(clock, right) == ArpResult::Ok);
            assert(a.randomState() == b.randomState());
        }
        assert(left.events.size() == right.events.size());
        for (uint32_t i = 0; i < left.events.size(); ++i)
            assert(left.events[i].kind == right.events[i].kind && left.events[i].data1 == right.events[i].data1 &&
                left.events[i].time.frame == right.events[i].time.frame && left.events[i].note == right.events[i].note);
        assert(a.stop(clock.time, left) == ArpResult::Ok && b.stop(clock.time, right) == ArpResult::Ok);
    }
    std::puts("PASS portable arpeggiator: timing, note identities, Hold Legato, sustain/Latch, bounded keys, explicit errors and retryable sink failure");
}

#ifdef OB1_ARP_REFERENCE
struct Comparison {
    std::unique_ptr<obervave::Engine> engine = std::make_unique<obervave::Engine>();
    ArpeggiatorProcessor arp;
    Recorder out;
    ArpSettings settings;
    ArpClock clock;
    uint32_t comparisons = 0;
    Comparison()
    {
        engine->initialize();
        assert(arp.seed(engine->rnd_state) == ArpResult::Ok);
        clock.quarterFrames = 768;
    }
    void compare(const char* operation)
    {
        auto& e = *engine;
        const uint32_t count = e.arp_qw - e.arp_qr;
        if (count != out.events.size()) {
            std::fprintf(stderr, "%s frame=%llu mode=%u latch=%u: legacy %u events, extracted %zu\n",
                operation, static_cast<unsigned long long>(clock.time.frame),
                unsigned(settings.mode), unsigned(settings.latch), count, out.events.size());
            std::abort();
        }
        for (const auto& event : out.events) {
            const auto& expected = e.arp_q[e.arp_qr++ % AQ];
            assert(event.kind == (expected.on ? Kind::NoteOn : Kind::NoteOff));
            assert(event.data1 == expected.note && event.data2 == expected.vel);
            assert(event.time.frame == clock.time.frame);
        }
        assert(arp.heldCount() == e.nheld[0]);
        assert(arp.activeCount() == e.arp[0].note_count);
        out.events.clear();
        ++comparisons;
    }
    void configure(ArpSettings next)
    {
        settings = next;
        auto& e = *engine;
        e.apply_parameter(obervave::P_ARP_MODE, uint8_t(next.mode));
        e.apply_parameter(obervave::P_ARP_LATCH, uint8_t(next.latch));
        e.apply_parameter(obervave::P_ARP_DIV, next.division);
        e.apply_parameter(obervave::P_ARP_OCT, next.octaves);
        e.apply_parameter(obervave::P_ARP_GATE, next.gate);
        e.apply_parameter(obervave::P_ARP_VEL, next.velocity);
        e.ctl_arp_sync = next.sync;
        e.ctl_arp_sync_grid = next.grid;
        assert(arp.configure(next, clock.time, out) == ArpResult::Ok);
        compare("configure");
    }
    void input(Event event)
    {
        event.time = clock.time;
        auto& e = *engine;
        if (event.kind == Kind::NoteOn) e.ev_note_on(0, event.data1, event.data2);
        else if (event.kind == Kind::NoteOff) e.ev_note_off(0, event.data1);
        else if (event.kind == Kind::ControlChange && event.data1 == 64) {
            e.ctl_sustain = event.data2 >= 64;
            e.engine_events();
        } else std::abort();
        const auto result = arp.input(event, out);
        assert(result == ArpResult::Ok || result == ArpResult::Bypassed);
        compare("input");
    }
    void tick(uint32_t count = 1)
    {
        for (uint32_t i = 0; i < count; ++i) {
            clock.time.frame += 16;
            auto& e = *engine;
            e.eng_t = uint32_t(clock.time.frame);
            e.ctl_ext_quarter = clock.quarterFrames;
            e.phaseAdvance = clock.advanceFrames;
            e.livePhaseAdjustment = clock.livePhaseAdjustment;
            uint32_t phase, bar;
            e.host_phase(&phase, &bar);
            clock.hasMasterPhase = true;
            clock.barPhaseFrames = bar;
            // Randomness is injected explicitly, not tied to DSP LFO/noise calls.
            assert(arp.seed(e.rnd_state) == ArpResult::Ok);
            e.arp_tick(0);
            assert(arp.tick(clock, out) == ArpResult::Ok);
            assert(arp.randomState() == e.rnd_state);
            compare("tick");
            if (settings.mode != ArpMode::Off) assert(arp.counter() == e.arp[0].cnt);
        }
    }
    void stop()
    {
        engine->engine_transport_stop();
        assert(arp.stop(clock.time, out) == ArpResult::Ok);
        compare("stop");
    }
};

static void checkReference()
{
    uint64_t checked = 0;
    for (uint32_t mode = 1; mode <= 8; ++mode)
        for (uint8_t division = 0; division < 7; ++division)
            for (const uint8_t octave : {0, 1, 2, 4})
                for (const uint8_t gate : {0, 1, 63, 126, 127}) {
                    Comparison c;
                    auto s = c.settings;
                    s.mode = ArpMode(mode); s.division = division; s.octaves = octave; s.gate = gate;
                    s.velocity = gate % 2 ? 0 : 73;
                    c.configure(s);
                    c.input(note(67, true, 80)); c.input(note(60, true, 110)); c.input(note(64, true, 50));
                    c.tick(210);
                    c.input(note(60, false)); c.tick(35);
                    c.input(note(67, false)); c.input(note(64, false)); c.tick();
                    c.stop();
                    checked += c.comparisons;
                }
    for (uint32_t mode = 1; mode <= 8; ++mode)
        for (uint32_t latch = 0; latch < 3; ++latch)
            for (uint8_t grid = 0; grid < 6; ++grid) {
                Comparison c;
                auto s = c.settings;
                s.mode = ArpMode(mode); s.latch = Latch(latch); s.sync = true; s.grid = grid;
                c.configure(s);
                c.clock.livePhaseAdjustment = true;
                c.input(note(60)); c.input(note(64)); c.input(note(67)); c.tick(220);
                c.input(pedal(false)); c.tick();
                c.input(pedal(true)); c.tick();
                c.input(note(60, false)); c.tick();
                c.input(note(69)); c.tick(40);
                c.clock.advanceFrames = 400; c.tick();
                c.clock.advanceFrames = -1200; c.tick(40);
                c.clock.advanceFrames = -1000; c.tick(40);
                c.clock.advanceFrames = 0; c.tick(40);
                c.clock.quarterFrames = 1200; c.tick(100);
                s.gate = 0; s.division = 6;
                c.configure(s); c.tick(40);
                c.input(note(64, false)); c.input(note(67, false)); c.input(note(69, false)); c.tick();
                c.input(note(72)); c.tick(40);
                s.latch = Latch::Off; c.configure(s); c.tick();
                c.input(pedal(false)); c.tick(40);
                c.stop(); c.tick(40);
                c.input(note(70)); c.tick(220);
                s.mode = ArpMode::Off; c.configure(s); c.tick();
                s.mode = ArpMode(mode); c.configure(s); c.tick(40);
                c.stop();
                checked += c.comparisons;
            }
    // Repeated and high notes, chord octave duplicates and bounded held overflow.
    for (uint32_t mode = 1; mode <= 8; ++mode) {
        Comparison c;
        auto s = c.settings;
        s.mode = ArpMode(mode); s.octaves = 4; s.latch = Latch::Add;
        c.configure(s);
        for (uint8_t pitch = 100; pitch < 128; ++pitch) { c.input(note(pitch)); c.tick(); }
        c.input(note(124)); c.input(note(112)); c.input(note(100)); c.tick(100);
        for (uint32_t other = 1; other <= 8; ++other) {
            s.mode = ArpMode(other); c.configure(s); c.tick(100);
        }
        c.stop();
        checked += c.comparisons;
    }
    // Host phase jumps must not realign an already-running phrase.
    for (uint32_t mode = 1; mode <= 8; ++mode) {
        Comparison c;
        auto s = c.settings;
        s.mode = ArpMode(mode); s.sync = true;
        c.configure(s);
        c.engine->hostClock = true;
        c.engine->hostTempo = 120;
        c.engine->hostFrame = 0;
        c.engine->hostBeat = -0.5;
        c.input(note(60)); c.input(note(64));
        c.tick(100);
        c.engine->hostBeat += 3;
        c.tick(100);
        c.stop();
        c.tick(30);
        c.input(note(67));
        c.tick(100);
        c.stop();
        checked += c.comparisons;
    }
    std::printf("PASS legacy arpeggiator parity: %llu operation boundaries, all modes/divisions/octaves/gates/grids, velocities, sustain/Latch, tempo/latency changes, duplicates, held overflow, mode changes and Stop\n",
        static_cast<unsigned long long>(checked));
}
#endif

int main()
{
    checkPortable();
#ifdef OB1_ARP_REFERENCE
    checkReference();
#endif
}
