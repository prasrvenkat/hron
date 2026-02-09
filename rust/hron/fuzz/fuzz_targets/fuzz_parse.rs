#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(s) = std::str::from_utf8(data) {
        // Parse should never panic, only return Ok or Err
        let _ = hron::Schedule::parse(s);
    }
});
