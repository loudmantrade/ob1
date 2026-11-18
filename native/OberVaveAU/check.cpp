// SPDX-License-Identifier: GPL-3.0-only
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
#include "Engine.h"
#include "UIBridge.h"

using namespace obervave;
static void check(OSStatus status, const char* action)
{
    if (status != noErr) throw std::runtime_error(std::string(action) + ": " + std::to_string(status));
}
static void require(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}
static void set(AudioUnit unit, UInt32 id, float value)
{
    check(AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0), "set parameter");
}
static float get(AudioUnit unit, UInt32 id)
{
    float value = 0;
    check(AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &value), "get parameter");
    return value;
}
struct Unit {
    AudioUnit unit = nullptr;
    AudioTimeStamp time{};
    double sampleRate = 44100, tempo = 120, initialBeat = 0.5;
    bool playing = true, transportChanged = false;
    Unit(AudioComponent component, double rate)
    {
        sampleRate = rate;
        check(AudioComponentInstanceNew(component, &unit), "instantiate");
        AudioStreamBasicDescription format{};
        format.mSampleRate = rate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        format.mBytesPerPacket = format.mBytesPerFrame = sizeof(float);
        format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = 2;
        format.mBitsPerChannel = 32;
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
            0, &format, sizeof(format)), "format");
        check(AudioUnitInitialize(unit), "initialize");
        time.mFlags = kAudioTimeStampSampleTimeValid;
    }
    ~Unit() { if (unit) { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); } }
    void sync(double bpm)
    {
        tempo = bpm;
        HostCallbackInfo callbacks{};
        callbacks.hostUserData = this;
        callbacks.beatAndTempoProc = [](void* context, Float64* beat, Float64* bpm) -> OSStatus {
            const auto& self = *static_cast<Unit*>(context);
            *beat = self.initialBeat + self.time.mSampleTime * self.tempo / (60 * self.sampleRate);
            *bpm = self.tempo;
            return noErr;
        };
        callbacks.transportStateProc = [](void* context, Boolean* playing, Boolean* changed,
            Float64* sample, Boolean* cycling, Float64* start, Float64* end) -> OSStatus {
            auto& self = *static_cast<Unit*>(context);
            *playing = self.playing;
            *changed = self.transportChanged;
            self.transportChanged = false;
            *sample = self.time.mSampleTime;
            *cycling = false;
            *start = *end = 0;
            return noErr;
        };
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global,
            0, &callbacks, sizeof(callbacks)), "host callbacks");
    }
    std::vector<float> render(UInt32 count)
    {
        std::vector<float> l(count), r(count);
        struct { UInt32 count; AudioBuffer buffers[2]; } audio{
            2, {{1, count * UInt32(sizeof(float)), l.data()}, {1, count * UInt32(sizeof(float)), r.data()}}};
        AudioUnitRenderActionFlags flags = 0;
        check(AudioUnitRender(unit, &flags, &time, 0, count, reinterpret_cast<AudioBufferList*>(&audio)), "render");
        for (UInt32 i = 0; i < count; ++i)
            require(std::isfinite(l[i]) && std::isfinite(r[i]), "non-finite sample");
        time.mSampleTime += count;
        return l;
    }
};
static void checkArpContinuity()
{
    for (const auto division : {D_8T, D_16T, D_32T, D_16}) {
        auto engine = std::make_unique<Engine>();
        engine->initialize();
        engine->live_p[0].v[P_ARP_MODE] = A_UP;
        engine->live_p[0].v[P_ARP_DIV] = division;
        engine->ctl_arp_sync = 1;
        engine->ctl_arp_sync_grid = 2;
        engine->ctl_ext_quarter = 22050;
        engine->hostClock = true;
        engine->hostTempo = 120;
        engine->hostBeat = 0.5;
        engine->ev_note_on(0, 60, 100);
        std::vector<uint32_t> steps;
        for (uint32_t frame = 0; frame < FS * 8; frame += CTL) {
            engine->eng_t = frame;
            // A host phase jump must not restart an already running arpeggio.
            if (frame == CTL * 9000) engine->hostBeat += 0.37;
            const auto before = engine->ui_arp_step;
            engine->arp_tick(0);
            if (engine->ui_arp_step != before) steps.push_back(frame);
        }
        require(steps.size() > 10, "missing arpeggio steps");
        const auto period = 22050 / DIV_PER_QUARTER[division];
        require(steps.front() >= 11025 - CTL && steps.front() <= 11025 + CTL,
            "first arpeggio step missed start grid");
        for (size_t i = 1; i < steps.size(); ++i) {
            const auto expected = steps.front() + (uint64_t(i) * period + CTL - 1) / CTL * CTL;
            require(steps[i] == expected, "running arpeggio resynchronized or skipped a step");
        }
        engine->ctl_ext_quarter = 29400;
        engine->hostTempo = 90;
        steps.clear();
        const auto start = engine->eng_t + CTL;
        for (uint32_t frame = start; frame < start + FS * 2; frame += CTL) {
            engine->eng_t = frame;
            const auto before = engine->ui_arp_step;
            engine->arp_tick(0);
            if (engine->ui_arp_step != before) steps.push_back(frame);
        }
        require(steps.size() > 2, "arpeggio stopped after tempo change");
        const auto slowerPeriod = 29400 / DIV_PER_QUARTER[division];
        for (size_t i = 1; i < steps.size(); ++i)
            require(std::abs(int(steps[i] - steps[i - 1]) - int(slowerPeriod)) < int(CTL),
                "running arpeggio did not follow master tempo");
        engine->ev_note_off(0, 60);
        engine->arp_tick(0);
        require(engine->arp[0].cnt == 0xFFFFFFFFu, "arp did not rearm after releasing all notes");
        engine->ev_note_on(0, 60, 100);
        const auto before = engine->ui_arp_step;
        for (uint32_t i = 0; i < 29400 + CTL; i += CTL) {
            engine->eng_t += CTL;
            uint32_t phase, bar;
            engine->host_phase(&phase, &bar);
            engine->arp_tick(0);
            if (engine->ui_arp_step != before) {
                require(bar % 29400 < CTL, "next phrase did not wait for start grid");
                break;
            }
        }
        require(engine->ui_arp_step != before, "next arpeggio phrase failed to start");
    }
    std::cout << "PASS continuous arp timing across bars and host phase jumps, including triplets\n";
}
static void checkLatchHeldKeys()
{
    for (const auto latch : {1u, 2u}) {
        auto engine = std::make_unique<Engine>();
        engine->initialize();
        engine->apply_parameter(P_ARP_MODE, A_UP);
        engine->apply_parameter(P_ARP_LATCH, latch);
        engine->ev_note_on(0, 60, 100);
        engine->ev_note_on(0, 64, 100);
        engine->ev_note_off(0, 60);
        engine->apply_parameter(P_ARP_LATCH, 0);
        require(engine->nheld[0] == 1 && engine->held[0][0].note == 64,
            "Latch Off must preserve physically held keys only");
        engine->apply_parameter(P_ARP_LATCH, latch);
        engine->ctl_sustain = 1;
        engine->ev_note_off(0, 64);
        engine->apply_parameter(P_ARP_LATCH, 0);
        require(engine->nheld[0] == 1, "Latch Off must respect sustain pedal");
        engine->ctl_sustain = 0;
        engine->ev_sustain_up(0);
        require(engine->nheld[0] == 0, "pedal release left stale notes");
    }
}
static void checkSustainClearsLatch()
{
    for (const auto latch : {0u, 1u, 2u}) {
        for (const bool keepKey : {false, true}) {
            auto engine = std::make_unique<Engine>();
            engine->initialize();
            engine->apply_parameter(P_ARP_MODE, A_UP);
            engine->apply_parameter(P_ARP_LATCH, latch);
            engine->ctl_arp_sync = 0;
            engine->ev_note_on(0, 60, 100);
            engine->ev_note_on(0, 64, 100);
            engine->ctl_sustain = 1;
            engine->engine_events();
            engine->ev_note_off(0, 60);
            if (!keepKey) engine->ev_note_off(0, 64);
            engine->arp_tick(0);
            const auto count = engine->arp[0].cnt;
            engine->ctl_sustain = 0;
            engine->engine_events();
            require(engine->live_p[0].v[P_ARP_LATCH] == latch, "pedal release disabled Latch");
            require(engine->nheld[0] == (keepKey ? 1u : 0u),
                "pedal release did not clear released latched notes");
            if (keepKey) {
                require(engine->held[0][0].note == 64 && engine->held[0][0].phys,
                    "pedal release removed physically held key");
                require(engine->arp[0].cnt == count, "pedal release restarted ongoing arpeggio");
                require(!engine->arp[0].sounding, "cleared source note kept sounding");
                engine->arp_stop_note(0);
                engine->arp_step(0);
                require(engine->arp[0].note == 64, "arp still uses a cleared note");
            } else {
                require(!engine->arp[0].sounding && engine->arp[0].cnt == 0xFFFFFFFFu,
                    "pedal release did not stop/rearm empty arpeggio");
            }
            engine->ev_note_on(0, 67, 100);
            engine->ev_note_off(0, 67);
            require(engine->nheld[0] == (keepKey ? 1u : 0u) + (latch ? 1u : 0u),
                "Latch no longer works after releasing pedal");
        }
        auto engine = std::make_unique<Engine>();
        engine->initialize();
        engine->apply_parameter(P_ARP_MODE, A_DOWN);
        engine->apply_parameter(P_ARP_LATCH, latch);
        engine->ev_note_on(0, 60, 100);
        engine->ev_note_on(0, 64, 100);
        engine->ctl_sustain = 1;
        engine->engine_events();
        engine->ev_note_off(0, 60);
        engine->arp_step(0);
        require(engine->arp[0].note == 64, "held-note test setup");
        engine->ctl_sustain = 0;
        engine->engine_events();
        require(engine->arp[0].sounding && engine->arp[0].note == 64,
            "pedal release cut a physically held sounding note");
    }
    std::cout << "PASS sustain release clears latch, preserves held keys/phase and leaves Latch enabled\n";
}
int main(int argc, char** argv)
{
    if (argc != 2) { std::cerr << "usage: check /absolute/path/OberVave.component\n"; return 2; }
    try {
        checkArpContinuity();
        checkLatchHeldKeys();
        checkSustainClearsLatch();
        auto url = CFURLCreateFromFileSystemRepresentation(nullptr,
            reinterpret_cast<const UInt8*>(argv[1]), std::strlen(argv[1]), true);
        auto bundle = CFBundleCreate(nullptr, url);
        CFRelease(url);
        require(bundle && CFBundleLoadExecutable(bundle), "cannot load bundle");
        auto factory = reinterpret_cast<AudioComponentFactoryFunction>(
            CFBundleGetFunctionPointerForName(bundle, CFSTR("OberVaveFactory")));
        require(factory, "missing factory");
        AudioComponentDescription desc{kAudioUnitType_MusicDevice, 'Obv1', 'Obvv', 0, 0};
        auto component = AudioComponentRegister(&desc, CFSTR("OberVave: Native test"), 256, factory);
        require(component, "cannot register");
        {
            Unit a(component, 44100), b(component, 44100);
            for (UInt32 slot = 0; slot < MOD_SLOTS; ++slot) {
                const auto base = kOberVaveModulationBase + slot * 3;
                require(get(a.unit, base) == 0 && get(a.unit, base + 2) == 64, "matrix not neutral by default");
                set(a.unit, base, 1 + slot % (NMODSRC - 1));
                set(a.unit, base + 1, slot);
                set(a.unit, base + 2, slot % 2 ? 0 : 128);
            }
            set(a.unit, kOberVaveLegacyWheel, 0);
            set(a.unit, kOberVaveProgram, 18);
            require(get(a.unit, kOberVaveModulationBase) == 0 &&
                get(a.unit, kOberVaveLegacyWheel) == 1, "program did not reset matrix");
            set(a.unit, kOberVaveModulationBase, MS_PRESSURE);
            set(a.unit, kOberVaveModulationBase + 1, MD_CUTOFF);
            set(a.unit, kOberVaveModulationBase + 2, 101);
            set(a.unit, kOberVaveLegacyWheel, 0);
            CFPropertyListRef state = nullptr;
            UInt32 size = sizeof(state);
            check(AudioUnitGetProperty(a.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, &size), "save matrix");
            check(AudioUnitSetProperty(b.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, sizeof(state)), "restore matrix");
            CFRelease(state);
            for (UInt32 id = kOberVaveModulationBase; id < kOberVaveParameterCount; ++id)
                require(get(a.unit, id) == get(b.unit, id), "AU matrix did not roundtrip");
            require(get(a.unit, kOberVaveProgram) == 18 && kOberVavePan == 67 &&
                kOberVaveGrid == 69, "legacy automation IDs changed");
            std::cout << "PASS all eight AU matrix slots, signed depth endpoints, program reset, state restore and stable legacy IDs\n";
        }
        {
            Unit a(component, 44100), b(component, 44100);
            for (UInt32 slot = 0; slot < CONTROLLER_SLOTS; ++slot) {
                const auto base = kOberVaveControllerBase + slot * CONTROLLER_FIELDS;
                require(get(a.unit, base) == 0 && get(a.unit, base + 5) == 64, "controller default not neutral");
                set(a.unit, base, slot == 0 ? CS_CC0 + 1 : CS_POLY);
                set(a.unit, base + 1, slot == 0 ? P_LFO_RATE : P_CUTOFF);
                set(a.unit, base + 2, slot == 0 ? 0 : 1);
                set(a.unit, base + 3, 32);
                set(a.unit, base + 4, 96);
                set(a.unit, base + 5, slot % 2 ? 0 : 128);
                set(a.unit, base + 6, 1);
            }
            check(MusicDeviceMIDIEvent(a.unit, 0xB0, 1, 0, 0), "controller low");
            a.render(32);
            require(get(a.unit, P_LFO_RATE) == 32, "AU controller Min not applied");
            check(MusicDeviceMIDIEvent(a.unit, 0xB0, 1, 127, 0), "controller high");
            a.render(32);
            require(get(a.unit, P_LFO_RATE) == 95, "AU controller Max not applied");
            require(get(a.unit, P_MOD_DEPTH) == 0, "OVERRIDE allowed old CC1 assignment");
            CFPropertyListRef state = nullptr;
            UInt32 size = sizeof(state);
            check(AudioUnitGetProperty(a.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, &size), "save controllers");
            check(AudioUnitSetProperty(b.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, sizeof(state)), "restore controllers");
            for (UInt32 id = 0; id < kOberVaveParameterCount; ++id)
                require(get(a.unit, id) == get(b.unit, id), "AU controller state did not roundtrip");
            auto legacy = CFDictionaryCreateMutableCopy(nullptr, 0, static_cast<CFDictionaryRef>(state));
            const auto data = static_cast<CFDataRef>(CFDictionaryGetValue(legacy, CFSTR("data")));
            require(data && CFDataGetLength(data) == 12 + kOberVaveParameterCount * 8, "unexpected preset layout");
            auto legacyData = CFDataCreateMutableCopy(nullptr, 0, data);
            for (const UInt32 count : {97u, 70u}) {
                UInt32 storedCount = CFSwapInt32HostToBig(count);
                CFDataSetLength(legacyData, 12 + count * 8);
                std::memcpy(CFDataGetMutableBytePtr(legacyData) + 8, &storedCount, sizeof(storedCount));
                CFDictionarySetValue(legacy, CFSTR("data"), legacyData);
                CFPropertyListRef oldState = legacy;
                check(AudioUnitSetProperty(b.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                    0, &oldState, sizeof(oldState)), "restore pre-controller state");
                for (UInt32 slot = 0; slot < CONTROLLER_SLOTS; ++slot)
                    require(get(b.unit, kOberVaveControllerBase + slot * CONTROLLER_FIELDS) == 0,
                        "old state retained controller routes");
            }
            CFRelease(legacyData); CFRelease(legacy); CFRelease(state);
            UInt32 armed = 1, learned = 0;
            check(AudioUnitSetProperty(a.unit, kOberVaveControllerLearn, kAudioUnitScope_Global,
                0, &armed, sizeof(armed)), "arm AU controller learn");
            check(MusicDeviceMIDIEvent(a.unit, 0x90, 60, 100, 0), "learn ignores note");
            check(MusicDeviceMIDIEvent(a.unit, 0xE0, 0, 64, 0), "learn bend");
            check(MusicDeviceMIDIEvent(a.unit, 0xD0, 100, 0, 0), "learn one-shot");
            a.render(64); size = sizeof(learned);
            check(AudioUnitGetProperty(a.unit, kOberVaveControllerLearn, kAudioUnitScope_Global,
                0, &learned, &size), "read AU controller learn");
            require(learned == CS_BEND, "AU learn not first controller/one-shot");
            check(AudioUnitGetProperty(a.unit, kOberVaveControllerLearn, kAudioUnitScope_Global,
                0, &learned, &size), "consume AU controller learn");
            require(learned == 0, "AU learn not consumed");
            check(AudioUnitSetProperty(a.unit, kOberVavePanic, kAudioUnitScope_Global,
                0, &armed, sizeof(armed)), "dedicated panic");
            a.render(64);
            set(a.unit, kOberVaveProgram, 18);
            require(get(a.unit, kOberVaveControllerBase) == 0, "program retained controller routes");
            std::cout << "PASS 16 AU Controller routes, exact ranges, overrides, all-parameter state, 97/70-ID preset migration, first-event MIDI Learn and program reset\n";
        }
        for (const double rate : {22050., 44100., 48000., 88200., 96000., 192000.}) {
            Unit a(component, rate), b(component, rate);
            set(a.unit, P_ARP_MODE, A_OFF);
            set(a.unit, P_AA, 0);
            set(a.unit, P_CHO_MIX, 0);
            set(a.unit, P_DLY_MIX, 0);
            set(a.unit, P_REV_MIX, 0);
            set(a.unit, P_CUTOFF, 42);
            require(get(b.unit, P_CUTOFF) != 42, "parameter state leaks between instances");
            CFPropertyListRef state = nullptr;
            UInt32 size = sizeof(state);
            check(AudioUnitGetProperty(a.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, &size), "save state");
            set(a.unit, P_CUTOFF, 90);
            check(AudioUnitSetProperty(b.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, sizeof(state)), "restore state");
            CFRelease(state);
            require(get(b.unit, P_CUTOFF) == 42, "custom patch not restored in a different instance");
            set(a.unit, P_CUTOFF, 42);
            check(MusicDeviceMIDIEvent(a.unit, 0x90, 60, 100, 128), "note on");
            auto first = a.render(512);
            double peak = 0;
            for (unsigned i = 0; i < first.size(); ++i) {
                peak = std::max(peak, double(std::abs(first[i])));
                if (i < 128) require(std::abs(first[i]) < 1e-8, "MIDI note played too early");
            }
            require(peak > 1e-5, "note produced no audio");
            if (rate == FS) {
                const auto onset = std::find_if(first.begin(), first.end(),
                    [](float value) { return std::abs(value) > 1e-8; });
                require(onset - first.begin() < 128 + 2 * CTL, "excess MIDI-to-audio delay");
            }
            for (const auto block : {1u, 15u, 16u, 17u, 127u, 128u, 255u, 256u, 511u, 1024u}) {
                a.render(block);
                const auto silence = b.render(block);
                require(std::all_of(silence.begin(), silence.end(),
                    [](float value) { return std::abs(value) < 1e-8; }), "voices/effects leak between instances");
            }
            check(MusicDeviceMIDIEvent(a.unit, 0x80, 60, 0, 0), "note off");
            set(a.unit, kOberVavePan, 1);
            auto panned = a.render(512);
            require(std::all_of(panned.begin(), panned.end(),
                [](float value) { return value == 0; }), "master pan not applied");
            Float64 latency = -1;
            size = sizeof(latency);
            check(AudioUnitGetProperty(a.unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global,
                0, &latency, &size), "latency");
            require(std::abs(latency - (rate == FS ? 0 : 16.0 / FS)) < 1e-9, "wrong reported latency");
            std::cout << "PASS " << rate << " Hz: MIDI offsets, stereo render, irregular blocks, "
                         "instance isolation, state restore, pan, latency\n";
        }
        for (const double rate : {44100., 48000., 96000.}) {
            for (const bool release : {false, true}) {
                Unit reference(component, rate), starting(component, rate);
                for (auto* unit : {&reference, &starting}) {
                    unit->sync(120);
                    unit->playing = false;
                    set(unit->unit, P_ARP_MODE, A_OFF);
                    set(unit->unit, P_AR, 0);
                    set(unit->unit, P_REV_MIX, 100);
                    set(unit->unit, P_DLY_MIX, 100);
                    set(unit->unit, P_DLY_FB, 100);
                    check(MusicDeviceMIDIEvent(unit->unit, 0x90, 60, 100, 0), "pre-play note");
                    for (unsigned i = 0; i < 80; ++i) unit->render(512);
                    if (release) {
                        check(MusicDeviceMIDIEvent(unit->unit, 0x80, 60, 0, 0), "tail note off");
                        for (unsigned i = 0; i < 20; ++i) unit->render(512);
                    }
                }
                check(AudioUnitReset(starting.unit, kAudioUnitScope_Global, 0), "host reset before Play");
                starting.playing = true;
                starting.transportChanged = true;
                // Logic may restart the host sample timeline together with Play.
                starting.time.mSampleTime = 0;
                bool audible = false;
                for (unsigned block = 0; block < 80; ++block) {
                    const auto expected = reference.render(511);
                    const auto actual = starting.render(511);
                    require(actual == expected, "Play/reset cut voices or altered effect tails");
                    audible |= std::any_of(actual.begin(), actual.end(),
                        [](float value) { return std::abs(value) > 1e-8; });
                }
                require(audible, "Play tail test had no sound to preserve");
            }
        }
        std::cout << "PASS Play and host Reset preserve held voices and effect tails at 44.1/48/96 kHz\n";
        for (const auto latch : {0.f, 1.f, 2.f}) {
            for (const bool arpeggiator : {false, true}) {
                Unit a(component, 44100);
                a.sync(120);
                set(a.unit, P_ARP_MODE, arpeggiator ? A_UP : A_OFF);
                set(a.unit, P_ARP_LATCH, latch);
                set(a.unit, kOberVaveSync, 0);
                set(a.unit, P_AR, 0);
                set(a.unit, P_CHO_MIX, 0);
                set(a.unit, P_DLY_MIX, 0);
                set(a.unit, P_REV_MIX, 0);
                check(MusicDeviceMIDIEvent(a.unit, 0x90, 60, 100, 0), "transport note");
                check(MusicDeviceMIDIEvent(a.unit, 0xB0, 64, 127, 0), "transport sustain");
                a.render(512);
                check(MusicDeviceMIDIEvent(a.unit, 0x90, 67, 100, 4000), "future transport note");
                a.playing = false;
                a.render(512);
                for (unsigned i = 0; i < 100; ++i) a.render(512);
                for (unsigned i = 0; i < 100; ++i) {
                    const auto audio = a.render(512);
                    require(std::all_of(audio.begin(), audio.end(),
                        [](float value) { return std::abs(value) < 1e-8; }),
                        "DAW Stop left notes playing or allowed queued notes to restart");
                }
                require(get(a.unit, P_ARP_LATCH) == latch, "DAW Stop disabled Latch");
                // Live input while stopped must remain usable.
                check(MusicDeviceMIDIEvent(a.unit, 0x90, 64, 100, 0), "live input while stopped");
                bool audible = false;
                for (unsigned i = 0; i < 30; ++i) {
                    const auto audio = a.render(512);
                    audible |= std::any_of(audio.begin(), audio.end(),
                        [](float value) { return std::abs(value) > 1e-8; });
                }
                require(audible, "DAW Stop disabled subsequent live input");
                a.transportChanged = true;
                a.render(512);
            }
        }
        std::cout << "PASS DAW Stop clears notes, latch/sustain and future events without disabling live input\n";
        for (const double tempo : {90., 120., 180.}) {
            Unit a(component, 44100);
            a.sync(tempo);
            set(a.unit, P_ARP_MODE, A_UP);
            set(a.unit, P_AA, 0);
            set(a.unit, kOberVaveSync, 1);
            set(a.unit, kOberVaveGrid, 2);
            check(MusicDeviceMIDIEvent(a.unit, 0x90, 60, 100, 0), "arp note");
            std::vector<float> audio;
            for (unsigned i = 0; i < 80; ++i) {
                const auto block = a.render(256);
                audio.insert(audio.end(), block.begin(), block.end());
            }
            const auto first = std::find_if(audio.begin(), audio.end(),
                [](float value) { return std::abs(value) > 1e-8; });
            const double onset = first - audio.begin();
            const double boundary = 0.5 * 60 * FS / tempo;
            require(onset >= boundary - CTL && onset < boundary + 3 * CTL,
                "arpeggio does not start on host quarter-note grid");
            std::cout << "PASS host sync " << tempo << " BPM: onset " << onset
                      << ", expected " << boundary << " samples\n";
        }
        {
            Unit a(component, 44100), b(component, 44100);
            for (const auto effective : {UInt32(P_ARP_MODE), UInt32(P_ARP_LATCH)}) {
                const auto selection = UInt32(effective == P_ARP_MODE ?
                    kOberVaveArpSelection : kOberVaveLatchSelection);
                const auto mode = effective == P_ARP_MODE ? float(A_DOWN) : 2.f;
                set(a.unit, effective, 0);
                set(a.unit, selection, mode);
                require(get(a.unit, effective) == 0, "mode menu enabled a disabled feature");
                require(get(a.unit, selection) == mode, "mode selection was not remembered");
                set(a.unit, effective, get(a.unit, selection));
                set(a.unit, selection, 1);
                require(get(a.unit, effective) == 1, "enabled feature did not follow mode selection");
                set(a.unit, effective, 0);
                require(get(a.unit, selection) == 1, "disabling feature erased its selected mode");
                set(a.unit, selection, mode);
            }
            CFPropertyListRef state = nullptr;
            UInt32 size = sizeof(state);
            check(AudioUnitGetProperty(a.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, &size), "save disabled modes");
            check(AudioUnitSetProperty(b.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, sizeof(state)), "restore disabled modes");
            CFRelease(state);
            require(get(b.unit, P_ARP_MODE) == 0 && get(b.unit, P_ARP_LATCH) == 0 &&
                get(b.unit, kOberVaveArpSelection) == A_DOWN && get(b.unit, kOberVaveLatchSelection) == 2,
                "disabled mode selections did not survive project restore");
            set(a.unit, P_ARP_MODE, A_PLAY);
            set(a.unit, P_ARP_LATCH, 2);
            size = sizeof(state);
            check(AudioUnitGetProperty(a.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &state, &size), "save legacy compatibility fixture");
            const auto legacy = CFDictionaryCreateMutableCopy(nullptr, 0, static_cast<CFDictionaryRef>(state));
            const auto data = CFDataCreateMutableCopy(nullptr, 0,
                static_cast<CFDataRef>(CFDictionaryGetValue(legacy, CFSTR("data"))));
            require(CFDataGetLength(data) == 12 + kOberVaveParameterCount * 8, "unexpected preset shape");
            CFDataSetLength(data, 12 + kOberVaveArpSelection * 8);
            const UInt32 count = CFSwapInt32HostToBig(kOberVaveArpSelection);
            std::memcpy(CFDataGetMutableBytePtr(data) + 8, &count, sizeof(count));
            CFDictionarySetValue(legacy, CFSTR("data"), data);
            CFPropertyListRef legacyState = legacy;
            set(b.unit, kOberVaveModulationBase, MS_LFO);
            set(b.unit, kOberVaveModulationBase + 2, 128);
            set(b.unit, kOberVaveLegacyWheel, 0);
            check(AudioUnitSetProperty(b.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global,
                0, &legacyState, sizeof(legacyState)), "restore old 70-parameter preset");
            CFRelease(data);
            CFRelease(legacy);
            CFRelease(state);
            require(get(b.unit, P_ARP_MODE) == A_PLAY && get(b.unit, P_ARP_LATCH) == 2 &&
                get(b.unit, kOberVaveArpSelection) == A_PLAY && get(b.unit, kOberVaveLatchSelection) == 2,
                "legacy preset lost selected modes");
            require(get(b.unit, kOberVaveModulationBase) == MS_OFF &&
                get(b.unit, kOberVaveModulationBase + 2) == 64 &&
                get(b.unit, kOberVaveLegacyWheel) == 1,
                "legacy preset inherited stale matrix or lost legacy wheel sound");
            std::cout << "PASS separate enable/mode controls and saved disabled selections\n";
        }
        {
            for (const auto latch : {1.f, 2.f}) {
                Unit a(component, 44100);
                set(a.unit, P_ARP_MODE, A_UP);
                set(a.unit, P_ARP_LATCH, latch);
                set(a.unit, kOberVaveSync, 0);
                set(a.unit, P_AR, 0);
                set(a.unit, P_CHO_MIX, 0);
                set(a.unit, P_DLY_MIX, 0);
                set(a.unit, P_REV_MIX, 0);
                check(MusicDeviceMIDIEvent(a.unit, 0x90, 60, 100, 0), "latch note on");
                a.render(512);
                check(MusicDeviceMIDIEvent(a.unit, 0x80, 60, 0, 0), "latch note off");
                for (unsigned i = 0; i < 100; ++i) a.render(512);
                OberVaveMeters meter{};
                UInt32 size = sizeof(meter);
                check(AudioUnitGetProperty(a.unit, kOberVaveMeters, kAudioUnitScope_Global, 0,
                    &meter, &size), "latched meters");
                require(meter.left > 0, "latch failed to keep playing after note off");
                check(MusicDeviceMIDIEvent(a.unit, 0xB0, 64, 127, 0), "sustain down");
                a.render(512);
                check(MusicDeviceMIDIEvent(a.unit, 0xB0, 64, 0, 0), "sustain up");
                for (unsigned i = 0; i < 100; ++i) a.render(512);
                for (unsigned i = 0; i < 100; ++i) {
                    const auto stopped = a.render(512);
                    require(std::all_of(stopped.begin(), stopped.end(),
                        [](float value) { return std::abs(value) < 1e-8; }),
                        "MIDI Sustain release did not stop latched arpeggio");
                }
                require(get(a.unit, P_ARP_LATCH) == latch, "MIDI Sustain release disabled Latch");
                check(MusicDeviceMIDIEvent(a.unit, 0x90, 60, 100, 0), "restart latched note");
                a.render(512);
                check(MusicDeviceMIDIEvent(a.unit, 0x80, 60, 0, 0), "release restarted note");
                a.render(512);
                set(a.unit, P_ARP_LATCH, 0);
                for (unsigned i = 0; i < 100; ++i) a.render(512);
                for (unsigned i = 0; i < 100; ++i) {
                    const auto stopped = a.render(512);
                    require(std::all_of(stopped.begin(), stopped.end(),
                        [](float value) { return std::abs(value) < 1e-8; }),
                        "Latch Off did not stop released arpeggio notes");
                }
            }
            std::cout << "PASS AU Latch Add/Replace to Off stops released arpeggio notes\n";
        }
        {
            Unit a(component, 44100);
            set(a.unit, P_ARP_MODE, A_OFF);
            OberVaveKeyboardEvent event{0x90, 60, 100};
            check(AudioUnitSetProperty(a.unit, kOberVaveKeyboard, kAudioUnitScope_Global, 0,
                &event, sizeof(event)), "editor keyboard event");
            a.render(1024);
            OberVaveMeters meter{};
            UInt32 size = sizeof(meter);
            check(AudioUnitGetProperty(a.unit, kOberVaveMeters, kAudioUnitScope_Global, 0,
                &meter, &size), "editor meters");
            require(meter.left > 0 && meter.right > 0, "keyboard did not produce metered audio");
            require(std::any_of(std::begin(meter.voices), std::end(meter.voices),
                [](float value) { return value > 0; }), "voice LEDs missing");
            check(AudioUnitGetProperty(a.unit, kOberVaveMeters, kAudioUnitScope_Global, 0,
                &meter, &size), "consume meter");
            require(meter.left == 0 && meter.right == 0, "meters did not reset after reading");
            event = {0x80, 60, 0};
            check(AudioUnitSetProperty(a.unit, kOberVaveKeyboard, kAudioUnitScope_Global, 0,
                &event, sizeof(event)), "editor note off");
            a.render(1024);
            std::cout << "PASS editor keyboard-to-audio queue, stereo meters and voice levels\n";
        }
        CFRelease(bundle);
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n'; return 1;
    }
}
