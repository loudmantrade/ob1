// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "ArpeggiatorContext.h"
#include "../Musical/NoteOwnership.h"

namespace obervave {

// Experimental single-native-part adapter. All operations belong to the audio owner.
class ArpeggiatorAdapter {
public:
    enum class InputOwnership : uint8_t { LegacyPitch, SourceNotes };
    using EventSink = bool (*)(void*, const ob1::music::Event&) noexcept;
    explicit ArpeggiatorAdapter(Engine& engine) : engine_(engine) {}
    ArpeggiatorAdapter(const ArpeggiatorAdapter&) = delete;
    ArpeggiatorAdapter& operator=(const ArpeggiatorAdapter&) = delete;

    bool attach(uint32_t instrument = 0, uint32_t channel = 0, uint32_t sourceID = 0,
                EventSink sink = nullptr, void* context = nullptr,
                InputOwnership ownership = InputOwnership::LegacyPitch)
    {
        if ((ownership != InputOwnership::LegacyPitch && ownership != InputOwnership::SourceNotes) ||
            attached_ || (context && !sink) || instrument >= ob1::music::instrumentCapacity ||
            channel > 15 || std::any_of(std::begin(engine_.externalArpeggiator),
                                    std::end(engine_.externalArpeggiator),
                                    [](bool external) { return external; })) return false;
        if (processor_.destination(instrument, channel) != ob1::music::ArpResult::Ok) return false;
        if (!engine_.set_external_arpeggiator(0, true)) return false;
        outputSourceID_ = sourceID;
        eventSink_ = sink;
        eventContext_ = context;
        sourceOwnership_ = ownership == InputOwnership::SourceNotes;
        attached_ = true;
        return view() || fail();
    }

    bool parameter(uint32_t parameter, uint8_t value, ob1::music::Time time)
    {
        if (!ready() || parameter >= NPARAM || value > PDEF[parameter].max) return false;
        time_ = time;
        const auto previous = engine_.live_p[0].v[parameter];
        engine_.apply_parameter(parameter, value);
        if (!view()) return fail();
        if (previous != value && parameter < P_CTL1_SRC &&
            (!engine_.part_sus(0) ||
             (parameter == P_ARP_LATCH && value == 0 && isHold())) &&
            ((parameter == P_ARP_LATCH && value == 0) ||
             (parameter == P_ARP_MODE && value == A_OFF)))
            return cleanup(true);
        return true;
    }

    bool input(const ob1::music::Event& event, bool fixedCC = false, bool controllers = true)
    {
        if (!ready()) return false;
        if (!sourceOwnership_ || !ob1::music::isNote(event))
            return inputPitch(event, fixedCC, controllers);
        auto sink = [&](const ob1::music::Event& note) { return inputPitch(note, fixedCC, controllers); };
        const auto result = ownership_.input(event, sink);
        if (result == ob1::music::OwnershipResult::Full ||
            result == ob1::music::OwnershipResult::OutputRejected) return fail();
        return result != ob1::music::OwnershipResult::InvalidInput;
    }

    bool releaseSource(ob1::music::Source source, ob1::music::Time time)
    {
        if (!ready() || !sourceOwnership_) return false;
        auto sink = [&](const ob1::music::Event& off) { return inputPitch(off, false, false); };
        const auto result = ownership_.releaseSource(source, time, sink);
        if (result == ob1::music::OwnershipResult::OutputRejected) return fail();
        return result != ob1::music::OwnershipResult::InvalidInput;
    }

private:
    bool inputPitch(const ob1::music::Event& event, bool fixedCC, bool controllers)
    {
        namespace music = ob1::music;
        if (!ready() || music::validate(event) != music::EventError::None ||
            event.routing.stage != music::Stage::Input) return false;
        if (event.kind == music::Kind::Stop) return stop(event.time);
        music::MIDIMessage message {};
        if (music::encodeMIDI(event, message) != music::EventError::None) return false;
        time_ = event.time;
        if (controllers) {
            bool accepted = true;
            auto apply = [&](uint32_t p, uint8_t v) {
                if (!parameter(p, v, event.time)) accepted = false;
            };
            engine_.controller_input_with_parameters(message.status, message.data1, message.data2, apply);
            if (!accepted) return fail();
        }
        if (!view()) return fail();
        if (music::isNote(event)) {
            if (event.kind == music::Kind::NoteOn) engine_.poly_pressure_valid[event.data1] = 0;
            const bool panic = engine_.ctl_panic != 0;
            engine_.engine_events();
            if (panic && !clearProcessor()) return false;
            if (!syncSustain()) return fail();
            auto sink = output();
            const auto result = processor_.input(event, sink);
            if (result != music::ArpResult::Ok && result != music::ArpResult::Bypassed) return fail();
            if (result == music::ArpResult::Bypassed &&
                (event.kind == music::Kind::NoteOn || !sustain_))
                return direct(event.data1, event.kind == music::Kind::NoteOn ? event.data2 : 0);
            return true;
        }
        // Fixed CC mappings must pass through the same parameter lifecycle as VALUE routes.
        const bool overridden = engine_.controller_override(Engine::controller_source(message.status, message.data1));
        if (!engine_.midi(message.status, message.data1, message.data2, false, false)) return fail();
        if (fixedCC && !overridden && event.kind == music::Kind::ControlChange) {
            for (uint32_t p = 0; p < NPARAM; ++p)
                if (PDEF[p].cc && PDEF[p].cc == event.data1 &&
                    !parameter(p, (uint32_t(event.data2) * PDEF[p].max + 63) / 127, time_))
                    return fail();
        }
        const bool panic = engine_.ctl_panic != 0;
        engine_.engine_events();
        if (panic) return clearProcessor();
        return syncSustain();
    }

public:
    bool render(int32_t* output, uint32_t frames, ob1::music::Time start)
    {
        if (!ready() || !output || !frames || frames > HALF_FRAMES || frames % CTL ||
            start.frame > UINT64_MAX - frames) return false;
        renderStart_ = start;
        restart_ = engine_.ctl_arp_restart != 0;
        panic_ = engine_.ctl_panic != 0;
        if (!engine_.render_audio_with_arpeggiator(output, frames, tick, this)) return fail();
        return true;
    }

    bool stop(ob1::music::Time time)
    {
        if (!attached_) return false;
        time_ = time;
        engine_.engine_transport_stop();
        fault_ = false;
        return clearProcessor();
    }

    bool faulted() const { return fault_; }
    const ob1::music::ArpeggiatorProcessor& processor() const { return processor_; }
    uint32_t inputOwnerCount() const { return ownership_.count(); }

private:
    Engine& engine_;
    ob1::music::ArpeggiatorProcessor processor_;
    ob1::music::NoteOwnership ownership_;
    bool sourceOwnership_ = false;
    ob1::music::Time time_ {}, renderStart_ {};
    ob1::music::ArpSettings previousEffective_ {};
    bool attached_ = false, fault_ = false, sustain_ = false, wasOn_ = false;
    bool performanceMod_ = false, restart_ = false, panic_ = false;
    uint32_t outputSourceID_ = 0;
    EventSink eventSink_ = nullptr;
    void* eventContext_ = nullptr;

    bool ready() const { return attached_ && !fault_ && engine_.externalArpeggiator[0]; }
    bool isHold() const { return processor_.settings().mode >= ob1::music::ArpMode::HoldRetrigger; }
    bool view()
    {
        ob1::music::ArpSettings settings {};
        return arpeggiator_settings(engine_, 0, settings) &&
            processor_.settingsView(settings) == ob1::music::ArpResult::Ok;
    }
    struct Output {
        ArpeggiatorAdapter& adapter;
        bool operator()(const ob1::music::Event& event)
        {
            if (!adapter.engine_.externalArpeggiator[0]) return false;
            auto routed = event;
            routed.source.id = adapter.outputSourceID_;
            if (adapter.eventSink_ && !adapter.eventSink_(adapter.eventContext_, routed)) return false;
            return adapter.engine_.external_note(0, event.data1,
                event.kind == ob1::music::Kind::NoteOn ? event.data2 : 0);
        }
    };
    Output output()
    {
        return {*this};
    }
    bool fail()
    {
        fault_ = true;
        engine_.voices_release_part(0);
        return false;
    }
    bool direct(uint8_t pitch, uint8_t velocity)
    {
        uint8_t last = 0;
        const bool held = processor_.lastHeld(last);
        return engine_.external_direct_note(0, pitch, velocity, held, last) || fail();
    }
    struct HeldSnapshot {
        std::array<uint8_t, ob1::music::ArpeggiatorProcessor::heldCapacity> pitches {};
        uint32_t count = 0;
    };
    HeldSnapshot held() const
    {
        HeldSnapshot result;
        while (processor_.heldPitch(result.count, result.pitches[result.count])) {
            if (++result.count == result.pitches.size()) break;
        }
        return result;
    }
    bool releaseRemoved(const HeldSnapshot& before)
    {
        if (processor_.settings().mode != ob1::music::ArpMode::Off) return true;
        const auto after = held();
        for (uint32_t i = 0; i < before.count; ++i)
            if (std::find(after.pitches.begin(), after.pitches.begin() + after.count,
                          before.pitches[i]) == after.pitches.begin() + after.count &&
                !direct(before.pitches[i], 0)) return false;
        return true;
    }
    bool cleanup(bool resetEmpty)
    {
        const auto before = held();
        auto sink = output();
        if (processor_.cleanupUnheld(time_, sink, resetEmpty) != ob1::music::ArpResult::Ok) return fail();
        return releaseRemoved(before);
    }
    bool syncSustain()
    {
        const bool down = engine_.part_sus(0) != 0;
        if (down == sustain_) return true;
        const auto before = held();
        ob1::music::Event event {};
        event.kind = ob1::music::Kind::ControlChange;
        event.data1 = 64;
        event.data2 = down ? 127 : 0;
        event.time = time_;
        auto sink = output();
        if (processor_.input(event, sink) != ob1::music::ArpResult::Ok) return fail();
        sustain_ = down;
        return releaseRemoved(before);
    }
    bool clearProcessor()
    {
        auto sink = output();
        if (processor_.stop(time_, sink) != ob1::music::ArpResult::Ok) return fail();
        ownership_.clear();
        sustain_ = wasOn_ = false;
        return true;
    }
    static bool tick(void* context, Engine& engine, uint32_t part, uint32_t offset) noexcept
    {
        auto& self = *static_cast<ArpeggiatorAdapter*>(context);
        if (part != 0 || &engine != &self.engine_ || !self.ready()) return false;
        self.time_ = {self.renderStart_.frame + offset};
        ArpeggiatorContext current {};
        if (!arpeggiator_context(engine, part, self.time_, current) ||
            self.processor_.settingsView(current.settings) != ob1::music::ArpResult::Ok) return false;
        const bool modulated = current.settings.mode != ob1::music::ArpMode(engine.controllerBase.v[P_ARP_MODE]) ||
            current.settings.latch != ob1::music::Latch(engine.controllerBase.v[P_ARP_LATCH]);
        if ((modulated || self.performanceMod_) && (!engine.part_sus(0) || self.isHold()) &&
            ((self.previousEffective_.mode != ob1::music::ArpMode::Off &&
              current.settings.mode == ob1::music::ArpMode::Off) ||
             (self.previousEffective_.latch != ob1::music::Latch::Off &&
              current.settings.latch == ob1::music::Latch::Off)) &&
            !self.cleanup(true)) return false;
        self.previousEffective_ = current.settings;
        self.performanceMod_ = modulated;
        if (self.panic_) {
            if (!self.clearProcessor()) return false;
            self.panic_ = false;
        }
        if (!self.syncSustain()) return false;
        if (self.restart_) {
            if (self.processor_.restart() != ob1::music::ArpResult::Ok) return false;
            self.restart_ = false;
        }
        if (current.settings.mode != ob1::music::ArpMode::Off && !self.wasOn_)
            engine.voices_release_part(0);
        auto sink = self.output();
        if (self.processor_.seed(engine.rnd_state) != ob1::music::ArpResult::Ok ||
            self.processor_.tick(current.clock, sink) != ob1::music::ArpResult::Ok) return false;
        engine.rnd_state = self.processor_.randomState();
        self.wasOn_ = current.settings.mode != ob1::music::ArpMode::Off;
        return true;
    }
};

} // namespace obervave
