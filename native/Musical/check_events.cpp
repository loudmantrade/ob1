// SPDX-License-Identifier: GPL-3.0-only
#include "Routing.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <limits>

using namespace ob1::music;

int main()
{
    Event event {};
    const Source keyboard {SourceKind::TouchKeyboard, 7};
    const Time time {123456789012ull, -ticksPerQuarter, true};
    for (uint32_t status = 0x80; status < 0xF0; ++status) {
        for (uint32_t a = 0; a < 128; ++a) {
            for (const uint32_t b : {0u, 1u, 64u, 127u}) {
                assert(decodeMIDI(status, a, b, keyboard, time, event) == EventError::None);
                assert(event.channel == (status & 15) && event.source == keyboard);
                assert(event.time.frame == time.frame && event.time.tick == time.tick && event.time.hasTick);
                assert(event.note == 0 && event.routing.stage == Stage::Input);
                MIDIMessage message {};
                assert(encodeMIDI(event, message) == EventError::None);
                const auto kind = status & 0xF0;
                assert(message.status == (kind == 0x90 && b == 0 ? 0x80 | (status & 15) : status));
                assert(message.data1 == a);
                assert(message.data2 == (kind == 0xC0 || kind == 0xD0 ? 0 : b));
            }
        }
    }
    for (const uint32_t status : {0xF8u, 0xFAu, 0xFBu, 0xFCu}) {
        assert(decodeMIDI(status, 127, 127, {}, {}, event) == EventError::None);
        MIDIMessage message {};
        assert(encodeMIDI(event, message) == EventError::None);
        assert(message.status == status && !message.data1 && !message.data2);
    }
    for (const uint32_t status : {0u, 0x7Fu, 0xF0u, 0xF1u, 0xF9u, 0xFEu, 0xFFu, 0x190u}) {
        event.note = 42;
        assert(decodeMIDI(status, 0, 0, {}, {}, event) == EventError::InvalidStatus);
        assert(event.note == 42);
    }
    assert(decodeMIDI(0x90, 128, 1, {}, {}, event) == EventError::InvalidData);
    assert(decodeMIDI(0x90, 1, 128, {}, {}, event) == EventError::InvalidData);
    assert(decodeMIDI(0x90, 1, 1, {SourceKind::Count, 0}, {}, event) == EventError::InvalidSource);
    assert(decodeMIDI(0x90, 60, 100, keyboard, {100}, event) == EventError::None);
    event.routing = {Target::Instruments, 0x8001, Stage::Output};
    event.note = 123;
    assert(validate(event) == EventError::None);
    BlockEvent block {};
    for (const uint32_t frames : {1u, 7u, 15u, 16u, 17u, 127u, 511u, 1024u}) {
        for (uint32_t offset = 0; offset < frames; ++offset) {
            event.time.frame = 100 + offset;
            assert(withinBlock(event, 100, frames, block) == EventError::None);
            assert(block.sampleOffset == offset && block.event.note == 123);
            assert(block.event.routing.instruments == 0x8001 && block.event.routing.stage == Stage::Output);
        }
        event.time.frame = 100 + frames;
        assert(withinBlock(event, 100, frames, block) == EventError::OutsideBlock);
    }
    event.time.frame = 99;
    assert(withinBlock(event, 100, 1, block) == EventError::OutsideBlock);
    assert(withinBlock(event, 0, 0, block) == EventError::OutsideBlock);
    event.time.frame = std::numeric_limits<Frame>::max();
    assert(withinBlock(event, event.time.frame - 15, 16, block) == EventError::None);
    assert(block.sampleOffset == 15);
    event.routing.instruments = 0;
    assert(validate(event) == EventError::InvalidRouting);
    event.routing = {Target::Channel, 1, Stage::Input};
    assert(validate(event) == EventError::InvalidRouting);
    event.routing = {};
    event.channel = 16;
    assert(validate(event) == EventError::InvalidData);
    event.channel = 0;
    event.data2 = 0;
    assert(validate(event) == EventError::InvalidData);
    event.kind = Kind::Count;
    assert(validate(event) == EventError::InvalidStatus);
    std::array<Event, 4> generated {};
    for (auto& e : generated) e.time.frame = 16;
    generated[0].kind = Kind::NoteOn; generated[0].note = 1;
    generated[1].kind = Kind::ControlChange;
    generated[2].kind = Kind::NoteOff;
    generated[3].kind = Kind::NoteOn; generated[3].note = 2;
    std::stable_sort(generated.begin(), generated.end(), generatedBefore);
    assert(generated[0].kind == Kind::NoteOff && generated[1].kind == Kind::ControlChange);
    assert(generated[2].note == 1 && generated[3].note == 2);
    generated[3].time.frame = 0;
    assert(generatedBefore(generated[3], generated[0]));
    assert(!generatedBefore(generated[0], generated[0]));
    assert(decodeMIDI(0x95, 60, 100, keyboard, {}, event) == EventError::None);
    for (uint32_t slot = 0; slot < instrumentCapacity; ++slot) {
        for (uint32_t channel = 0; channel < 16; ++channel) {
            const ChannelRoute route {uint8_t(channel), 48, 72};
            for (uint32_t note = 0; note < 128; ++note) {
                event.data1 = uint8_t(note);
                assert(matches(event, slot, route) == (channel == 5 && note >= 48 && note <= 72));
                event.kind = Kind::NoteOff;
                assert(matches(event, slot, route) == (channel == 5));
                event.kind = Kind::NoteOn;
            }
        }
    }
    event.routing.target = Target::Instruments;
    for (uint32_t mask = 1; mask <= 0xFFFF; ++mask) {
        event.routing.instruments = uint16_t(mask);
        for (uint32_t slot = 0; slot < instrumentCapacity; ++slot)
            assert(matches(event, slot, {15, 127, 127}) == ((mask & (1u << slot)) != 0));
    }
    const auto routed = forInstrument(event, 15);
    assert(routed.routing.instruments == 0x8000 && routed.source == event.source);
    assert(routed.time.frame == event.time.frame && routed.kind == event.kind && routed.data1 == event.data1);
    std::puts("PASS portable musical events: MIDI roundtrip, source/routing identity, validation, 64-bit time, block offsets and generated event ordering");
    std::puts("PASS portable routing: all logical instrument masks, channel/zone matching, unfiltered releases and pinned destinations");
}
