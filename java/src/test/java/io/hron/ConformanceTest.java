package io.hron;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/** Conformance tests loaded from spec/tests.json. */
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

  // Parse tests

  @TestFactory
  Stream<DynamicTest> parseTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode parse = SPEC.get("parse");
    parse
        .fieldNames()
        .forEachRemaining(
            section -> {
              if (section.equals("description")) return;
              JsonNode group = parse.get(section);
              JsonNode testsNode = group.get("tests");
              if (testsNode == null || !testsNode.isArray()) return;

              for (JsonNode tc : testsNode) {
                String name = section + "/" + tc.get("name").asText();
                String input = tc.get("input").asText();
                String canonical = tc.get("canonical").asText();

                tests.add(
                    DynamicTest.dynamicTest(
                        name,
                        () -> {
                          Schedule s = Schedule.parse(input);
                          assertEquals(canonical, s.toString(), "parse(" + input + ").toString()");

                          // Roundtrip test
                          Schedule s2 = Schedule.parse(canonical);
                          assertEquals(
                              canonical,
                              s2.toString(),
                              "roundtrip: parse(" + canonical + ").toString()");
                        }));
              }
            });
    return tests.stream();
  }

  @TestFactory
  Stream<DynamicTest> parseErrorTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode errorTests = SPEC.get("parse_errors").get("tests");

    for (JsonNode tc : errorTests) {
      String name = tc.get("name").asText();
      String input = tc.get("input").asText();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                assertThrows(
                    HronException.class,
                    () -> Schedule.parse(input),
                    "expected parse error for: " + input);
              }));
    }
    return tests.stream();
  }

  // Eval tests

  @TestFactory
  Stream<DynamicTest> evalTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode eval = SPEC.get("eval");
    eval.fieldNames()
        .forEachRemaining(
            section -> {
              if (section.equals("description")) return;
              JsonNode group = eval.get(section);
              JsonNode testsNode = group.get("tests");
              if (testsNode == null || !testsNode.isArray()) return;

              for (JsonNode tc : testsNode) {
                String name = section + "/" + tc.get("name").asText();
                String expression = tc.get("expression").asText();

                // Use test-specific now or default
                ZonedDateTime now =
                    tc.has("now") ? parseZonedDateTime(tc.get("now").asText()) : DEFAULT_NOW;

                // Test next
                if (tc.has("next")) {
                  tests.add(
                      DynamicTest.dynamicTest(
                          name + "/next",
                          () -> {
                            Schedule s = Schedule.parse(expression);
                            var result = s.nextFrom(now);

                            JsonNode nextNode = tc.get("next");
                            if (nextNode.isNull() || nextNode.asText().isEmpty()) {
                              assertTrue(result.isEmpty(), "expected null for nextFrom()");
                            } else {
                              ZonedDateTime expected = parseZonedDateTime(nextNode.asText());
                              assertTrue(result.isPresent(), "expected non-null for nextFrom()");
                              assertEquals(
                                  expected.toInstant(),
                                  result.get().toInstant(),
                                  "nextFrom() mismatch");
                            }
                          }));
                }

                // Test next_date
                if (tc.has("next_date")) {
                  tests.add(
                      DynamicTest.dynamicTest(
                          name + "/next_date",
                          () -> {
                            Schedule s = Schedule.parse(expression);
                            var result = s.nextFrom(now);

                            String expectedDate = tc.get("next_date").asText();
                            assertTrue(result.isPresent(), "expected non-null for nextFrom()");

                            String gotDate = result.get().toLocalDate().toString();
                            assertEquals(expectedDate, gotDate, "nextFrom() date mismatch");
                          }));
                }

                // Test next_n
                if (tc.has("next_n")) {
                  tests.add(
                      DynamicTest.dynamicTest(
                          name + "/next_n",
                          () -> {
                            Schedule s = Schedule.parse(expression);
                            List<String> expectedStrs =
                                MAPPER.convertValue(
                                    tc.get("next_n"), new TypeReference<List<String>>() {});

                            int n =
                                tc.has("next_n_count")
                                    ? tc.get("next_n_count").asInt()
                                    : expectedStrs.size();

                            List<ZonedDateTime> results = s.nextNFrom(now, n);
                            assertEquals(
                                expectedStrs.size(), results.size(), "nextNFrom() count mismatch");

                            for (int i = 0; i < expectedStrs.size(); i++) {
                              ZonedDateTime expected = parseZonedDateTime(expectedStrs.get(i));
                              assertEquals(
                                  expected.toInstant(),
                                  results.get(i).toInstant(),
                                  "nextNFrom()[" + i + "] mismatch");
                            }
                          }));
                }

                // Test next_n_length
                if (tc.has("next_n_length")) {
                  tests.add(
                      DynamicTest.dynamicTest(
                          name + "/next_n_length",
                          () -> {
                            Schedule s = Schedule.parse(expression);
                            int expectedLength = tc.get("next_n_length").asInt();
                            int n = tc.get("next_n_count").asInt();

                            List<ZonedDateTime> results = s.nextNFrom(now, n);
                            assertEquals(
                                expectedLength, results.size(), "nextNFrom() length mismatch");
                          }));
                }
              }
            });
    return tests.stream();
  }

  // PreviousFrom tests

  @TestFactory
  Stream<DynamicTest> previousFromTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode previousFromSection = SPEC.get("eval").get("previous_from");
    if (previousFromSection == null) return tests.stream();

    JsonNode testsNode = previousFromSection.get("tests");
    if (testsNode == null || !testsNode.isArray()) return tests.stream();

    for (JsonNode tc : testsNode) {
      String name = tc.has("name") ? tc.get("name").asText() : tc.get("expression").asText();
      String expression = tc.get("expression").asText();
      String nowStr = tc.get("now").asText();

      tests.add(
          DynamicTest.dynamicTest(
              "previous_from/" + name,
              () -> {
                Schedule s = Schedule.parse(expression);
                ZonedDateTime now = parseZonedDateTime(nowStr);
                var result = s.previousFrom(now);

                JsonNode expectedNode = tc.get("expected");
                if (expectedNode.isNull()) {
                  assertTrue(result.isEmpty(), "expected null for previousFrom()");
                } else {
                  ZonedDateTime expected = parseZonedDateTime(expectedNode.asText());
                  assertTrue(result.isPresent(), "expected non-null for previousFrom()");
                  assertEquals(
                      expected.toInstant(),
                      result.get().toInstant(),
                      "previousFrom() mismatch");
                }
              }));
    }
    return tests.stream();
  }

  // Matches tests

  @TestFactory
  Stream<DynamicTest> matchesTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode matchesSection = SPEC.get("eval").get("matches");
    if (matchesSection == null) return tests.stream();

    JsonNode testsNode = matchesSection.get("tests");
    if (testsNode == null || !testsNode.isArray()) return tests.stream();

    for (JsonNode tc : testsNode) {
      String name = "matches/" + tc.get("name").asText();
      String expression = tc.get("expression").asText();
      String datetimeStr = tc.get("datetime").asText();
      boolean expected = tc.get("expected").asBoolean();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                Schedule s = Schedule.parse(expression);
                ZonedDateTime datetime = parseZonedDateTime(datetimeStr);
                boolean result = s.matches(datetime);
                assertEquals(
                    expected, result, "matches() for: " + expression + " at " + datetimeStr);
              }));
    }
    return tests.stream();
  }

  // Occurrences tests

  @TestFactory
  Stream<DynamicTest> occurrencesTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode occurrencesSection = SPEC.get("eval").get("occurrences");
    if (occurrencesSection == null) return tests.stream();

    JsonNode testsNode = occurrencesSection.get("tests");
    if (testsNode == null || !testsNode.isArray()) return tests.stream();

    for (JsonNode tc : testsNode) {
      String name = "occurrences/" + tc.get("name").asText();
      String expression = tc.get("expression").asText();
      String fromStr = tc.get("from").asText();
      int take = tc.get("take").asInt();
      List<String> expectedStrs =
          MAPPER.convertValue(tc.get("expected"), new TypeReference<List<String>>() {});

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                Schedule s = Schedule.parse(expression);
                ZonedDateTime from = parseZonedDateTime(fromStr);

                List<ZonedDateTime> results = s.occurrences(from).limit(take).toList();

                assertEquals(expectedStrs.size(), results.size(), "occurrences() count mismatch");

                for (int i = 0; i < expectedStrs.size(); i++) {
                  ZonedDateTime expected = parseZonedDateTime(expectedStrs.get(i));
                  assertEquals(
                      expected.toInstant(),
                      results.get(i).toInstant(),
                      "occurrences()[" + i + "] mismatch");
                }
              }));
    }
    return tests.stream();
  }

  // Between tests

  @TestFactory
  Stream<DynamicTest> betweenTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode betweenSection = SPEC.get("eval").get("between");
    if (betweenSection == null) return tests.stream();

    JsonNode testsNode = betweenSection.get("tests");
    if (testsNode == null || !testsNode.isArray()) return tests.stream();

    for (JsonNode tc : testsNode) {
      String name = "between/" + tc.get("name").asText();
      String expression = tc.get("expression").asText();
      String fromStr = tc.get("from").asText();
      String toStr = tc.get("to").asText();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                Schedule s = Schedule.parse(expression);
                ZonedDateTime from = parseZonedDateTime(fromStr);
                ZonedDateTime to = parseZonedDateTime(toStr);

                List<ZonedDateTime> results = s.between(from, to).toList();

                if (tc.has("expected")) {
                  List<String> expectedStrs =
                      MAPPER.convertValue(tc.get("expected"), new TypeReference<List<String>>() {});

                  assertEquals(expectedStrs.size(), results.size(), "between() count mismatch");

                  for (int i = 0; i < expectedStrs.size(); i++) {
                    ZonedDateTime expected = parseZonedDateTime(expectedStrs.get(i));
                    assertEquals(
                        expected.toInstant(),
                        results.get(i).toInstant(),
                        "between()[" + i + "] mismatch");
                  }
                } else if (tc.has("expected_count")) {
                  int expectedCount = tc.get("expected_count").asInt();
                  assertEquals(expectedCount, results.size(), "between() count mismatch");
                }
              }));
    }
    return tests.stream();
  }

  // Cron tests

  @TestFactory
  Stream<DynamicTest> toCronTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode cronTests = SPEC.get("cron").get("to_cron").get("tests");

    for (JsonNode tc : cronTests) {
      String name = tc.get("name").asText();
      String hron = tc.get("hron").asText();
      String expectedCron = tc.get("cron").asText();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                Schedule s = Schedule.parse(hron);
                String cron = s.toCron();
                assertEquals(expectedCron, cron);
              }));
    }
    return tests.stream();
  }

  @TestFactory
  Stream<DynamicTest> toCronErrorTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode cronTests = SPEC.get("cron").get("to_cron_errors").get("tests");

    for (JsonNode tc : cronTests) {
      String name = tc.get("name").asText();
      String hron = tc.get("hron").asText();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                Schedule s = Schedule.parse(hron);
                assertThrows(
                    HronException.class, s::toCron, "expected toCron() error for: " + hron);
              }));
    }
    return tests.stream();
  }

  @TestFactory
  Stream<DynamicTest> fromCronTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode cronTests = SPEC.get("cron").get("from_cron").get("tests");

    for (JsonNode tc : cronTests) {
      String name = tc.get("name").asText();
      String cron = tc.get("cron").asText();
      String expectedHron = tc.get("hron").asText();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                Schedule s = Schedule.fromCron(cron);
                assertEquals(expectedHron, s.toString());
              }));
    }
    return tests.stream();
  }

  @TestFactory
  Stream<DynamicTest> fromCronErrorTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode cronTests = SPEC.get("cron").get("from_cron_errors").get("tests");

    for (JsonNode tc : cronTests) {
      String name = tc.get("name").asText();
      String cron = tc.get("cron").asText();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                assertThrows(
                    HronException.class,
                    () -> Schedule.fromCron(cron),
                    "expected fromCron() error for: " + cron);
              }));
    }
    return tests.stream();
  }

  @TestFactory
  Stream<DynamicTest> cronRoundtripTests() {
    List<DynamicTest> tests = new ArrayList<>();
    JsonNode cronTests = SPEC.get("cron").get("roundtrip").get("tests");

    for (JsonNode tc : cronTests) {
      String name = tc.get("name").asText();
      String hron = tc.get("hron").asText();

      tests.add(
          DynamicTest.dynamicTest(
              name,
              () -> {
                Schedule s1 = Schedule.parse(hron);
                String cron = s1.toCron();

                Schedule s2 = Schedule.fromCron(cron);
                String cron2 = s2.toCron();

                assertEquals(cron, cron2, "roundtrip failed for: " + hron);
              }));
    }
    return tests.stream();
  }

  // Helper: parse zoned datetime with timezone in brackets
  // Format: "2026-02-06T12:00:00+00:00[UTC]"
  private static final Pattern ZDT_PATTERN = Pattern.compile("^(.+?)\\[([^\\]]+)\\]$");

  private static ZonedDateTime parseZonedDateTime(String s) {
    Matcher m = ZDT_PATTERN.matcher(s);
    if (!m.matches()) {
      // Try parsing without brackets
      return ZonedDateTime.parse(s, DateTimeFormatter.ISO_OFFSET_DATE_TIME);
    }

    String isoStr = m.group(1);
    String tzName = m.group(2);

    ZoneId zone = ZoneId.of(tzName);
    ZonedDateTime parsed = ZonedDateTime.parse(isoStr, DateTimeFormatter.ISO_OFFSET_DATE_TIME);
    return parsed.withZoneSameInstant(zone);
  }
}
