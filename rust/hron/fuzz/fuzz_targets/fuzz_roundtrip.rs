#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(s) = std::str::from_utf8(data) {
        if let Ok(schedule) = hron::Schedule::parse(s) {
            let displayed = schedule.to_string();
            let reparsed = hron::Schedule::parse(&displayed)
                .expect("display output must be parseable");
            let redisplayed = reparsed.to_string();
            assert_eq!(displayed, redisplayed, "roundtrip idempotency failed");
        }
    }
});
