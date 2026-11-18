// SPDX-License-Identifier: GPL-3.0-only
#include "OberVave-Bridging-Header.h"
#include "../../native/OberVave/Engine.h"
#include "../../native/Musical/Routing.h"
#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <new>

namespace rack {
using namespace obervave;
namespace music = ob1::music;
constexpr uint32_t capacity = OV_RACK_CAPACITY;
constexpr uint32_t queueSize = 4096;
static_assert(NPARAM == OV_RACK_PARAMETERS);
static_assert(capacity == music::instrumentCapacity);

const factory_t* program(uint32_t index)
{
    if (index >= 768 || index / 128) return &FACT_INIT;
    if (index < NFACT) return &FACTORY[index];
    return index - NFACT < NVIBE ? &FACT_VIBE[index - NFACT] : &FACT_INIT;
}

std::array<uint8_t, NPARAM> defaultCCs()
{
    std::array<uint8_t, NPARAM> result;
    result.fill(255);
    for (uint32_t p = 0; p < NPARAM; ++p)
        if (PDEF[p].cc) result[p] = PDEF[p].cc;
    uint32_t next = 20;
    for (uint32_t p = 0; p < P_MOD1_SRC; ++p) {
        if (PDEF[p].cc) continue;
        while (next < 120 &&
               (next == 64 || std::find(result.begin(), result.end(), next) != result.end())) ++next;
        if (next < 120) result[p] = next++;
    }
    return result;
}
const auto defaults = defaultCCs();

struct Clock {
    uint32_t frame = 0, bpm = 120, quarter = 0, anchor = 0, phaseTick = 0;
    uint32_t ticks = 0, start = 0, last = 0, historyCount = 0, historyNext = 0;
    std::array<uint32_t, 5> history {};
    bool external = false;

    uint32_t length() const { return quarter ? quarter : (60 * FS / bpm + 24) / 48 * 48; }
    void release()
    {
        if (quarter) bpm = std::clamp((60 * FS + quarter / 2) / quarter, 40u, 240u);
        quarter = ticks = historyCount = historyNext = 0;
        external = false;
    }
    void midi(uint8_t status)
    {
        if (status == 0xFC) { release(); return; }
        if (status == 0xFA || status == 0xFB) {
            ticks = phaseTick = 0;
            start = anchor = frame;
            external = true;
            return;
        }
        if (status != 0xF8) return;
        if (!external || !ticks || frame - last > FS / 4) {
            phaseTick = 0;
            anchor = frame;
            external = true;
        } else {
            uint32_t expected;
            if (phaseTick == 95) {
                phaseTick = 0;
                anchor += length() * 4;
                expected = anchor;
            } else {
                ++phaseTick;
                expected = anchor + uint32_t(uint64_t(phaseTick) * length() / 24);
            }
            anchor += int32_t(frame - expected) / 8;
        }
        if (!ticks || frame - last > FS / 4) { ticks = 1; start = frame; }
        else if (++ticks == 25) {
            const auto measured = frame - start;
            if (measured >= FS / 5 && measured <= FS * 8 / 5) {
                history[historyNext] = measured;
                historyNext = (historyNext + 1) % history.size();
                historyCount = std::min(historyCount + 1, uint32_t(history.size()));
                auto sorted = history;
                std::sort(sorted.begin(), sorted.begin() + historyCount);
                const auto median = sorted[historyCount / 2];
                quarter = quarter ? uint32_t(int32_t(quarter) + (int32_t(median) - int32_t(quarter)) / 4) : median;
            }
            ticks = 1;
            start = frame;
        }
        last = frame;
    }
};

struct Timing {
    uint32_t frame, quarter;
    double beat;
    int32_t advance;
};

// New engines implement this contract and add a factory entry; routing and clock stay in the rack.
struct SynthEngine {
    virtual ~SynthEngine() = default;
    virtual void parameter(uint32_t index, uint8_t value) = 0;
    virtual uint8_t parameter(uint32_t index) const = 0;
    virtual bool event(const music::Event& event) = 0;
    virtual void controllerInput(uint8_t status, uint8_t d1, uint8_t d2) = 0;
    virtual bool controllerOverride(uint32_t source) const = 0;
    virtual void stop() = 0;
    virtual void sync(bool enabled, uint32_t grid) = 0;
    virtual void render(const Timing& timing, int32_t* output) = 0;
    virtual uint32_t voiceLevel(uint32_t voice) const = 0;
};

struct OberVaveEngine final : SynthEngine {
    Engine dsp {};
    OberVaveEngine()
    {
        dsp.initialize();
        dsp.livePhaseAdjustment = true;
    }
    void parameter(uint32_t p, uint8_t v) override { dsp.apply_parameter(p, v); }
    uint8_t parameter(uint32_t p) const override { return dsp.live_p[0].v[p]; }
    void controllerInput(uint8_t s, uint8_t d1, uint8_t d2) override { dsp.controller_input(s, d1, d2); }
    bool controllerOverride(uint32_t source) const override { return dsp.controller_override(source); }
    bool event(const music::Event& event) override
    {
        music::MIDIMessage message {};
        if (event.routing.stage != music::Stage::Input ||
            music::encodeMIDI(event, message) != music::EventError::None) return false;
        return midi(message.status, message.data1, message.data2);
    }
    bool midi(uint8_t status, uint8_t d1, uint8_t d2)
    {
        if (!dsp.midi(status, d1, d2, false, false)) return false;
        dsp.engine_events();
        return true;
    }
    void stop() override { dsp.engine_transport_stop(); }
    void sync(bool on, uint32_t grid) override { dsp.ctl_arp_sync = on; dsp.ctl_arp_sync_grid = grid; }
    void render(const Timing& timing, int32_t* out) override
    {
        dsp.ctl_ext_quarter = timing.quarter;
        dsp.hostClock = true;
        dsp.hostBeat = timing.beat;
        dsp.hostTempo = 60.0 * FS / timing.quarter;
        dsp.hostFrame = timing.frame;
        dsp.eng_t = timing.frame - CTL;
        dsp.phaseAdvance = timing.advance;
        // Firmware adds its dry signal to the output; each instance needs a clean bus.
        std::fill_n(out, CTL * 2, 0);
        dsp.render_audio(out, CTL);
    }
    uint32_t voiceLevel(uint32_t voice) const override { return std::clamp(int32_t(dsp.ui_vlevel[voice]), 0, 32767); }
};

struct EngineType {
    uint32_t id;
    const char* name;
    std::unique_ptr<SynthEngine> (*create)();
};
const EngineType engines[] = {
    {OV_ENGINE_OBERVAVE, "OberVave", []() -> std::unique_ptr<SynthEngine> {
        return std::make_unique<OberVaveEngine>();
    }}
};
const EngineType* engineType(uint32_t id)
{
    for (const auto& type : engines) if (type.id == id) return &type;
    return nullptr;
}

struct Retired {
    Retired* next = nullptr;
    virtual ~Retired() = default;
};
struct Instrument final : Retired {
    std::unique_ptr<SynthEngine> engine;
    ov_instrument_config config;
    uint8_t bankMSB = 0, bankLSB = 0;
    int32_t learn = -1;
    uint8_t activeNotes[16][128] {};
    float leftGain = 1, rightGain = 1;
    explicit Instrument(const ov_instrument_config& c) : engine(engineType(c.engine)->create()), config(c)
    {
        for (uint32_t p = 0; p < NPARAM; ++p) engine->parameter(p, c.parameters[p]);
        engine->sync(c.sync, c.grid);
        bankMSB = c.program / 128;
        const float gain = c.muted || c.level_db <= -48 ? 0 : std::pow(10.f, c.level_db / 20);
        leftGain = gain * (c.pan > 0 ? std::sqrt(1 - c.pan) : 1);
        rightGain = gain * (c.pan < 0 ? std::sqrt(1 + c.pan) : 1);
    }
    void stop()
    {
        engine->stop();
        std::memset(activeNotes, 0, sizeof(activeNotes));
    }
};
struct Scene final : Retired {
    std::array<std::unique_ptr<Instrument>, capacity> slots;
};

struct Snapshot {
    std::atomic<uint32_t> peak {0};
    std::array<std::atomic<uint8_t>, NPARAM> parameters {}, cc {};
    std::array<std::atomic<uint32_t>, 8> levels {};
    std::atomic<uint32_t> program {17}, learned {0}, sync {0}, grid {2};
    std::atomic<uint32_t> sequence {0};
};
std::array<Snapshot, capacity> snapshots;
std::atomic<uint32_t> selected {0}, audioFrame {0}, midiBuffer {20};
std::atomic<uint32_t> tempo {120}, internalTempo {120}, externalClock {0}, error {0};
std::atomic<uint32_t> stopGeneration {0};
std::atomic<int32_t> audioAdvance {0}, masterPan {0};
std::atomic<uint32_t> keyboardMask {1}, panic {0}, peakLeft {0}, peakRight {0};
std::atomic<Retired*> retired {nullptr};
std::unique_ptr<Scene> scene;
Clock clock;
music::Frame processedFrames = 0;
ov_scene_config capturedScene {};
std::atomic<uint32_t> captureState {0};
std::array<std::atomic<uint32_t>, 128> keyboardHeld {};
uint8_t midiStatus = 0, midiData[2] {}, midiCount = 0;
std::atomic<uint32_t> keyLearn {0};
std::atomic<uint32_t> controllerLearnSlot {0}, controllerLearned {0};
std::atomic<uint32_t> sustainInverted {0}, sustainInput {0};
std::atomic<uint32_t> sustainDownChannels {0};
std::mutex parserMutex;

enum class Kind { MIDI, Parameter, CC, ResetCC, Learn, Program, Sync, Grid, Route, Add, Remove, Scene, Capture };
struct Command {
    Kind kind = Kind::MIDI;
    uint32_t slot = 0, a = 0, b = 0, c = 0, due = 0;
    bool scheduled = false;
    music::Source source {};
    Retired* object = nullptr;
    ov_instrument_config config {};
};
std::array<Command, queueSize> commands, scheduled;
std::atomic<uint32_t> writeIndex {0}, readIndex {0};
std::mutex producerMutex;
uint32_t scheduledCount = 0;

bool enqueue(const Command& command)
{
    std::lock_guard<std::mutex> lock(producerMutex);
    const auto write = writeIndex.load(std::memory_order_relaxed);
    if (write - readIndex.load(std::memory_order_acquire) == queueSize) {
        error.store(1);
        panic.store(1);
        return false;
    }
    commands[write % queueSize] = command;
    writeIndex.store(write + 1, std::memory_order_release);
    return true;
}
void retire(Retired* object)
{
    if (!object) return;
    auto head = retired.load(std::memory_order_relaxed);
    do { object->next = head; }
    while (!retired.compare_exchange_weak(head, object, std::memory_order_release, std::memory_order_relaxed));
}
void publish(uint32_t slot)
{
    if (!scene->slots[slot]) return;
    const auto& c = scene->slots[slot]->config;
    auto& out = snapshots[slot];
    out.sequence.fetch_add(1);
    for (uint32_t p = 0; p < NPARAM; ++p) {
        out.parameters[p].store(c.parameters[p], std::memory_order_relaxed);
        out.cc[p].store(c.cc[p], std::memory_order_relaxed);
    }
    out.program.store(c.program);
    out.sync.store(c.sync);
    out.grid.store(c.grid);
    out.sequence.fetch_add(1);
}
bool valid(const ov_instrument_config& c)
{
    if (!engineType(c.engine) || c.channel < 1 || c.channel > 16 || c.low_note > c.high_note ||
        c.high_note > 127 || c.program >= 768 || c.sync > 1 || c.grid > 5 || c.muted > 1 ||
        !std::isfinite(c.level_db) || c.level_db < -48 || c.level_db > 0 ||
        !std::isfinite(c.pan) || std::abs(c.pan) > 1) return false;
    for (uint32_t p = 0; p < NPARAM; ++p)
        if (c.parameters[p] > PDEF[p].max || (c.cc[p] > 127 && c.cc[p] != 255)) return false;
    return true;
}
void setProgram(uint32_t slot, uint32_t index)
{
    auto& inst = *scene->slots[slot];
    inst.stop();
    patch_t patch {};
    patch_from_factory(&patch, program(index));
    inst.config.program = index;
    for (uint32_t p = 0; p < NPARAM; ++p) {
        inst.config.parameters[p] = patch.v[p];
        inst.engine->parameter(p, patch.v[p]);
    }
    publish(slot);
}
void stopAll()
{
    for (auto& inst : scene->slots) if (inst) inst->stop();
    sustainDownChannels.store(0);
    stopGeneration.fetch_add(1, std::memory_order_relaxed);
}
void deliver(Instrument& instrument, const music::Event& event)
{
    if (!instrument.engine->event(event)) { error.store(2); panic.store(1); }
}
void routeEvent(const music::Event& event)
{
    music::MIDIMessage message {};
    if (music::encodeMIDI(event, message) != music::EventError::None ||
        event.routing.stage != music::Stage::Input ||
        (event.kind >= music::Kind::Clock && event.routing.target != music::Target::Channel)) {
        error.store(2);
        return;
    }
    const auto status = message.status, d1 = message.data1, d2 = message.data2;
    if (status >= 0xF8) {
        clock.midi(status);
        if (status == 0xFC) {
            internalTempo.store(clock.bpm);
            stopAll(); scheduledCount = 0;
        }
        // Start establishes the common clock, not a forced restart of live notes or FX.
        return;
    }
    const uint32_t channel = status & 15, kind = status & 0xF0;
    uint32_t pedalValue = d2;
    if (kind == 0xB0 && d1 == 64) {
        const uint32_t value = sustainInverted.load() ? 127 - d2 : d2;
        const uint32_t bit = 1u << channel;
        if (value >= 96) sustainDownChannels.fetch_or(bit);
        else if (value <= 31) sustainDownChannels.fetch_and(~bit);
        pedalValue = sustainDownChannels.load() & bit ? 127 : 0;
    }
    for (uint32_t slot = 0; slot < capacity; ++slot) {
        auto* inst = scene->slots[slot].get();
        if (!inst || !music::matches(event, slot,
            {uint8_t(inst->config.channel - 1), uint8_t(inst->config.low_note), uint8_t(inst->config.high_note)}))
            continue;
        const auto routed = music::forInstrument(event, slot);
        const auto source = Engine::controller_source(status, d1);
        const bool overridden = inst->engine->controllerOverride(source);
        if (source) {
            uint32_t armed = slot + 1;
            if (controllerLearnSlot.compare_exchange_strong(armed, 0)) controllerLearned.store(source);
            inst->engine->controllerInput(status, d1, d2);
            for (uint32_t p = 0; p < CONTROLLER_TARGETS; ++p)
                inst->config.parameters[p] = inst->engine->parameter(p);
        }
        if (kind == 0x80 || kind == 0x90) {
            auto& held = inst->activeNotes[channel][d1];
            const bool on = kind == 0x90 && d2;
            if (on) {
                held = 1;
            } else {
                if (!held) continue;
                held = 0;
            }
            deliver(*inst, routed);
        } else if (kind == 0xC0) {
            const auto index = (inst->bankMSB * 128u + inst->bankLSB) * 128u + d1;
            if (index < 768) setProgram(slot, index);
        } else if (kind == 0xB0) {
            if (inst->learn >= 0) {
                inst->config.cc[inst->learn] = d1;
                snapshots[slot].learned.store(((inst->learn + 1) << 8) | (d1 + 1));
                inst->learn = -1;
            }
            if (d1 == 0 && !overridden) inst->bankMSB = d2;
            if (d1 == 32 && !overridden) inst->bankLSB = d2;
            // Handle performance controllers once; the per-patch map is applied below.
            if (d1 == 1 || d1 == 7 || d1 == 64 || d1 == 120 || d1 == 121 || d1 == 123) {
                if ((d1 == 120 || d1 == 123) && !overridden) inst->stop();
                else {
                    auto interpreted = routed;
                    if (d1 == 64) interpreted.data2 = uint8_t(pedalValue);
                    deliver(*inst, interpreted);
                }
            }
            if (!overridden) for (uint32_t p = 0; p < NPARAM; ++p) if (inst->config.cc[p] == d1) {
                const auto value = (uint32_t(d2) * PDEF[p].max + 63) / 127;
                inst->config.parameters[p] = value;
                inst->engine->parameter(p, value);
            }
            publish(slot);
        } else {
            deliver(*inst, routed);
            publish(slot);
        }
    }
}
void apply(const Command& c)
{
    if (c.kind == Kind::Capture) {
        capturedScene = {};
        capturedScene.tempo = tempo.load();
        for (uint32_t s = 0; s < capacity; ++s) if (scene->slots[s]) {
            capturedScene.slots[s].present = 1;
            capturedScene.slots[s].config = scene->slots[s]->config;
        }
        captureState.store(2, std::memory_order_release);
        return;
    }
    if (c.kind == Kind::Scene) {
        stopGeneration.fetch_add(1, std::memory_order_relaxed);
        retire(scene.release());
        scene.reset(static_cast<Scene*>(c.object));
        scheduledCount = 0;
        internalTempo.store(c.a);
        if (!clock.quarter) clock.bpm = c.a;
        for (uint32_t s = 0; s < capacity; ++s) {
            snapshots[s].peak.store(0);
            publish(s);
        }
        return;
    }
    if (c.kind == Kind::MIDI) {
        music::Event event {};
        if (music::decodeMIDI(c.a, c.b, c.c, c.source, {processedFrames}, event) != music::EventError::None)
            error.store(2);
        else routeEvent(event);
        return;
    }
    if (c.slot >= capacity) return;
    auto& pointer = scene->slots[c.slot];
    if (c.kind == Kind::Add || c.kind == Kind::Remove) {
        snapshots[c.slot].peak.store(0);
        retire(pointer.release());
        if (c.kind == Kind::Add) pointer.reset(static_cast<Instrument*>(c.object));
        publish(c.slot);
        return;
    }
    if (!pointer) return;
    auto& inst = *pointer;
    switch (c.kind) {
    case Kind::Parameter:
        inst.config.parameters[c.a] = c.b;
        inst.engine->parameter(c.a, c.b);
        break;
    case Kind::CC: inst.config.cc[c.a] = c.b; break;
    case Kind::ResetCC:
        std::copy(defaults.begin(), defaults.end(), inst.config.cc);
        break;
    case Kind::Learn: inst.learn = int32_t(c.a); break;
    case Kind::Program: setProgram(c.slot, c.a); break;
    case Kind::Sync:
        inst.config.sync = c.a;
        inst.engine->sync(c.a, inst.config.grid);
        break;
    case Kind::Grid:
        inst.config.grid = c.a;
        inst.engine->sync(inst.config.sync, c.a);
        break;
    case Kind::Route:
        if (inst.config.channel != c.config.channel || inst.config.low_note != c.config.low_note ||
            inst.config.high_note != c.config.high_note) inst.stop();
        inst.config.channel = c.config.channel;
        inst.config.low_note = c.config.low_note;
        inst.config.high_note = c.config.high_note;
        inst.config.level_db = c.config.level_db;
        inst.config.pan = c.config.pan;
        inst.config.muted = c.config.muted;
        break;
    default: break;
    }
    publish(c.slot);
}
void drain()
{
    auto read = readIndex.load(std::memory_order_relaxed);
    const auto write = writeIndex.load(std::memory_order_acquire);
    while (read != write) {
        const auto c = commands[read % queueSize];
        if (c.scheduled && int32_t(clock.frame - c.due) < 0) {
            if (scheduledCount == queueSize) { error.store(1); panic.store(1); }
            else {
                auto i = scheduledCount++;
                while (i && int32_t(scheduled[i - 1].due - c.due) > 0) {
                    scheduled[i] = scheduled[i - 1];
                    --i;
                }
                scheduled[i] = c;
            }
        } else apply(c);
        ++read;
    }
    readIndex.store(read, std::memory_order_release);
    while (scheduledCount && int32_t(clock.frame - scheduled[0].due) >= 0) {
        const auto c = scheduled[0];
        --scheduledCount;
        for (uint32_t i = 0; i < scheduledCount; ++i) scheduled[i] = scheduled[i + 1];
        apply(c);
    }
    if (panic.exchange(0)) { stopAll(); scheduledCount = 0; }
}

uint32_t outputPosition = CTL;
float output[2][CTL] {};
float masterLeft = 1, masterRight = 1;
void renderBlock()
{
    clock.frame += CTL;
    processedFrames += CTL;
    drain();
    if (clock.quarter && clock.frame - clock.last > FS) {
        clock.release();
        internalTempo.store(clock.bpm);
    }
    if (!clock.quarter) clock.bpm = internalTempo.load(std::memory_order_relaxed);
    const auto q = clock.length();
    const int64_t phase = clock.external ? int32_t(clock.frame - clock.anchor) : int64_t(clock.frame);
    Timing timing {clock.frame, q, double(phase) / q, audioAdvance.load(std::memory_order_relaxed)};
    if (clock.external) timing.advance += midiBuffer.load(std::memory_order_relaxed) * FS / 1000;
    std::memset(output, 0, sizeof(output));
    int32_t buffer[CTL * 2];
    for (uint32_t s = 0; s < capacity; ++s) {
        auto* inst = scene->slots[s].get();
        if (!inst) continue;
        inst->engine->render(timing, buffer);
        const auto& c = inst->config;
        const float gain = c.muted || c.level_db <= -48 ? 0 : std::pow(10.f, c.level_db / 20);
        const float left = gain * (c.pan > 0 ? std::sqrt(1 - c.pan) : 1);
        const float right = gain * (c.pan < 0 ? std::sqrt(1 + c.pan) : 1);
        float peak = 0;
        for (uint32_t i = 0; i < CTL; ++i) {
            const float blend = float(i + 1) / CTL;
            const float l = buffer[i * 2] / 32768.f * (inst->leftGain + (left - inst->leftGain) * blend);
            const float r = buffer[i * 2 + 1] / 32768.f * (inst->rightGain + (right - inst->rightGain) * blend);
            output[0][i] += l;
            output[1][i] += r;
            peak = std::max(peak, std::max(std::abs(l), std::abs(r)));
        }
        const auto level = uint32_t(std::min(peak, 1.f) * 65535);
        auto previous = snapshots[s].peak.load(std::memory_order_relaxed);
        while (previous < level &&
               !snapshots[s].peak.compare_exchange_weak(previous, level, std::memory_order_relaxed)) {}
        inst->leftGain = left;
        inst->rightGain = right;
        for (uint32_t v = 0; v < 8; ++v) snapshots[s].levels[v].store(inst->engine->voiceLevel(v));
    }
    const float pan = masterPan.load(std::memory_order_relaxed) / 1000.f;
    const float left = pan > 0 ? std::sqrt(1 - pan) : 1;
    const float right = pan < 0 ? std::sqrt(1 + pan) : 1;
    for (uint32_t i = 0; i < CTL; ++i) {
        const float blend = float(i + 1) / CTL;
        output[0][i] *= masterLeft + (left - masterLeft) * blend;
        output[1][i] *= masterRight + (right - masterRight) * blend;
    }
    masterLeft = left;
    masterRight = right;
    audioFrame.store(clock.frame);
    externalClock.store(clock.quarter != 0);
    tempo.store(clock.quarter ? (60 * FS + q / 2) / q : clock.bpm);
}

void command(Kind kind, uint32_t a = 0, uint32_t b = 0)
{
    Command c;
    c.kind = kind;
    c.slot = selected.load();
    c.a = a;
    c.b = b;
    enqueue(c);
}
void send(uint32_t status, uint32_t d1, uint32_t d2, uint32_t frame, bool timed, bool external = true)
{
    if (!((status >= 0x80 && status < 0xF0 && d1 <= 127 && d2 <= 127) ||
          status == 0xF8 || status == 0xFA || status == 0xFB || status == 0xFC)) return;
    if ((status & 0xF0) == 0xB0 && d1 == 64)
        sustainInput.store(0x10000 | ((status & 15) << 8) | d2);
    if (external && (status & 0xF0) == 0x90 && d2 != 0) {
        uint32_t channel = (status & 15) + 1;
        keyLearn.compare_exchange_strong(channel, 0x100 | d1);
    }
    Command c;
    c.a = status; c.b = d1; c.c = d2; c.due = frame; c.scheduled = timed;
    c.source.kind = external ? music::SourceKind::ExternalMIDI : music::SourceKind::TouchKeyboard;
    enqueue(c);
}
} // namespace rack

extern "C" {
void ov_init(void)
{
    using namespace rack;
    if (scene) return;
    scene = std::make_unique<Scene>();
    ov_instrument_config c {};
    c.engine = OV_ENGINE_OBERVAVE; c.channel = 1; c.high_note = 127; c.program = 17; c.grid = 2;
    for (uint32_t p = 0; p < NPARAM; ++p) {
        c.parameters[p] = ov_rack_factory_parameter(17, p);
        c.cc[p] = defaults[p];
    }
    scene->slots[0] = std::make_unique<Instrument>(c);
    publish(0);
}
uint32_t ov_engine_count(void) { return uint32_t(std::size(rack::engines)); }
uint32_t ov_engine_id(uint32_t index) { return index < ov_engine_count() ? rack::engines[index].id : 0; }
const char* ov_engine_name(uint32_t id) { const auto* t = rack::engineType(id); return t ? t->name : ""; }
uint32_t ov_rack_factory_parameter(uint32_t index, uint32_t p)
{
    if (p >= rack::NPARAM) return 0;
    rack::patch_t patch {};
    rack::patch_from_factory(&patch, rack::program(index));
    return patch.v[p];
}
uint32_t ov_rack_default_cc(uint32_t p) { return p < rack::NPARAM ? rack::defaults[p] : 255; }
int ov_rack_add(uint32_t slot, const ov_instrument_config* config)
{
    using namespace rack;
    if (slot >= capacity || !config || !valid(*config)) { error.store(2); return 0; }
    try {
        auto instance = std::make_unique<Instrument>(*config);
        Command c; c.kind = Kind::Add; c.slot = slot; c.object = instance.get();
        if (!enqueue(c)) return 0;
        instance.release();
        return 1;
    } catch (const std::bad_alloc&) { error.store(3); return 0; }
}
int ov_rack_remove(uint32_t slot)
{
    if (slot >= rack::capacity) { rack::error.store(2); return 0; }
    rack::Command c; c.kind = rack::Kind::Remove; c.slot = slot;
    return rack::enqueue(c);
}
int ov_rack_load(const ov_scene_config* config)
{
    using namespace rack;
    if (!config || config->tempo < 40 || config->tempo > 240) { error.store(2); return 0; }
    for (const auto& slot : config->slots)
        if (slot.present > 1 || (slot.present && !valid(slot.config))) { error.store(2); return 0; }
    try {
        auto next = std::make_unique<Scene>();
        for (uint32_t s = 0; s < capacity; ++s)
            if (config->slots[s].present) next->slots[s] = std::make_unique<Instrument>(config->slots[s].config);
        Command c; c.kind = Kind::Scene; c.object = next.get(); c.a = config->tempo;
        if (!enqueue(c)) return 0;
        next.release();
        return 1;
    } catch (const std::bad_alloc&) { error.store(3); return 0; }
}
int ov_rack_snapshot_request(void)
{
    uint32_t idle = 0;
    if (!rack::captureState.compare_exchange_strong(idle, 1)) return 0;
    rack::Command c; c.kind = rack::Kind::Capture;
    if (rack::enqueue(c)) return 1;
    rack::captureState.store(0);
    return 0;
}
int ov_rack_snapshot_read(ov_scene_config* out)
{
    if (!out || rack::captureState.load(std::memory_order_acquire) != 2) return 0;
    *out = rack::capturedScene;
    rack::captureState.store(0);
    return 1;
}
int ov_rack_read(uint32_t slot, ov_instrument_config* out)
{
    if (slot >= rack::capacity || !out) return 0;
    auto& snapshot = rack::snapshots[slot];
    // All payload fields are atomic; retrying avoids a torn program/parameter update.
    for (uint32_t retry = 0; retry < 8; ++retry) {
        const auto before = snapshot.sequence.load();
        if (before & 1) continue;
        for (uint32_t p = 0; p < rack::NPARAM; ++p) {
            out->parameters[p] = snapshot.parameters[p].load();
            out->cc[p] = snapshot.cc[p].load();
        }
        out->program = snapshot.program.load();
        out->sync = snapshot.sync.load();
        out->grid = snapshot.grid.load();
        if (before == snapshot.sequence.load()) return 1;
    }
    return 0;
}
uint32_t ov_rack_take_level(uint32_t slot)
{
    return slot < rack::capacity ? rack::snapshots[slot].peak.exchange(0, std::memory_order_relaxed) : 0;
}
uint32_t ov_rack_stop_generation(void) { return rack::stopGeneration.load(std::memory_order_relaxed); }
int ov_rack_configure(uint32_t slot, uint32_t channel, uint32_t low, uint32_t high,
                      float db, float pan, uint32_t muted)
{
    if (slot >= rack::capacity || channel < 1 || channel > 16 || low > high || high > 127 ||
        !std::isfinite(db) || db < -48 || db > 0 || !std::isfinite(pan) || std::abs(pan) > 1 || muted > 1) {
        rack::error.store(2); return 0;
    }
    rack::Command c; c.kind = rack::Kind::Route; c.slot = slot;
    c.config.channel = channel; c.config.low_note = low; c.config.high_note = high;
    c.config.level_db = db; c.config.pan = pan; c.config.muted = muted;
    return rack::enqueue(c);
}
void ov_rack_select(uint32_t slot) { if (slot < rack::capacity) rack::selected.store(slot); }
void ov_rack_collect(void)
{
    auto* head = rack::retired.exchange(nullptr, std::memory_order_acquire);
    while (head) { auto* next = head->next; delete head; head = next; }
}
uint32_t ov_rack_take_error(void) { return rack::error.exchange(0); }
uint32_t ov_program_count(void) { return 768; }
uint32_t ov_parameter_count(void) { return rack::NPARAM; }
uint32_t ov_parameter_max(uint32_t p) { return p < rack::NPARAM ? rack::PDEF[p].max : 0; }
double ov_lfo_rate_hz(uint32_t value) { return obervave::lfo_rate_hz(value); }
uint32_t ov_parameter_value(uint32_t p)
{ return p < rack::NPARAM ? rack::snapshots[rack::selected.load()].parameters[p].load() : 0; }
uint32_t ov_parameter_cc(uint32_t p)
{ return p < rack::NPARAM ? rack::snapshots[rack::selected.load()].cc[p].load() : 255; }
uint32_t ov_voice_level(uint32_t v)
{ return v < 8 ? rack::snapshots[rack::selected.load()].levels[v].load() : 0; }
uint32_t ov_current_program(void) { return rack::snapshots[rack::selected.load()].program.load(); }
const char* ov_program_name(uint32_t index) { return index < 768 ? rack::program(index)->name : ""; }
void ov_select_program(uint32_t index) { if (index < 768) rack::command(rack::Kind::Program, index); }
void ov_set_parameter(uint32_t p, uint32_t value)
{ if (p < rack::NPARAM && value <= ov_parameter_max(p)) rack::command(rack::Kind::Parameter, p, value); }
void ov_set_parameter_cc(uint32_t p, uint32_t cc)
{ if (p < rack::NPARAM && (cc <= 127 || cc == 255)) rack::command(rack::Kind::CC, p, cc); }
void ov_reset_parameter_ccs(void) { rack::command(rack::Kind::ResetCC); }
void ov_set_midi_learn(int32_t p)
{ if (p >= -1 && p < int32_t(rack::NPARAM)) rack::command(rack::Kind::Learn, uint32_t(p)); }
uint32_t ov_take_midi_learn_result(void) { return rack::snapshots[rack::selected.load()].learned.exchange(0); }
uint32_t ov_tempo(void) { return rack::tempo.load(); }
uint32_t ov_midi_clock_active(void) { return rack::externalClock.load(); }
void ov_set_tempo(uint32_t bpm)
{
    const auto value = std::clamp(bpm, 40u, 240u);
    rack::internalTempo.store(value);
    if (!rack::externalClock.load()) rack::tempo.store(value);
}
uint32_t ov_arp_sync_enabled(void) { return rack::snapshots[rack::selected.load()].sync.load(); }
void ov_set_arp_sync(uint32_t on) { rack::command(rack::Kind::Sync, on != 0); }
void ov_set_arp_sync_grid(uint32_t grid) { if (grid <= 5) rack::command(rack::Kind::Grid, grid); }
void ov_set_arp_audio_latency_ms(float ms)
{
    if (!std::isfinite(ms) || ms < -500 || ms > 2000) { rack::error.store(2); return; }
    rack::audioAdvance.store(int32_t(std::lround(ms * FS / 1000.f)));
}
uint32_t ov_ble_midi_buffer_ms(void) { return rack::midiBuffer.load(); }
void ov_set_ble_midi_buffer_ms(uint32_t ms) { rack::midiBuffer.store(std::min(ms, 50u)); }
void ov_set_master_pan(float pan)
{ if (std::isfinite(pan)) rack::masterPan.store(int32_t(std::clamp(pan, -1.f, 1.f) * 1000)); }
void ov_set_output_meter(float left, float right)
{
    auto update = [](std::atomic<uint32_t>& peak, float value) {
        const auto level = uint32_t(std::clamp(std::abs(value), 0.f, 1.f) * 65535);
        auto previous = peak.load();
        while (previous < level && !peak.compare_exchange_weak(previous, level)) {}
    };
    update(rack::peakLeft, left); update(rack::peakRight, right);
}
uint32_t ov_take_output_meter(void)
{ return rack::peakLeft.exchange(0) | (rack::peakRight.exchange(0) << 16); }
void ov_midi_message(uint32_t s, uint32_t d1, uint32_t d2) { rack::send(s, d1, d2, 0, false); }
void ov_midi_message_at(uint32_t s, uint32_t d1, uint32_t d2, uint32_t f) { rack::send(s, d1, d2, f, true); }
uint32_t ov_audio_frame(void) { return rack::audioFrame.load(); }
void ov_keyboard_channels(uint32_t mask) { rack::keyboardMask.store(mask & 0xFFFF); }
void ov_note_on(uint32_t note, uint32_t velocity)
{
    ov_keyboard_note_on(note, velocity, rack::keyboardMask.load());
}
void ov_keyboard_note_on(uint32_t note, uint32_t velocity, uint32_t channels)
{
    if (note > 127 || velocity < 1 || velocity > 127) return;
    const auto mask = channels & 0xFFFF;
    rack::keyboardHeld[note].fetch_or(mask);
    for (uint32_t ch = 0; ch < 16; ++ch) if (mask & (1u << ch)) rack::send(0x90 | ch, note, velocity, 0, false, false);
}
void ov_note_off(uint32_t note)
{
    ov_keyboard_note_off(note, 0xFFFF);
}
void ov_keyboard_note_off(uint32_t note, uint32_t channels)
{
    if (note > 127) return;
    const auto mask = rack::keyboardHeld[note].fetch_and(~channels) & channels;
    for (uint32_t ch = 0; ch < 16; ++ch) if (mask & (1u << ch))
        rack::send(0x80 | ch, note, 0, 0, false, false);
}
void ov_keyboard_control(uint32_t status, uint32_t d1, uint32_t d2)
{
    const auto mask = rack::keyboardMask.load();
    for (uint32_t ch = 0; ch < 16; ++ch) if (mask & (1u << ch))
        rack::send((status & 0xF0) | ch, d1, d2, 0, false, false);
}
void ov_all_notes_off(void) { rack::panic.store(1); }
void ov_set_sustain_inverted(uint32_t inverted) { rack::sustainInverted.store(inverted != 0); }
uint32_t ov_sustain_input(void) { return rack::sustainInput.load(); }
uint32_t ov_sustain_down_channels(void) { return rack::sustainDownChannels.load(); }
void ov_controller_learn(uint32_t armed)
{
    rack::controllerLearned.store(0);
    rack::controllerLearnSlot.store(armed ? rack::selected.load() + 1 : 0);
}
uint32_t ov_controller_learned(void) { return rack::controllerLearned.exchange(0); }
void ov_key_learn(uint32_t channel) { rack::keyLearn.store(channel <= 16 ? channel : 0); }
uint32_t ov_take_key_learn(void)
{
    auto value = rack::keyLearn.load();
    if (value < 0x100 || !rack::keyLearn.compare_exchange_strong(value, 0)) return 0;
    return (value & 127) + 1;
}
static void midiByte(uint32_t value, uint32_t frame, bool timed)
{
    using namespace rack;
    std::lock_guard<std::mutex> lock(parserMutex);
    const auto byte = uint8_t(value);
    if (byte >= 0xF8) { send(byte, 0, 0, frame, timed); return; }
    if (byte & 0x80) { midiStatus = byte < 0xF0 ? byte : 0; midiCount = 0; return; }
    if (!midiStatus) return;
    midiData[midiCount++] = byte & 0x7F;
    const auto kind = midiStatus & 0xF0;
    const uint32_t expected = kind == 0xC0 || kind == 0xD0 ? 1 : 2;
    if (midiCount == expected) {
        send(midiStatus, midiData[0], expected == 2 ? midiData[1] : 0, frame, timed);
        midiCount = 0;
    }
}
void ov_midi_byte(uint32_t byte) { midiByte(byte, 0, false); }
void ov_midi_byte_at(uint32_t byte, uint32_t frame) { midiByte(byte, frame, true); }
void ov_render(float* left, float* right, uint32_t frames)
{
    if (!rack::scene || !left || !right) return;
    for (uint32_t i = 0; i < frames; ++i) {
        if (rack::outputPosition == CTL) { rack::renderBlock(); rack::outputPosition = 0; }
        left[i] = rack::output[0][rack::outputPosition];
        right[i] = rack::output[1][rack::outputPosition++];
    }
}
}
