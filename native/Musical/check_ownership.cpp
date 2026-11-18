// SPDX-License-Identifier: GPL-3.0-only
#include "NoteOwnership.h"
#include <cassert>
#include <cstdio>
#include <vector>

using namespace ob1::music;

static Event note(Source source, uint8_t pitch = 60, NoteID id = 0, uint8_t channel = 0)
{
    Event event {};
    event.kind = Kind::NoteOn;
    event.data1 = pitch;
    event.data2 = 100;
    event.source = source;
    event.note = id;
    event.channel = channel;
    event.routing = {Target::Instruments, 1u << 7, Stage::Input};
    return event;
}

int main()
{
    NoteOwnership owners;
    std::vector<Event> events;
    bool reject = false;
    auto sink = [&](const Event& event) {
        if (reject) return false;
        events.push_back(event);
        return true;
    };
    const Source midi {SourceKind::ExternalMIDI, 9}, touch {SourceKind::TouchKeyboard, 9};
    auto a = note(midi), b = note(touch);
    assert(owners.input(a, sink) == OwnershipResult::Forwarded);
    assert(owners.input(a, sink) == OwnershipResult::Forwarded && owners.count() == 1);
    assert(owners.input(b, sink) == OwnershipResult::Forwarded && owners.count() == 2);
    a.kind = Kind::NoteOff;
    a.data2 = 0;
    assert(owners.input(a, sink) == OwnershipResult::Retained && owners.count() == 1);
    assert(owners.input(a, sink) == OwnershipResult::Unmatched);
    assert(events.size() == 3);
    assert(owners.releaseSource(touch, {123, 42, true}, sink) == OwnershipResult::Forwarded);
    assert(!owners.count() && events.size() == 4);
    const auto& off = events.back();
    assert(off.kind == Kind::NoteOff && off.channel == 0 && off.source == touch);
    assert(off.routing.instruments == (1u << 7) && off.time.frame == 123 &&
           off.time.tick == 42 && off.time.hasTick);

    for (const auto channel : {0, 1})
        for (const auto id : {1, 2})
            assert(owners.input(note(midi, 60, id, channel), sink) == OwnershipResult::Forwarded);
    assert(owners.count() == 4);
    assert(owners.releaseSource(midi, {}, sink) == OwnershipResult::Forwarded && !owners.count());
    assert(events.back().note == 2 && events.back().channel == 1);
    auto invalid = b;
    invalid.routing.stage = Stage::Output;
    assert(owners.input(invalid, sink) == OwnershipResult::InvalidInput);
    invalid = b;
    invalid.kind = Kind::ControlChange;
    assert(owners.input(invalid, sink) == OwnershipResult::InvalidInput);
    invalid = b;
    invalid.source.kind = SourceKind::Count;
    assert(owners.input(invalid, sink) == OwnershipResult::InvalidInput);
    assert(owners.releaseSource(invalid.source, {}, sink) == OwnershipResult::InvalidInput);
    reject = true;
    assert(owners.input(b, sink) == OwnershipResult::OutputRejected && !owners.count());
    reject = false;
    assert(owners.input(b, sink) == OwnershipResult::Forwarded);
    reject = true;
    assert(owners.releaseSource(touch, {}, sink) == OwnershipResult::OutputRejected);
    assert(owners.count() == 1);
    reject = false;
    assert(owners.releaseSource(touch, {}, sink) == OwnershipResult::Forwarded);
    assert(!owners.count());
    assert(owners.input(note(midi, 60), sink) == OwnershipResult::Forwarded);
    assert(owners.input(note(midi, 64), sink) == OwnershipResult::Forwarded);
    uint32_t releases = 0;
    auto rejectSecond = [&](const Event& event) {
        assert(event.kind == Kind::NoteOff && event.source == midi);
        return ++releases != 2;
    };
    assert(owners.releaseSource(midi, {}, rejectSecond) == OwnershipResult::OutputRejected);
    assert(owners.count() == 1 && releases == 2);
    assert(owners.releaseSource(midi, {}, sink) == OwnershipResult::Forwarded && !owners.count());
    assert(events.back().data1 == 64);

    for (uint32_t i = 0; i < NoteOwnership::capacity; ++i)
        assert(owners.input(note(midi, i % 128, i + 1), sink) == OwnershipResult::Forwarded);
    const auto size = events.size();
    assert(owners.input(note(touch), sink) == OwnershipResult::Full);
    assert(events.size() == size && owners.count() == NoteOwnership::capacity);
    assert(owners.input(note(midi, 0, 1), sink) == OwnershipResult::Forwarded);
    assert(owners.count() == NoteOwnership::capacity);
    owners.clear();
    assert(!owners.count());
    std::puts("PASS physical-note ownership: source kind/endpoint/channel/note IDs, repeat retrigger, final-owner Off, captured releases, capacity, validation and retryable rejection");
}
