#include <stdint.h>

typedef struct Fm1BenchResult {
    uint32_t status;
    uint32_t speed_milli_x;
    uint32_t emulated_ms;
    uint32_t wall_ms;
    uint64_t audio_frames;
    uint32_t short_quanta;
    uint32_t over_deadline;
    uint32_t p95_us;
    uint32_t p99_us;
    uint32_t max_us;
    uint32_t sample_count;
    uint32_t deadline_us;
    uint32_t native_jit_active;
    uint32_t native_jit_compiled_blocks;
} Fm1BenchResult;

Fm1BenchResult fm1_ios_bench(
    const uint8_t *package,
    uint32_t package_len,
    uint32_t mhz,
    uint32_t run_seconds,
    uint32_t warmup_ms,
    uint32_t quantum,
    uint32_t native_jit,
    const uint8_t *script_ptr,
    uint32_t script_len,
    uint32_t *samples_ptr,
    uint32_t samples_capacity
);
