// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Event.h"
#include <array>

namespace ob1::music {

enum class OwnershipResult : uint8_t { Forwarded, Retained, Unmatched, InvalidInput, Full, OutputRejected };

// One destination's physical keys. Sustain/Latch belong to the downstream processor.
class NoteOwnership {
public:
    static constexpr uint32_t capacity = 256;

    uint32_t count() const
    {
        uint32_t result = 0;
        for (const auto& entry : entries_) result += entry.used;
        return result;
    }

    void clear() { entries_ = {}; }

    template<class Sink>
    OwnershipResult input(const Event& event, Sink& sink)
    {
        if (validate(event) != EventError::None || !isNote(event) || event.routing.stage != Stage::Input)
            return OwnershipResult::InvalidInput;
        uint32_t match = capacity, available = capacity;
        bool other = false;
        for (uint32_t i = 0; i < capacity; ++i) {
            const auto& entry = entries_[i];
            if (!entry.used) {
                if (available == capacity) available = i;
            } else if (entry.on.data1 == event.data1) {
                if (entry.on.source == event.source && entry.on.channel == event.channel &&
                    entry.on.note == event.note) match = i;
                else other = true;
            }
        }
        if (event.kind == Kind::NoteOn) {
            const auto index = match == capacity ? available : match;
            if (index == capacity) return OwnershipResult::Full;
            if (!sink(event)) return OwnershipResult::OutputRejected;
            entries_[index] = {event, true};
            return OwnershipResult::Forwarded;
        }
        if (match == capacity) return OwnershipResult::Unmatched;
        if (!other && !sink(event)) return OwnershipResult::OutputRejected;
        entries_[match].used = false;
        return other ? OwnershipResult::Retained : OwnershipResult::Forwarded;
    }

    // Disconnect/key-source cleanup uses each On's captured channel, ID and routing.
    template<class Sink>
    OwnershipResult releaseSource(Source source, Time time, Sink& sink)
    {
        if (source.kind >= SourceKind::Count) return OwnershipResult::InvalidInput;
        for (uint32_t i = 0; i < capacity; ++i) {
            if (!entries_[i].used || !(entries_[i].on.source == source)) continue;
            auto off = entries_[i].on;
            off.kind = Kind::NoteOff;
            off.data2 = 0;
            off.time = time;
            const auto result = input(off, sink);
            if (result == OwnershipResult::OutputRejected) return result;
        }
        return OwnershipResult::Forwarded;
    }

private:
    struct Entry { Event on {}; bool used = false; };
    std::array<Entry, capacity> entries_ {};
};

} // namespace ob1::music
