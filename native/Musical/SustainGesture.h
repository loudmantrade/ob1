// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Event.h"
#include <array>

namespace ob1::music {

class SustainGesture {
public:
    enum class Result { None, Stop, Full };
    void clear() { states_ = {}; }
    void releaseSource(Source source)
    {
        for (auto& state : states_) if (state.used && state.source == source) state = {};
    }

    // Values are polarity-corrected; durations use the processing sample clock.
    Result input(Source source, uint8_t channel, uint8_t value, Frame now,
                 uint32_t quarterFrames, uint32_t sampleRate)
    {
        State* found = nullptr;
        State* available = nullptr;
        for (auto& state : states_) {
            if (state.used && state.source == source && state.channel == channel) found = &state;
            if ((!state.used || (!state.down && now - state.released > quarterFrames)) && !available)
                available = &state;
        }
        if (!found) {
            if (value < 96) return Result::None;
            if (!available) return Result::Full;
            found = available;
            *found = {};
            found->used = true;
            found->source = source;
            found->channel = channel;
        }
        auto& state = *found;
        if (value >= 96 && !state.down) {
            if (state.count && now - state.released > quarterFrames) state.count = 0;
            state.down = true;
            state.pressed = now;
        } else if (value <= 31 && state.down) {
            state.down = false;
            state.released = now;
            if (now - state.pressed > uint64_t(sampleRate) * 300 / 1000) state.count = 0;
            else if (++state.count == 3) {
                state.count = 0;
                return Result::Stop;
            }
        }
        return Result::None;
    }

private:
    struct State {
        Source source {};
        Frame pressed = 0, released = 0;
        uint8_t channel = 0, count = 0;
        bool used = false, down = false;
    };
    // 64 ingress connections plus legacy MIDI and touch, each with 16 channels.
    std::array<State, (64 + 2) * 16> states_ {};
};

} // namespace ob1::music
