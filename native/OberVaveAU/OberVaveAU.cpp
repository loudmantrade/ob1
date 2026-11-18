// SPDX-License-Identifier: GPL-3.0-only
#include <AudioUnitSDK/MusicDeviceBase.h>
#include <AudioUnitSDK/AUPlugInDispatch.h>
#include <array>
#include <atomic>
#include <memory>
#include "Engine.h"
#include "UIBridge.h"

namespace {
using namespace obervave;
constexpr UInt32 kProgram = NPARAM, kMaster = NPARAM + 1, kPan = NPARAM + 2;
constexpr UInt32 kSync = NPARAM + 3, kGrid = NPARAM + 4;
constexpr UInt32 kArpSelection = NPARAM + 5, kLatchSelection = NPARAM + 6, kCount = NPARAM + 7;
constexpr UInt32 kPrograms = NFACT + NVIBE;
static_assert(kProgram == kOberVaveProgram && kCount == kOberVaveParameterCount);
constexpr unsigned kTaps = 32, kPhases = 1024;
constexpr double kResampleDelay = 16.0;
const char* const names[] = {
    "OSC 1 Wave", "OSC 1 Pulse Width", "OSC 1 Level", "Noise",
    "OSC 2 Wave", "OSC 2 Pulse Width", "OSC 2 Level", "OSC 2 Semitone",
    "Oscillator Sync", "Cross Mod", "Envelope to OSC 2", "OSC 2 Fine",
    "Filter Cutoff", "Filter Resonance", "Filter Envelope Amount", "Filter Key Tracking", "Filter Type",
    "Filter Drive", "Velocity to Filter", "Velocity to Amp",
    "Filter Attack", "Filter Decay", "Filter Sustain", "Filter Release",
    "Amp Attack", "Amp Decay", "Amp Sustain", "Amp Release",
    "LFO Shape", "LFO Rate", "LFO Delay", "LFO Phase",
    "LFO Pitch", "LFO Pulse Width", "LFO Filter", "LFO Amp", "LFO Pitch Target", "LFO PWM Target",
    "Voice Mode", "Unison Voices", "Unison Detune", "Glide",
    "Vintage", "Stereo Spread", "Pitch Bend Range", "Patch Volume", "Mod Wheel Depth",
    "Arp Mode", "Arp Division", "Arp Octaves", "Arp Gate", "FM Morph",
    "Chorus Rate", "Chorus Depth", "Chorus Mix", "Delay Time", "Delay Feedback", "Delay Tone", "Delay Mix",
    "Reverb Size", "Reverb Damping", "Reverb Pre-delay", "Reverb Mix", "Arp Latch", "Arp Velocity",
    "Factory Program", "Master Volume", "Master Pan", "Arp Master Sync", "Arp Start Grid",
    "Arp Selected Mode", "Latch Selected Mode"
};
static_assert(sizeof(names) / sizeof(*names) == kCount);

const factory_t& factory(UInt32 index)
{
    return index < NFACT ? FACTORY[index] : FACT_VIBE[index - NFACT];
}

class OberVaveAU final : public ausdk::MusicDeviceBase {
public:
    explicit OberVaveAU(AudioUnit instance) : MusicDeviceBase(instance, 0, 1)
    {
        CreateElements();
        Globals()->UseIndexedParameters(kCount);
        for (UInt32 i = 0; i < kCount; ++i) store(i, 0);
        store(kArpSelection, A_UP);
        store(kLatchSelection, 1);
        for (UInt32 i = 0; i < NPARAM; ++i) store(i, PDEF[i].def);
        loadProgram(17);
        store(kMaster, 1);
        store(kSync, 1);
        store(kGrid, 2);
    }

    bool CanScheduleParameters() const override { return false; }
    OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope,
                             AudioUnitElement bus, UInt32& size, bool& writable) override
    {
        if (id == kAudioUnitProperty_CocoaUI || id == kOberVaveMeters || id == kOberVaveKeyboard) {
            if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (bus != 0) return kAudioUnitErr_InvalidElement;
            size = id == kAudioUnitProperty_CocoaUI ? sizeof(AudioUnitCocoaViewInfo) :
                id == kOberVaveMeters ? sizeof(OberVaveMeters) : sizeof(OberVaveKeyboardEvent);
            writable = id == kOberVaveKeyboard;
            return noErr;
        }
        return MusicDeviceBase::GetPropertyInfo(id, scope, bus, size, writable);
    }
    OSStatus GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement bus,
                         void* data) override
    {
        if (scope == kAudioUnitScope_Global && bus == 0) {
            if (id == kAudioUnitProperty_CocoaUI) return OberVaveCocoaViewInfo(data);
            if (id == kOberVaveMeters) {
                auto& meter = *static_cast<OberVaveMeters*>(data);
                meter.left = peaks[0].exchange(0);
                meter.right = peaks[1].exchange(0);
                for (unsigned i = 0; i < 8; ++i) meter.voices[i] = voiceLevels[i].load();
                meter.tempo = displayTempo.load();
                meter.hostClock = displayHostClock.load();
                return noErr;
            }
        }
        return MusicDeviceBase::GetProperty(id, scope, bus, data);
    }
    OSStatus SetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement bus,
                         const void* data, UInt32 size) override
    {
        if (id != kOberVaveKeyboard)
            return MusicDeviceBase::SetProperty(id, scope, bus, data, size);
        if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        if (size != sizeof(OberVaveKeyboardEvent)) return kAudioUnitErr_InvalidPropertyValue;
        const auto event = *static_cast<const OberVaveKeyboardEvent*>(data);
        if (event.status < 0x80 || event.status >= 0xF0 || event.data1 > 127 || event.data2 > 127)
            return kAudioUnitErr_InvalidPropertyValue;
        const auto write = keyWrite.load(std::memory_order_relaxed);
        if (write - keyRead.load(std::memory_order_acquire) == keyboard.size())
            return kAudioUnitErr_CannotDoInCurrentContext;
        keyboard[write % keyboard.size()] = event;
        keyWrite.store(write + 1, std::memory_order_release);
        return noErr;
    }
    bool StreamFormatWritable(AudioUnitScope scope, AudioUnitElement bus) override
    {
        return scope == kAudioUnitScope_Output && bus == 0;
    }
    UInt32 SupportedNumChannels(const AUChannelInfo** info) override
    {
        static const AUChannelInfo channels{0, 2};
        if (info) *info = &channels;
        return 1;
    }
    bool ValidFormat(AudioUnitScope scope, AudioUnitElement bus,
                     const AudioStreamBasicDescription& format) override
    {
        return scope == kAudioUnitScope_Output && bus == 0 && format.mChannelsPerFrame == 2 &&
            format.mSampleRate >= 22050 && format.mSampleRate <= 192000 &&
            AUBase::ValidFormat(scope, bus, format);
    }

    OSStatus GetParameterInfo(AudioUnitScope scope, AudioUnitParameterID id,
                             AudioUnitParameterInfo& info) override
    {
        if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
        if (id >= kCount) return kAudioUnitErr_InvalidParameter;
        info = {};
        auto name = CFStringCreateWithCString(nullptr, names[id], kCFStringEncodingUTF8);
        FillInParameterName(info, name, true);
        info.flags |= kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable;
        if (id == kProgram || id == P_ARP_MODE || id == P_ARP_LATCH ||
            id == kArpSelection || id == kLatchSelection)
            info.flags |= kAudioUnitParameterFlag_IsGlobalMeta;
        info.unit = kAudioUnitParameterUnit_Indexed;
        info.minValue = minimum(id);
        info.maxValue = maximum(id);
        info.defaultValue = id < NPARAM ? PDEF[id].def :
            id == kProgram ? 17 : id == kGrid ? 2 :
            id == kMaster || id == kSync || id == kArpSelection || id == kLatchSelection ? 1 : 0;
        if (id == kMaster) info.unit = kAudioUnitParameterUnit_LinearGain;
        if (id == kPan) info.unit = kAudioUnitParameterUnit_Pan;
        return noErr;
    }
    OSStatus GetParameterList(AudioUnitScope scope, AudioUnitParameterID* list,
                             UInt32& count) override
    {
        if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
        count = kCount;
        if (list) for (UInt32 i = 0; i < count; ++i) list[i] = i;
        return noErr;
    }
    OSStatus GetParameter(AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement bus,
                         AudioUnitParameterValue& value) override
    {
        if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        if (id >= kCount) return kAudioUnitErr_InvalidParameter;
        value = values[id].load(std::memory_order_relaxed);
        return noErr;
    }
    OSStatus SetParameter(AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement bus,
                         AudioUnitParameterValue value, UInt32) override
    {
        if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        if (id >= kCount || !std::isfinite(value)) return kAudioUnitErr_InvalidParameter;
        value = std::clamp(value, minimum(id), maximum(id));
        if (id != kMaster && id != kPan) value = std::round(value);
        if (id == kProgram) loadProgram(UInt32(value));
        else {
            store(id, value);
            if (id == kArpSelection || id == kLatchSelection) {
                const auto effective = id == kArpSelection ? P_ARP_MODE : P_ARP_LATCH;
                if (values[effective].load() != 0) store(effective, value);
            }
        }
        return noErr;
    }
    OSStatus GetParameterValueStrings(AudioUnitScope scope, AudioUnitParameterID id,
                                      CFArrayRef* strings) override
    {
        if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
        const char* const* options = nullptr;
        UInt32 count = 0;
        static const char* const grid[] = {"1/1", "1/2", "1/4", "1/8", "1/16", "1/32"};
        if (id == kProgram) count = kPrograms;
        else if (id == kArpSelection) { options = ARP_NAME + 1; count = NARPMODE - 1; }
        else if (id == kLatchSelection) { options = LATCH_NAME + 1; count = 2; }
        else if (id == kGrid) { options = grid; count = 6; }
        else if (id < NPARAM) {
            switch (PDEF[id].kind) {
            case K_WAVE: options = WAVE_NAME; count = 4; break;
            case K_FTYPE: options = FTYPE_NAME; count = NFTYPE; break;
            case K_MODE: options = MODE_NAME; count = 4; break;
            case K_ARP: options = ARP_NAME; count = NARPMODE; break;
            case K_DIV: options = DIV_NAME; count = NDIV; break;
            case K_LSHAPE: options = LSHAPE_NAME; count = 6; break;
            case K_LPHASE: options = LPHASE_NAME; count = 3; break;
            case K_TO: options = TO_NAME; count = 3; break;
            case K_DDIV: options = DDIV_NAME; count = NDDIV; break;
            case K_LATCH: options = LATCH_NAME; count = 3; break;
            default: return kAudioUnitErr_InvalidProperty;
            }
        } else return kAudioUnitErr_InvalidProperty;
        if (!strings) return noErr;
        auto array = CFArrayCreateMutable(nullptr, count, &kCFTypeArrayCallBacks);
        for (UInt32 i = 0; i < count; ++i) {
            auto text = CFStringCreateWithCString(nullptr,
                id == kProgram ? factory(i).name : options[i], kCFStringEncodingUTF8);
            CFArrayAppendValue(array, text);
            CFRelease(text);
        }
        *strings = array;
        return noErr;
    }

    OSStatus RestoreState(CFPropertyListRef state) override
    {
        bool hasArpSelection = false, hasLatchSelection = false;
        if (!state || CFGetTypeID(state) != CFDictionaryGetTypeID())
            return kAudioUnitErr_InvalidPropertyValue;
        const auto data = static_cast<CFDataRef>(
            CFDictionaryGetValue(static_cast<CFDictionaryRef>(state), CFSTR("data")));
        if (data) {
            if (CFGetTypeID(data) != CFDataGetTypeID())
                return kAudioUnitErr_InvalidPropertyValue;
            const auto* cursor = CFDataGetBytePtr(data);
            auto remaining = CFDataGetLength(data);
            const auto word = [&cursor, &remaining]() {
                UInt32 value;
                std::memcpy(&value, cursor, sizeof(value));
                cursor += sizeof(value);
                remaining -= sizeof(value);
                return CFSwapInt32BigToHost(value);
            };
            while (remaining) {
                if (remaining < 12) return kAudioUnitErr_InvalidPropertyValue;
                const auto scope = word(), element = word(), count = word();
                if (scope != kAudioUnitScope_Global || element != 0 ||
                    count > kCount || remaining < CFIndex(count * 8))
                    return kAudioUnitErr_InvalidPropertyValue;
                for (UInt32 i = 0; i < count; ++i) {
                    const auto id = word(), bits = word();
                    if (id == kArpSelection) hasArpSelection = true;
                    if (id == kLatchSelection) hasLatchSelection = true;
                    float value;
                    std::memcpy(&value, &bits, sizeof(value));
                    if (id >= kCount || !std::isfinite(value) ||
                        value < minimum(id) || value > maximum(id))
                        return kAudioUnitErr_InvalidPropertyValue;
                }
            }
        }
        store(kArpSelection, A_UP);
        store(kLatchSelection, 1);
        const auto status = MusicDeviceBase::RestoreState(state);
        if (status != noErr) return status;
        if (!hasArpSelection) Globals()->SetParameter(kArpSelection,
            std::max(1.f, Globals()->GetParameter(P_ARP_MODE)));
        if (!hasLatchSelection) Globals()->SetParameter(kLatchSelection,
            std::max(1.f, Globals()->GetParameter(P_ARP_LATCH)));
        for (UInt32 id = 0; id < kCount; ++id) {
            const auto value = Globals()->GetParameter(id);
            if (!std::isfinite(value) || value < minimum(id) || value > maximum(id))
                return kAudioUnitErr_InvalidPropertyValue;
        }
        for (UInt32 id = 0; id < kCount; ++id)
            values[id].store(Globals()->GetParameter(id), std::memory_order_relaxed);
        return noErr;
    }

    OSStatus Initialize() override
    {
        const auto status = MusicDeviceBase::Initialize();
        if (status != noErr) return status;
        rate = GetStreamFormat(kAudioUnitScope_Output, 0).mSampleRate;
        resetEngine();
        makeFilter();
        return noErr;
    }
    OSStatus Reset(AudioUnitScope scope, AudioUnitElement bus) override
    {
        const auto status = MusicDeviceBase::Reset(scope, bus);
        // Hosts reset the render timeline on Play; this is not a musical Stop.
        // Keep voices, effects and the continuous resampler timeline intact.
        if (status == noErr) eventCount = 0;
        return status;
    }
    Float64 GetLatency() override { return rate == FS ? 0 : kResampleDelay / FS; }
    bool SupportsTail() override { return true; }
    Float64 GetTailTime() override { return 20; }

    OSStatus MIDIEvent(UInt32 status, UInt32 d1, UInt32 d2, UInt32 offset) override
    {
        if (d1 > 127 || d2 > 127 || status < 0x80 || status >= 0xF0)
            return kAudioUnitErr_InvalidParameter;
        if (eventCount == events.size()) return kAudioUnitErr_CannotDoInCurrentContext;
        Event event{position + double(offset) * FS / rate,
                    uint8_t(status), uint8_t(d1), uint8_t(d2)};
        auto index = eventCount++;
        while (index && events[index - 1].frame > event.frame) {
            events[index] = events[index - 1]; --index;
        }
        events[index] = event;
        return noErr;
    }
    OSStatus Render(AudioUnitRenderActionFlags& flags, const AudioTimeStamp&,
                    UInt32 frames) override
    {
        if (!engine) return kAudioUnitErr_Uninitialized;
        auto& buffers = Output(0).GetBufferList();
        if (buffers.mNumberBuffers != 2) return kAudioUnitErr_FormatNotSupported;
        auto* left = static_cast<float*>(buffers.mBuffers[0].mData);
        auto* right = static_cast<float*>(buffers.mBuffers[1].mData);
        for (UInt32 i = 0; i < NPARAM; ++i)
            engine->apply_parameter(i, UInt32(values[i].load(std::memory_order_relaxed)));
        auto read = keyRead.load(std::memory_order_relaxed);
        const auto write = keyWrite.load(std::memory_order_acquire);
        for (; read != write; ++read) {
            const auto event = keyboard[read % keyboard.size()];
            const auto status = MIDIEvent(event.status, event.data1, event.data2, 0);
            if (status != noErr) return status;
        }
        keyRead.store(read, std::memory_order_release);
        Boolean playing = false, changed = false, cycling = false;
        Float64 timeline = 0, cycleStart = 0, cycleEnd = 0;
        if (CallHostTransportState(&playing, &changed, &timeline, &cycling,
                                  &cycleStart, &cycleEnd) == noErr) {
            if (!playing && (hostWasPlaying || changed)) {
                engine->engine_transport_stop();
                eventCount = 0;
            }
            hostWasPlaying = playing;
        }
        engine->ctl_arp_sync = values[kSync].load() != 0;
        engine->ctl_arp_sync_grid = UInt32(values[kGrid].load());
        double beat = 0, tempo = 120;
        engine->hostClock = CallHostBeatAndTempo(&beat, &tempo) == noErr &&
            std::isfinite(beat) && std::isfinite(tempo) && tempo >= 40 && tempo <= 240;
        if (engine->hostClock) {
            engine->hostBeat = beat + (double(generated) - position) * tempo / (60.0 * FS);
            engine->hostTempo = tempo;
            engine->hostFrame = engine->eng_t;
            engine->ctl_tempo = UInt32(std::round(tempo));
            engine->ctl_ext_quarter = UInt32(std::round(60.0 * FS / tempo));
        } else engine->ctl_ext_quarter = 0;
        displayTempo.store(engine->hostClock ? tempo : 120);
        displayHostClock.store(engine->hostClock);
        const float master = values[kMaster].load();
        const float pan = values[kPan].load();
        const float lg = master * (pan > 0 ? std::sqrt(1 - pan) : 1);
        const float rg = master * (pan < 0 ? std::sqrt(1 + pan) : 1);
        float peakLeft = 0, peakRight = 0;
        for (UInt32 i = 0; i < frames; ++i) {
            const auto sample = int64_t(std::floor(position));
            while (int64_t(generated) <= sample) generateBlock();
            float l = 0, r = 0;
            if (rate == FS) {
                l = history[0][sample & 63]; r = history[1][sample & 63];
            } else {
                const auto phase = std::min(unsigned((position - sample) * kPhases), kPhases - 1);
                for (unsigned tap = 0; tap < kTaps; ++tap) {
                    if (sample < tap) continue;
                    l += history[0][(sample - tap) & 63] * filter[phase][tap];
                    r += history[1][(sample - tap) & 63] * filter[phase][tap];
                }
            }
            left[i] = l * lg; right[i] = r * rg;
            peakLeft = std::max(peakLeft, std::abs(left[i]));
            peakRight = std::max(peakRight, std::abs(right[i]));
            position += double(FS) / rate;
        }
        for (unsigned i = 0; i < 2; ++i) {
            const auto peak = i == 0 ? peakLeft : peakRight;
            auto previous = peaks[i].load();
            while (previous < peak && !peaks[i].compare_exchange_weak(previous, peak)) {}
        }
        for (unsigned i = 0; i < 8; ++i)
            voiceLevels[i].store(std::clamp(float(engine->ui_vlevel[i]) / 32767.f, 0.f, 1.f));
        flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

private:
    struct Event { double frame; uint8_t status, d1, d2; };
    std::array<std::atomic<float>, kCount> values{};
    std::unique_ptr<Engine> engine;
    std::array<Event, 2048> events{};
    std::array<OberVaveKeyboardEvent, 256> keyboard{};
    std::atomic<uint32_t> keyRead{0}, keyWrite{0};
    std::atomic<float> peaks[2]{}, voiceLevels[8]{}, displayTempo{120};
    std::atomic<UInt32> displayHostClock{0};
    size_t eventCount = 0;
    double rate = FS, position = 0;
    uint64_t generated = 0;
    bool hostWasPlaying = false;
    float history[2][64]{};
    float filter[kPhases][kTaps]{};

    static float maximum(UInt32 id)
    {
        return id < NPARAM ? PDEF[id].max : id == kProgram ? kPrograms - 1 :
            id == kArpSelection ? NARPMODE - 1 : id == kLatchSelection ? 2 : id == kGrid ? 5 : 1;
    }
    static float minimum(UInt32 id)
    {
        return id == kPan ? -1 : id == kArpSelection || id == kLatchSelection ? 1 : 0;
    }
    void store(UInt32 id, float value)
    {
        values[id].store(value, std::memory_order_relaxed);
        Globals()->SetParameter(id, value);
        if (value != 0 && (id == P_ARP_MODE || id == P_ARP_LATCH))
            store(id == P_ARP_MODE ? kArpSelection : kLatchSelection, value);
    }
    void loadProgram(UInt32 index)
    {
        patch_t patch{};
        patch_from_factory(&patch, &factory(index));
        for (UInt32 i = 0; i < NPARAM; ++i) store(i, patch.v[i]);
        store(kProgram, index);
    }
    void resetEngine()
    {
        engine = std::make_unique<Engine>();
        engine->initialize();
        generated = 0; position = 0; eventCount = 0;
        hostWasPlaying = false;
        for (auto& peak : peaks) peak.store(0);
        for (auto& level : voiceLevels) level.store(0);
        std::memset(history, 0, sizeof(history));
    }
    void generateBlock()
    {
        size_t used = 0;
        while (used < eventCount && events[used].frame <= generated) {
            const auto event = events[used++];
            if ((event.status & 0xF0) == 0xC0 && event.d1 < kPrograms) {
                loadProgram(event.d1);
                for (UInt32 p = 0; p < NPARAM; ++p) engine->apply_parameter(p, UInt32(values[p].load()));
                engine->parts_off(0);
            } else {
                engine->midi(event.status, event.d1, event.d2);
                if ((event.status & 0xF0) == 0xB0)
                    for (UInt32 p = 0; p < NPARAM; ++p)
                        if (PDEF[p].cc && PDEF[p].cc == event.d1) store(p, engine->live_p[0].v[p]);
            }
        }
        if (used) {
            std::move(events.begin() + used, events.begin() + eventCount, events.begin());
            eventCount -= used;
        }
        int32_t block[CTL * 2]{};
        engine->engine_audio(block, CTL);
        for (unsigned i = 0; i < CTL; ++i) {
            history[0][(generated + i) & 63] = block[2 * i] / 32768.f;
            history[1][(generated + i) & 63] = block[2 * i + 1] / 32768.f;
        }
        generated += CTL;
    }
    void makeFilter()
    {
        const double cutoff = std::min(1.0, rate / FS) * 0.94;
        constexpr double pi = 3.14159265358979323846;
        for (unsigned phase = 0; phase < kPhases; ++phase) {
            double sum = 0;
            for (unsigned tap = 0; tap < kTaps; ++tap) {
                const double x = double(tap) - kResampleDelay + double(phase) / kPhases;
                const double sinc = std::abs(x) < 1e-10 ? cutoff : std::sin(pi * cutoff * x) / (pi * x);
                const double window = 0.5 + 0.5 * std::cos(pi * x / kResampleDelay);
                filter[phase][tap] = std::abs(x) <= kResampleDelay ? sinc * window : 0;
                sum += filter[phase][tap];
            }
            for (auto& coefficient : filter[phase]) coefficient /= sum;
        }
    }
};
} // namespace

extern "C" __attribute__((visibility("default")))
void* OberVaveFactory(const AudioComponentDescription* description)
{
    return ausdk::AUMIDIEffectFactory<OberVaveAU>::Factory(description);
}
