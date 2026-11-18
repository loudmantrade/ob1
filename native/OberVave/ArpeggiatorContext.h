// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Engine.h"
#include "../Musical/Arpeggiator.h"

namespace obervave {

struct ArpeggiatorContext {
    ob1::music::ArpSettings settings;
    ob1::music::ArpClock clock;
};

inline bool arpeggiator_settings(const Engine& engine, uint32_t part, ob1::music::ArpSettings& output)
{
    if (part >= NPART) return false;
    const auto* patch = engine.pt[part].p->v;
    ob1::music::ArpSettings settings {};
    settings.mode = ob1::music::ArpMode(patch[P_ARP_MODE]);
    settings.latch = ob1::music::Latch(patch[P_ARP_LATCH]);
    settings.division = patch[P_ARP_DIV];
    settings.octaves = patch[P_ARP_OCT];
    settings.gate = patch[P_ARP_GATE];
    settings.velocity = patch[P_ARP_VEL];
    settings.sync = engine.ctl_arp_sync != 0;
    settings.grid = engine.ctl_arp_sync_grid;
    output = settings;
    return true;
}

// Read only at the external-ARP callback, while the effective patch is installed.
inline bool arpeggiator_context(Engine& engine, uint32_t part, ob1::music::Time time,
                               ArpeggiatorContext& output)
{
    if (part >= NPART || !engine.externalArpeggiator[part] || !engine.controllerRendering)
        return false;
    ArpeggiatorContext result {};
    if (!arpeggiator_settings(engine, part, result.settings)) return false;
    auto& clock = result.clock;
    clock.time = time;
    clock.quarterFrames = engine.quarter_len();
    uint32_t phase = 0;
    clock.hasMasterPhase = engine.host_phase(&phase, &clock.barPhaseFrames);
    clock.advanceFrames = engine.phaseAdvance;
    clock.livePhaseAdjustment = engine.livePhaseAdjustment;
    output = result;
    return true;
}

} // namespace obervave
