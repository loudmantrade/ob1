// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Event.h"
#include <algorithm>
#include <array>
#include <limits>

namespace ob1::music {

enum class ArpMode : uint8_t { Off, Up, Down, UpDown, Random, Played, Chord, HoldRetrigger, HoldLegato };
enum class Latch : uint8_t { Off, Add, Replace };
enum class ArpResult : uint8_t { Ok, Bypassed, InvalidInput, OutputRejected, Faulted, NoteIDExhausted };

struct ArpSettings {
    ArpMode mode = ArpMode::Off;
    Latch latch = Latch::Off;
    uint8_t division = 3, octaves = 1, gate = 64, velocity = 0;
    bool sync = false;
    uint8_t grid = 2;
};

struct ArpClock {
    Time time {};
    uint32_t quarterFrames = 22032;
    // Master phase already includes signed audio/MIDI compensation.
    uint32_t barPhaseFrames = 0;
    bool hasMasterPhase = false;
    int32_t advanceFrames = 0;
    bool livePhaseAdjustment = false;
};

// Derived from the OberVave GPL-3.0 arpeggiator; no DSP/patch/voice dependency.
class ArpeggiatorProcessor {
public:
    static constexpr uint32_t controlFrames = 16, heldCapacity = 16;
    static constexpr uint32_t idle = std::numeric_limits<uint32_t>::max();

    const ArpSettings& settings() const { return settings_; }
    uint32_t heldCount() const { return heldCount_; }
    uint32_t activeCount() const { return activeCount_; }
    uint32_t position() const { return position_; }
    uint32_t counter() const { return counter_; }
    uint32_t randomState() const { return random_; }
    bool faulted() const { return fault_ != ArpResult::Ok; }
    bool lastHeld(uint8_t& pitch) const
    {
        if (!heldCount_) return false;
        pitch = held_[heldCount_ - 1].pitch;
        return true;
    }
    bool heldPitch(uint32_t index, uint8_t& pitch) const
    {
        if (index >= heldCount_) return false;
        pitch = held_[index].pitch;
        return true;
    }

    // Native input and rendering see different patches; restoring a view is not a parameter edit.
    ArpResult settingsView(const ArpSettings& next)
    {
        if (!valid(next)) return ArpResult::InvalidInput;
        if (faulted()) return ArpResult::Faulted;
        settings_ = next;
        return ArpResult::Ok;
    }

    template<class Sink>
    ArpResult cleanupUnheld(Time time, Sink& sink, bool resetEmpty)
    {
        if (faulted()) return ArpResult::Faulted;
        releaseUnheld(time, sink);
        if (resetEmpty && !heldCount_) {
            releaseAll(time, sink);
            position_ = 0;
            counter_ = idle;
        }
        return fault_;
    }

    ArpResult restart()
    {
        if (faulted()) return ArpResult::Faulted;
        position_ = 0;
        counter_ = idle;
        return ArpResult::Ok;
    }

    ArpResult destination(uint32_t instrument, uint32_t channel)
    {
        if (instrument >= instrumentCapacity || channel > 15 || heldCount_ || activeCount_)
            return ArpResult::InvalidInput;
        instrument_ = uint8_t(instrument);
        channel_ = uint8_t(channel);
        return ArpResult::Ok;
    }

    ArpResult seed(uint32_t value)
    {
        if (!value) return ArpResult::InvalidInput;
        random_ = value;
        return ArpResult::Ok;
    }

    template<class Sink>
    ArpResult configure(const ArpSettings& next, Time time, Sink& sink)
    {
        if (!valid(next)) return ArpResult::InvalidInput;
        if (faulted()) return ArpResult::Faulted;
        const auto previous = settings_;
        settings_ = next;
        if ((!sustain_ || isHold(next.mode)) &&
            ((previous.latch != next.latch && next.latch == Latch::Off) ||
             (previous.mode != next.mode && next.mode == ArpMode::Off))) {
            releaseUnheld(time, sink);
            if (!heldCount_) {
                releaseAll(time, sink);
                position_ = 0;
                counter_ = idle;
            }
        }
        return fault_;
    }

    template<class Sink>
    ArpResult input(const Event& event, Sink& sink)
    {
        if (validate(event) != EventError::None || event.routing.stage != Stage::Input)
            return ArpResult::InvalidInput;
        if (faulted()) return ArpResult::Faulted;
        if (event.kind == Kind::Stop ||
            (event.kind == Kind::ControlChange && (event.data1 == 120 || event.data1 == 123)))
            return stop(event.time, sink);
        if (event.kind == Kind::ControlChange && event.data1 == 64) {
            const bool down = event.data2 >= 64;
            const bool release = sustain_ && !down;
            sustain_ = down;
            if (release) releaseUnheld(event.time, sink);
            return fault_;
        }
        if (!isNote(event)) return ArpResult::Bypassed;
        const auto pitch = event.data1;
        const bool enabled = settings_.mode != ArpMode::Off;
        if (event.kind == Kind::NoteOn) {
            if (enabled && (settings_.latch == Latch::Replace || isHold(settings_.mode)))
                discardUnheld();
            else if (enabled && sustain_) {
                bool physical = false;
                for (uint32_t i = 0; i < heldCount_; ++i) physical |= held_[i].physical;
                if (!physical) heldCount_ = 0;
            }
            removeHeld(pitch);
            if (heldCount_ == heldCapacity) eraseHeld(0);
            held_[heldCount_++] = {pitch, event.data2, true};
            dirty_ = true;
            if (heldCount_ == 1 && counter_ == idle) position_ = 0;
        } else {
            for (uint32_t i = 0; i < heldCount_; ++i)
                if (held_[i].pitch == pitch) held_[i].physical = false;
            if (!sustain_ && (!enabled || settings_.latch == Latch::Off)) {
                removeHeld(pitch);
                dirty_ = true;
            }
        }
        return enabled ? ArpResult::Ok : ArpResult::Bypassed;
    }

    template<class Sink>
    ArpResult tick(const ArpClock& clock, Sink& sink)
    {
        if (clock.quarterFrames < controlFrames ||
            clock.quarterFrames > std::numeric_limits<uint32_t>::max() / 4u)
            return ArpResult::InvalidInput;
        if (faulted()) return ArpResult::Faulted;
        const auto mode = settings_.mode;
        int64_t elapsed = controlFrames;
        const int64_t delta = int64_t(clock.advanceFrames) - appliedAdvance_;
        appliedAdvance_ = clock.advanceFrames;
        if (!clock.livePhaseAdjustment || !settings_.sync || !wasOn_ || !heldCount_ ||
            mode == ArpMode::Off || counter_ == idle) {
            delayedFrames_ = 0;
        } else {
            elapsed += delta + delayedFrames_;
            const int64_t next = int64_t(counter_) + elapsed;
            delayedFrames_ = next < 0 ? next : 0;
            if (next < 0) elapsed = -int64_t(counter_);
        }
        if (mode == ArpMode::Off) {
            if (wasOn_) { releaseAll(clock.time, sink); wasOn_ = false; }
            return fault_;
        }
        if (previousMode_ != mode) {
            releaseAll(clock.time, sink);
            previousMode_ = mode;
            counter_ = idle;
        }
        if (!wasOn_) { wasOn_ = true; position_ = 0; counter_ = idle; }
        if (!heldCount_) {
            releaseAll(clock.time, sink);
            position_ = 0;
            counter_ = idle;
            return fault_;
        }
        if (isHold(mode) && counter_ != idle) {
            if (dirty_) {
                if (mode != ArpMode::HoldLegato) releaseAll(clock.time, sink);
                step(clock.time, sink);
            }
            return fault_;
        }
        constexpr uint32_t divisions[] {1, 2, 3, 4, 6, 8, 12};
        const uint32_t period = std::max(controlFrames, clock.quarterFrames / divisions[settings_.division]);
        const uint32_t gate = uint32_t(uint64_t(period) * (settings_.gate + 1u) >> 7);
        if (settings_.sync && counter_ == idle && clock.hasMasterPhase) {
            const uint32_t grid = uint32_t((uint64_t(clock.quarterFrames) * 4u) >> settings_.grid);
            if (clock.barPhaseFrames % grid >= controlFrames) return fault_;
            counter_ = 0;
            releaseAll(clock.time, sink);
            step(clock.time, sink);
            return fault_;
        }
        const int64_t next = int64_t(counter_) + elapsed;
        if (counter_ == idle || next >= period) {
            counter_ = counter_ == idle ? 0 : uint32_t(next % period);
            releaseAll(clock.time, sink);
            step(clock.time, sink);
        } else {
            counter_ = uint32_t(next);
            if (counter_ >= gate && settings_.gate < 127) releaseAll(clock.time, sink);
        }
        return fault_;
    }

    // A failed sink leaves accepted Note Ons tracked. Stop retries their Offs.
    template<class Sink>
    ArpResult stop(Time time, Sink& sink)
    {
        fault_ = ArpResult::Ok;
        releaseAll(time, sink);
        heldCount_ = 0;
        sustain_ = wasOn_ = dirty_ = false;
        counter_ = idle;
        position_ = 0;
        delayedFrames_ = 0;
        return fault_;
    }

private:
    struct Held { uint8_t pitch = 0, velocity = 0; bool physical = false; };
    std::array<Held, heldCapacity> held_ {};
    std::array<uint8_t, 128> active_ {};
    std::array<NoteID, 128> identities_ {};
    uint32_t heldCount_ = 0, activeCount_ = 0, counter_ = idle, position_ = 0;
    uint32_t random_ = 0x9E3779B9u;
    int32_t appliedAdvance_ = 0;
    int64_t delayedFrames_ = 0;
    NoteID nextNote_ = 1;
    ArpSettings settings_ {};
    ArpMode previousMode_ = ArpMode::Off;
    ArpResult fault_ = ArpResult::Ok;
    uint8_t instrument_ = 0, channel_ = 0;
    bool sustain_ = false, wasOn_ = false, dirty_ = false;

    static bool isHold(ArpMode mode)
    {
        return mode == ArpMode::HoldRetrigger || mode == ArpMode::HoldLegato;
    }
    static bool valid(const ArpSettings& s)
    {
        return s.mode <= ArpMode::HoldLegato && s.latch <= Latch::Replace &&
            s.division < 7 && s.octaves <= 4 && s.gate <= 127 && s.velocity <= 127 && s.grid <= 5;
    }
    void eraseHeld(uint32_t index)
    {
        for (uint32_t i = index + 1; i < heldCount_; ++i) held_[i - 1] = held_[i];
        --heldCount_;
    }
    void removeHeld(uint8_t pitch)
    {
        for (uint32_t i = 0; i < heldCount_; ++i)
            if (held_[i].pitch == pitch) { eraseHeld(i); return; }
    }
    void discardUnheld()
    {
        uint32_t count = 0;
        for (uint32_t i = 0; i < heldCount_; ++i)
            if (held_[i].physical) held_[count++] = held_[i];
        heldCount_ = count;
    }
    Event output(Kind kind, uint8_t pitch, uint8_t velocity, Time time, NoteID id) const
    {
        Event e {};
        e.kind = kind; e.channel = channel_; e.data1 = pitch; e.data2 = velocity;
        e.source = {SourceKind::Arpeggiator, instrument_};
        e.routing = {Target::Instruments, uint16_t(1u << instrument_), Stage::Output};
        e.time = time; e.note = id;
        return e;
    }
    template<class Sink>
    void noteOn(uint8_t pitch, uint8_t velocity, Time time, Sink& sink)
    {
        if (faulted()) return;
        if (!nextNote_) { fault_ = ArpResult::NoteIDExhausted; return; }
        const auto id = nextNote_;
        if (!sink(output(Kind::NoteOn, pitch, velocity, time, id))) {
            fault_ = ArpResult::OutputRejected;
            return;
        }
        ++nextNote_;
        identities_[pitch] = id;
        active_[activeCount_++] = pitch;
    }
    template<class Sink>
    bool noteOff(uint8_t pitch, Time time, Sink& sink)
    {
        if (!sink(output(Kind::NoteOff, pitch, 0, time, identities_[pitch]))) {
            fault_ = ArpResult::OutputRejected;
            return false;
        }
        identities_[pitch] = 0;
        return true;
    }
    template<class Sink>
    void releaseAll(Time time, Sink& sink)
    {
        uint32_t pending = 0;
        for (uint32_t i = 0; i < activeCount_; ++i)
            if (!noteOff(active_[i], time, sink)) active_[pending++] = active_[i];
        activeCount_ = pending;
    }
    template<class Sink>
    void releaseUnheld(Time time, Sink& sink)
    {
        std::array<bool, 128> gone {};
        for (uint32_t i = 0; i < heldCount_; ++i)
            if (!held_[i].physical) gone[held_[i].pitch] = true;
        discardUnheld();
        if (settings_.mode != ArpMode::Off) {
            if (isHold(settings_.mode)) dirty_ = true;
            if (settings_.mode != ArpMode::HoldLegato) {
                for (uint32_t i = 0; i < activeCount_; ++i)
                    if (gone[active_[i]]) { releaseAll(time, sink); break; }
            }
            if (!heldCount_) {
                releaseAll(time, sink);
                position_ = 0;
                counter_ = idle;
            }
        }
    }
    template<class Sink>
    void step(Time time, Sink& sink)
    {
        if (faulted() || !heldCount_) return;
        const auto mode = settings_.mode;
        const uint32_t octaves = std::max(1u, uint32_t(settings_.octaves));
        if (mode == ArpMode::HoldLegato) {
            std::array<bool, 128> next {};
            for (uint32_t i = 0; i < heldCount_; ++i) next[held_[i].pitch] = true;
            uint32_t remaining = 0;
            for (uint32_t i = 0; i < activeCount_; ++i) {
                const auto pitch = active_[i];
                if (next[pitch] || !noteOff(pitch, time, sink)) active_[remaining++] = pitch;
            }
            activeCount_ = remaining;
            if (faulted()) return;
            // Legacy order is held-key order, including common notes.
            activeCount_ = 0;
            for (uint32_t i = 0; i < heldCount_; ++i) {
                const auto& key = held_[i];
                if (identities_[key.pitch]) active_[activeCount_++] = key.pitch;
                else noteOn(key.pitch, settings_.velocity ? settings_.velocity : key.velocity, time, sink);
            }
            dirty_ = false;
            return;
        }
        if (mode == ArpMode::Chord || mode == ArpMode::HoldRetrigger) {
            std::array<bool, 128> played {};
            const uint32_t count = mode == ArpMode::HoldRetrigger ? 1 : octaves;
            for (uint32_t octave = 0; octave < count; ++octave)
                for (uint32_t i = 0; i < heldCount_; ++i) {
                    const auto& key = held_[i];
                    const uint32_t pitch = key.pitch + octave * 12;
                    if (pitch > 127 || played[pitch]) continue;
                    played[pitch] = true;
                    noteOn(uint8_t(pitch), settings_.velocity ? settings_.velocity : key.velocity, time, sink);
                }
            dirty_ = false;
            return;
        }
        std::array<uint8_t, heldCapacity> sorted {};
        for (uint32_t i = 0; i < heldCount_; ++i) sorted[i] = held_[i].pitch;
        if (mode != ArpMode::Played) std::sort(sorted.begin(), sorted.begin() + heldCount_);
        const uint32_t length = heldCount_ * octaves;
        uint32_t index;
        if (mode == ArpMode::Random) {
            random_ ^= random_ << 13; random_ ^= random_ >> 17; random_ ^= random_ << 5;
            index = random_ % length;
        } else if (mode == ArpMode::UpDown && length > 2) {
            if (position_ >= 2 * length - 2) position_ = 0;
            index = position_ < length ? position_ : 2 * length - 2 - position_;
            ++position_;
        } else {
            if (position_ >= length) position_ = 0;
            index = mode == ArpMode::Down ? length - 1 - position_ : position_;
            ++position_;
        }
        const auto source = sorted[index % heldCount_];
        uint8_t velocity = settings_.velocity;
        if (!velocity) for (uint32_t i = 0; i < heldCount_; ++i)
            if (held_[i].pitch == source) { velocity = held_[i].velocity; break; }
        noteOn(uint8_t(std::min(127u, source + 12 * (index / heldCount_))), velocity, time, sink);
    }
};

} // namespace ob1::music
