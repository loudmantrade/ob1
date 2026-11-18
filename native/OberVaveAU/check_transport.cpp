// SPDX-License-Identifier: GPL-3.0-only
#include <cassert>
#include <cstdio>
#include "../../ios/OberVave/SynthRack.cpp"

static void checkCompensation(uint32_t external, uint32_t division, uint32_t grid)
{
    auto engine = std::make_unique<rack::OberVaveEngine>();
    auto& e = engine->dsp;
    e.ctl_ext_quarter = 22050;
    e.ctl_arp_sync = 1;
    e.ctl_arp_sync_grid = grid;
    e.live_p[0].v[rack::P_ARP_MODE] = rack::A_UP;
    e.live_p[0].v[rack::P_ARP_DIV] = division;
    e.live_p[0].v[rack::P_ARP_OCT] = 1;
    e.live_p[0].v[rack::P_ARP_GATE] = 63;
    e.ev_note_on(0, 60, 100); e.ev_note_on(0, 64, 100); e.ev_note_on(0, 67, 100);
    double beatJump = 0;
    auto tick = [&]() {
        e.eng_t += CTL;
        if (external) {
            e.hostClock = true;
            e.hostBeat = double(e.eng_t) / 22050 + beatJump;
            e.hostFrame = e.eng_t;
        }
        e.arp_tick(0);
    };
    const int32_t base = external ? 882 : 0;
    e.phaseAdvance = base;
    for (e.eng_t = 8000; e.eng_t < 100000 && !e.ui_arp_step;) tick();
    assert(e.ui_arp_step == 1);
    const float offsets[] = {0.1f, 0.2f, -0.1f, 100, 40, -500, -480, 500, 0};
    int32_t previous = base;
    for (float offset : offsets) {
        const auto period = e.arp[0].period, position = e.arp[0].pos, note = e.arp[0].note;
        const auto advance = int32_t(std::lround(offset * FS / 1000.f)) + base;
        const int64_t distance = int64_t(period) - e.arp[0].cnt - (advance - previous);
        const uint32_t ticks = distance > CTL ? uint32_t((distance + CTL - 1) / CTL) : 1;
        previous = e.phaseAdvance = advance;
        const auto steps = e.ui_arp_step;
        for (uint32_t t = 1; t <= ticks; ++t) {
            tick();
            assert(e.ui_arp_step == steps + (t == ticks));
            if (t < ticks) assert(e.arp[0].pos == position && e.arp[0].note == note);
        }
        assert(e.arp[0].pos == (position < 3 ? position : 0) + 1);
        assert(!e.delayedFrames[0] && e.arp[0].cnt < period);
        const auto stableSteps = e.ui_arp_step;
        const auto stableTicks = (period - e.arp[0].cnt + CTL - 1) / CTL;
        // Jumping the master beat must not re-quantize a running phrase.
        beatJump += 2;
        for (uint32_t t = 1; t <= stableTicks; ++t) {
            tick();
            assert(e.ui_arp_step == stableSteps + (t == stableTicks));
        }
    }
    e.phaseAdvance = base - 22050;
    tick();
    assert(e.delayedFrames[0] < 0);
    const auto delayed = e.delayedFrames[0];
    e.phaseAdvance = base - 17640;
    tick();
    assert(e.delayedFrames[0] == delayed + 4410 + CTL);
    e.engine_transport_stop();
    tick();
    assert(!e.delayedFrames[0]);
    e.ctl_arp_sync = 0;
    e.ev_note_on(0, 60, 100); tick();
    const auto counter = e.arp[0].cnt;
    e.phaseAdvance += 22050; tick();
    assert(e.arp[0].cnt == counter + CTL);
}

int main()
{
    for (uint32_t external = 0; external <= 1; ++external)
        for (uint32_t division = 0; division < rack::NDIV; ++division)
            for (uint32_t grid = 0; grid <= 5; ++grid) checkCompensation(external, division, grid);

    for (uint32_t external = 0; external <= 1; ++external) {
        for (int32_t milliseconds = -100; milliseconds <= 100; milliseconds += 100) {
            auto engine = std::make_unique<rack::OberVaveEngine>();
            auto& e = engine->dsp;
            e.ctl_ext_quarter = 22050; e.ctl_arp_sync = 1; e.ctl_arp_sync_grid = 2;
            e.live_p[0].v[rack::P_ARP_MODE] = rack::A_UP;
            const auto advance = milliseconds * 441 / 10 + (external ? 882 : 0);
            e.phaseAdvance = advance;
            e.ev_note_on(0, 60, 100);
            uint32_t onset = 0;
            for (e.eng_t = 8000; e.eng_t < 30000; e.eng_t += CTL) {
                e.arp_tick(0);
                if (e.ui_arp_step) { onset = e.eng_t; break; }
            }
            const uint32_t expected = 22050 - advance;
            assert(onset >= expected && onset <= expected + CTL);
            e.eng_t = 0;
            e.phaseAdvance = -4410 + (external ? 882 : 0);
            uint32_t phase, bar;
            e.host_phase(&phase, &bar);
            assert(bar >= uint32_t(88200 + e.phaseAdvance - 1) && bar <= uint32_t(88200 + e.phaseAdvance));
        }
    }
    std::puts("PASS production iPad engine: start grid, signed/fine/live/repeated compensation, all divisions and grids, sync off");

    for (uint32_t latch = 0; latch <= 2; ++latch) {
        auto engine = std::make_unique<rack::OberVaveEngine>();
        auto& e = engine->dsp;
        for (uint32_t p = 0; p < NPART; ++p) {
            e.live_p[p].v[rack::P_ARP_MODE] = rack::A_UP;
            e.live_p[p].v[rack::P_ARP_LATCH] = latch;
            e.ev_note_on(p, 60 + p, 100);
            e.arp_tick(p);
        }
        e.ctl_sustain = 1;
        e.note_event(1, 72, 100);
        engine->stop();
        assert(e.nq_r == e.nq_w && !e.ctl_sustain);
        for (uint32_t p = 0; p < NPART; ++p)
            assert(!e.nheld[p] && !e.arp[p].sounding && e.arp[p].cnt == 0xFFFFFFFFu);
        for (const auto& voice : e.vc) assert(!voice.gate);
        assert(e.live_p[0].v[rack::P_ARP_LATCH] == latch);
    }
    std::puts("PASS production iPad adapter Stop releases all firmware parts and retains ARP/Latch settings");
}
