// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Event.h"

namespace ob1::music {

struct ChannelRoute {
    uint8_t channel = 0;
    uint8_t low = 0, high = 127;
};

// The caller validates the event, slot and route before dispatch.
inline bool matches(const Event& event, uint32_t slot, const ChannelRoute& route)
{
    if (event.routing.target == Target::Instruments)
        return (event.routing.instruments & (uint32_t(1) << slot)) != 0;
    if (event.channel != route.channel) return false;
    return event.kind != Kind::NoteOn || (event.data1 >= route.low && event.data1 <= route.high);
}

inline Event forInstrument(const Event& event, uint32_t slot)
{
    auto routed = event;
    routed.routing.target = Target::Instruments;
    routed.routing.instruments = uint16_t(uint32_t(1) << slot);
    return routed;
}

} // namespace ob1::music
