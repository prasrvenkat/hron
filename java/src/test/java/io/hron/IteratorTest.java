package io.hron;

import org.junit.jupiter.api.Test;

import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Iterator-specific tests for {@code occurrences()} and {@code between()} methods.
 *
 * These tests verify Java-specific Stream behavior beyond conformance tests:
 * - Laziness (streams don't evaluate eagerly)
 * - Early termination
 * - Integration with Stream methods (map, filter, collect)
 * - forEach patterns
 */
class IteratorTest {

    private static ZonedDateTime parseZoned(String s) {
        // Parse '2026-02-06T12:00:00+00:00[UTC]' format
        int bracketIdx = s.indexOf('[');
        String isoStr = s.substring(0, bracketIdx);
        String tzName = s.substring(bracketIdx + 1, s.length() - 1);
        ZoneId zone = ZoneId.of(tzName);
        return ZonedDateTime.parse(isoStr, DateTimeFormatter.ISO_OFFSET_DATE_TIME).withZoneSameInstant(zone);
    }

    // =========================================================================
    // Laziness Tests
    // =========================================================================

    @Test
    void occurrencesIsLazy() throws HronException {
        // An unbounded schedule should not hang or OOM when creating the stream
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Creating the stream should be instant (lazy)
        Stream<ZonedDateTime> stream = schedule.occurrences(from);

        // Taking just 1 should work without evaluating the rest
        List<ZonedDateTime> results = stream.limit(1).collect(Collectors.toList());
        assertEquals(1, results.size());
    }

    @Test
    void betweenIsLazy() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
        ZonedDateTime to = parseZoned("2026-12-31T23:59:00+00:00[UTC]");

        // Creating the stream should be instant
        Stream<ZonedDateTime> stream = schedule.between(from, to);

        // Taking just 3 should not evaluate all ~330 days
        List<ZonedDateTime> results = stream.limit(3).collect(Collectors.toList());
        assertEquals(3, results.size());
    }

    // =========================================================================
    // Early Termination Tests
    // =========================================================================

    @Test
    void occurrencesEarlyTerminationWithLimit() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        List<ZonedDateTime> results = schedule.occurrences(from)
                .limit(5)
                .collect(Collectors.toList());

        assertEquals(5, results.size());
    }

    @Test
    void occurrencesEarlyTerminationWithTakeWhile() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
        ZonedDateTime cutoff = parseZoned("2026-02-05T00:00:00+00:00[UTC]");

        List<ZonedDateTime> results = schedule.occurrences(from)
                .takeWhile(dt -> dt.isBefore(cutoff))
                .collect(Collectors.toList());

        // Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
        assertEquals(4, results.size());
    }

    @Test
    void occurrencesFindFirstSaturday() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Find the first Saturday occurrence
        Optional<ZonedDateTime> saturday = schedule.occurrences(from)
                .filter(dt -> dt.getDayOfWeek().getValue() == 6) // Saturday
                .findFirst();

        // Feb 7, 2026 is a Saturday
        assertTrue(saturday.isPresent());
        assertEquals(7, saturday.get().getDayOfMonth());
    }

    // =========================================================================
    // Stream Methods Tests
    // =========================================================================

    @Test
    void worksWithFilter() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Filter to only weekends from first 14 days
        List<ZonedDateTime> weekends = schedule.occurrences(from)
                .limit(14)
                .filter(dt -> {
                    int dow = dt.getDayOfWeek().getValue();
                    return dow == 6 || dow == 7; // Saturday or Sunday
                })
                .collect(Collectors.toList());

        // 2 weekends in 2 weeks = 4 days
        assertEquals(4, weekends.size());
    }

    @Test
    void worksWithMap() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Map to just the day number
        List<Integer> days = schedule.occurrences(from)
                .limit(5)
                .map(ZonedDateTime::getDayOfMonth)
                .collect(Collectors.toList());

        assertEquals(List.of(1, 2, 3, 4, 5), days);
    }

    @Test
    void worksWithSkip() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Skip first 5, take next 3
        List<ZonedDateTime> results = schedule.occurrences(from)
                .skip(5)
                .limit(3)
                .collect(Collectors.toList());

        assertEquals(3, results.size());
        // Should be Feb 6, 7, 8
        assertEquals(6, results.get(0).getDayOfMonth());
        assertEquals(7, results.get(1).getDayOfMonth());
        assertEquals(8, results.get(2).getDayOfMonth());
    }

    @Test
    void betweenWorksWithCount() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
        ZonedDateTime to = parseZoned("2026-02-10T23:59:00+00:00[UTC]");

        // Count occurrences in range
        long count = schedule.between(from, to).count();

        // Feb 1-10 inclusive = 10 days
        assertEquals(10, count);
    }

    @Test
    void worksWithReduce() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
        ZonedDateTime to = parseZoned("2026-02-10T23:59:00+00:00[UTC]");

        // Find the last occurrence using reduce
        Optional<ZonedDateTime> last = schedule.between(from, to)
                .reduce((first, second) -> second);

        assertTrue(last.isPresent());
        assertEquals(10, last.get().getDayOfMonth());
    }

    // =========================================================================
    // Collect Patterns
    // =========================================================================

    @Test
    void occurrencesCollectToList() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 until 2026-02-05 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        List<ZonedDateTime> results = schedule.occurrences(from).collect(Collectors.toList());

        assertEquals(5, results.size()); // Feb 1-5
    }

    @Test
    void betweenCollectToList() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
        ZonedDateTime to = parseZoned("2026-02-07T23:59:00+00:00[UTC]");

        List<ZonedDateTime> results = schedule.between(from, to).collect(Collectors.toList());

        assertEquals(7, results.size());
    }

    // =========================================================================
    // forEach Patterns
    // =========================================================================

    @Test
    void occurrencesForEachWithCounter() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        AtomicInteger count = new AtomicInteger(0);
        schedule.occurrences(from)
                .limit(5)
                .forEach(dt -> count.incrementAndGet());

        assertEquals(5, count.get());
    }

    @Test
    void betweenForEachCollectDays() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
        ZonedDateTime to = parseZoned("2026-02-03T23:59:00+00:00[UTC]");

        List<Integer> days = new java.util.ArrayList<>();
        schedule.between(from, to).forEach(dt -> days.add(dt.getDayOfMonth()));

        assertEquals(List.of(1, 2, 3), days);
    }

    // =========================================================================
    // Edge Cases
    // =========================================================================

    @Test
    void occurrencesEmptyWhenPastUntil() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 until 2026-01-01 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        List<ZonedDateTime> results = schedule.occurrences(from)
                .limit(10)
                .collect(Collectors.toList());

        assertEquals(0, results.size());
    }

    @Test
    void betweenEmptyRange() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T12:00:00+00:00[UTC]");
        ZonedDateTime to = parseZoned("2026-02-01T13:00:00+00:00[UTC]");

        List<ZonedDateTime> results = schedule.between(from, to).collect(Collectors.toList());

        assertEquals(0, results.size());
    }

    @Test
    void occurrencesSingleDateTerminates() throws HronException {
        Schedule schedule = Schedule.parse("on 2026-02-14 at 14:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Request many but should only get 1
        List<ZonedDateTime> results = schedule.occurrences(from)
                .limit(100)
                .collect(Collectors.toList());

        assertEquals(1, results.size());
    }

    // =========================================================================
    // Timezone Handling
    // =========================================================================

    @Test
    void occurrencesPreservesTimezone() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in America/New_York");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00-05:00[America/New_York]");

        List<ZonedDateTime> results = schedule.occurrences(from)
                .limit(3)
                .collect(Collectors.toList());

        for (ZonedDateTime dt : results) {
            assertEquals(ZoneId.of("America/New_York"), dt.getZone());
        }
    }

    @Test
    void betweenHandlesDSTTransition() throws HronException {
        // March 8, 2026 is DST spring forward in America/New_York
        // 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
        Schedule schedule = Schedule.parse("every day at 02:30 in America/New_York");
        ZonedDateTime from = parseZoned("2026-03-07T00:00:00-05:00[America/New_York]");
        ZonedDateTime to = parseZoned("2026-03-10T00:00:00-04:00[America/New_York]");

        List<ZonedDateTime> results = schedule.between(from, to).collect(Collectors.toList());

        // Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
        assertEquals(3, results.size());
        assertEquals(2, results.get(0).getHour()); // Mar 7 02:30
        assertEquals(3, results.get(1).getHour()); // Mar 8 03:30 (shifted due to DST)
        assertEquals(2, results.get(2).getHour()); // Mar 9 02:30
    }

    // =========================================================================
    // Multiple Times Per Day
    // =========================================================================

    @Test
    void occurrencesMultipleTimesPerDay() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00, 12:00, 17:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        List<ZonedDateTime> results = schedule.occurrences(from)
                .limit(9) // 3 days worth
                .collect(Collectors.toList());

        assertEquals(9, results.size());
        // First day: 09:00, 12:00, 17:00
        assertEquals(9, results.get(0).getHour());
        assertEquals(12, results.get(1).getHour());
        assertEquals(17, results.get(2).getHour());
    }

    // =========================================================================
    // Complex Stream Chains
    // =========================================================================

    @Test
    void complexStreamChain() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Complex chain: skip weekends, take first 5 weekdays, get their day numbers
        List<Integer> weekdayDays = schedule.occurrences(from)
                .limit(14) // Two weeks to ensure we have enough
                .filter(dt -> {
                    int dow = dt.getDayOfWeek().getValue();
                    return dow >= 1 && dow <= 5; // Monday-Friday
                })
                .limit(5)
                .map(ZonedDateTime::getDayOfMonth)
                .collect(Collectors.toList());

        // Feb 2026: 2,3,4,5,6 are Mon-Fri
        assertEquals(List.of(2, 3, 4, 5, 6), weekdayDays);
    }

    // =========================================================================
    // Stream Properties
    // =========================================================================

    @Test
    void occurrencesReturnsStream() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        Stream<ZonedDateTime> stream = schedule.occurrences(from);

        assertNotNull(stream);
        // Streams are one-shot, consuming it
        stream.limit(1).forEach(dt -> {});
    }

    @Test
    void betweenReturnsStream() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
        ZonedDateTime to = parseZoned("2026-02-05T00:00:00+00:00[UTC]");

        Stream<ZonedDateTime> stream = schedule.between(from, to);

        assertNotNull(stream);
    }

    @Test
    void streamIsSequential() throws HronException {
        Schedule schedule = Schedule.parse("every day at 09:00 in UTC");
        ZonedDateTime from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

        Stream<ZonedDateTime> stream = schedule.occurrences(from);

        assertFalse(stream.isParallel());
    }
}
