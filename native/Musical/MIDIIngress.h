// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Event.h"
#include <array>
#include <limits>

namespace ob1::music {

class MIDIByteParser {
public:
    template<class Sink>
    bool input(uint32_t value, Sink& sink)
    {
        if (value > 255) return false;
        const auto byte = uint8_t(value);
        if (byte >= 0xF8) {
            if (byte == 0xF8 || byte == 0xFA || byte == 0xFB || byte == 0xFC)
                return sink(byte, 0, 0);
            return true;
        }
        if (byte & 0x80) {
            status_ = byte < 0xF0 ? byte : 0;
            count_ = 0;
            return true;
        }
        if (!status_) return true;
        data_[count_++] = byte;
        const uint32_t expected = (status_ & 0xF0) == 0xC0 || (status_ & 0xF0) == 0xD0 ? 1 : 2;
        if (count_ != expected) return true;
        count_ = 0;
        return sink(status_, data_[0], expected == 2 ? data_[1] : 0);
    }

private:
    uint8_t status_ = 0, count_ = 0, data_[2] {};
};

// Producer-side registry; its caller serializes access, never the audio thread.
class MIDIIngress {
public:
    static constexpr uint32_t capacity = 64;

    uint32_t open()
    {
        if (next_ == std::numeric_limits<uint32_t>::max()) return 0;
        for (auto& stream : streams_) {
            if (stream.id) continue;
            stream = {};
            stream.id = ++next_;
            return stream.id;
        }
        return 0;
    }
    bool close(uint32_t id)
    {
        auto* stream = find(id);
        if (!stream) return false;
        *stream = {};
        return true;
    }
    bool contains(uint32_t id) const
    {
        if (!id) return false;
        for (const auto& stream : streams_) if (stream.id == id) return true;
        return false;
    }
    template<class Sink>
    bool input(uint32_t id, uint32_t byte, Sink& sink)
    {
        auto* stream = find(id);
        return stream && stream->parser.input(byte, sink);
    }

private:
    struct Stream { uint32_t id = 0; MIDIByteParser parser; };
    std::array<Stream, capacity> streams_ {};
    uint32_t next_ = 0;
    Stream* find(uint32_t id)
    {
        if (!id) return nullptr;
        for (auto& stream : streams_) if (stream.id == id) return &stream;
        return nullptr;
    }
};

} // namespace ob1::music
