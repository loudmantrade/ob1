// SPDX-License-Identifier: GPL-3.0-only
#include "Pattern.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

using namespace ob1::music;
constexpr auto ok = PatternError::None;

static bool sameNote(const PatternNote& a, const PatternNote& b)
{
    return a.id == b.id && a.start == b.start && a.duration == b.duration &&
        a.pitch == b.pitch && a.velocity == b.velocity && a.channel == b.channel &&
        a.routing.target == b.routing.target && a.routing.instruments == b.routing.instruments &&
        a.routing.stage == b.routing.stage;
}
static bool same(const PatternData& a, const PatternData& b)
{
    if (a.version != b.version || a.id != b.id || a.name != b.name || a.length != b.length ||
        a.nextNote != b.nextNote || a.count != b.count || a.loop != b.loop ||
        a.quantization.grid != b.quantization.grid || a.quantization.strength != b.quantization.strength ||
        a.quantization.ends != b.quantization.ends) return false;
    for (uint32_t i = 0; i < a.count; ++i) if (!sameNote(a.notes[i], b.notes[i])) return false;
    return true;
}

static void checkNames()
{
    for (const auto name : {"Arp output", "  Pattern 2  ", "\xd0\x90\xd1\x80\xd0\xbf",
                             "\xf0\x9f\x8e\xb9"}) assert(patternNameValid(name));
    assert(patternNameValid(std::string(patternNameBytes, 'x')));
    assert(!patternNameValid(std::string(patternNameBytes + 1, 'x')));
    const std::string invalid[] = {
        "", "   ", "\t", "\n", std::string("a\0b", 3), "\x7f", "\x80", "\xc0\xaf", "\xc1\xbf",
        "\xc2", "\xc2 ", "\xe0\x80\x80", "\xed\xa0\x80", "\xf0\x80\x80\x80", "\xf4\x90\x80\x80",
        "\xf5\x80\x80\x80", "\xc2\x85", "\xc2\xa0", "\xe2\x80\x83\xe3\x80\x80"
    };
    auto pattern = std::make_unique<Pattern>();
    assert(pattern->initialize(1, "Original") == ok);
    for (const auto& name : invalid) {
        const auto before = pattern->data();
        assert(!patternNameValid(name));
        assert(pattern->rename(name) == PatternError::InvalidName && same(before, pattern->data()));
        assert(pattern->initialize(2, name) == PatternError::InvalidName && same(before, pattern->data()));
    }
    assert(pattern->rename(pattern->name().substr(1)) == ok && pattern->name() == "riginal");
    assert(pattern->initialize(7, pattern->name()) == ok && pattern->name() == "riginal");
    std::puts("PASS pattern names: bounded UTF-8, multilingual/emoji, self-aliasing, controls/blank/invalid UTF-8 rejection and transactional errors");
}

static void checkNotes()
{
    auto pattern = std::make_unique<Pattern>();
    NoteID id = 999;
    assert(pattern->add({}, id) == PatternError::NotFound && id == 999);
    assert(pattern->initialize(0, "Test") == PatternError::InvalidCounter);
    assert(pattern->initialize(1, "Test", 0) == PatternError::InvalidLength);
    assert(pattern->initialize(1, "Test", maxPatternTicks + 1) == PatternError::InvalidLength);
    assert(pattern->initialize(1, "Test", maxPatternTicks) == ok);
    assert(validatePatternNote({}, 0) == PatternError::InvalidLength);
    assert(validatePatternNote({}, std::numeric_limits<Tick>::max()) == PatternError::InvalidLength);
    PatternNote note {};
    note.start = maxPatternTicks - 1;
    note.duration = maxPatternTicks;
    note.channel = 15; note.pitch = 127; note.velocity = 127;
    note.routing = {Target::Instruments, 0xffff, Stage::Output};
    assert(pattern->add(note, id) == ok && id == 1);
    assert(pattern->data().notes[0].start + pattern->data().notes[0].duration > pattern->data().length);
    note.start = 0;
    assert(pattern->add(note, id) == ok && id == 2);
    assert(pattern->data().notes[0].id == 2 && pattern->data().notes[1].id == 1);
    assert(pattern->add(note, id) == ok && id == 3);
    assert(pattern->data().notes[1].id == 3);
    note.start = 1;
    assert(pattern->edit(2, note) == ok && pattern->data().notes[0].id == 3);
    assert(pattern->data().notes[1].id == 2);
    assert(pattern->erase(1) == ok && pattern->erase(1) == PatternError::NotFound);
    const auto before = pattern->data();
    assert(pattern->length(1) == PatternError::InvalidLength && same(before, pattern->data()));
    assert(pattern->length(2) == ok);
    assert(pattern->loop(false) == ok && !pattern->data().loop);
    assert(pattern->loop(true) == ok && pattern->data().loop);

    for (uint32_t field = 0; field < 14; ++field) {
        auto invalid = note;
        auto expected = PatternError::InvalidNote;
        switch (field) {
        case 0: invalid.start = -1; break;
        case 1: invalid.start = 2; break;
        case 2: invalid.duration = 0; break;
        case 3: invalid.duration = -1; break;
        case 4: invalid.duration = std::numeric_limits<Tick>::max(); break;
        case 5: invalid.pitch = 128; break;
        case 6: invalid.channel = 16; break;
        case 7: invalid.velocity = 0; break;
        case 8: invalid.velocity = 128; break;
        case 9: invalid.routing.target = Target(2); expected = PatternError::InvalidRouting; break;
        case 10: invalid.routing.stage = Stage(2); expected = PatternError::InvalidRouting; break;
        case 11: invalid.routing.instruments = 0; expected = PatternError::InvalidRouting; break;
        case 12: invalid.routing.target = Target::Channel; expected = PatternError::InvalidRouting; break;
        case 13: invalid.start = std::numeric_limits<Tick>::min(); break;
        }
        const auto saved = pattern->data();
        id = 999;
        assert(pattern->add(invalid, id) == expected && id == 999);
        assert(pattern->edit(2, invalid) == expected && same(saved, pattern->data()));
        assert(pattern->edit(999, invalid) == PatternError::NotFound);
    }
    for (uint32_t channel = 0; channel < 16; ++channel)
        for (uint32_t pitch = 0; pitch < 128; ++pitch) {
            note.channel = channel; note.pitch = pitch;
            note.routing = {Target::Channel, 0, Stage::Input};
            assert(pattern->edit(2, note) == ok);
            note.routing = {Target::Instruments, uint16_t(1u << channel), Stage::Output};
            assert(pattern->edit(2, note) == ok);
        }
    assert(pattern->initialize(2, "Capacity") == ok);
    note = {};
    for (uint32_t i = 0; i < patternNoteCapacity; ++i) {
        note.start = patternNoteCapacity - i;
        assert(pattern->add(note, id) == ok && id == i + 1);
    }
    assert(pattern->data().count == patternNoteCapacity && validatePattern(pattern->data()) == ok);
    const auto full = pattern->data();
    assert(pattern->add(note, id) == PatternError::Full && same(full, pattern->data()));
    assert(pattern->erase(500) == ok);
    assert(pattern->add(note, id) == ok && id == patternNoteCapacity + 1);
    assert(pattern->erase(1) == ok && pattern->erase(2) == ok);
    auto exhausted = pattern->data();
    exhausted.nextNote = std::numeric_limits<NoteID>::max() - 1;
    assert(pattern->restore(exhausted) == ok);
    assert(pattern->add(note, id) == ok && id == std::numeric_limits<NoteID>::max() - 1);
    assert(pattern->add(note, id) == PatternError::IDExhausted);
    assert(validatePattern(pattern->data()) == ok);
    std::puts("PASS pattern notes: full MIDI range, explicit layer/channel/stage routing, overlap/cross-loop durations, stable sorted IDs, edit/remove, bounds, capacity and non-reused ID exhaustion");
}

static Tick referenceQuantize(Tick tick, PatternQuantization q, Tick maximum)
{
    auto target = Tick(std::floor(double(tick) / q.grid + 0.5)) * q.grid;
    target = std::min(target, maximum / q.grid * q.grid);
    const auto amount = Tick(std::floor(std::abs(double(target - tick)) * q.strength / 100 + 0.5));
    return tick + (target < tick ? -amount : amount);
}
static void checkQuantization()
{
    auto pattern = std::make_unique<Pattern>();
    assert(pattern->initialize(1, "Quantize", 3871) == ok);
    NoteID id;
    assert(pattern->add({}, id) == ok);
    uint64_t compared = 0;
    for (const Tick length : {1, 13, 3871, int(maxPatternTicks)}) {
        PatternNote note {};
        assert(pattern->edit(id, note) == ok && pattern->length(length) == ok);
        for (const Tick grid : {0, 1, 2, 3, 5, 7, 60, 80, 120, 160, 240, 320, 480, 640, 960, 1920, 3840})
            for (const uint8_t strength : {0, 1, 25, 50, 99, 100})
                for (bool ends : {false, true}) {
                    const PatternQuantization q {grid, strength, ends};
                    assert(pattern->quantization(q) == ok);
                    for (Tick start = 0; start < length; start += std::max(Tick(1), length / 113)) {
                        note.start = start;
                        note.duration = (start * 31 + 1) % maxPatternTicks + 1;
                        assert(pattern->edit(id, note) == ok);
                        const auto saved = pattern->data().notes[0];
                        PatternTiming actual;
                        assert(pattern->timing(id, actual) == ok);
                        auto expected = PatternTiming {note.start, note.duration};
                        if (grid && strength) {
                            expected.start = referenceQuantize(note.start, q, length - 1);
                            if (ends) expected.duration = std::clamp(
                                referenceQuantize(note.start + note.duration, q, maxPatternTicks * 2) - expected.start,
                                Tick(1), maxPatternTicks);
                        }
                        assert(actual.start == expected.start && actual.duration == expected.duration);
                        assert(actual.start >= 0 && actual.start < length && actual.duration > 0 &&
                            actual.duration <= maxPatternTicks && sameNote(saved, pattern->data().notes[0]));
                        ++compared;
                    }
                }
    }
    const auto saved = pattern->data();
    assert(pattern->quantization({-1, 100, false}) == PatternError::InvalidQuantization);
    assert(pattern->quantization({3841, 100, false}) == PatternError::InvalidQuantization);
    assert(pattern->quantization({120, 101, false}) == PatternError::InvalidQuantization);
    assert(same(saved, pattern->data()));
    PatternTiming untouched {123, 456};
    assert(pattern->timing(0, untouched) == PatternError::NotFound && untouched.start == 123 && untouched.duration == 456);
    std::printf("PASS non-destructive quantization: %llu timing pairs vs independent rounding oracle, straight/triplet/custom grids, strength, starts/ends, loop-edge clamps and original timing preserved\n",
        static_cast<unsigned long long>(compared));
}

static void checkRestore()
{
    auto pattern = std::make_unique<Pattern>();
    assert(pattern->initialize(42, "Restore") == ok);
    NoteID id;
    assert(pattern->add({}, id) == ok);
    PatternNote note {};
    note.start = 100;
    assert(pattern->add(note, id) == ok);
    const auto saved = pattern->data();
    for (uint32_t field = 0; field < 13; ++field) {
        auto invalid = saved;
        auto expected = PatternError::InvalidCounter;
        switch (field) {
        case 0: invalid.version = 2; expected = PatternError::InvalidVersion; break;
        case 1: invalid.name.fill('x'); expected = PatternError::InvalidName; break;
        case 2: invalid.name.fill(0); expected = PatternError::InvalidName; break;
        case 3: invalid.id = 0; break;
        case 4: invalid.nextNote = 0; break;
        case 5: invalid.nextNote = 2; break;
        case 6: invalid.count = patternNoteCapacity + 1; expected = PatternError::Full; break;
        case 7: invalid.notes[1].id = 1; expected = PatternError::DuplicateID; break;
        case 8: std::swap(invalid.notes[0], invalid.notes[1]); expected = PatternError::Unsorted; break;
        case 9: invalid.length = 100; expected = PatternError::InvalidNote; break;
        case 10: invalid.notes[0].id = 0; expected = PatternError::InvalidNote; break;
        case 11: invalid.quantization.grid = -1; expected = PatternError::InvalidQuantization; break;
        case 12: invalid.notes[0].routing.instruments = 0; expected = PatternError::InvalidRouting; break;
        }
        assert(pattern->restore(invalid) == expected && same(pattern->data(), saved));
    }
    assert(pattern->restore(pattern->data()) == ok);
    auto store = std::make_unique<PatternStore>();
    PatternID a, b;
    PatternID untouchedID = 999;
    assert(store->create("", 3840, untouchedID) == PatternError::InvalidName);
    assert(store->create("Invalid", 0, untouchedID) == PatternError::InvalidLength);
    assert(untouchedID == 999 && !store->count() && store->nextID() == 1);
    assert(store->create("One", 3840, a) == ok);
    assert(store->addNote(a, {}, id) == ok);
    assert(store->quantization(a, {120, 50, true}) == ok);
    assert(store->loop(a, false) == ok);
    assert(store->duplicate(a, store->get(a)->name(), b) == ok && b != a);
    const auto duplicateCounter = store->nextID();
    assert(store->duplicate(a, "", untouchedID) == PatternError::InvalidName &&
        untouchedID == 999 && store->nextID() == duplicateCounter);
    assert(store->get(b)->data().notes[0].id == id && !store->get(b)->data().loop);
    assert(store->rename(b, "Copy") == ok && store->get(a)->name() == "One");
    assert(store->eraseNote(b, id) == ok && store->get(a)->data().count == 1);
    auto snapshot = std::make_unique<PatternStoreData>();
    store->snapshot(*snapshot);
    auto restored = std::make_unique<PatternStore>();
    assert(restored->restore(*snapshot) == ok && restored->count() == 2);
    for (uint32_t slot = 0; slot < patternCapacity; ++slot) {
        const auto* original = store->at(slot);
        const auto* copy = restored->at(slot);
        assert(bool(original) == bool(copy));
        if (copy) assert(same(original->data(), copy->data()));
    }
    for (uint32_t field = 0; field < 7; ++field) {
        store->snapshot(*snapshot);
        auto expected = PatternError::InvalidCounter;
        switch (field) {
        case 0: snapshot->version = 2; expected = PatternError::InvalidVersion; break;
        case 1: snapshot->nextID = 0; break;
        case 2: snapshot->nextID = b; break;
        case 3: snapshot->count = patternCapacity + 1; expected = PatternError::Full; break;
        case 4: snapshot->count = 1; break;
        case 5: snapshot->patterns[1].id = a; expected = PatternError::DuplicateID; break;
        case 6: snapshot->patterns[1].notes[0] = {}; snapshot->patterns[1].count = 1;
            expected = PatternError::InvalidNote; break;
        }
        assert(restored->restore(*snapshot) == expected && restored->count() == 2);
        assert(same(restored->get(a)->data(), store->get(a)->data()));
        assert(same(restored->get(b)->data(), store->get(b)->data()));
    }
    assert(store->erase(a) == ok && store->erase(a) == PatternError::NotFound);
    PatternID c;
    assert(store->create("Reused slot, new ID", 960, c) == ok && c > b);
    assert(!store->get(a) && !store->get(0) && !store->at(patternCapacity));
    assert(store->rename(a, "Missing") == PatternError::NotFound);
    assert(store->length(a, 100) == PatternError::NotFound);
    assert(store->loop(a, false) == PatternError::NotFound);
    assert(store->quantization(a, {}) == PatternError::NotFound);
    assert(store->addNote(a, {}, id) == PatternError::NotFound);
    assert(store->editNote(a, id, {}) == PatternError::NotFound);
    assert(store->eraseNote(a, id) == PatternError::NotFound);
    PatternID unchanged = 999;
    assert(store->duplicate(a, "Missing", unchanged) == PatternError::NotFound && unchanged == 999);
    for (uint32_t i = store->count(); i < patternCapacity; ++i)
        assert(store->create("Fill", 1, unchanged) == ok);
    unchanged = 999;
    assert(store->create("Full", 1, unchanged) == PatternError::Full && unchanged == 999);
    assert(store->duplicate(b, "Full", unchanged) == PatternError::Full && unchanged == 999);
    assert(store->erase(b) == ok);
    store->snapshot(*snapshot);
    snapshot->nextID = std::numeric_limits<PatternID>::max() - 1;
    assert(store->restore(*snapshot) == ok);
    assert(store->create("Last", 1, c) == ok && c == std::numeric_limits<PatternID>::max() - 1);
    assert(store->erase(c) == ok);
    assert(store->create("Exhausted", 1, unchanged) == PatternError::IDExhausted && unchanged == 999);
    assert(store->duplicate(store->at(0)->data().id, "Exhausted", unchanged) == PatternError::IDExhausted);
    std::puts("PASS pattern management/snapshots: CRUD/duplicate independence, IDs survive slot reuse, complete round-trip, bad versions/counters/duplicates reject atomically, bank capacity and ID exhaustion");
}

static void checkRandom()
{
    auto pattern = std::make_unique<Pattern>();
    assert(pattern->initialize(1, "Random", maxPatternTicks) == ok);
    std::vector<PatternNote> oracle;
    NoteID next = 1;
    std::mt19937 random(0x54103a);
    for (uint32_t operation = 0; operation < 20000; ++operation) {
        PatternNote note {};
        note.start = random() % maxPatternTicks;
        note.duration = random() % maxPatternTicks + 1;
        note.pitch = random() % 128;
        note.velocity = random() % 127 + 1;
        note.channel = random() % 16;
        note.routing = {Target::Instruments, uint16_t(random() % 65535 + 1),
                        random() & 1 ? Stage::Input : Stage::Output};
        const auto action = random() % 3;
        if (action == 0 || oracle.empty()) {
            NoteID id = 999;
            const auto result = pattern->add(note, id);
            if (oracle.size() == patternNoteCapacity) assert(result == PatternError::Full && id == 999);
            else {
                assert(result == ok && id == next++);
                note.id = id;
                oracle.push_back(note);
            }
        } else {
            const auto index = random() % oracle.size();
            if (action == 1) {
                note.id = oracle[index].id;
                assert(pattern->edit(note.id, note) == ok);
                oracle[index] = note;
            } else {
                assert(pattern->erase(oracle[index].id) == ok);
                oracle.erase(oracle.begin() + index);
            }
        }
        std::sort(oracle.begin(), oracle.end(), [](const auto& a, const auto& b) {
            return a.start == b.start ? a.id < b.id : a.start < b.start;
        });
        assert(pattern->data().count == oracle.size() && pattern->data().nextNote == next);
        for (uint32_t i = 0; i < oracle.size(); ++i) assert(sameNote(pattern->data().notes[i], oracle[i]));
        if (operation % 37 == 0) assert(validatePattern(pattern->data()) == ok);
    }
    std::puts("PASS 20000 deterministic pattern edits vs independent vector oracle: original timing/routing/velocity/IDs and canonical ordering retained");
}

int main()
{
    checkNames();
    checkNotes();
    checkQuantization();
    checkRestore();
    checkRandom();
}
