// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

#define FS 44100u
#define HALF_FRAMES 256u
#define REV_DIV 2u
#define BOARD_SMK37 0
#define TRACE(k, a, b) ((void)0)
#define RING_PUBLISH() ((void)0)
#define RING_TAKE() ((void)0)
#define section(name)

namespace obervave {
#include "../../fw/obervave/firmware/src/obv_dsp.h"
#include "../../fw/obervave/firmware/src/obv_params.h"
#include "../../fw/obervave/firmware/src/obv_patches.h"

// Shared by the iPad rack and AU; mutable firmware state belongs to each instance.
#define OBV_LOCAL
#define OBV_CPP_INSTANCE
#define OBV_MASTER_PHASE(ph, bar) host_phase(ph, bar)
#define OBV_ARP_ELAPSED(p) arp_elapsed(p)
struct Engine {
    bool seq_phase(uint32_t*) { return false; }
    bool seq_starting() { return false; }
    void seq_tick() {}
    uint32_t seq_q8_now(uint32_t) { return 0xFFFFFFFFu; }

#include "../../fw/obervave/firmware/src/obv_fx.h"
#include "../../fw/obervave/firmware/src/obv_engine.h"

    double hostBeat = 0, hostTempo = 120;
    uint32_t hostFrame = 0;
    bool hostClock = false;
    int32_t phaseAdvance = 0;
    bool livePhaseAdjustment = false;
    int32_t appliedAdvance[NPART] = {};
    int64_t delayedFrames[NPART] = {};

    Engine() = default;
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    int64_t arp_elapsed(uint32_t p)
    {
        const int32_t delta = phaseAdvance - appliedAdvance[p];
        appliedAdvance[p] = phaseAdvance;
        const auto& a = arp[p];
        if (!livePhaseAdjustment || !ctl_arp_sync || !a.was_on || !nheld[p] ||
            pt[p].p->v[P_ARP_MODE] == A_OFF || a.cnt == 0xFFFFFFFFu) {
            delayedFrames[p] = 0;
            return CTL;
        }
        const int64_t elapsed = CTL + int64_t(delta) + delayedFrames[p];
        const int64_t next = int64_t(a.cnt) + elapsed;
        delayedFrames[p] = next < 0 ? next : 0;
        return next < 0 ? -int64_t(a.cnt) : elapsed;
    }

    void initialize()
    {
        for (uint32_t i = 0; i < NPART; ++i) {
            patch_from_factory(&live_p[i], &FACTORY[17]);
            pt[i].p = &live_p[i];
        }
        engine_init();
    }

    bool host_phase(uint32_t* phase, uint32_t* bar)
    {
        const auto q = quarter_len();
        double beat = hostClock
            ? hostBeat + double(eng_t - hostFrame) * hostTempo / (60.0 * FS)
            : double(eng_t) / q;
        beat += double(phaseAdvance) / q;
        beat = std::fmod(beat, 4.0);
        if (beat < 0) beat += 4;
        *bar = uint32_t(beat * q);
        *phase = *bar % q;
        return true;
    }

    void apply_parameter(uint32_t parameter, uint8_t value)
    {
        const auto previous = live_p[0].v[parameter];
        live_p[0].v[parameter] = value;
        if (previous == value || part_sus(0)) return;
        if ((parameter == P_ARP_LATCH && value == 0) ||
            (parameter == P_ARP_MODE && value == A_OFF)) {
            ev_sustain_up(0);
            if (!nheld[0]) {
                arp_stop_note(0);
                arp[0].pos = 0;
                arp[0].cnt = 0xFFFFFFFFu;
            }
        }
    }

    void midi(uint8_t status, uint8_t d1, uint8_t d2)
    {
        switch (status & 0xF0) {
        case 0x80: note_event(0, d1, 0); break;
        case 0x90: note_event(d2 != 0, d1, d2); break;
        case 0xB0:
            if (d1 == 7) ctl_cc7 = d2;
            if (d1 == 64) ctl_sustain = d2 >= 64;
            if (d1 == 120 || d1 == 123) ctl_panic = 1;
            for (uint32_t i = 0; i < NPARAM; ++i)
                if (PDEF[i].cc && PDEF[i].cc == d1)
                    apply_parameter(i, (uint32_t(d2) * PDEF[i].max + 63) / 127);
            break;
        case 0xE0: ctl_bend = int32_t(d1 | (uint32_t(d2) << 7)) - 8192; break;
        }
    }
};
#undef OBV_LOCAL
#undef OBV_CPP_INSTANCE
#undef OBV_MASTER_PHASE
#undef OBV_ARP_ELAPSED
#undef live
#undef section
} // namespace obervave
