use std::ffi::{c_char, c_void};

const MACH_ABSOLUTE_TIME: u32 = 32;
const NANOS_PER_SECOND: u128 = 1_000_000_000;

#[repr(C)]
struct MachTimebaseInfo {
    numer: u32,
    denom: u32,
}

#[repr(C)]
struct JoinToken {
    sig: u32,
    opaque: [u8; 36],
}

#[link(name = "AudioToolbox", kind = "framework")]
unsafe extern "C" {
    fn AudioWorkIntervalCreate(name: *const c_char, clock: u32, attr: *mut c_void) -> *mut c_void;
}

unsafe extern "C" {
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut MachTimebaseInfo) -> i32;
    fn os_workgroup_join(workgroup: *mut c_void, token: *mut JoinToken) -> i32;
    fn os_workgroup_leave(workgroup: *mut c_void, token: *mut JoinToken);
    fn os_workgroup_interval_start(
        interval: *mut c_void,
        start: u64,
        deadline: u64,
        data: *mut c_void,
    ) -> i32;
    fn os_workgroup_interval_finish(interval: *mut c_void, data: *mut c_void) -> i32;
    fn os_release(object: *mut c_void);
}

pub struct AudioWorkInterval {
    interval: *mut c_void,
    token: JoinToken,
    timebase: MachTimebaseInfo,
    joined: bool,
    active: bool,
    cycle_started: bool,
    logged_error: bool,
}

impl AudioWorkInterval {
    pub fn new() -> Option<Self> {
        let name = b"fm1-machine\0";
        let interval = unsafe {
            AudioWorkIntervalCreate(name.as_ptr().cast(), MACH_ABSOLUTE_TIME, std::ptr::null_mut())
        };
        if interval.is_null() {
            eprintln!("fm1-plugin: could not create Audio Work Interval; using QoS only");
            return None;
        }

        let mut timebase = MachTimebaseInfo { numer: 0, denom: 0 };
        let status = unsafe { mach_timebase_info(&mut timebase) };
        if status != 0 || timebase.numer == 0 || timebase.denom == 0 {
            eprintln!("fm1-plugin: could not read Mach timebase ({status}); using QoS only");
            unsafe { os_release(interval) };
            return None;
        }

        let mut token = JoinToken { sig: 0, opaque: [0; 36] };
        let status = unsafe { os_workgroup_join(interval, &mut token) };
        if status != 0 {
            eprintln!("fm1-plugin: could not join Audio Work Interval ({status}); using QoS only");
            unsafe { os_release(interval) };
            return None;
        }

        Some(Self {
            interval,
            token,
            timebase,
            joined: true,
            active: true,
            cycle_started: false,
            logged_error: false,
        })
    }

    pub fn start(&mut self, frames_until_empty: usize, sample_rate: f64) -> bool {
        if !self.active || self.cycle_started {
            return false;
        }
        let start = unsafe { mach_absolute_time() };
        let nanos = (frames_until_empty.max(1) as u128 * NANOS_PER_SECOND
            / sample_rate.max(1.0) as u128)
            .max(1);
        let ticks = nanos
            .saturating_mul(self.timebase.denom as u128)
            .checked_div(self.timebase.numer as u128)
            .unwrap_or(1)
            .max(1)
            .min(u64::MAX as u128) as u64;
        let deadline = start.saturating_add(ticks);
        let status = unsafe {
            os_workgroup_interval_start(self.interval, start, deadline, std::ptr::null_mut())
        };
        if status != 0 {
            self.log_error("start", status);
            self.active = false;
            return false;
        }
        self.cycle_started = true;
        true
    }

    pub fn finish(&mut self) {
        if !self.cycle_started {
            return;
        }
        let status = unsafe { os_workgroup_interval_finish(self.interval, std::ptr::null_mut()) };
        self.cycle_started = false;
        if status != 0 {
            self.log_error("finish", status);
            self.active = false;
        }
    }

    fn log_error(&mut self, operation: &str, status: i32) {
        if !self.logged_error {
            eprintln!("fm1-plugin: Audio Work Interval {operation} failed ({status}); using QoS only");
            self.logged_error = true;
        }
    }
}

impl Drop for AudioWorkInterval {
    fn drop(&mut self) {
        if self.joined {
            unsafe {
                if self.cycle_started {
                    let status =
                        os_workgroup_interval_finish(self.interval, std::ptr::null_mut());
                    if status != 0 {
                        eprintln!("fm1-plugin: Audio Work Interval finish during shutdown failed ({status})");
                    }
                }
                os_workgroup_leave(self.interval, &mut self.token);
                os_release(self.interval);
            }
            self.cycle_started = false;
            self.joined = false;
        }
    }
}
