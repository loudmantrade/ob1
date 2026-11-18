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
    for (auto mode : {RecordMode::WaitForNote, RecordMode::Immediate}) {
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

int main()
{
    checkPosition(); checkPlayback(); checkRecording(); checkRecordModes();
}
