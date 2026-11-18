use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::time::{Duration, Instant};

const RATE: u64 = 44_100;
const MAX_PACKAGE_BYTES: u32 = 32 * 1024 * 1024;
const MAX_RUN_SECONDS: u32 = 60;
const MAX_WARMUP_MS: u32 = 60_000;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Fm1BenchResult {
    pub status: u32,
    pub speed_milli_x: u32,
    pub emulated_ms: u32,
    pub wall_ms: u32,
    pub audio_frames: u64,
    pub short_quanta: u32,
    pub over_deadline: u32,
    pub p95_us: u32,
    pub p99_us: u32,
    pub max_us: u32,
    pub sample_count: u32,
    pub deadline_us: u32,
    pub native_jit_active: u32,
    pub native_jit_compiled_blocks: u32,
}

#[no_mangle]
pub unsafe extern "C" fn fm1_ios_bench(
    package: *const u8,
    package_len: u32,
    mhz: u32,
    run_seconds: u32,
    warmup_ms: u32,
    quantum: u32,
    native_jit: u32,
    script_ptr: *const u8,
    script_len: u32,
    samples_ptr: *mut u32,
    samples_capacity: u32,
) -> Fm1BenchResult {
    match catch_unwind(AssertUnwindSafe(|| {
        run(
            package,
            package_len,
            mhz,
            run_seconds,
            warmup_ms,
            quantum,
            native_jit,
            script_ptr,
            script_len,
            samples_ptr,
            samples_capacity,
        )
    })) {
        Ok(result) => result,
        Err(_) => Fm1BenchResult { status: 6, ..Fm1BenchResult::default() },
    }
}

unsafe fn run(
    package: *const u8,
    package_len: u32,
    mhz: u32,
    run_seconds: u32,
    warmup_ms: u32,
    quantum: u32,
    native_jit: u32,
    script_ptr: *const u8,
    script_len: u32,
    samples_ptr: *mut u32,
    samples_capacity: u32,
) -> Fm1BenchResult {
    if package.is_null()
        || package_len == 0
        || package_len > MAX_PACKAGE_BYTES
        || !valid_configuration(mhz, run_seconds, warmup_ms, quantum)
        || native_jit > 1
        || script_len > 4_096
        || (script_ptr.is_null() && script_len != 0)
        || (samples_ptr.is_null() && samples_capacity != 0)
    {
        return Fm1BenchResult { status: 5, ..Fm1BenchResult::default() };
    }
    let max_samples = (run_seconds as u64 * RATE).div_ceil(quantum as u64) + 2;
    if (samples_capacity as u64) < max_samples {
        return Fm1BenchResult { status: 5, ..Fm1BenchResult::default() };
    }
    let deadline_us = ((quantum as u64 * 1_000_000) / RATE) as u32;

    let package_bytes = std::slice::from_raw_parts(package, package_len as usize);
    let script_bytes = if script_len == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(script_ptr, script_len as usize)
    };
    let Ok(script) = std::str::from_utf8(script_bytes) else {
        return Fm1BenchResult { status: 5, ..Fm1BenchResult::default() };
    };
    let measurement_ms = run_seconds * 1_000;
    let total_ms = warmup_ms + measurement_ms;
    if !valid_script(script, total_ms) {
        return Fm1BenchResult { status: 5, ..Fm1BenchResult::default() };
    }

    let firmware = fm1_web::fm1_alloc(package_len);
    ptr::copy_nonoverlapping(package_bytes.as_ptr(), firmware, package_len as usize);
    fm1_web::fm1_lcd_timed(0);
    fm1_web::fm1_jit(native_jit, 0);
    fm1_web::fm1_ahead(1_024);
    if fm1_web::fm1_boot_fwsc(firmware, package_len, ptr::null_mut(), 0, mhz) != 0 {
        return Fm1BenchResult { status: 1, ..Fm1BenchResult::default() };
    }

    if !script.is_empty() {
        let script_buffer = fm1_web::fm1_alloc(script_bytes.len() as u32);
        ptr::copy_nonoverlapping(script_bytes.as_ptr(), script_buffer, script_bytes.len());
        if fm1_web::fm1_bench_script(script_buffer, script_bytes.len() as u32) != 0 {
            return Fm1BenchResult { status: 5, ..Fm1BenchResult::default() };
        }
    }

    let boot_budget = ((mhz as u64 * 1_000_000 * 20) / 1_000) as u32;
    let play_budget = ((mhz as u64 * 1_000_000 * 3 * quantum as u64) / (2 * RATE)) as u32;
    let mut budget = boot_budget;
    let deadline = Instant::now() + Duration::from_secs((total_ms / 10).max(60) as u64);
    let mut steady_started = None;
    let mut frames = 0u64;
    let mut short_quanta = 0u32;
    let mut steady_times = Vec::new();

    while fm1_web::fm1_ms() < total_ms {
        let before_ms = fm1_web::fm1_ms();
        let render_started = Instant::now();
        if before_ms >= warmup_ms {
            steady_started.get_or_insert(render_started);
        }
        let have = fm1_web::fm1_render(quantum, budget);
        let render_us = render_started.elapsed().as_micros().min(u32::MAX as u128) as u32;

        if before_ms >= warmup_ms {
            steady_times.push(render_us);
            frames = frames.saturating_add(have as u64);
            if have < quantum {
                short_quanta = short_quanta.saturating_add(1);
            }
        }

        if have > 0 {
            budget = play_budget;
        }
        if fm1_web::fm1_halted() != 0 {
            return Fm1BenchResult { status: 2, ..Fm1BenchResult::default() };
        }
        if fm1_web::fm1_ms() == before_ms && have == 0 {
            return Fm1BenchResult { status: 3, ..Fm1BenchResult::default() };
        }
        if Instant::now() >= deadline {
            return Fm1BenchResult { status: 4, ..Fm1BenchResult::default() };
        }
    }

    let wall_ms = steady_started
        .map(|started: Instant| started.elapsed().as_millis().min(u32::MAX as u128) as u32)
        .unwrap_or(0);
    let emulated_ms = fm1_web::fm1_ms().saturating_sub(warmup_ms);
    let sample_count = steady_times.len().min(samples_capacity as usize);
    if sample_count != 0 {
        ptr::copy_nonoverlapping(steady_times.as_ptr(), samples_ptr, sample_count);
    }
    steady_times.sort_unstable();
    let percentile = |pct: usize| -> u32 {
        if steady_times.is_empty() {
            return 0;
        }
        let index = steady_times.len().saturating_mul(pct).div_ceil(100).saturating_sub(1);
        steady_times[index]
    };
    let max_us = steady_times.last().copied().unwrap_or(0);

    Fm1BenchResult {
        status: 0,
        speed_milli_x: if wall_ms == 0 {
            0
        } else {
            ((emulated_ms as u64 * 1_000) / wall_ms as u64).min(u32::MAX as u64) as u32
        },
        emulated_ms,
        wall_ms,
        audio_frames: frames,
        short_quanta,
        over_deadline: steady_times.iter().filter(|&&us| us > deadline_us).count() as u32,
        p95_us: percentile(95),
        p99_us: percentile(99),
        max_us,
        sample_count: sample_count as u32,
        deadline_us,
        native_jit_active: fm1_web::fm1_jit_active(),
        native_jit_compiled_blocks: fm1_web::fm1_jit_compiled_blocks(),
    }
}

fn valid_script(script: &str, run_ms: u32) -> bool {
    if script.trim().is_empty() {
        return true;
    }
    script.split(',').all(|event| {
        let Some((time, action)) = event.trim().split_once(':') else {
            return false;
        };
        let Ok(time) = time.trim().parse::<u32>() else {
            return false;
        };
        if time > run_ms {
            return false;
        }
        let action = action.trim();
        if let Some(hex) = action.strip_prefix('m') {
            return !hex.is_empty()
                && hex.len() % 2 == 0
                && hex.bytes().all(|byte| byte.is_ascii_hexdigit());
        }
        if let Some(value) = action.strip_prefix("pot:") {
            return value.parse::<u16>().is_ok_and(|value| value <= 1023);
        }
        if let Some((channel, value)) = action.strip_prefix('a').and_then(|input| input.split_once(':')) {
            return channel.parse::<u8>().is_ok_and(|channel| channel <= 22)
                && value.parse::<u16>().is_ok_and(|value| value <= 1023);
        }
        if let Some((encoder, clicks)) = action.strip_prefix('e').and_then(|input| input.split_once(':')) {
            return encoder.parse::<u8>().is_ok() && clicks.parse::<i32>().is_ok();
        }
        let (key, velocity, pressure) = match action.split_once(['@', '~']) {
            Some((key, velocity)) => (key, Some(velocity), action.contains('~')),
            None => (action.strip_suffix('^').unwrap_or(action), None, false),
        };
        key.parse::<u8>().is_ok()
            && velocity.is_none_or(|value| value.parse::<u8>().is_ok_and(|value| (1..=127).contains(&value)))
            && (!pressure || velocity.is_some())
    })
}

fn valid_configuration(mhz: u32, run_seconds: u32, warmup_ms: u32, quantum: u32) -> bool {
    (1..=240).contains(&mhz)
        && (1..=MAX_RUN_SECONDS).contains(&run_seconds)
        && warmup_ms <= MAX_WARMUP_MS
        && [32, 64, 128, 256, 512, 1_024].contains(&quantum)
}

#[cfg(test)]
mod tests {
    use super::{valid_configuration, valid_script};

    #[test]
    fn validates_supported_scenarios_within_the_run_window() {
        assert!(valid_script("800:21@100,900:21^,1000:m903c64", 6_000));
        assert!(valid_script("11999:21", 12_000));
        assert!(!valid_script("12001:21", 12_000));
        assert!(valid_script("500:21~90,600:e2:-3,700:a16:700,800:pot:512", 6_000));
        assert!(valid_script("", 6_000));
        assert!(!valid_script("7000:21", 6_000));
        assert!(!valid_script("800:999", 6_000));
        assert!(!valid_script("800:21@0", 6_000));
        assert!(!valid_script("800:m90xz64", 6_000));
        assert!(!valid_script("800:21,,900:22", 6_000));
    }

    #[test]
    fn warmup_is_added_to_the_measurement_duration() {
        assert!(valid_configuration(120, 6, 6_000, 128));
        assert!(valid_configuration(120, 6, 60_000, 128));
        assert!(!valid_configuration(120, 6, 60_001, 128));
    }
}
