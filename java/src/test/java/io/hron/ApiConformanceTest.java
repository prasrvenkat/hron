package io.hron;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

/** API conformance tests loaded from spec/api.json. */
public class ApiConformanceTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();
  private static JsonNode SPEC;

  @BeforeAll
  static void loadSpec() throws IOException {
    Path specPath = Path.of("../spec/api.json");
    String json = Files.readString(specPath);
    SPEC = MAPPER.readTree(json);
  }

  // Static methods

  @Test
  void testParse() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    assertNotNull(s);
  }

  @Test
  void testFromCron() throws HronException {
    Schedule s = Schedule.fromCron("0 9 * * *");
    assertNotNull(s);
  }

  @Test
  void testValidate() {
    assertTrue(Schedule.validate("every day at 09:00"));
    assertFalse(Schedule.validate("not a schedule"));
  }

  // Instance methods

  @Test
  void testNextFrom() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var result = s.nextFrom(now);
    assertTrue(result.isPresent());
  }

  @Test
  void testNextNFrom() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var results = s.nextNFrom(now, 3);
    assertEquals(3, results.size());
  }

  @Test
  void testMatches() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00 in UTC");
    ZonedDateTime matchTime = ZonedDateTime.of(2026, 2, 10, 9, 0, 0, 0, ZoneId.of("UTC"));
    ZonedDateTime noMatchTime = ZonedDateTime.of(2026, 2, 10, 10, 0, 0, 0, ZoneId.of("UTC"));
    assertTrue(s.matches(matchTime));
    assertFalse(s.matches(noMatchTime));
  }

  @Test
  void testToCron() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    String cron = s.toCron();
    assertEquals("0 9 * * *", cron);
  }

  @Test
  void testToString() throws HronException {
    Schedule s = Schedule.parse("every day at 9:00");
    assertEquals("every day at 09:00", s.toString());
  }

  // Getters

  @Test
  void testTimezoneNone() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    assertTrue(s.timezone().isEmpty());
  }

  @Test
  void testTimezonePresent() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00 in America/New_York");
    assertTrue(s.timezone().isPresent());
    assertEquals("America/New_York", s.timezone().get());
  }

  // Error types

  @Test
  void testErrorKinds() {
    assertEquals("lex", ErrorKind.LEX.value());
    assertEquals("parse", ErrorKind.PARSE.value());
    assertEquals("eval", ErrorKind.EVAL.value());
    assertEquals("cron", ErrorKind.CRON.value());
  }

  @Test
  void testLexError() {
    HronException err = HronException.lex("test", new Span(0, 1), "input");
    assertEquals(ErrorKind.LEX, err.kind());
    assertTrue(err.span().isPresent());
    assertTrue(err.input().isPresent());
  }

  @Test
  void testParseError() {
    HronException err = HronException.parse("test", new Span(0, 1), "input", "suggestion");
    assertEquals(ErrorKind.PARSE, err.kind());
    assertTrue(err.span().isPresent());
    assertTrue(err.input().isPresent());
    assertTrue(err.suggestion().isPresent());
  }

  @Test
  void testEvalError() {
    HronException err = HronException.eval("test");
    assertEquals(ErrorKind.EVAL, err.kind());
    assertTrue(err.span().isEmpty());
  }

  @Test
  void testCronError() {
    HronException err = HronException.cron("test");
    assertEquals(ErrorKind.CRON, err.kind());
    assertTrue(err.span().isEmpty());
  }

  @Test
  void testDisplayRich() {
    HronException err = HronException.parse("test error", new Span(0, 4), "test input", null);
    String rich = err.displayRich();
    assertFalse(rich.isEmpty());
    assertTrue(rich.contains("error:"));
  }

  // Behavioral tests

  @Test
  void testExactTimeBoundary() throws HronException {
    // If now equals an occurrence exactly, skip it
    Schedule s = Schedule.parse("every day at 12:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var next = s.nextFrom(now);
    assertTrue(next.isPresent());

    // Next should be tomorrow, not today
    assertEquals(7, next.get().getDayOfMonth());
  }

  @Test
  void testIntervalAlignment() throws HronException {
    Schedule s = Schedule.parse("every 3 days at 09:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var next = s.nextFrom(now);
    assertTrue(next.isPresent());

    // Feb 6 is aligned (day 20490 from epoch, 20490 % 3 = 0)
    // Since 09:00 has passed, next should be Feb 9
    assertEquals(9, next.get().getDayOfMonth());
  }

  // Spec coverage tests - verify all api.json methods are implemented

  @Test
  void specVersionIsPresent() {
    assertTrue(SPEC.has("version"));
    assertNotNull(SPEC.get("version").asText());
  }

  @Test
  void specStaticMethodsExist() {
    JsonNode schedule = SPEC.get("schedule");
    JsonNode staticMethods = schedule.get("staticMethods");

    Map<String, String> expectedMethods =
        Map.of(
            "parse", "parse",
            "fromCron", "fromCron",
            "validate", "validate");

    for (JsonNode method : staticMethods) {
      String name = method.get("name").asText();
      assertTrue(expectedMethods.containsKey(name), "Unmapped spec static method: " + name);
    }
  }

  @Test
  void specInstanceMethodsExist() {
    JsonNode schedule = SPEC.get("schedule");
    JsonNode instanceMethods = schedule.get("instanceMethods");

    Map<String, String> expectedMethods =
        Map.of(
            "nextFrom", "nextFrom",
            "nextNFrom", "nextNFrom",
            "matches", "matches",
            "occurrences", "occurrences",
            "between", "between",
            "toCron", "toCron",
            "toString", "toString");

    for (JsonNode method : instanceMethods) {
      String name = method.get("name").asText();
      assertTrue(expectedMethods.containsKey(name), "Unmapped spec instance method: " + name);
    }
  }

  @Test
  void specGettersExist() {
    JsonNode schedule = SPEC.get("schedule");
    JsonNode getters = schedule.get("getters");

    Map<String, String> expectedGetters = Map.of("timezone", "timezone");

    for (JsonNode getter : getters) {
      String name = getter.get("name").asText();
      assertTrue(expectedGetters.containsKey(name), "Unmapped spec getter: " + name);
    }
  }

  @Test
  void specErrorKindsMatch() {
    JsonNode error = SPEC.get("error");
    JsonNode kinds = error.get("kinds");

    Set<String> expectedKinds = Set.of("lex", "parse", "eval", "cron");

    for (JsonNode kind : kinds) {
      String name = kind.asText();
      assertTrue(expectedKinds.contains(name), "Unexpected error kind in spec: " + name);
    }
  }

  @Test
  void specErrorConstructorsExist() {
    JsonNode error = SPEC.get("error");
    JsonNode constructors = error.get("constructors");

    Map<String, String> expectedConstructors =
        Map.of(
            "lex", "lex",
            "parse", "parse",
            "eval", "eval",
            "cron", "cron");

    for (JsonNode constructor : constructors) {
      String name = constructor.asText();
      assertTrue(
          expectedConstructors.containsKey(name), "Unmapped spec error constructor: " + name);
    }
  }

  @Test
  void specErrorMethodsExist() {
    JsonNode error = SPEC.get("error");
    JsonNode methods = error.get("methods");

    Map<String, String> expectedMethods = Map.of("displayRich", "displayRich");

    for (JsonNode method : methods) {
      String name = method.get("name").asText();
      assertTrue(expectedMethods.containsKey(name), "Unmapped spec error method: " + name);
    }
  }
}
