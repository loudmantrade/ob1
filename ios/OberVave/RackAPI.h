#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OV_RACK_CAPACITY 16
#define OV_RACK_PARAMETERS 65
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
/* Post-instrument level/pan/mute stereo peak, normalized to 0...65535; read clears it. */
uint32_t ov_rack_take_level(uint32_t slot);
uint32_t ov_rack_stop_generation(void);
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

#ifdef __cplusplus
}
#endif
