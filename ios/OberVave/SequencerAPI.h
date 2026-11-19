#pragma once
#include <stdint.h>
#include "RackAPI.h"
#ifdef __cplusplus
extern "C" {
#endif
#define OV_SEQ_ROWS 8
#define OV_SEQ_NOTES 1024
#define OV_SEQ_AUTOMATION 256
typedef struct {
    uint64_t id;
    int64_t start, duration;
    uint32_t pitch, velocity, output;
    uint32_t quant_override, quant_grid, quant_strength, quant_ends;
} ov_seq_note;
typedef struct {
    uint64_t id;
    int64_t tick;
    uint32_t kind, controller, value; /* kind 0 CC, 1 pitch bend */
} ov_seq_automation;
typedef struct {
    uint32_t slot, row, count, loop, intro_enabled, quantize;
    int64_t length, intro;
    uint32_t regions_enabled; /* 0 legacy, 1 start=-intro, 2 explicit start */
    int64_t pattern_start, loop_start, loop_end;
    char name[97];
    ov_seq_note notes[OV_SEQ_NOTES];
    uint32_t automation_count;
    ov_seq_automation automation[OV_SEQ_AUTOMATION];
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
/* Shares the rack snapshot mailbox. All fields are captured on the audio owner
   at one command boundary. Either read function consumes the pending snapshot. */
typedef struct {
    ov_scene_config scene;
    uint64_t epoch, generations[OV_RACK_CAPACITY], revisions[OV_RACK_CAPACITY][OV_SEQ_ROWS];
    uint32_t solo_mask, internal_tempo, clock_external;
} ov_seq_scene_snapshot;
int ov_seq_snapshot_read(ov_seq_scene_snapshot* snapshot);
int ov_seq_record(uint32_t slot, uint32_t row, uint32_t output, uint32_t intro);
/* mode: 0 Wait for note, 1 Count-in, 2 Immediate; beats: 0 free, 1..256 fixed. */
int ov_seq_arm(uint32_t slot, uint32_t row, uint32_t mode, uint32_t count_bars, uint32_t beats, uint32_t output);
/* Resolve a short pad tap against audio-owned recording/playback state. */
int ov_seq_tap(uint32_t slot, uint32_t row, uint32_t mode, uint32_t count_bars, uint32_t beats, uint32_t output, uint32_t grid);
int ov_seq_finish_record(void);
uint32_t ov_seq_record_phase(void); /* 0 idle, 1 waiting for note, 2 count-in, 3 body, 4 waiting for scene bar, 5 finishing at bar */
uint32_t ov_seq_record_state(void); /* coherent snapshot: phase in bits 0..2; (cell ID + 1) in bits 3..10; 0 idle */
/* One active take per slot; legacy getters above report the first active slot. */
uint32_t ov_seq_record_state_for_slot(uint32_t slot);
uint32_t ov_seq_record_progress_for_slot(uint32_t slot);
uint32_t ov_seq_record_remaining_for_slot(uint32_t slot);
uint32_t ov_seq_record_remaining(void);
int64_t ov_seq_record_length(void); /* current length in 960-PPQ ticks */
uint32_t ov_seq_record_result(void); /* 1 saved, 2 cancelled, 3 failed; read before mailbox */
/* Single control-thread consumer; bounded FIFO. Each armed recorder reserves a result entry.
   Rack error 4 rejects a new take if unread completions + active takes occupy all 16 entries. */
uint32_t ov_seq_record_ready(void);
int ov_seq_read_record(ov_seq_clip* clip);
int ov_seq_read_completion(ov_seq_clip* clip, uint32_t* result, uint64_t* epoch);
uint64_t ov_seq_scene_epoch(void);
uint64_t ov_seq_record_revision(void); /* revision of front completion; read before consuming */
uint32_t ov_seq_record_progress(void); /* body bar phase, 0..65535 */
void ov_seq_set_metronome(uint32_t enabled); /* shared count-in/recording/playback click; accent matches transport beat one */
uint64_t ov_seq_transport_beat(void); /* zero-based global quarter count since transport activity began */
int32_t ov_seq_active(uint32_t slot);
int32_t ov_seq_pending(uint32_t slot);
uint32_t ov_seq_position(uint32_t slot); /* 0..65535 */
int64_t ov_seq_position_ticks(uint32_t slot); /* signed pattern-relative audio-owned position */
int32_t ov_seq_recording_slot(void);
int32_t ov_seq_recording_row(void);
uint32_t ov_seq_stopping(uint32_t slot);
/* Transaction: mode bit 0 COPY (otherwise MOVE), bit 1 permits confirmed replacement.
   Mode 4 DELETE requires source and target to be the same cell.
   Expected immutable source + cell revisions reject stale UI.
   One control-thread consumer reads acknowledgements. No model mutation before success. */
typedef struct { uint64_t token, source_revision, target_revision; uint32_t success; } ov_seq_edit_result;
uint64_t ov_seq_cell_revision(uint32_t slot, uint32_t row);
int ov_seq_edit(const ov_seq_clip* source, uint32_t target_slot, uint32_t target_row,
                uint32_t mode, uint64_t epoch, uint64_t source_revision,
                uint64_t target_revision, uint64_t token);
int ov_seq_read_edit(ov_seq_edit_result* result);
/* Revision-checked same-cell replacement. Active and queued playback retain their
   transport position; already sounding notes retain their original Note Off. */
int ov_seq_replace_pattern(const ov_seq_clip* expected, const ov_seq_clip* replacement,
                           uint64_t epoch, uint64_t revision, uint64_t token);
/* Atomically replace up to 128 distinct cells. A null expected or replacement
   represents an empty cell; both may not be null for the same change.
   The audio owner checks the scene epoch, cell revisions and expected contents
   before changing any cell. Completion is reported by ov_seq_read_edit: its
   source and target revisions refer to the first and last cells respectively;
   on success every affected cell's revision increments exactly once.
   Clips are copied before this function returns. */
typedef struct {
    uint32_t slot, row;
    uint64_t revision;
    const ov_seq_clip* expected;
    const ov_seq_clip* replacement;
} ov_seq_cell_change;
int ov_seq_change_cells(const ov_seq_cell_change* changes, uint32_t count,
                        uint64_t epoch, uint64_t token);
/* One audio-owner transaction for sound, mixer and cell replacements on
   existing instruments. Any conflict rejects the whole transaction. Arrays
   and clips are copied before return; zero counts permit null pointers.
   Completion uses ov_rack_read_parameter_result. Successful changed cells
   advance their revision exactly once. */
int ov_seq_change_bundle(const ov_rack_sound_change* sounds, uint32_t sound_count,
                         const ov_rack_mixer_change* mixer, uint32_t mixer_count,
                         const ov_seq_cell_change* cells, uint32_t cell_count,
                         uint64_t epoch, uint64_t token);
/* Route mask bits 0..5 are the ov_rack_change_route fields; bits 6 and 7
   select ARP sync and grid. Route and mixer changes must not both address
   level, pan or mute on the same slot. */
typedef struct {
    uint32_t slot, mask;
    ov_instrument_config expected, replacement;
} ov_seq_route_change;
int ov_seq_change_bundle_with_routes(const ov_rack_sound_change* sounds, uint32_t sound_count,
                                     const ov_rack_mixer_change* mixer, uint32_t mixer_count,
                                     const ov_seq_cell_change* cells, uint32_t cell_count,
                                     const ov_seq_route_change* routes, uint32_t route_count,
                                     uint64_t epoch, uint64_t token);
/* Like the route bundle, but permits each sound replacement to change its
   program. A changed program stops notes and sequencer playback only for
   that instrument, as normal program selection does. The supplied replacement
   sound is applied rather than loading a factory preset. Every affected slot
   must have one generation guard obtained from ov_rack_slot_generation;
   removal, replacement or scene load invalidates the guard. Read generation
   both before and after the corresponding snapshot and retry if it changes.
   The getter returns 0 while a slot replacement is in progress. */
typedef struct { uint32_t slot; uint64_t generation; } ov_seq_slot_guard;
int ov_rack_slot_generation(uint32_t slot, uint64_t* generation);
int ov_seq_change_bundle_with_programs(const ov_rack_sound_change* sounds, uint32_t sound_count,
                                       const ov_rack_mixer_change* mixer, uint32_t mixer_count,
                                       const ov_seq_cell_change* cells, uint32_t cell_count,
                                       const ov_seq_route_change* routes, uint32_t route_count,
                                       const ov_seq_slot_guard* guards, uint32_t guard_count,
                                       uint64_t epoch, uint64_t token);
/* Structural replacement includes every cell, including empty cells. Changes
   are prepared off the audio thread; a conflicting slot or cell rejects the
   entire bundle. Slots in this array must not occur in the other arrays.
   A structural replacement stops only the affected slot and invalidates all
   eight cell revisions and its instrument generation. */
typedef struct {
    uint32_t slot, expected_present, replacement_present, expected_solo, replacement_solo;
    uint64_t generation;
    ov_instrument_config expected, replacement;
    uint64_t revisions[OV_SEQ_ROWS];
    const ov_seq_clip* expected_clips[OV_SEQ_ROWS];
    const ov_seq_clip* replacement_clips[OV_SEQ_ROWS];
} ov_seq_slot_change;
int ov_seq_change_bundle_with_slots(const ov_rack_sound_change* sounds, uint32_t sound_count,
                                    const ov_rack_mixer_change* mixer, uint32_t mixer_count,
                                    const ov_seq_cell_change* cells, uint32_t cell_count,
                                    const ov_seq_route_change* routes, uint32_t route_count,
                                    const ov_seq_slot_guard* guards, uint32_t guard_count,
                                    const ov_seq_slot_change* slots, uint32_t slot_count,
                                    uint64_t epoch, uint64_t token);
/* An optional tempo change is checked and committed with the entire bundle.
   It is rejected while MIDI clock controls the transport or if the internal
   tempo no longer equals expected. */
typedef struct { uint32_t expected, replacement; } ov_seq_tempo_change;
uint32_t ov_seq_internal_tempo(void);
int ov_seq_change_full_bundle(const ov_rack_sound_change* sounds, uint32_t sound_count,
                              const ov_rack_mixer_change* mixer, uint32_t mixer_count,
                              const ov_seq_cell_change* cells, uint32_t cell_count,
                              const ov_seq_route_change* routes, uint32_t route_count,
                              const ov_seq_slot_guard* guards, uint32_t guard_count,
                              const ov_seq_slot_change* slots, uint32_t slot_count,
                              const ov_seq_tempo_change* tempo,
                              uint64_t epoch, uint64_t token);
/* Brief, output-stage preview for this instrument. Audio owner schedules Note Off;
   previews do not enter the recorder and have independent note ownership. */
int ov_seq_audition(uint32_t slot, uint32_t pitch, uint32_t velocity, uint64_t epoch);
uint32_t ov_seq_pad_pending(uint32_t slot, uint32_t row);
#ifdef __cplusplus
}
#endif
