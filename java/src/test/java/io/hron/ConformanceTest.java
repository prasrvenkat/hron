package io.hron;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DynamicContainer;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;

public class ConformanceTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();
  private static JsonNode SPEC;
  private static ZonedDateTime DEFAULT_NOW;

  @BeforeAll
  static void loadSpec() throws IOException {
    Path specPath = Path.of("../spec/tests.json");
    String json = Files.readString(specPath);
    SPEC = MAPPER.readTree(json);
    DEFAULT_NOW = parseZonedDateTime(SPEC.get("now").asText());
  }

  private interface CaseCheck {
    void check(JsonNode tc, String label) throws Exception;
  }

  /** One test per case, failing on any field the check does not read. */
  private static Stream<DynamicTest> cases(
      JsonNode section, String prefix, Set<String> fields, CaseCheck check) {
    List<DynamicTest> tests = new ArrayList<>();
    for (JsonNode tc : section.get("tests")) {
      String label = prefix + "/" + tc.get("name").asText();
      tests.add(
          DynamicTest.dynamicTest(
              label,
              () -> {
                assertKnownFields(tc, fields, label);
                check.check(tc, label);
              }));
    }
    return tests.stream();
  }

  private static String text(JsonNode tc, String field, String label) {
    return required(tc, field, label).asText();
  }

  @TestFactory
  Stream<DynamicTest> parseTests() {
    List<DynamicTest> tests = new ArrayList<>();
    SPEC.get("parse")
        .properties()
        .forEach(
            section -> {
              if (section.getKey().equals("description")) return;
              cases(
                      section.getValue(),
                      "parse/" + section.getKey(),
                      Set.of("input", "canonical"),
                      (tc, label) -> {
                        String input = text(tc, "input", label);
                        String canonical = text(tc, "canonical", label);
                        assertEquals(
                            canonical, Schedule.parse(input).toString(), label + ": " + input);
                        assertEquals(
                            canonical,
                            Schedule.parse(canonical).toString(),
                            label + ": roundtrip of " + canonical);
                      })
                  .forEach(tests::add);
            });
    return tests.stream();
  }

  @TestFactory
  Stream<DynamicTest> parseErrorTests() {
    return cases(
        SPEC.get("parse_errors"),
        "parse_errors",
        Set.of("input", "error_contains"),
        (tc, label) -> {
          String input = text(tc, "input", label);
          HronException e =
              assertThrows(HronException.class, () -> Schedule.parse(input), label + ": " + input);
          assertFalse(Schedule.validate(input), label + ": validate(" + input + ")");
          if (tc.has("error_contains")) {
            String expected = tc.get("error_contains").asText();
            assertTrue(
                e.getMessage().contains(expected),
                label + ": error '" + e.getMessage() + "' does not contain '" + expected + "'");
          }
        });
  }

  private static final Set<String> TOP_LEVEL_KEYS =
      Set.of(
          "$schema",
          "version",
          "description",
          "now",
          "_eval_assertion_types",
          "_behavioral_notes",
          "parse",
          "parse_errors",
          "eval",
          "cron",
          "invariants");

  private static final Set<String> CRON_SECTIONS =
      Set.of(
          "description", "to_cron", "to_cron_errors", "from_cron", "from_cron_errors", "roundtrip");

  private static final Set<String> NEXT_SECTIONS =
      Set.of(
          "day_repeat",
          "interval_repeat",
          "month_repeat",
          "week_repeat",
          "single_date",
          "year_repeat",
          "except",
          "until",
          "except_and_until",
          "n_occurrences",
          "multi_time",
          "during",
          "day_ranges",
          "leap_year",
          "dst_spring_forward",
          "dst_fall_back",
          "timezone_default",
          "contradictory",
          "edge_cases");

  private static final Set<String> NEXT_ASSERTIONS =
      Set.of("next", "next_date", "next_n", "next_n_length");

  @Test
  void specHasOnlyKnownSections() {
    assertKnownFields(SPEC, TOP_LEVEL_KEYS, "tests.json");
    assertKnownFields(SPEC.get("cron"), CRON_SECTIONS, "cron");
  }

  @TestFactory
  Stream<DynamicTest> evalTests() {
    List<DynamicTest> tests = new ArrayList<>();
    SPEC.get("eval")
        .properties()
        .forEach(
            section -> {
              if (section.getKey().equals("description")) return;
              for (JsonNode tc : section.getValue().get("tests")) {
                String name = section.getKey() + "/" + tc.get("name").asText();
                tests.add(
                    DynamicTest.dynamicTest(name, () -> checkEvalCase(section.getKey(), name, tc)));
              }
            });
    return tests.stream();
  }

  private static void checkEvalCase(String section, String name, JsonNode tc) throws HronException {
    String label = name + " (" + tc.get("expression").asText() + ")";
    Schedule s = Schedule.parse(tc.get("expression").asText());
    switch (section) {
      case "matches" -> {
        assertKnownFields(tc, Set.of("expression", "datetime", "expected"), label);
        ZonedDateTime datetime = parseZonedDateTime(required(tc, "datetime", label).asText());
        JsonNode expectedNode = required(tc, "expected", label);
        assertTrue(expectedNode.isBoolean(), label + ": expected is not a boolean");
        boolean expected = expectedNode.asBoolean();
        assertEquals(expected, s.matches(datetime), label + ": matches(" + datetime + ")");
      }
      case "previous_from" -> {
        assertKnownFields(tc, Set.of("expression", "now", "expected"), label);
        ZonedDateTime now = parseZonedDateTime(required(tc, "now", label).asText());
        assertEquals(
            timestamp(required(tc, "expected", label)),
            s.previousFrom(now).map(ZonedDateTime::toInstant),
            label + ": previousFrom(" + now + ")");
      }
      case "occurrences" -> {
        assertKnownFields(tc, Set.of("expression", "from", "take", "expected"), label);
        ZonedDateTime from = parseZonedDateTime(required(tc, "from", label).asText());
        int take = required(tc, "take", label).asInt();
        assertEquals(
            timestamps(required(tc, "expected", label)),
            instants(s.occurrences(from).limit(take).toList()),
            label + ": occurrences(" + from + ")");
      }
      case "between" -> {
        assertKnownFields(
            tc, Set.of("expression", "from", "to", "expected", "expected_count"), label);
        ZonedDateTime from = parseZonedDateTime(required(tc, "from", label).asText());
        ZonedDateTime to = parseZonedDateTime(required(tc, "to", label).asText());
        List<Instant> results = instants(s.between(from, to).toList());
        assertTrue(
            tc.has("expected") || tc.has("expected_count"),
            label + ": no expected or expected_count");
        if (tc.has("expected")) {
          assertEquals(timestamps(tc.get("expected")), results, label + ": between()");
        }
        if (tc.has("expected_count")) {
          assertEquals(tc.get("expected_count").asInt(), results.size(), label + ": between()");
        }
      }
      default -> {
        assertTrue(NEXT_SECTIONS.contains(section), "unknown eval section: " + section);
        checkNextCase(s, tc, label);
      }
    }
  }

  private static void checkNextCase(Schedule s, JsonNode tc, String label) {
    assertKnownFields(
        tc,
        Set.of("expression", "now", "next", "next_date", "next_n", "next_n_count", "next_n_length"),
        label);
    assertTrue(
        NEXT_ASSERTIONS.stream().anyMatch(tc::has),
        label + ": no assertion field among " + NEXT_ASSERTIONS);
    ZonedDateTime now = tc.has("now") ? parseZonedDateTime(tc.get("now").asText()) : DEFAULT_NOW;
    Optional<ZonedDateTime> next = s.nextFrom(now);

    if (tc.has("next")) {
      assertEquals(
          timestamp(tc.get("next")), next.map(ZonedDateTime::toInstant), label + ": nextFrom()");
    }
    if (tc.has("next_date")) {
      JsonNode expected = tc.get("next_date");
      assertEquals(
          expected.isNull() ? Optional.empty() : Optional.of(expected.asText()),
          next.map(t -> t.toLocalDate().toString()),
          label + ": nextFrom() date");
    }
    if (tc.has("next_n")) {
      List<Instant> expected = timestamps(tc.get("next_n"));
      int n = tc.has("next_n_count") ? tc.get("next_n_count").asInt() : expected.size();
      assertEquals(expected, instants(s.nextNFrom(now, n)), label + ": nextNFrom(" + n + ")");
    }
    if (tc.has("next_n_length")) {
      int n = required(tc, "next_n_count", label).asInt();
      assertEquals(
          tc.get("next_n_length").asInt(),
          s.nextNFrom(now, n).size(),
          label + ": nextNFrom(" + n + ") length");
    }
  }

  private static JsonNode required(JsonNode tc, String field, String label) {
    assertTrue(tc.has(field), label + ": missing " + field);
    return tc.get(field);
  }

  private static void assertKnownFields(JsonNode node, Set<String> allowed, String label) {
    Set<String> common = Set.of("name", "description");
    List<String> unknown = new ArrayList<>();
    node.fieldNames()
        .forEachRemaining(
            field -> {
              if (!allowed.contains(field) && !common.contains(field)) unknown.add(field);
            });
    assertEquals(List.of(), unknown, label + ": unknown fields");
  }

  private static Optional<Instant> timestamp(JsonNode node) {
    return node.isNull()
        ? Optional.empty()
        : Optional.of(parseZonedDateTime(node.asText()).toInstant());
  }

  private static List<Instant> timestamps(JsonNode node) {
    assertTrue(node.isArray(), "expected a list, got " + node);
    List<Instant> result = new ArrayList<>();
    node.forEach(item -> result.add(parseZonedDateTime(item.asText()).toInstant()));
    return result;
  }

  @TestFactory
  Stream<DynamicTest> cronTests() {
    JsonNode cron = SPEC.get("cron");
    return Stream.of(
            cases(
                cron.get("to_cron"),
                "cron/to_cron",
                Set.of("hron", "cron"),
                (tc, label) ->
                    assertEquals(
                        text(tc, "cron", label),
                        Schedule.parse(text(tc, "hron", label)).toCron(),
                        label)),
            cases(
                cron.get("to_cron_errors"),
                "cron/to_cron_errors",
                Set.of("hron"),
                (tc, label) -> {
                  Schedule s = Schedule.parse(text(tc, "hron", label));
                  assertThrows(HronException.class, s::toCron, label);
                }),
            cases(
                cron.get("from_cron"),
                "cron/from_cron",
                Set.of("cron", "hron"),
                (tc, label) ->
                    assertEquals(
                        text(tc, "hron", label),
                        Schedule.fromCron(text(tc, "cron", label)).toString(),
                        label)),
            cases(
                cron.get("from_cron_errors"),
                "cron/from_cron_errors",
                Set.of("cron"),
                (tc, label) ->
                    assertThrows(
                        HronException.class,
                        () -> Schedule.fromCron(text(tc, "cron", label)),
                        label)),
            cases(
                cron.get("roundtrip"),
                "cron/roundtrip",
                Set.of("hron"),
                (tc, label) -> {
                  String c = Schedule.parse(text(tc, "hron", label)).toCron();
                  assertEquals(c, Schedule.fromCron(c).toCron(), label);
                }))
        .flatMap(tests -> tests);
  }

  private record Invariant(String name, String expression, ZonedDateTime now, int count) {
    Schedule schedule() throws HronException {
      return Schedule.parse(expression);
    }

    String rule(String rule) {
      return "invariants/" + name + " (" + expression + ") " + rule;
    }
  }

  private interface InvariantRule {
    void check(Invariant inv) throws HronException;
  }

  @TestFactory
  Stream<DynamicContainer> invariantTests() {
    JsonNode invariants = SPEC.get("invariants");
    int count = invariants.get("count").asInt();
    Map<String, InvariantRule> implemented =
        Map.of(
            "next_matches", ConformanceTest::nextMatches,
            "next_after_now", ConformanceTest::nextAfterNow,
            "next_n_chain", ConformanceTest::nextNChain,
            "occurrences_prefix", ConformanceTest::occurrencesPrefix,
            "between_window", ConformanceTest::betweenWindow,
            "prev_inverse", ConformanceTest::prevInverse,
            "prev_before_now", ConformanceTest::prevBeforeNow,
            "display_roundtrip", ConformanceTest::displayRoundtrip);
    List<String> rules = new ArrayList<>();
    invariants.get("rules").fieldNames().forEachRemaining(rules::add);

    List<DynamicContainer> containers = new ArrayList<>();
    for (JsonNode tc : invariants.get("tests")) {
      Invariant inv =
          new Invariant(
              tc.get("name").asText(),
              tc.get("expression").asText(),
              parseZonedDateTime(tc.get("now").asText()),
              count);
      Stream<DynamicTest> tests =
          rules.stream()
              .map(
                  rule ->
                      DynamicTest.dynamicTest(
                          rule,
                          () -> {
                            assertKnownFields(
                                tc, Set.of("expression", "now"), "invariants/" + inv.name());
                            assertTrue(
                                implemented.containsKey(rule), "rule not implemented: " + rule);
                            implemented.get(rule).check(inv);
                          }));
      containers.add(DynamicContainer.dynamicContainer("invariants/" + inv.name(), tests));
    }
    return containers.stream();
  }

  private static void nextMatches(Invariant inv) throws HronException {
    Schedule s = inv.schedule();
    s.nextFrom(inv.now())
        .ifPresent(
            t ->
                assertTrue(
                    s.matches(t), inv.rule("next_matches") + ": matches(" + t + ") is false"));
  }

  private static void nextAfterNow(Invariant inv) throws HronException {
    inv.schedule()
        .nextFrom(inv.now())
        .ifPresent(
            t ->
                assertTrue(
                    t.isAfter(inv.now()), inv.rule("next_after_now") + ": nextFrom is " + t));
  }

  private static void nextNChain(Invariant inv) throws HronException {
    Schedule s = inv.schedule();
    List<ZonedDateTime> nextN = s.nextNFrom(inv.now(), inv.count());
    Optional<ZonedDateTime> first = s.nextFrom(inv.now());
    String rule = inv.rule("next_n_chain");
    assertEquals(first.isEmpty(), nextN.isEmpty(), rule + ": emptiness differs from nextFrom(now)");
    if (nextN.isEmpty()) {
      return;
    }
    assertEquals(first.get().toInstant(), nextN.getFirst().toInstant(), rule + ": first element");
    for (int i = 1; i < nextN.size(); i++) {
      ZonedDateTime before = nextN.get(i - 1);
      assertTrue(before.isBefore(nextN.get(i)), rule + ": not strictly increasing at " + i);
      assertEquals(
          Optional.of(nextN.get(i).toInstant()),
          s.nextFrom(before).map(ZonedDateTime::toInstant),
          rule + ": element " + i + " is not nextFrom(" + before + ")");
    }
  }

  private static void occurrencesPrefix(Invariant inv) throws HronException {
    Schedule s = inv.schedule();
    assertEquals(
        instants(s.nextNFrom(inv.now(), inv.count())),
        instants(s.occurrences(inv.now()).limit(inv.count()).toList()),
        inv.rule("occurrences_prefix"));
  }

  private static void betweenWindow(Invariant inv) throws HronException {
    Schedule s = inv.schedule();
    List<ZonedDateTime> nextN = s.nextNFrom(inv.now(), inv.count());
    if (nextN.isEmpty()) {
      return;
    }
    assertEquals(
        instants(nextN),
        instants(s.between(inv.now(), nextN.getLast()).toList()),
        inv.rule("between_window"));
  }

  private static void prevInverse(Invariant inv) throws HronException {
    Schedule s = inv.schedule();
    List<ZonedDateTime> nextN = s.nextNFrom(inv.now(), inv.count());
    for (int i = 1; i < nextN.size(); i++) {
      assertEquals(
          Optional.of(nextN.get(i - 1).toInstant()),
          s.previousFrom(nextN.get(i)).map(ZonedDateTime::toInstant),
          inv.rule("prev_inverse") + ": previousFrom(" + nextN.get(i) + ")");
    }
  }

  private static void prevBeforeNow(Invariant inv) throws HronException {
    Schedule s = inv.schedule();
    Optional<ZonedDateTime> prev = s.previousFrom(inv.now());
    if (prev.isEmpty()) {
      return;
    }
    ZonedDateTime p = prev.get();
    String rule = inv.rule("prev_before_now") + ": previousFrom(now) is " + p;
    assertTrue(p.isBefore(inv.now()), rule + ", not before now");
    assertTrue(s.matches(p), rule + ", which does not match");
    s.nextFrom(p)
        .ifPresent(
            next -> assertFalse(next.isBefore(inv.now()), rule + ", but nextFrom(p) is " + next));
  }

  private static void displayRoundtrip(Invariant inv) throws HronException {
    String display = inv.schedule().toString();
    assertEquals(display, Schedule.parse(display).toString(), inv.rule("display_roundtrip"));
  }

  private static List<Instant> instants(List<ZonedDateTime> times) {
    return times.stream().map(ZonedDateTime::toInstant).toList();
  }

  private static final Pattern ZDT_PATTERN = Pattern.compile("^(.+?)\\[([^\\]]+)\\]$");

  private static ZonedDateTime parseZonedDateTime(String s) {
    Matcher m = ZDT_PATTERN.matcher(s);
    if (!m.matches()) {
      return ZonedDateTime.parse(s, DateTimeFormatter.ISO_OFFSET_DATE_TIME);
    }

    String isoStr = m.group(1);
    String tzName = m.group(2);

    ZoneId zone = ZoneId.of(tzName);
    ZonedDateTime parsed = ZonedDateTime.parse(isoStr, DateTimeFormatter.ISO_OFFSET_DATE_TIME);
    return parsed.withZoneSameInstant(zone);
  }
}
