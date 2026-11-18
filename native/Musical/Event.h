// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <type_traits>

namespace ob1::music {

using Frame = uint64_t;
using Tick = int64_t;
using NoteID = uint64_t;
constexpr Tick ticksPerQuarter = 960;
constexpr uint32_t instrumentCapacity = 16;

enum class SourceKind : uint8_t { ExternalMIDI, TouchKeyboard, Host, Arpeggiator, Pattern, System, Count };
struct Source {
    SourceKind kind = SourceKind::ExternalMIDI;
    uint32_t id = 0;
    bool operator==(const Source& other) const { return kind == other.kind && id == other.id; }
};
enum class Kind : uint8_t {
    NoteOff, NoteOn, PolyPressure, ControlChange, ProgramChange, ChannelPressure,
    PitchBend, Clock, Start, Continue, Stop, Count
};
enum class Target : uint8_t { Channel, Instruments };
enum class Stage : uint8_t { Input, Output };
struct Routing {
    Target target = Target::Channel;
    uint16_t instruments = 0;
    // Recorded output skips arpeggiation on replay; input recordings do not.
    Stage stage = Stage::Input;
};
struct Time {
    Frame frame = 0;
    Tick tick = 0;
    bool hasTick = false;
};
struct Event {
    Kind kind = Kind::NoteOff;
    uint8_t channel = 0; // Zero-based throughout the core.
    uint8_t data1 = 0, data2 = 0;
    Source source {};
    Routing routing {};
    Time time {};
    NoteID note = 0; // Zero until an ingress/processor assigns ownership.
};
struct BlockEvent {
    Event event;
    uint32_t sampleOffset = 0;
};
struct MIDIMessage { uint8_t status, data1, data2; };
enum class EventError : uint8_t {
    None, InvalidStatus, InvalidData, InvalidSource, InvalidRouting, OutsideBlock
};

inline bool isNote(const Event& event)
{
    return event.kind == Kind::NoteOn || event.kind == Kind::NoteOff;
}

inline EventError validate(const Event& event)
{
    if (event.kind >= Kind::Count) return EventError::InvalidStatus;
    if (event.channel > 15 || event.data1 > 127 || event.data2 > 127 ||
        (event.kind == Kind::NoteOn && !event.data2) ||
        ((event.kind == Kind::ChannelPressure || event.kind == Kind::ProgramChange) && event.data2) ||
        (event.kind >= Kind::Clock && (event.channel || event.data1 || event.data2)))
        return EventError::InvalidData;
    if (event.source.kind >= SourceKind::Count) return EventError::InvalidSource;
    if ((event.routing.target != Target::Channel && event.routing.target != Target::Instruments) ||
        (event.routing.stage != Stage::Input && event.routing.stage != Stage::Output) ||
        (event.routing.target == Target::Channel && event.routing.instruments) ||
        (event.routing.target == Target::Instruments && !event.routing.instruments))
        return EventError::InvalidRouting;
    return EventError::None;
}

inline EventError decodeMIDI(uint32_t status, uint32_t data1, uint32_t data2,
                             Source source, Time time, Event& output)
{
    if (data1 > 127 || data2 > 127) return EventError::InvalidData;
    Event event {};
    event.source = source;
    event.time = time;
    event.channel = status & 15;
    event.data1 = uint8_t(data1);
    event.data2 = uint8_t(data2);
    if (status >= 0x80 && status < 0xF0) {
        switch (status & 0xF0) {
        case 0x80: event.kind = Kind::NoteOff; break;
        case 0x90: event.kind = data2 ? Kind::NoteOn : Kind::NoteOff; break;
        case 0xA0: event.kind = Kind::PolyPressure; break;
        case 0xB0: event.kind = Kind::ControlChange; break;
        case 0xC0: event.kind = Kind::ProgramChange; event.data2 = 0; break;
        case 0xD0: event.kind = Kind::ChannelPressure; event.data2 = 0; break;
        case 0xE0: event.kind = Kind::PitchBend; break;
        }
    } else {
        event.channel = event.data1 = event.data2 = 0;
        switch (status) {
        case 0xF8: event.kind = Kind::Clock; break;
        case 0xFA: event.kind = Kind::Start; break;
        case 0xFB: event.kind = Kind::Continue; break;
        case 0xFC: event.kind = Kind::Stop; break;
        default: return EventError::InvalidStatus;
        }
    }
    const auto error = validate(event);
    if (error == EventError::None) output = event;
    return error;
}

inline EventError encodeMIDI(const Event& event, MIDIMessage& output)
{
    const auto error = validate(event);
    if (error != EventError::None) return error;
    uint8_t status = 0;
    switch (event.kind) {
    case Kind::NoteOff: status = 0x80; break;
    case Kind::NoteOn: status = 0x90; break;
    case Kind::PolyPressure: status = 0xA0; break;
    case Kind::ControlChange: status = 0xB0; break;
    case Kind::ProgramChange: status = 0xC0; break;
    case Kind::ChannelPressure: status = 0xD0; break;
    case Kind::PitchBend: status = 0xE0; break;
    case Kind::Clock: status = 0xF8; break;
    case Kind::Start: status = 0xFA; break;
    case Kind::Continue: status = 0xFB; break;
    case Kind::Stop: status = 0xFC; break;
    case Kind::Count: return EventError::InvalidStatus;
    }
    output = {uint8_t(status | event.channel), event.data1, event.data2};
    return EventError::None;
}

inline EventError withinBlock(const Event& event, Frame start, uint32_t frames, BlockEvent& output)
{
    const auto error = validate(event);
    if (error != EventError::None) return error;
    if (event.time.frame < start || event.time.frame - start >= frames)
        return EventError::OutsideBlock;
    output = {event, uint32_t(event.time.frame - start)};
    return EventError::None;
}

// Only generated batches use this ordering. Received MIDI keeps its FIFO order.
inline bool generatedBefore(const Event& a, const Event& b)
{
    if (a.time.frame != b.time.frame) return a.time.frame < b.time.frame;
    const auto priority = [](Kind kind) {
        return kind == Kind::NoteOff ? 0 : kind == Kind::NoteOn ? 2 : 1;
    };
    return priority(a.kind) < priority(b.kind);
}

static_assert(std::is_trivially_copyable_v<Event>);
static_assert(std::is_trivially_destructible_v<Event>);

} // namespace ob1::music
