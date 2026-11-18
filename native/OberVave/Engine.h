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

inline double lfo_rate_hz(uint32_t value)
{
    return double(LFO_INC[std::min(value, 127u)]) * FS / (4294967296.0 * CTL);
}

// Shared by the iPad rack and AU; mutable firmware state belongs to each instance.
#define OBV_LOCAL
#define OBV_CPP_INSTANCE
#define OBV_MASTER_PHASE(ph, bar) host_phase(ph, bar)
#define OBV_ARP_ELAPSED(p) arp_elapsed(p)
#define OBV_VOICE_CONTROLLERS(v, g, patch) voice_controllers(v, g, patch)
#define OBV_EXTERNAL_ARP(p) externalArpeggiator[p]
#define OBV_EXTERNAL_ARP_TICK(p) external_arpeggiator_tick(p)
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
    int32_t controllerValues[NCONTROLLER_SOURCE] {};
    bool controllerSeen[NCONTROLLER_SOURCE] {};
    patch_t controllerBase {};
    bool controllerRendering = false;
    bool controllerPolyMod = false;
    uint8_t previousControllerArp = A_OFF, previousControllerLatch = 0;
    bool controllerPerformanceMod = false;
    bool externalArpeggiator[NPART] {};
    // Offset follows eng_t: CTL at the first tick, not an output-buffer sample index.
    using ArpeggiatorTick = bool (*)(void*, Engine&, uint32_t part, uint32_t frameOffset) noexcept;
    ArpeggiatorTick arpeggiatorTick = nullptr;
    void* arpeggiatorContext = nullptr;
    uint32_t arpeggiatorStartFrame = 0, arpeggiatorFailedParts = 0;

    void external_arpeggiator_tick(uint32_t part)
    {
        if (!arpeggiatorTick || (arpeggiatorFailedParts >> part & 1u)) return;
        if (!arpeggiatorTick(arpeggiatorContext, *this, part, eng_t - arpeggiatorStartFrame)) {
            arpeggiatorFailedParts |= 1u << part;
            parts_off(part);
        }
    }

    // Audio-owner operation. Switching clears this part's old notes, not its patch or FX.
    bool set_external_arpeggiator(uint32_t part, bool enabled)
    {
        if (part >= NPART) return false;
        if (externalArpeggiator[part] == enabled) return true;
        parts_off(part);
        arp[part] = {};
        arp[part].cnt = 0xFFFFFFFFu;
        delayedFrames[part] = 0;
        appliedAdvance[part] = phaseAdvance;
        auto write = nq_r;
        const auto end = nq_w;
        for (auto read = nq_r; read != end; ++read) {
            const auto event = nq[read % NQ];
            if (event.part % NPART != part) nq[write++ % NQ] = event;
        }
        nq_w = write;
        externalArpeggiator[part] = enabled;
        return true;
    }

    bool external_note(uint32_t part, uint32_t note, uint32_t velocity)
    {
        if (part >= NPART || note > 127 || velocity > 127 || !externalArpeggiator[part])
            return false;
        if (velocity) voice_trigger(part, note, velocity);
        else voice_release(part, note, 1);
        return true;
    }

    // The caller has already updated its held keys and interpreted Sustain.
    bool external_direct_note(uint32_t part, uint32_t note, uint32_t velocity,
                              bool hasHeld, uint32_t lastHeld = 0)
    {
        if (part >= NPART || note > 127 || velocity > 127 ||
            (hasHeld && lastHeld > 127) || !externalArpeggiator[part] ||
            pt[part].p->v[P_ARP_MODE] != A_OFF) return false;
        if (velocity) {
            poly_pressure_valid[note] = 0;
            voice_trigger(part, note, velocity);
        } else voice_release_held(part, note, hasHeld, lastHeld);
        return true;
    }

    static uint32_t controller_source(uint8_t status, uint8_t d1)
    {
        switch (status & 0xF0) {
        case 0xB0: return CS_CC0 + d1;
        case 0xE0: return CS_BEND;
        case 0xD0: return CS_PRESSURE;
        case 0xA0: return CS_POLY;
        default: return 0;
        }
    }

    bool controller_override(uint32_t source) const
    {
        if (!source) return false;
        for (uint32_t s = 0; s < CONTROLLER_SLOTS; ++s) {
            const auto p = P_CTL1_SRC + s * CONTROLLER_FIELDS;
            if (live_p[0].v[p] == source && live_p[0].v[p + 6]) return true;
        }
        return false;
    }

    void controller_input(uint8_t status, uint8_t d1, uint8_t d2)
    {
        const auto source = controller_source(status, d1);
        if (!source) return;
        const int32_t value = source == CS_BEND ? d1 | (uint32_t(d2) << 7) :
            (source == CS_PRESSURE ? d1 : d2) * 16383 / 127;
        controllerValues[source] = value;
        controllerSeen[source] = true;
        if (source == CS_POLY) {
            poly_pressure[d1] = d2;
            poly_pressure_valid[d1] = 1;
        }
        for (uint32_t s = 0; s < CONTROLLER_SLOTS; ++s) {
            const auto p = P_CTL1_SRC + s * CONTROLLER_FIELDS;
            const auto* v = live_p[0].v;
            if (v[p] != source || v[p + 2] != 0) continue;
            const auto target = v[p + 1];
            const int32_t scaled = v[p + 3] * 16383 + (v[p + 4] - int32_t(v[p + 3])) * value;
            apply_parameter(target, (int64_t(scaled) * PDEF[target].max + 128 * 16383 / 2) / (128 * 16383));
        }
    }

    void controller_offsets(patch_t& patch, const voice_t* voice = nullptr)
    {
        const auto* base = controllerRendering ? controllerBase.v : live_p[0].v;
        int32_t offsets[CONTROLLER_TARGETS] {};
        for (uint32_t s = 0; s < CONTROLLER_SLOTS; ++s) {
            const auto p = P_CTL1_SRC + s * CONTROLLER_FIELDS;
            const auto source = base[p], target = base[p + 1];
            if (!source || base[p + 2] != 1 || !controllerSeen[source]) continue;
            int32_t value = controllerValues[source];
            if (voice && source == CS_POLY)
                value = poly_pressure_valid[voice->note] ? poly_pressure[voice->note] * 16383 / 127 : 0;
            if (source == CS_BEND)
                value = value < 8192 ? (value - 8192) * 16383 / 8192 : (value - 8192) * 16383 / 8191;
            offsets[target] += int64_t(value) * (int32_t(base[p + 5]) - 64) * PDEF[target].max / (64 * 16383);
        }
        for (uint32_t p = 0; p < CONTROLLER_TARGETS; ++p)
            patch.v[p] = std::clamp(int32_t(base[p]) + offsets[p], 0, int32_t(PDEF[p].max));
    }

    bool voice_controllers(const voice_t* voice, part_t* part, patch_t* patch)
    {
        if (!controllerRendering || !controllerPolyMod || voice->part != 0) return false;
        *part = pt[voice->part];
        *patch = live_p[0];
        controller_offsets(*patch, voice);
        const auto oldCut = part->cut_sm, oldReso = part->reso_sm;
        part->p = patch;
        block_globals(part);
        part->cut_sm = oldCut + (int32_t(patch->v[P_CUTOFF]) - live_p[0].v[P_CUTOFF]) * 256;
        part->reso_sm = std::clamp(oldReso + (int32_t(patch->v[P_RESO]) - live_p[0].v[P_RESO]) * 256, 0, 127 * 256);
        return true;
    }

    void render_audio(int32_t* output, uint32_t frames)
    {
        render_audio_with_arpeggiator(output, frames, nullptr, nullptr);
    }

    bool render_audio_with_arpeggiator(int32_t* output, uint32_t frames,
                                      ArpeggiatorTick tick, void* context)
    {
        arpeggiatorTick = tick;
        arpeggiatorContext = context;
        arpeggiatorStartFrame = eng_t;
        arpeggiatorFailedParts = 0;
        controllerBase = live_p[0];
        controllerRendering = true;
        controllerPolyMod = false;
        for (uint32_t s = 0; s < CONTROLLER_SLOTS; ++s) {
            const auto p = P_CTL1_SRC + s * CONTROLLER_FIELDS;
            controllerPolyMod |= controllerBase.v[p] == CS_POLY &&
                controllerBase.v[p + 2] == 1 && controllerBase.v[p + 5] != 64 &&
                controllerSeen[CS_POLY];
        }
        controller_offsets(live_p[0]);
        const bool performanceMod = live_p[0].v[P_ARP_MODE] != controllerBase.v[P_ARP_MODE] ||
            live_p[0].v[P_ARP_LATCH] != controllerBase.v[P_ARP_LATCH];
        if (!externalArpeggiator[0] && (performanceMod || controllerPerformanceMod) &&
            (!part_sus(0) || arp_is_hold(live_p[0].v[P_ARP_MODE])) &&
            ((previousControllerArp != A_OFF && live_p[0].v[P_ARP_MODE] == A_OFF) ||
             (previousControllerLatch && !live_p[0].v[P_ARP_LATCH]))) {
            ev_sustain_up(0);
            if (!nheld[0]) {
                arp_stop_note(0);
                arp[0].cnt = 0xFFFFFFFFu;
            }
        }
        previousControllerArp = live_p[0].v[P_ARP_MODE];
        previousControllerLatch = live_p[0].v[P_ARP_LATCH];
        controllerPerformanceMod = performanceMod;
        engine_audio(output, frames);
        live_p[0] = controllerBase;
        controllerRendering = false;
        arpeggiatorTick = nullptr;
        arpeggiatorContext = nullptr;
        return arpeggiatorFailedParts == 0;
    }

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
        std::fill_n(externalArpeggiator, NPART, false);
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
        if (previous == value) return;
        if (parameter >= P_CTL1_SRC) {
            if (controller_override(CS_BEND)) ctl_bend = 0;
            if (controller_override(CS_CC0 + 7)) ctl_cc7 = 127;
            if (controller_override(CS_CC0 + 64)) ctl_sustain = 0;
            return;
        }
        if (externalArpeggiator[0]) return;
        if (part_sus(0) && !(parameter == P_ARP_LATCH && value == 0 &&
                             arp_is_hold(live_p[0].v[P_ARP_MODE]))) return;
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

    bool midi(uint8_t status, uint8_t d1, uint8_t d2, bool fixedCC = true, bool controllers = true)
    {
        if (externalArpeggiator[0] && ((status & 0xF0) == 0x80 || (status & 0xF0) == 0x90))
            return false;
        if (controllers) controller_input(status, d1, d2);
        const bool overridden = controller_override(controller_source(status, d1));
        switch (status & 0xF0) {
        case 0x80: note_event(0, d1, 0); break;
        case 0x90:
            if (d2) poly_pressure_valid[d1] = 0;
            note_event(d2 != 0, d1, d2);
            break;
        case 0xA0: poly_pressure[d1] = d2; poly_pressure_valid[d1] = 1; break;
        case 0xD0: ctl_pressure = d1; break;
        case 0xB0:
            if (d1 == 1) ctl_mod = d2;
            if (d1 == 121 && !overridden) {
                ctl_mod = ctl_pressure = 0;
                std::memset(poly_pressure_valid, 0, sizeof(poly_pressure_valid));
                std::fill_n(controllerSeen, NCONTROLLER_SOURCE, false);
            }
            if (d1 == 7) ctl_cc7 = overridden ? 127 : d2;
            if (d1 == 64) ctl_sustain = !overridden && d2 >= 64;
            if ((d1 == 120 || d1 == 123) && !overridden) ctl_panic = 1;
            if (fixedCC && !overridden) for (uint32_t i = 0; i < NPARAM; ++i)
                if (PDEF[i].cc && PDEF[i].cc == d1)
                    apply_parameter(i, (uint32_t(d2) * PDEF[i].max + 63) / 127);
            break;
        case 0xE0: ctl_bend = overridden ? 0 : int32_t(d1 | (uint32_t(d2) << 7)) - 8192; break;
        }
        return true;
    }
};
#undef OBV_LOCAL
#undef OBV_CPP_INSTANCE
#undef OBV_MASTER_PHASE
#undef OBV_ARP_ELAPSED
#undef OBV_VOICE_CONTROLLERS
#undef OBV_EXTERNAL_ARP
#undef OBV_EXTERNAL_ARP_TICK
#undef live
#undef section
} // namespace obervave
