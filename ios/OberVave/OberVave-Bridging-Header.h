#include <stdint.h>
#include "RackAPI.h"

#ifdef __cplusplus
extern "C" {
#endif
void ov_init(void);
uint32_t ov_program_count(void);
uint32_t ov_parameter_count(void);
uint32_t ov_parameter_max(uint32_t parameter);
double ov_lfo_rate_hz(uint32_t value);
uint32_t ov_parameter_value(uint32_t parameter);
uint32_t ov_parameter_cc(uint32_t parameter);
uint32_t ov_voice_level(uint32_t voice);
void ov_set_output_meter(float left, float right);
uint32_t ov_take_output_meter(void);
void ov_set_master_pan(float pan);
uint32_t ov_ble_midi_buffer_ms(void);
void ov_set_ble_midi_buffer_ms(uint32_t milliseconds);
void ov_set_parameter_cc(uint32_t parameter, uint32_t cc);
void ov_reset_parameter_ccs(void);
void ov_set_midi_learn(int32_t parameter);
uint32_t ov_take_midi_learn_result(void);
uint32_t ov_tempo(void);
uint32_t ov_midi_clock_active(void);
uint32_t ov_arp_sync_enabled(void);
void ov_set_arp_sync(uint32_t enabled);
void ov_set_arp_sync_grid(uint32_t grid);
void ov_set_arp_audio_latency_ms(float milliseconds);
uint32_t ov_current_program(void);
const char *ov_program_name(uint32_t index);
void ov_select_program(uint32_t index);
void ov_set_parameter(uint32_t parameter, uint32_t value);
void ov_set_tempo(uint32_t bpm);
void ov_note_on(uint32_t note, uint32_t velocity);
void ov_note_off(uint32_t note);
void ov_midi_message(uint32_t status, uint32_t data1, uint32_t data2);
uint32_t ov_audio_frame(void);
void ov_midi_message_at(uint32_t status, uint32_t data1, uint32_t data2, uint32_t frame);
void ov_midi_byte_at(uint32_t byte, uint32_t frame);
void ov_midi_byte(uint32_t byte);
void ov_all_notes_off(void);
void ov_render(float *left, float *right, uint32_t frames);
#ifdef __cplusplus
}
#endif
