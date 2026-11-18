// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Event.h"
#include <algorithm>
#include <array>
#include <cstdlib>
#include <limits>
#include <string_view>

namespace ob1::music {

using PatternID = uint32_t;
constexpr uint32_t patternVersion = 1, patternCapacity = 16, patternNoteCapacity = 1024;
constexpr uint32_t patternNameBytes = 96;
constexpr Tick maxPatternTicks = ticksPerQuarter * 256;

enum class PatternError : uint8_t {
    None, InvalidVersion, InvalidName, InvalidLength, InvalidQuantization,
    InvalidNote, InvalidRouting, DuplicateID, InvalidCounter, Unsorted,
    Full, NotFound, IDExhausted
};

struct PatternQuantization {
    Tick grid = 0; // Zero disables quantization; otherwise integer PPQ ticks.
    uint8_t strength = 100;
    bool ends = false;
};

struct PatternNote {
    NoteID id = 0;
    Tick start = 0, duration = ticksPerQuarter;
    Routing routing {Target::Instruments, 1, Stage::Input};
    uint8_t channel = 0, pitch = 60, velocity = 100;
};

struct PatternData {
    uint32_t version = patternVersion;
    PatternID id = 0;
    std::array<char, patternNameBytes + 1> name {};
    Tick length = ticksPerQuarter * 4;
    PatternQuantization quantization {};
    NoteID nextNote = 1;
    uint32_t count = 0;
    bool loop = true;
    std::array<PatternNote, patternNoteCapacity> notes {};
};

struct PatternTiming { Tick start = 0, duration = 0; };

inline bool patternNameValid(std::string_view name)
{
    if (name.empty() || name.size() > patternNameBytes) return false;
    bool visible = false;
    for (size_t i = 0; i < name.size();) {
        const auto first = uint8_t(name[i++]);
        uint32_t code = first, extra = 0, minimum = 0;
        if (first >= 0xc2 && first <= 0xdf) { code &= 0x1f; extra = 1; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { code &= 0xf; extra = 2; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { code &= 7; extra = 3; minimum = 0x10000; }
        else if (first >= 0x80) return false;
        if (extra > name.size() - i) return false;
        for (uint32_t j = 0; j < extra; ++j) {
            const auto next = uint8_t(name[i++]);
            if ((next & 0xc0) != 0x80) return false;
            code = (code << 6) | (next & 0x3f);
        }
        if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ||
            code < 0x20 || (code >= 0x7f && code <= 0x9f)) return false;
        const bool space = code == 0x20 || code == 0xa0 || code == 0x1680 ||
            (code >= 0x2000 && code <= 0x200a) || code == 0x2028 ||
            code == 0x2029 || code == 0x202f || code == 0x205f || code == 0x3000;
        visible |= !space;
    }
    return visible;
}

inline bool patternNoteBefore(const PatternNote& a, const PatternNote& b)
{
    return a.start != b.start ? a.start < b.start : a.id < b.id;
}

inline PatternError validatePatternQuantization(PatternQuantization quantization)
{
    return quantization.grid < 0 || quantization.grid > ticksPerQuarter * 4 ||
        quantization.strength > 100 ? PatternError::InvalidQuantization : PatternError::None;
}

inline PatternError validatePatternNote(const PatternNote& note, Tick length)
{
    if (length < 1 || length > maxPatternTicks) return PatternError::InvalidLength;
    if (!note.id || note.start < 0 || note.start >= length || note.duration < 1 ||
        note.duration > maxPatternTicks || note.pitch > 127 ||
        note.channel > 15 || !note.velocity || note.velocity > 127)
        return PatternError::InvalidNote;
    Event event {};
    event.kind = Kind::NoteOn;
    event.channel = note.channel;
    event.data1 = note.pitch;
    event.data2 = note.velocity;
    event.routing = note.routing;
    return validate(event) == EventError::None ? PatternError::None : PatternError::InvalidRouting;
}

inline PatternError validatePattern(const PatternData& data)
{
    if (data.version != patternVersion) return PatternError::InvalidVersion;
    const auto end = std::find(data.name.begin(), data.name.end(), '\0');
    if (end == data.name.end() || !patternNameValid({data.name.data(), size_t(end - data.name.begin())}))
        return PatternError::InvalidName;
    if (!data.id) return PatternError::InvalidCounter;
    if (data.length < 1 || data.length > maxPatternTicks) return PatternError::InvalidLength;
    const auto quantization = validatePatternQuantization(data.quantization);
    if (quantization != PatternError::None) return quantization;
    if (data.count > patternNoteCapacity) return PatternError::Full;
    if (!data.nextNote) return PatternError::InvalidCounter;
    for (uint32_t i = 0; i < data.count; ++i) {
        const auto& note = data.notes[i];
        const auto result = validatePatternNote(note, data.length);
        if (result != PatternError::None) return result;
        if (note.id >= data.nextNote) return PatternError::InvalidCounter;
        if (i && patternNoteBefore(note, data.notes[i - 1])) return PatternError::Unsorted;
        for (uint32_t j = 0; j < i; ++j)
            if (data.notes[j].id == note.id) return PatternError::DuplicateID;
    }
    return PatternError::None;
}

// Control-thread editor. Published data is const; audio owners consume immutable snapshots.
class Pattern {
public:
    const PatternData& data() const { return data_; }
    std::string_view name() const { return data_.name.data(); }

    PatternError initialize(PatternID id, std::string_view name, Tick length = ticksPerQuarter * 4)
    {
        if (!id) return PatternError::InvalidCounter;
        if (!patternNameValid(name)) return PatternError::InvalidName;
        if (length < 1 || length > maxPatternTicks) return PatternError::InvalidLength;
        // The view may refer to this pattern's current name.
        std::array<char, patternNameBytes + 1> copied {};
        std::copy(name.begin(), name.end(), copied.begin());
        data_ = {};
        data_.id = id;
        data_.name = copied;
        data_.length = length;
        return PatternError::None;
    }

    PatternError restore(const PatternData& data)
    {
        const auto result = validatePattern(data);
        if (result == PatternError::None) data_ = data;
        return result;
    }

    PatternError rename(std::string_view name)
    {
        if (!data_.id) return PatternError::NotFound;
        if (!patternNameValid(name)) return PatternError::InvalidName;
        std::array<char, patternNameBytes + 1> copied {};
        std::copy(name.begin(), name.end(), copied.begin());
        data_.name = copied;
        return PatternError::None;
    }

    PatternError length(Tick length)
    {
        if (!data_.id) return PatternError::NotFound;
        if (length < 1 || length > maxPatternTicks) return PatternError::InvalidLength;
        for (uint32_t i = 0; i < data_.count; ++i)
            if (data_.notes[i].start >= length) return PatternError::InvalidLength;
        data_.length = length;
        return PatternError::None;
    }

    PatternError loop(bool loop)
    {
        if (!data_.id) return PatternError::NotFound;
        data_.loop = loop;
        return PatternError::None;
    }
    PatternError quantization(PatternQuantization quantization)
    {
        if (!data_.id) return PatternError::NotFound;
        const auto result = validatePatternQuantization(quantization);
        if (result != PatternError::None) return result;
        data_.quantization = quantization;
        return PatternError::None;
    }

    PatternError add(PatternNote note, NoteID& output)
    {
        if (!data_.id) return PatternError::NotFound;
        if (data_.count == patternNoteCapacity) return PatternError::Full;
        if (data_.nextNote == std::numeric_limits<NoteID>::max()) return PatternError::IDExhausted;
        note.id = data_.nextNote;
        const auto result = validatePatternNote(note, data_.length);
        if (result != PatternError::None) return result;
        ++data_.nextNote;
        insert(note);
        output = note.id;
        return PatternError::None;
    }

    PatternError edit(NoteID id, PatternNote note)
    {
        const auto index = find(id);
        if (index == data_.count) return PatternError::NotFound;
        note.id = id;
        const auto result = validatePatternNote(note, data_.length);
        if (result != PatternError::None) return result;
        remove(index);
        insert(note);
        return PatternError::None;
    }

    PatternError erase(NoteID id)
    {
        const auto index = find(id);
        if (index == data_.count) return PatternError::NotFound;
        remove(index);
        return PatternError::None;
    }

    PatternError timing(NoteID id, PatternTiming& output) const
    {
        const auto index = find(id);
        if (index == data_.count) return PatternError::NotFound;
        const auto& note = data_.notes[index];
        const auto& q = data_.quantization;
        if (!q.grid || !q.strength) { output = {note.start, note.duration}; return PatternError::None; }
        const auto start = quantized(note.start, q, data_.length - 1);
        Tick duration = note.duration;
        if (q.ends) {
            const auto end = quantized(note.start + note.duration, q, maxPatternTicks * 2);
            duration = std::clamp(end - start, Tick(1), maxPatternTicks);
        }
        output = {start, duration};
        return PatternError::None;
    }

private:
    friend class PatternStore;
    PatternData data_ {};

    uint32_t find(NoteID id) const
    {
        for (uint32_t i = 0; i < data_.count; ++i) if (data_.notes[i].id == id) return i;
        return data_.count;
    }
    void remove(uint32_t index)
    {
        for (uint32_t i = index + 1; i < data_.count; ++i) data_.notes[i - 1] = data_.notes[i];
        data_.notes[--data_.count] = {};
    }
    void insert(const PatternNote& note)
    {
        auto index = data_.count++;
        while (index && patternNoteBefore(note, data_.notes[index - 1])) {
            data_.notes[index] = data_.notes[index - 1];
            --index;
        }
        data_.notes[index] = note;
    }
    static Tick quantized(Tick tick, PatternQuantization q, Tick maximum)
    {
        Tick nearest = (tick / q.grid + (tick % q.grid >= (q.grid + 1) / 2)) * q.grid;
        nearest = std::min(nearest, maximum / q.grid * q.grid);
        const auto delta = nearest - tick;
        const Tick shift = (std::abs(delta) * q.strength + 50) / 100;
        return tick + (delta < 0 ? -shift : shift);
    }
};

struct PatternStoreData {
    uint32_t version = patternVersion;
    PatternID nextID = 1;
    uint32_t count = 0;
    std::array<PatternData, patternCapacity> patterns {};
};

class PatternStore {
public:
    const Pattern* get(PatternID id) const
    {
        for (const auto& pattern : patterns_) if (id && pattern.data().id == id) return &pattern;
        return nullptr;
    }
    const Pattern* at(uint32_t slot) const
    {
        return slot < patternCapacity && patterns_[slot].data().id ? &patterns_[slot] : nullptr;
    }
    uint32_t count() const
    {
        uint32_t count = 0;
        for (const auto& pattern : patterns_) count += pattern.data().id != 0;
        return count;
    }
    PatternID nextID() const { return nextID_; }

    void snapshot(PatternStoreData& output) const
    {
        output.version = patternVersion;
        output.nextID = nextID_;
        output.count = count();
        for (uint32_t slot = 0; slot < patternCapacity; ++slot) output.patterns[slot] = patterns_[slot].data();
    }

    PatternError restore(const PatternStoreData& input)
    {
        if (input.version != patternVersion) return PatternError::InvalidVersion;
        if (input.count > patternCapacity) return PatternError::Full;
        if (!input.nextID) return PatternError::InvalidCounter;
        uint32_t count = 0;
        for (uint32_t i = 0; i < patternCapacity; ++i) {
            const auto& pattern = input.patterns[i];
            if (!pattern.id) continue;
            ++count;
            const auto result = validatePattern(pattern);
            if (result != PatternError::None) return result;
            if (pattern.id >= input.nextID) return PatternError::InvalidCounter;
            for (uint32_t j = 0; j < i; ++j)
                if (input.patterns[j].id == pattern.id) return PatternError::DuplicateID;
        }
        if (count != input.count) return PatternError::InvalidCounter;
        for (uint32_t i = 0; i < patternCapacity; ++i) {
            if (input.patterns[i].id) patterns_[i].data_ = input.patterns[i];
            else patterns_[i] = {};
        }
        nextID_ = input.nextID;
        return PatternError::None;
    }

    PatternError rename(PatternID id, std::string_view name)
    {
        auto* pattern = editable(id);
        return pattern ? pattern->rename(name) : PatternError::NotFound;
    }
    PatternError length(PatternID id, Tick length)
    {
        auto* pattern = editable(id);
        return pattern ? pattern->length(length) : PatternError::NotFound;
    }
    PatternError loop(PatternID id, bool loop)
    {
        auto* pattern = editable(id);
        return pattern ? pattern->loop(loop) : PatternError::NotFound;
    }
    PatternError quantization(PatternID id, PatternQuantization quantization)
    {
        auto* pattern = editable(id);
        return pattern ? pattern->quantization(quantization) : PatternError::NotFound;
    }
    PatternError addNote(PatternID id, PatternNote note, NoteID& output)
    {
        auto* pattern = editable(id);
        return pattern ? pattern->add(note, output) : PatternError::NotFound;
    }
    PatternError editNote(PatternID id, NoteID noteID, PatternNote note)
    {
        auto* pattern = editable(id);
        return pattern ? pattern->edit(noteID, note) : PatternError::NotFound;
    }
    PatternError eraseNote(PatternID id, NoteID noteID)
    {
        auto* pattern = editable(id);
        return pattern ? pattern->erase(noteID) : PatternError::NotFound;
    }

    PatternError create(std::string_view name, Tick length, PatternID& output)
    {
        auto* slot = available();
        if (!slot) return PatternError::Full;
        if (nextID_ == std::numeric_limits<PatternID>::max()) return PatternError::IDExhausted;
        const auto result = slot->initialize(nextID_, name, length);
        if (result != PatternError::None) return result;
        output = nextID_++;
        return PatternError::None;
    }

    PatternError duplicate(PatternID id, std::string_view name, PatternID& output)
    {
        const auto* original = get(id);
        if (!original) return PatternError::NotFound;
        if (!patternNameValid(name)) return PatternError::InvalidName;
        auto* slot = available();
        if (!slot) return PatternError::Full;
        if (nextID_ == std::numeric_limits<PatternID>::max()) return PatternError::IDExhausted;
        std::array<char, patternNameBytes + 1> copied {};
        std::copy(name.begin(), name.end(), copied.begin());
        *slot = *original;
        slot->data_.name = copied;
        slot->data_.id = nextID_;
        output = nextID_++;
        return PatternError::None;
    }

    PatternError erase(PatternID id)
    {
        auto* pattern = editable(id);
        if (!pattern) return PatternError::NotFound;
        *pattern = {};
        return PatternError::None;
    }

private:
    std::array<Pattern, patternCapacity> patterns_ {};
    PatternID nextID_ = 1;

    Pattern* editable(PatternID id)
    {
        for (auto& pattern : patterns_) if (id && pattern.data().id == id) return &pattern;
        return nullptr;
    }
    Pattern* available()
    {
        for (auto& pattern : patterns_) if (!pattern.data().id) return &pattern;
        return nullptr;
    }
};

static_assert(std::is_trivially_copyable_v<PatternData>);
static_assert(std::is_trivially_destructible_v<PatternData>);
static_assert(std::is_trivially_copyable_v<PatternStoreData>);

} // namespace ob1::music
