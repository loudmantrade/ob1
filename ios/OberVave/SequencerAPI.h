#pragma once
#include <stdint.h>
#include "RackAPI.h"
#ifdef __cplusplus
extern "C" {
#endif
#define OV_SEQ_ROWS 8
#define OV_SEQ_NOTES 1024
typedef struct {
    uint64_t id;
    int64_t start, duration;
    uint32_t pitch, velocity, output;
} ov_seq_note;
typedef struct {
    uint32_t slot, row, count, loop, intro_enabled, quantize;
    int64_t length, intro;
    char name[97];
    ov_seq_note notes[OV_SEQ_NOTES];
} ov_seq_clip;
/* Calls enqueue control-thread commands. No struct pointers are retained. */
int ov_seq_set_clip(const ov_seq_clip* clip);
int ov_rack_load_sequenced(const ov_scene_config* scene, const ov_seq_clip* clips, uint32_t count);
uint32_t ov_seq_take_level(uint32_t slot);
int ov_seq_delete(uint32_t slot, uint32_t row);
int ov_seq_launch(uint32_t slot, uint32_t row, uint32_t grid);
int ov_seq_launch_row(uint32_t row, uint32_t grid);
int ov_seq_stop(uint32_t slot, uint32_t arp);
int ov_seq_solo(uint32_t slot, uint32_t enabled);
int ov_seq_record(uint32_t slot, uint32_t row, uint32_t output, uint32_t intro);
/* mode: 0 Wait for note, 1 Count-in, 2 Immediate; beats: 0 free, 1..256 fixed. */
int ov_seq_arm(uint32_t slot, uint32_t row, uint32_t mode, uint32_t count_bars, uint32_t beats, uint32_t output);
/* Resolve a short pad tap against audio-owned recording/playback state. */
int ov_seq_tap(uint32_t slot, uint32_t row, uint32_t mode, uint32_t count_bars, uint32_t beats, uint32_t output, uint32_t grid);
int ov_seq_finish_record(void);
uint32_t ov_seq_record_phase(void); /* 0 idle, 1 waiting for note, 2 count-in, 3 body, 4 waiting for scene bar, 5 finishing at bar */
uint32_t ov_seq_record_remaining(void);
int64_t ov_seq_record_length(void); /* current length in 960-PPQ ticks */
uint32_t ov_seq_record_result(void); /* 1 saved, 2 cancelled, 3 failed; read before mailbox */
/* Single control-thread consumer; bounded FIFO. The audio recorder reserves a result entry when armed.
   Rack error 4 rejects a new take if all 16 completion entries are unread. */
uint32_t ov_seq_record_ready(void);
int ov_seq_read_record(ov_seq_clip* clip);
int ov_seq_read_completion(ov_seq_clip* clip, uint32_t* result, uint64_t* epoch);
uint64_t ov_seq_scene_epoch(void);
uint32_t ov_seq_record_progress(void); /* body bar phase, 0..65535 */
int32_t ov_seq_active(uint32_t slot);
int32_t ov_seq_pending(uint32_t slot);
uint32_t ov_seq_position(uint32_t slot); /* 0..65535 */
int32_t ov_seq_recording_slot(void);
int32_t ov_seq_recording_row(void);
uint32_t ov_seq_stopping(uint32_t slot);
#ifdef __cplusplus
}
#endif
