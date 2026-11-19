#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OV_RACK_CAPACITY 16
#define OV_RACK_PARAMETERS 202
#define OV_ENGINE_OBERVAVE 1
uint32_t ov_engine_count(void);
uint32_t ov_engine_id(uint32_t index);
const char *ov_engine_name(uint32_t id);

typedef struct {
    uint32_t engine;
    uint32_t channel; /* 1...16 */
    uint32_t low_note, high_note;
    uint32_t program;
    uint32_t sync, grid;
    float level_db, pan;
    uint32_t muted;
    uint8_t parameters[OV_RACK_PARAMETERS];
    uint8_t cc[OV_RACK_PARAMETERS]; /* 255 = unassigned */
} ov_instrument_config;

typedef struct {
    uint32_t present;
    ov_instrument_config config;
} ov_rack_slot;

typedef struct {
    uint32_t tempo;
    ov_rack_slot slots[OV_RACK_CAPACITY];
} ov_scene_config;

/* Configuration and lifecycle APIs run on the main thread, never the audio thread. */
int ov_rack_add(uint32_t slot, const ov_instrument_config *config);
int ov_rack_remove(uint32_t slot);
int ov_rack_load(const ov_scene_config *scene);
int ov_rack_snapshot_request(void);
int ov_rack_snapshot_read(ov_scene_config *scene);
int ov_rack_read(uint32_t slot, ov_instrument_config *config);
/* Optional single-consumer feed of external MIDI changes, captured on the
   audio owner. The feed is disabled until enabled. A nonzero lost count means
   the consumer must invalidate any history that may span the missing events. */
typedef struct {
    uint64_t epoch, frame;
    uint32_t slot, source, status, data1, data2;
    ov_instrument_config before, after;
} ov_rack_external_change;
void ov_rack_external_history_enable(uint32_t enabled);
int ov_rack_read_external_change(ov_rack_external_change *change);
uint32_t ov_rack_external_history_lost(void);
/* Checked, atomic parameter changes; completion is consumed on the control
   thread. Changes are copied before return and must address distinct fields. */
typedef struct { uint32_t slot, parameter, expected, replacement; } ov_rack_parameter_change;
typedef struct { uint64_t token; uint32_t success; } ov_rack_parameter_result;
int ov_rack_change_parameters(const ov_rack_parameter_change *changes, uint32_t count,
                              uint64_t epoch, uint64_t token);
int ov_rack_read_parameter_result(ov_rack_parameter_result *result);
/* UI parameter commands can report queue failure and preserve ordering when
   reading a value most recently changed by pattern automation. */
int ov_rack_set_parameter(uint32_t slot, uint32_t parameter, uint32_t value);
/* 1: value is automation-owned, 0: it is not or a UI command is pending,
   -1: the coherent snapshot was unavailable. */
int ov_rack_automated_parameter(uint32_t slot, uint32_t parameter, uint32_t *value);
/* Route masks address channel, low note, high note, level, pan, mute, sync
   and grid in bits 0..7. Unselected fields are neither checked nor changed. Completion
   uses the parameter-result queue. */
int ov_rack_change_route(uint32_t slot, uint32_t mask,
                         const ov_instrument_config *expected, const ov_instrument_config *replacement,
                         uint64_t epoch, uint64_t token);
/* Replace a preset's parameter values and CC assignments as one checked
   operation. Program, routing and arpeggiator clock settings are preserved.
   The acknowledgement uses the parameter-result queue. */
int ov_rack_change_sound(uint32_t slot, const ov_instrument_config *expected,
                         const ov_instrument_config *replacement, uint64_t epoch, uint64_t token);
/* Atomically check and replace sounds for distinct slots. Either every sound
   is changed or none are; results use the parameter-result queue. */
typedef struct {
    uint32_t slot;
    ov_instrument_config expected, replacement;
} ov_rack_sound_change;
int ov_rack_change_sounds(const ov_rack_sound_change *changes, uint32_t count,
                          uint64_t epoch, uint64_t token);
/* Atomically check and replace the mixer fields of distinct instruments. */
typedef struct {
    uint32_t slot;
    float expected_level, expected_pan, replacement_level, replacement_pan;
    uint32_t expected_mute, replacement_mute;
    uint32_t expected_solo, replacement_solo;
} ov_rack_mixer_change;
int ov_rack_change_mixer(const ov_rack_mixer_change *changes, uint32_t count,
                         uint64_t epoch, uint64_t token);
/* Post-instrument level/pan/mute stereo peak, normalized to 0...65535; read clears it. */
uint32_t ov_rack_take_level(uint32_t slot);
uint32_t ov_rack_stop_generation(void);
/* Ordered global transport stop: releases notes, clears scheduled playback,
   preserves patches and effect tails. Failure reports the existing overflow error/Panic. */
int ov_rack_stop_all(void);
int ov_rack_configure(uint32_t slot, uint32_t channel, uint32_t low, uint32_t high,
                      float level_db, float pan, uint32_t muted);
void ov_rack_select(uint32_t slot);
void ov_rack_collect(void);
uint32_t ov_rack_take_error(void);
uint32_t ov_rack_default_cc(uint32_t parameter);
uint32_t ov_rack_factory_parameter(uint32_t program, uint32_t parameter);
void ov_keyboard_channels(uint32_t mask);
void ov_keyboard_note_on(uint32_t note, uint32_t velocity, uint32_t channels);
void ov_keyboard_note_off(uint32_t note, uint32_t channels);
void ov_keyboard_control(uint32_t status, uint32_t data1, uint32_t data2);
/* One-shot external Note On learn, filtered by channel (1...16); 0 cancels.
   Read returns note + 1, or 0 while waiting. Notes still reach the synth. */
void ov_key_learn(uint32_t channel);
uint32_t ov_take_key_learn(void);
void ov_set_sustain_inverted(uint32_t inverted);
/* Device preference, off by default: 3 presses <=300 ms, gaps <=1 quarter note. */
void ov_set_sustain_stop_gesture(uint32_t enabled);
/* Last incoming CC64: bit 16 valid, bits 8...11 channel (0...15), bits 0...6 raw value. */
uint32_t ov_sustain_input(void);
/* Hysteresis state: press >=96, release <=31 after polarity normalization. */
uint32_t ov_sustain_down_channels(void);
void ov_controller_learn(uint32_t armed);
uint32_t ov_controller_learned(void); /* 0 waiting, otherwise source ID */

#ifdef __cplusplus
}
#endif
