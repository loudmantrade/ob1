// SPDX-License-Identifier: GPL-3.0-only
#include "Sequencer.h"
#include <cassert>
#include <cstdio>
#include <memory>
#include <vector>

using namespace ob1::music;

static Pattern makePattern(Tick intro = 0, bool loop = true)
{
    auto data = std::make_unique<PatternData>();
    data->id = 1; data->length = 960; data->intro = intro; data->loop = loop;
    std::copy_n("Sequence", 9, data->name.begin());
    data->count = intro ? 2 : 1; data->nextNote = data->count + 1;
    data->notes[0] = {1, intro ? -intro : 0, 120, {Target::Instruments, 1, Stage::Output}, 0, 60, 100};
    if (intro) data->notes[1] = {2, 0, 120, {Target::Instruments, 1, Stage::Output}, 0, 64, 100};
    Pattern pattern;
    assert(pattern.restore(*data) == PatternError::None);
    return pattern;
}

static void checkPosition()
{
    for (uint32_t quarter : {11025u, 22032u, 66150u, 12347u}) {
        MusicalPosition position;
        const uint64_t blocks = 1000000, frames = blocks * 16;
        for (uint64_t i = 0; i < blocks; ++i) position.advance(16, quarter);
        assert(position.value == int64_t(frames * ticksPerQuarter * tickUnit / quarter));
        const auto before = position.value;
        position.advance(16, quarter + 17);
        assert(position.value - before == int64_t(uint64_t(16) * ticksPerQuarter * tickUnit / (quarter + 17)));
        MusicalPosition overnight;
        const uint64_t longBlocks = 100000, longBlockFrames = 16384;
        for (uint64_t i = 0; i < longBlocks; ++i) overnight.advance(longBlockFrames, quarter);
        assert(overnight.value == int64_t(longBlocks * longBlockFrames * ticksPerQuarter * tickUnit / quarter));
    }
    assert(ClipPlayer::boundary(100 * tickUnit, LaunchGrid::Free) == 100 * tickUnit);
    assert(ClipPlayer::boundary(100 * tickUnit, LaunchGrid::Beat) == 960 * tickUnit);
    assert(ClipPlayer::boundary(100 * tickUnit, LaunchGrid::Bar) == 3840 * tickUnit);
    assert(ClipPlayer::boundary(3840 * tickUnit, LaunchGrid::Bar) == 3840 * tickUnit);
    MusicalPosition external;
    external.value = 8000 * tickUnit;
    external.followPhase(0, 22032);
    assert(external.value == 7680 * tickUnit);
    external.followPhase(11016, 22032);
    assert(external.value == 8160 * tickUnit);
    std::puts("PASS fixed-point clock: four million control blocks, 10-hour traces, fractional tempos, phase/tempo change and exact grid boundaries");
}

static void checkPlayback()
{
    auto pattern = std::make_unique<Pattern>(makePattern(240));
    auto player = std::make_unique<ClipPlayer>();
    std::vector<Event> events;
    auto sink = [&](const Event& event) { events.push_back(event); return true; };
    player->queue(3, pattern.get(), 3500 * tickUnit, LaunchGrid::Bar);
    assert(player->pendingOrigin == 3840 * tickUnit && player->pendingStart == 3600 * tickUnit);
    assert(player->process(3599 * tickUnit, 1, 5, 9, sink) && events.empty());
    assert(player->process(3600 * tickUnit, 2, 5, 9, sink));
    assert(events.size() == 1 && events[0].kind == Kind::NoteOn && events[0].data1 == 60);
    assert(events[0].source.kind == SourceKind::Pattern && events[0].routing.instruments == (1 << 5));
    assert(events[0].channel == 9 && events[0].routing.stage == Stage::Output);
    assert(player->process(3840 * tickUnit, 3, 5, 9, sink));
    assert(events.size() == 3 && events[1].kind == Kind::NoteOff && events[2].data1 == 64);
    const auto firstMain = events.back().note;
    for (Tick tick = 3841; tick <= 3840 + 960 * 20; tick += 16)
        assert(player->process(tick * tickUnit, tick, 5, 9, sink));
    uint32_t pickup = 0, main = 0;
    for (const auto& event : events) if (event.kind == Kind::NoteOn) {
        if (event.data1 == 60) ++pickup;
        else { ++main; assert(event.note >= firstMain); }
    }
    assert(pickup == 1 && main == 20);
    assert(player->stop(99999, sink) && player->row == -1 && player->pendingRow == -1);
    for (const auto& note : player->active) assert(!note.used);

    auto disabled = std::make_unique<PatternData>(pattern->data());
    disabled->introEnabled = false;
    assert(pattern->restore(*disabled) == PatternError::None);
    events.clear();
    player->queue(2, pattern.get(), 0, LaunchGrid::Free);
    assert(player->process(0, 1, 0, 0, sink));
    assert(events.size() == 1 && events[0].data1 == 64);
    player->queue(7, nullptr, 1, LaunchGrid::Free);
    assert(player->process(1, 2, 0, 0, sink) && player->row == -1);

    auto shorter = std::make_unique<Pattern>(makePattern(120));
    const auto shared = ClipPlayer::boundary(3500 * tickUnit + 240 * tickUnit, LaunchGrid::Bar);
    ClipPlayer other;
    player->queue(1, pattern.get(), 3500 * tickUnit, LaunchGrid::Bar, shared);
    other.queue(1, shorter.get(), 3500 * tickUnit, LaunchGrid::Bar, shared);
    assert(player->pendingOrigin == other.pendingOrigin);
    assert(other.pendingStart == shared - 120 * tickUnit);
    assert(player->stop(100000, sink));

    auto once = std::make_unique<Pattern>(makePattern(0, false));
    player->queue(0, once.get(), 0, LaunchGrid::Free);
    auto reject = [](const Event&) { return false; };
    assert(!player->process(0, 1, 0, 0, reject));
    assert(player->stop(1, sink));
    player->queue(0, once.get(), 0, LaunchGrid::Free);
    assert(player->process(0, 1, 0, 0, sink));
    assert(!player->stop(2, reject));
    assert(player->stop(3, sink));
    player->queue(0, once.get(), 0, LaunchGrid::Free);
    assert(player->process(0, 1, 0, 0, sink));
    assert(player->process(960 * tickUnit, 2, 0, 0, sink) && player->row == -1);
    std::puts("PASS playback: pickup exactly once, 20 loops, output bypass, captured IDs/slot, disabled intro, empty-cell Stop, shared row boundary, rejection/retry and one-shot");
}

static Event note(Kind kind, uint8_t pitch = 60, uint32_t source = 1)
{
    Event event {};
    event.kind = kind; event.data1 = pitch; event.data2 = kind == Kind::NoteOn ? 100 : 0;
    event.source = {SourceKind::ExternalMIDI, source};
    return event;
}

static void checkRegionTails()
{
    auto data = std::make_unique<PatternData>();
    data->id = 1; data->length = 1440; data->regionsEnabled = true;
    data->loopStart = 240; data->loopEnd = 960; data->loop = true;
    std::copy_n("Regions", 8, data->name.begin());
    data->count = 3; data->nextNote = 4;
    data->notes[0] = {1, 0, 100, {Target::Instruments, 1, Stage::Output}, 0, 60, 100};
    data->notes[1] = {2, 720, 2000, {Target::Instruments, 1, Stage::Output}, 0, 64, 100};
    data->notes[2] = {3, 1000, 100, {Target::Instruments, 1, Stage::Output}, 0, 67, 100};
    Pattern pattern;
    assert(pattern.restore(*data) == PatternError::None);
    auto invalid = *data;
    invalid.loopStart = invalid.loopEnd;
    assert(validatePattern(invalid) == PatternError::InvalidLength);
    ClipPlayer player;
    std::vector<Event> events;
    auto sink = [&](const Event& e) { events.push_back(e); return true; };
    player.queue(0, &pattern, 0, LaunchGrid::Free);
    for (Tick t = 0; t <= 2200; t += 20) assert(player.process(t * tickUnit, t, 0, 0, sink));
    std::vector<Event> ons, offs;
    for (const auto& event : events) {
        assert(event.data1 != 67);
        if (event.kind == Kind::NoteOn) ons.push_back(event);
        else offs.push_back(event);
    }
    assert(ons.size() == 4 && ons[0].data1 == 60 &&
           ons[1].time.tick == 720 && ons[2].time.tick == 1440 && ons[3].time.tick == 2160);
    assert(offs.size() == 3 && offs[0].data1 == 60 && offs[1].note == ons[1].note &&
           offs[2].note == ons[2].note);
    assert(player.stop(2201, sink));

    data->loop = false;
    assert(pattern.restore(*data) == PatternError::None);
    events.clear(); player.queue(0, &pattern, 0, LaunchGrid::Free);
    assert(player.process(0, 1, 0, 0, sink));
    assert(player.process(720 * tickUnit, 2, 0, 0, sink));
    assert(player.process(1439 * tickUnit, 3, 0, 0, sink) && player.row == 0);
    assert(player.process(1440 * tickUnit, 4, 0, 0, sink) && player.row == -1);
    for (const auto& event : events) assert(event.data1 != 67);
    assert(events.back().kind == Kind::NoteOff && events.back().data1 == 64);
    std::puts("PASS regions: pre-loop once, exclusive loop end, overlapping same-pitch tails, tail release, one-shot endpoint");
}

static void checkAutomation()
{
    auto data = std::make_unique<PatternData>();
    data->id = 1; data->length = 1440; data->regionsEnabled = true;
    data->loopStart = 240; data->loopEnd = 960;
    std::copy_n("Automation", 11, data->name.begin());
    data->automationCount = 4;
    data->automation[0] = {1, 0, AutomationKind::ControlChange, 1, 5};
    data->automation[1] = {2, 480, AutomationKind::ControlChange, 74, 127};
    data->automation[2] = {3, 480, AutomationKind::PitchBend, 0, 8192};
    data->automation[3] = {4, 1000, AutomationKind::ControlChange, 1, 99};
    Pattern pattern;
    assert(pattern.restore(*data) == PatternError::None);
    auto invalid = *data;
    invalid.automation[2].value = 16384;
    assert(validatePattern(invalid) == PatternError::InvalidAutomation);
    invalid = *data; invalid.automation[2].id = 2;
    assert(validatePattern(invalid) == PatternError::DuplicateID);
    invalid = *data; invalid.automation[2].kind = AutomationKind(9);
    assert(validatePattern(invalid) == PatternError::InvalidAutomation);
    ClipPlayer player;
    std::vector<Event> events;
    auto sink = [&](const Event& e) { events.push_back(e); return true; };
    player.queue(0, &pattern, 0, LaunchGrid::Free);
    for (Tick t = 0; t <= 1250; t += 10) assert(player.process(t * tickUnit, t, 3, 4, sink));
    assert(events.size() == 5);
    assert(events[0].kind == Kind::ControlChange && events[0].data1 == 1 && events[0].data2 == 5);
    assert(events[1].kind == Kind::ControlChange && events[1].data1 == 74 && events[1].data2 == 127);
    assert(events[2].kind == Kind::PitchBend && events[2].data1 == 0 && events[2].data2 == 64);
    assert(events[3].kind == Kind::ControlChange && events[3].time.tick == 1200);
    assert(events[4].kind == Kind::PitchBend && events[4].time.tick == 1200);
    for (const auto& event : events)
        assert(event.source.kind == SourceKind::Pattern && event.routing.instruments == (1 << 3) && event.channel == 4);
    assert(player.stop(1300, sink));
    events.clear(); player.queue(0, &pattern, 0, LaunchGrid::Free);
    assert(player.process(0, 0, 3, 4, sink));
    assert(player.process(1200 * tickUnit, 1, 3, 4, sink));
    assert(events.size() == 5 && events[1].time.tick == 480 && events[2].time.tick == 480 &&
           events[3].time.tick == 1200 && events[4].time.tick == 1200);
    assert(events[1].kind == Kind::ControlChange && events[2].kind == Kind::PitchBend &&
           events[3].kind == Kind::ControlChange && events[4].kind == Kind::PitchBend);
    std::puts("PASS automation: bounded validation, CC and 14-bit bend, ordered equal ticks, loop and tail");
}

static void checkNoteQuantization()
{
    auto data = std::make_unique<PatternData>();
    data->id = 1; data->length = 960; data->quantization.grid = 120;
    std::copy_n("Quant", 6, data->name.begin());
    data->count = 2; data->nextNote = 3;
    data->notes[0] = {1, 100, 145, {Target::Instruments, 1, Stage::Output}, 0, 60, 100};
    data->notes[1] = {2, 200, 145, {Target::Instruments, 1, Stage::Output}, 0, 64, 100};
    data->notes[0].quantizationOverride = true;
    data->notes[0].quantization = {240, 100, true};
    Pattern pattern;
    assert(pattern.restore(*data) == PatternError::None);
    PatternTiming a, b;
    assert(pattern.timingAt(0, a) == PatternError::None && a.start == 0 && a.duration == 240);
    assert(pattern.timingAt(1, b) == PatternError::None && b.start == 240 && b.duration == 145);
    data->notes[0].quantization = {0, 100, false};
    assert(pattern.restore(*data) == PatternError::None);
    assert(pattern.timingAt(0, a) == PatternError::None && a.start == 100 && a.duration == 145);
    data->notes[0].quantization.grid = 240; data->notes[0].quantization.strength = 50;
    assert(pattern.restore(*data) == PatternError::None);
    assert(pattern.timingAt(0, a) == PatternError::None && a.start == 50 && a.duration == 145);
    data->notes[0].quantization.strength = 101;
    assert(pattern.restore(*data) == PatternError::InvalidQuantization);
    std::puts("PASS note quantization: per-note override, start/end, strength, off and original timing");
}

static void checkIndependentStarts()
{
    auto data = std::make_unique<PatternData>();
    data->id = 1; data->length = 1440; data->intro = 960; data->regionsEnabled = true;
    data->patternStart = -480; data->loopStart = -240; data->loopEnd = 480;
    std::copy_n("Starts", 7, data->name.begin());
    data->count = 3; data->nextNote = 4;
    data->notes[0] = {1, -720, 20, {Target::Instruments, 1, Stage::Output}, 0, 60, 100};
    data->notes[1] = {2, -480, 20, {Target::Instruments, 1, Stage::Output}, 0, 61, 100};
    data->notes[2] = {3, -240, 20, {Target::Instruments, 1, Stage::Output}, 0, 62, 100};
    Pattern pattern;
    assert(pattern.restore(*data) == PatternError::None);
    ClipPlayer player;
    std::vector<Event> events;
    auto sink = [&](const Event& e) { events.push_back(e); return true; };
    player.queue(0, &pattern, 0, LaunchGrid::Free);
    assert(player.pendingStart == 0 && player.pendingOrigin == 480 * tickUnit);
    for (Tick t = 0; t <= 1000; t += 20) assert(player.process(t * tickUnit, t, 0, 0, sink));
    uint32_t pickup = 0, loop = 0;
    for (const auto& event : events) if (event.kind == Kind::NoteOn) {
        assert(event.data1 != 60);
        pickup += event.data1 == 61; loop += event.data1 == 62;
    }
    assert(pickup == 1 && loop == 2);
    assert(player.stop(1001, sink));

    data->intro = 0; data->patternStart = 240; data->loopStart = 480; data->loopEnd = 960;
    data->notes[0].start = 0; data->notes[1].start = 240; data->notes[2].start = 480;
    assert(pattern.restore(*data) == PatternError::None);
    events.clear(); player.queue(0, &pattern, 0, LaunchGrid::Free);
    assert(player.pendingStart == 0 && player.pendingOrigin == -240 * tickUnit);
    assert(player.process(0, 0, 0, 0, sink));
    assert(events.size() == 1 && events[0].data1 == 61);
    assert(player.process(240 * tickUnit, 1, 0, 0, sink));
    assert(events.back().data1 == 62 && events.back().kind == Kind::NoteOn);
    std::puts("PASS independent starts: editable pre-start data, negative repeating section and positive launch");
}

static void checkRecording()
{
    auto recorder = std::make_unique<ClipRecorder>();
    auto pattern = std::make_unique<Pattern>(makePattern());
    recorder->begin(5, 2, pattern->data(), 3500 * tickUnit, true, true);
    assert(recorder->origin == 3840 * tickUnit);
    assert(recorder->capture(note(Kind::NoteOn), 3600 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOff), 3900 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOn, 64), 4000 * tickUnit));
    recorder->finish(4200 * tickUnit);
    assert(!recorder->running && recorder->data.count == 2 && recorder->data.intro == 240);
    assert(recorder->data.notes[0].start == -240 && recorder->data.notes[0].duration == 300);
    assert(recorder->data.notes[1].start == 160 && recorder->data.notes[1].duration == 200);
    assert(recorder->data.notes[0].routing.instruments == (1 << 5));
    assert(recorder->data.notes[0].routing.stage == Stage::Output);
    assert(validatePattern(recorder->data) == PatternError::None);
    recorder->begin(0, 0, pattern->data(), 3500 * tickUnit, false, false);
    assert(recorder->capture(note(Kind::NoteOn), 3600 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOff), 3900 * tickUnit));
    auto own = note(Kind::NoteOn);
    own.source.kind = SourceKind::Pattern;
    assert(recorder->capture(own, 4000 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOn, 64), 4000 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOn, 64, 2), 4100 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOff, 64), 4200 * tickUnit));
    recorder->finish(recorder->stopAt + tickUnit);
    assert(recorder->data.count == 2 && recorder->data.intro == 0);
    assert(recorder->data.notes[0].duration == 200 && recorder->data.notes[1].duration == 700);
    assert(recorder->data.notes[0].routing.stage == Stage::Input);
    assert(validatePattern(recorder->data) == PatternError::None);

    recorder->begin(0, 0, pattern->data(), 0, true, false);
    for (uint32_t i = 0; i < patternNoteCapacity; ++i) {
        assert(recorder->capture(note(Kind::NoteOn), 0));
        assert(recorder->capture(note(Kind::NoteOff), tickUnit));
    }
    assert(!recorder->capture(note(Kind::NoteOn), 0) && recorder->overflow);
    recorder->finish(tickUnit);
    assert(recorder->data.count == patternNoteCapacity);
    std::puts("PASS recorder: negative pickup/cross-zero duration, stop finalization, input/output routing, source overlap, ignores own playback and explicit bounded overflow");
}

static void checkBarCompletion()
{
    auto recorder = std::make_unique<ClipRecorder>();
    auto settings = std::make_unique<Pattern>(makePattern());
    recorder->arm(0, 0, settings->data(), 123 * tickUnit, RecordMode::Immediate, 1, 0, false, false);
    const auto origin = recorder->origin;
    assert(recorder->lengthAt(origin) == 3840);
    assert(recorder->lengthAt(origin + 3839 * tickUnit) == 3840);
    assert(recorder->lengthAt(origin + 3840 * tickUnit) == 7680);
    assert(recorder->lengthAt(origin + 7680 * tickUnit) == 11520);
    recorder->requestFinish(origin + 4000 * tickUnit);
    assert(recorder->running && recorder->finishQueued && recorder->phase(origin + 4000 * tickUnit) == 5);
    assert(recorder->stopAt == origin + 7680 * tickUnit && recorder->lengthAt(origin + 4000 * tickUnit) == 7680);
    recorder->requestFinish(origin + 7000 * tickUnit);
    assert(recorder->stopAt == origin + 7680 * tickUnit);
    assert(recorder->capture(note(Kind::NoteOn), origin + 5000 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOff), origin + 6000 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOn, 64), origin + 7000 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOn, 67), recorder->stopAt));
    recorder->finish(recorder->stopAt + tickUnit / 2);
    assert(recorder->data.length == 7680 && recorder->data.count == 2);
    assert(recorder->data.notes[1].duration == 680 && validatePattern(recorder->data) == PatternError::None);
    for (const uint32_t beats : {2u, 6u, 12u}) {
        recorder->arm(0, 0, settings->data(), origin, RecordMode::Immediate, 1, beats, false, false);
        const auto limit = recorder->stopAt;
        recorder->requestFinish(origin + 100 * tickUnit);
        assert(recorder->stopAt == std::min(limit, origin + 3840 * tickUnit));
        recorder->finish(recorder->stopAt + tickUnit);
        assert(recorder->data.length == std::min(Tick(beats) * 960, Tick(3840)));
    }
    recorder->arm(0, 0, settings->data(), origin, RecordMode::WaitForNote, 1, 0, false, false);
    assert(recorder->lengthAt(origin + 20000 * tickUnit) == 3840);
    recorder->requestFinish(origin);
    assert(!recorder->finishQueued);
    recorder->arm(0, 0, settings->data(), origin, RecordMode::Immediate, 1, 0, false, false);
    recorder->requestFinish(origin + 3840 * tickUnit);
    assert(recorder->stopAt == origin + 3840 * tickUnit);
    std::puts("PASS bar completion: free length grows by whole bars, tap queues immutable boundary, capture continues until it, exact-tick cutoff, fixed cap/early finish and waiting state");
    auto pattern = std::make_unique<Pattern>(makePattern());
    ClipPlayer player;
    std::vector<Event> events;
    auto sink = [&](const Event& event) { events.push_back(event); return true; };
    player.queue(0, pattern.get(), 0, LaunchGrid::Free);
    assert(player.process(0, 1, 0, 0, sink));
    player.requestStop(100 * tickUnit);
    assert(player.stopping() && player.pendingStart == 3840 * tickUnit);
    player.requestStop(3900 * tickUnit);
    assert(player.pendingStart == 3840 * tickUnit);
    assert(player.process(3839 * tickUnit, 2, 0, 0, sink) && player.row == 0);
    assert(player.process(3840 * tickUnit, 3, 0, 0, sink) && player.row == -1 && !player.stopping());
    for (const auto& note : player.active) assert(!note.used);
    player.queue(0, pattern.get(), 3840 * tickUnit, LaunchGrid::Free);
    assert(player.process(3840 * tickUnit, 4, 0, 0, sink));
    player.requestStop(3840 * tickUnit);
    assert(player.pendingStart == 7680 * tickUnit);
}

static void checkRecordModes()
{
    auto recorder = std::make_unique<ClipRecorder>();
    auto settings = std::make_unique<Pattern>(makePattern());
    auto recorded = std::make_unique<Pattern>();
    recorder->arm(1, 2, settings->data(), 123 * tickUnit, RecordMode::WaitForNote, 1, 4, false, true);
    assert(recorder->waiting && recorder->phase(10000 * tickUnit) == 1 && recorder->stopAt == INT64_MAX);
    assert(recorder->capture(note(Kind::NoteOn), 500 * tickUnit) && !recorder->started);
    recorder->firstNote(2000 * tickUnit);
    assert(!recorder->waiting && recorder->origin == 2000 * tickUnit && recorder->stopAt == 5840 * tickUnit);
    assert(recorder->capture(note(Kind::NoteOn), 2000 * tickUnit));
    assert(recorder->capture(note(Kind::NoteOff), 2240 * tickUnit));
    recorder->finish(recorder->stopAt);
    assert(recorder->data.notes[0].start == 0 && recorder->data.notes[0].duration == 240);
    assert(recorder->data.length == 3840 && recorder->publish(*recorded));
    assert(validatePattern(recorded->data()) == PatternError::None);

    recorder->arm(0, 0, settings->data(), 0, RecordMode::WaitForNote, 1, 0, false, true);
    recorder->finish(10000 * tickUnit);
    assert(recorder->cancelled && !recorder->publish(*recorded));
    recorder->arm(0, 0, settings->data(), 3500 * tickUnit, RecordMode::WaitForNote, 1, 4, true, true);
    assert(recorder->waiting && recorder->stopAt == INT64_MAX);
    assert(recorder->phase(20000 * tickUnit) == 1 && !recorder->withIntro);
    recorder->firstNote(20123 * tickUnit);
    assert(recorder->origin == 20123 * tickUnit && recorder->stopAt == 23963 * tickUnit);
    assert(recorder->capture(note(Kind::NoteOn), recorder->origin));
    recorder->finish(recorder->stopAt);
    assert(recorder->data.notes[0].start == 0 && recorder->data.intro == 0);
    for (auto mode : {RecordMode::Immediate}) {
        recorder->arm(0, 0, settings->data(), 3500 * tickUnit, mode, 1, 3, true, true);
        assert(!recorder->waiting && recorder->origin == 3840 * tickUnit);
        assert(recorder->capture(note(Kind::NoteOn), 3600 * tickUnit));
        assert(recorder->capture(note(Kind::NoteOff), 3900 * tickUnit));
        recorder->finish(recorder->stopAt);
        assert(recorder->data.length == 2880 && recorder->data.intro == 240);
        assert(recorder->data.notes[0].start == -240 && recorder->data.notes[0].duration == 300);
        assert(recorder->publish(*recorded) && validatePattern(recorded->data()) == PatternError::None);
    }
    recorder->arm(0, 0, settings->data(), 0, RecordMode::Immediate, 1, 0, false, true);
    assert(recorder->capture(note(Kind::NoteOn), 960 * tickUnit));
    recorder->finish(960 * tickUnit);
    assert(recorder->data.length == 961 && recorder->data.notes[0].duration == 1);
    assert(recorder->publish(*recorded) && validatePattern(recorded->data()) == PatternError::None);
    recorder->arm(0, 0, settings->data(), 0, RecordMode::Immediate, 1, 0, false, true);
    assert(recorder->stopAt == INT64_MAX);
    assert(recorder->capture(note(Kind::NoteOn), 0));
    assert(recorder->capture(note(Kind::NoteOff), 960 * 600 * tickUnit));
    assert(recorder->running && recorder->data.notes[0].duration == 960 * 600);
    recorder->finish(960 * 1000 * tickUnit);
    assert(recorder->data.length == 960 * 1000 && recorder->publish(*recorded));
    assert(validatePattern(recorded->data()) == PatternError::None);

    for (const uint32_t bars : {1u, 2u}) {
        recorder->arm(0, 0, settings->data(), 3500 * tickUnit, RecordMode::CountIn, bars, 4, true, true);
        assert(recorder->countStart == 3840 * tickUnit);
        assert(recorder->origin == (3840 + bars * 3840) * tickUnit);
        assert(recorder->click(3500 * tickUnit) == -1);
        uint32_t clicks = 0;
        for (auto tick = Tick(3500); tick <= 3840 + bars * 3840; ++tick) {
            const auto click = recorder->click(tick * tickUnit);
            if (click >= 0) { assert(click == int32_t(clicks % 4)); ++clicks; }
        }
        assert(clicks == bars * 4);
        assert(recorder->remaining(recorder->countStart) == bars * 4);
        assert(recorder->capture(note(Kind::NoteOn), 3500 * tickUnit));
        assert(recorder->capture(note(Kind::NoteOff), recorder->origin + 100 * tickUnit));
        assert(recorder->phase(recorder->origin) == 3 && recorder->remaining(recorder->origin) == 0);
        recorder->finish(recorder->stopAt);
        assert(recorder->data.intro == 340 + bars * 3840);
        assert(recorder->publish(*recorded) && validatePattern(recorded->data()) == PatternError::None);
    }
    recorder->arm(0, 0, settings->data(), 123 * tickUnit, RecordMode::Immediate, 1, 0, false, true);
    assert(recorder->origin == 123 * tickUnit && recorder->freeLength && !recorder->withIntro);
    assert(recorder->capture(note(Kind::NoteOn), 123 * tickUnit));
    recorder->finish(123 * tickUnit + 1500 * tickUnit + tickUnit / 2);
    assert(recorder->data.length == 1501 && recorder->data.notes[0].duration == 1500);
    assert(recorder->publish(*recorded) && validatePattern(recorded->data()) == PatternError::None);
    // Autoplay starts at the main loop, not a second performance of the pickup.
    auto intro = std::make_unique<Pattern>(makePattern(240));
    ClipPlayer player;
    std::vector<Event> output;
    auto sink = [&](const Event& event) { output.push_back(event); return true; };
    player.queue(0, intro.get(), 5000 * tickUnit, LaunchGrid::Free, -1, false);
    assert(player.process(5000 * tickUnit, 1, 0, 0, sink));
    assert(output.size() == 1 && output[0].data1 == 64);
    std::puts("PASS record modes: Wait arms without timing out, first-note zero, cancellation, live-scene pickup, exact 4/8 clicks and full count-in bars, fixed/free lengths and no duplicate intro on autoplay");
}

static void checkRecordingClicks()
{
    auto recorder = std::make_unique<ClipRecorder>();
    auto settings = std::make_unique<Pattern>(makePattern());
    const auto quarter = ticksPerQuarter * tickUnit;
    for (const uint32_t bars : {1u, 2u}) {
        recorder->arm(0, 0, settings->data(), 0, RecordMode::CountIn, bars, 0, false, true);
        for (uint32_t beat = 0; beat < bars * 4 + 2; ++beat) {
            assert(recorder->click(beat * quarter, true) == int32_t(beat % 4));
            assert(recorder->click(beat * quarter + quarter / 2, true) == -1);
        }
        recorder->requestFinish(recorder->origin + quarter);
        assert(recorder->finishQueued);
        assert(recorder->click(recorder->origin + 2 * quarter, true) == 2);
        assert(recorder->click(recorder->stopAt - 1, true) == 3);
        assert(recorder->click(recorder->stopAt, true) == -1);
        recorder->finish(recorder->stopAt);
        assert(recorder->click(recorder->stopAt + quarter, true) == -1);
    }
    std::puts("PASS recording clicks: continuous count-in/body accents, no duplicate clicks, queued completion and exact stop deadline");
}

int main()
{
    checkPosition(); checkPlayback(); checkRegionTails(); checkAutomation(); checkNoteQuantization(); checkIndependentStarts(); checkRecording(); checkRecordModes(); checkBarCompletion(); checkRecordingClicks();
}
