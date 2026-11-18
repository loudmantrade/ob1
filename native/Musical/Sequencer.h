// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Pattern.h"

namespace ob1::music {

constexpr uint32_t sequencerRows = 8;
constexpr int64_t tickUnit = INT64_C(1) << 20;
enum class LaunchGrid : uint8_t { Free, Beat, Bar };
enum class RecordMode : uint8_t { WaitForNote, CountIn, Immediate };

// Audio-owner clock: fractional remainders survive blocks, not rounded step intervals.
class MusicalPosition {
public:
    int64_t value = 0;
    void advance(uint32_t frames, uint32_t quarter)
    {
        if (quarter != quarter_) { remainder_ = 0; quarter_ = quarter; }
        const auto numerator = uint64_t(frames) * ticksPerQuarter * tickUnit + remainder_;
        value += numerator / quarter;
        remainder_ = numerator % quarter;
    }
    void followPhase(int32_t phaseFrames, uint32_t quarter)
    {
        const int64_t bar = ticksPerQuarter * tickUnit * 4;
        const int64_t phase = int64_t(phaseFrames) * ticksPerQuarter * tickUnit / quarter;
        auto correction = (phase - value % bar) % bar;
        if (correction > bar / 2) correction -= bar;
        if (correction < -bar / 2) correction += bar;
        value = std::max(INT64_C(0), value + correction);
    }
private:
    uint32_t quarter_ = 0;
    uint64_t remainder_ = 0;
};

class ClipPlayer {
public:
    struct Active { Event on {}; int64_t off = 0; bool used = false; };
    const Pattern* clip = nullptr;
    int32_t row = -1, pendingRow = -1;
    int64_t origin = 0, pendingOrigin = 0, pendingStart = 0, previous = -1;
    uint32_t generation = 0;
    std::array<Active, 256> active {};

    static int64_t boundary(int64_t earliest, LaunchGrid grid)
    {
        if (grid == LaunchGrid::Free) return earliest;
        const auto step = ticksPerQuarter * tickUnit * (grid == LaunchGrid::Bar ? 4 : 1);
        return (earliest + step - 1) / step * step;
    }
    void queue(int32_t nextRow, const Pattern* next, int64_t now, LaunchGrid grid, int64_t groupOrigin = -1,
               bool playIntro = true)
    {
        queued_ = next;
        pendingRow = nextRow;
        queuedIntro_ = playIntro;
        const auto intro = playIntro && next && next->data().introEnabled ? next->data().intro * tickUnit : 0;
        pendingOrigin = groupOrigin >= 0 ? groupOrigin : boundary(now + intro, grid);
        pendingStart = pendingOrigin - intro;
    }
    bool stopping() const { return pendingRow >= 0 && !queued_ && row >= 0; }
    void requestStop(int64_t now)
    {
        if (row < 0 || stopping()) return;
        queue(row, nullptr, now + 1, LaunchGrid::Bar);
    }

    template<class Sink>
    bool stop(Frame frame, Sink& sink)
    {
        bool accepted = true;
        for (auto& note : active) if (note.used) {
            auto off = note.on;
            off.kind = Kind::NoteOff; off.data2 = 0; off.time.frame = frame;
            if (sink(off)) note.used = false;
            else accepted = false;
        }
        clip = queued_ = nullptr;
        row = pendingRow = -1;
        previous = -1;
        return accepted;
    }

    template<class Sink>
    bool process(int64_t now, Frame frame, uint32_t slot, uint8_t channel, Sink& sink)
    {
        if (pendingRow >= 0 && now >= pendingStart) {
            const auto* next = queued_;
            const auto nextRow = pendingRow;
            const auto nextOrigin = pendingOrigin;
            const auto start = pendingStart;
            const auto intro = queuedIntro_;
            if (!stop(frame, sink)) return false;
            if (++generation == 0) return false;
            clip = next; row = next ? nextRow : -1; origin = nextOrigin; previous = start - 1;
            playIntro_ = intro;
        }
        for (auto& note : active) if (note.used && note.off <= now) {
            auto off = note.on;
            off.kind = Kind::NoteOff; off.data2 = 0; off.time.frame = frame;
            if (!sink(off)) return false;
            note.used = false;
        }
        if (!clip) return true;
        const auto& data = clip->data();
        const auto length = data.length * tickUnit;
        for (uint32_t i = 0; i < data.count; ++i) {
            const auto& note = data.notes[i];
            if (note.start < 0 && (!data.introEnabled || !playIntro_)) continue;
            PatternTiming timing;
            if (clip->timingAt(i, timing) != PatternError::None) return false;
            int64_t onset = origin + timing.start * tickUnit;
            if (note.start >= 0 && data.loop && onset <= previous)
                onset += ((previous - onset) / length + 1) * length;
            uint32_t emitted = 0;
            while (onset > previous && onset <= now) {
                if (++emitted > 64 || nextNote_ == UINT64_MAX) return false;
                Active* available = nullptr;
                for (auto& item : active) if (!item.used) { available = &item; break; }
                if (!available) return false;
                Event on {};
                on.kind = Kind::NoteOn;
                on.channel = channel;
                on.data1 = note.pitch; on.data2 = note.velocity;
                on.source = {SourceKind::Pattern, slot + 1};
                on.note = nextNote_++;
                on.routing = {Target::Instruments, uint16_t(1u << slot), note.routing.stage};
                on.time = {frame, onset / tickUnit, true};
                if (!sink(on)) return false;
                *available = {on, onset + timing.duration * tickUnit, true};
                if (note.start < 0 || !data.loop) break;
                onset += length;
            }
        }
        previous = now;
        if (!data.loop && now >= origin + length) {
            bool sounding = false;
            for (const auto& note : active) sounding |= note.used;
            if (!sounding) { clip = nullptr; row = -1; }
        }
        return true;
    }
private:
    const Pattern* queued_ = nullptr;
    NoteID nextNote_ = 1;
    bool queuedIntro_ = true, playIntro_ = true;
};

class ClipRecorder {
public:
    bool running = false, output = false, withIntro = false, started = false, overflow = false;
    uint32_t slot = 0, row = 0;
    int64_t origin = 0, stopAt = 0;
    PatternData data {};
    bool waiting = false, freeLength = false, cancelled = false, finishQueued = false;
    int64_t countStart = 0;
    uint32_t countBeats = 0;

    void begin(uint32_t instrument, uint32_t cell, const PatternData& settings,
               int64_t now, bool recordOutput, bool intro)
    {
        slot = instrument; row = cell; output = recordOutput; withIntro = intro;
        data = settings; data.count = 0; data.nextNote = 1; data.notes = {};
        data.intro = 0; data.introEnabled = intro;
        origin = ClipPlayer::boundary(now, LaunchGrid::Bar);
        stopAt = origin + data.length * tickUnit;
        running = true; started = false; overflow = false; held_ = {};
        waiting = freeLength = cancelled = finishQueued = false; countBeats = 0; lastClick_ = -1;
        cancelBeforeBody_ = false;
    }

    void arm(uint32_t instrument, uint32_t cell, const PatternData& settings, int64_t now,
             RecordMode mode, uint32_t bars, uint32_t beats, bool scenePlaying, bool recordOutput)
    {
        begin(instrument, cell, settings, now, recordOutput, false);
        cancelBeforeBody_ = true;
        freeLength = beats == 0;
        data.length = beats ? Tick(beats) * ticksPerQuarter : maxPatternTicks;
        data.loop = true;
        waiting = mode == RecordMode::WaitForNote && !scenePlaying;
        origin = scenePlaying ? ClipPlayer::boundary(now, LaunchGrid::Bar) : now;
        if (mode == RecordMode::CountIn) {
            countStart = origin; countBeats = bars * 4;
            origin += int64_t(countBeats) * ticksPerQuarter * tickUnit;
        }
        withIntro = mode == RecordMode::CountIn || scenePlaying;
        data.introEnabled = withIntro;
        stopAt = waiting || freeLength ? INT64_MAX : origin + data.length * tickUnit;
    }

    void firstNote(int64_t now)
    {
        if (!running || !waiting) return;
        origin = now; stopAt = freeLength ? INT64_MAX : origin + data.length * tickUnit; waiting = false;
    }

    Tick lengthAt(int64_t now) const
    {
        if (!freeLength) return data.length;
        const auto bar = ticksPerQuarter * 4;
        if (waiting || now < origin) return bar;
        const auto elapsed = std::max(INT64_C(0), (finishQueued ? stopAt : now) - origin);
        const auto bars = elapsed / (bar * tickUnit) + (finishQueued ? 0 : 1);
        return std::max(Tick(1), bars) * bar;
    }

    void requestFinish(int64_t now)
    {
        if (!running || finishQueued || waiting || now < origin) return;
        const auto bar = ticksPerQuarter * tickUnit * 4;
        const auto elapsed = std::max(INT64_C(1), now - origin);
        const auto boundary = origin + (elapsed + bar - 1) / bar * bar;
        stopAt = std::min(stopAt, boundary);
        finishQueued = true;
    }

    uint32_t phase(int64_t now) const
    {
        if (!running) return 0;
        if (waiting) return 1;
        if (now >= origin) return finishQueued ? 5 : 3;
        return countBeats && now >= countStart ? 2 : 4;
    }
    uint32_t remaining(int64_t now) const
    {
        if (!running || waiting) return 0;
        if (finishQueued) return uint32_t(std::max(INT64_C(0), stopAt - now +
            ticksPerQuarter * tickUnit - 1) / (ticksPerQuarter * tickUnit));
        if (now >= origin) return 0;
        const auto boundary = countBeats && now < countStart ? countStart : origin;
        return uint32_t((boundary - now + ticksPerQuarter * tickUnit - 1) / (ticksPerQuarter * tickUnit));
    }
    int32_t click(int64_t now)
    {
        if (!running || waiting || !countBeats || now < countStart || now >= origin) return -1;
        const auto beat = (now - countStart) / (ticksPerQuarter * tickUnit);
        if (beat <= lastClick_) return -1;
        lastClick_ = beat;
        return int32_t(beat % 4);
    }

    bool capture(const Event& event, int64_t now)
    {
        if (!running || !isNote(event) || event.source.kind == SourceKind::Pattern) return true;
        if (waiting) return true;
        if (now - origin >= maxPatternTicks * tickUnit) { overflow = true; return false; }
        if (now < origin && !withIntro) return true;
        if (now >= stopAt) return true;
        if (event.kind == Kind::NoteOn) {
            for (auto& held : held_) if (held.used && same(held.on, event)) close(held, now);
            Pending* available = nullptr;
            for (auto& held : held_) if (!held.used) { available = &held; break; }
            if (!available || data.count == patternNoteCapacity) { overflow = true; return false; }
            *available = {event, now, true};
            started = true;
        } else {
            for (auto& held : held_) if (held.used && same(held.on, event)) { close(held, now); break; }
        }
        return !overflow;
    }
    void finish(int64_t now)
    {
        now = std::min(now, stopAt);
        cancelled = waiting || (cancelBeforeBody_ && now <= origin);
        if (cancelled) { running = false; held_ = {}; return; }
        if (finishQueued && !freeLength) data.length = std::min(data.length, (stopAt - origin) / tickUnit);
        if (freeLength) {
            data.length = std::max((now - origin + tickUnit - 1) / tickUnit, Tick(1));
            if (data.length > maxPatternTicks) { overflow = true; running = false; held_ = {}; return; }
            for (uint32_t i = 0; i < data.count; ++i) data.length = std::max(data.length, data.notes[i].start + 1);
            for (const auto& held : held_) if (held.used)
                data.length = std::max(data.length, (held.start - origin) / tickUnit + 1);
        }
        for (auto& held : held_) if (held.used) close(held, std::min(now, stopAt));
        std::sort(data.notes.begin(), data.notes.begin() + data.count, patternNoteBefore);
        running = false;
    }
    bool publish(Pattern& pattern) const
    {
        if (running || overflow || cancelled) return false;
        pattern.data_ = data;
        return true;
    }
private:
    int64_t lastClick_ = -1;
    bool cancelBeforeBody_ = false;
    struct Pending { Event on {}; int64_t start = 0; bool used = false; };
    std::array<Pending, 256> held_ {};
    static bool same(const Event& a, const Event& b)
    {
        return a.source == b.source && a.channel == b.channel && a.data1 == b.data1 && a.note == b.note;
    }
    void close(Pending& held, int64_t now)
    {
        if (data.count == patternNoteCapacity) { overflow = true; held.used = false; return; }
        const auto duration = std::max((now - held.start) / tickUnit, Tick(1));
        if (duration > maxPatternTicks) { overflow = true; held.used = false; return; }
        auto& note = data.notes[data.count];
        note.id = data.nextNote;
        note.start = (held.start - origin) / tickUnit;
        note.duration = duration;
        note.pitch = held.on.data1; note.velocity = held.on.data2;
        note.channel = held.on.channel;
        note.routing = {Target::Instruments, uint16_t(1u << slot), output ? Stage::Output : Stage::Input};
        if (validatePatternNote(note, data.length, ticksPerQuarter * 12) != PatternError::None) {
            note = {}; overflow = true; held.used = false; return;
        }
        ++data.count; ++data.nextNote;
        data.intro = std::max(data.intro, -note.start);
        held.used = false;
    }
};

} // namespace ob1::music
