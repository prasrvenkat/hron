package io.hron;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.hron.ast.DayFilter;
import io.hron.ast.DayRepeat;
import io.hron.ast.ExceptionSpec;
import io.hron.ast.MonthName;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.TimeOfDay;
import io.hron.ast.UntilSpec;
import io.hron.ast.Weekday;
import java.io.IOException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;

public class ApiConformanceTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();
  private static JsonNode SPEC;

  @BeforeAll
  static void loadSpec() throws IOException {
    Path specPath = Path.of("../spec/api.json");
    String json = Files.readString(specPath);
    SPEC = MAPPER.readTree(json);
  }

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
  void testPreviousFrom() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var result = s.previousFrom(now);
    assertTrue(result.isPresent());
    assertEquals(6, result.get().getDayOfMonth());
    assertEquals(9, result.get().getHour());
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

  @Test
  void gettersReturnTheParts() throws HronException {
    Schedule s =
        Schedule.parse(
            "every monday, friday at 9:00 except dec 25, 2026-07-04 until 2027-01-01"
                + " starting 2026-02-09 during jul, jan in america/new_york");
    assertEquals(
        new DayRepeat(
            1,
            DayFilter.days(List.of(Weekday.MONDAY, Weekday.FRIDAY)),
            List.of(new TimeOfDay(9, 0))),
        s.expression());
    assertEquals(
        List.of(ExceptionSpec.named(MonthName.DECEMBER, 25), ExceptionSpec.iso("2026-07-04")),
        s.except());
    assertEquals(Optional.of(UntilSpec.iso("2027-01-01")), s.until());
    assertEquals(Optional.of("2026-02-09"), s.starting());
    assertEquals(List.of(MonthName.JULY, MonthName.JANUARY), s.during());
    assertEquals(Optional.of("America/New_York"), s.timezone());
  }

  @Test
  void gettersAreEmptyWithoutTheirClauses() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    assertEquals(List.of(), s.except());
    assertEquals(Optional.empty(), s.until());
    assertEquals(Optional.empty(), s.starting());
    assertEquals(List.of(), s.during());
    assertEquals(Optional.empty(), s.timezone());
  }

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

  @Test
  void testExactTimeBoundary() throws HronException {
    Schedule s = Schedule.parse("every day at 12:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var next = s.nextFrom(now);
    assertTrue(next.isPresent());

    assertEquals(7, next.get().getDayOfMonth());
  }

  @Test
  void testIntervalAlignment() throws HronException {
    Schedule s = Schedule.parse("every 3 days at 09:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var next = s.nextFrom(now);
    assertTrue(next.isPresent());

    // Feb 6, 2026 is day 20490 from the epoch, a multiple of 3, so the next
    // aligned day after its 09:00 is Feb 9.
    assertEquals(9, next.get().getDayOfMonth());
  }

  @Test
  void specVersionIsPresent() {
    assertTrue(SPEC.has("version"));
    assertNotNull(SPEC.get("version").asText());
  }

  @Test
  void equalSchedulesHaveEqualParts() throws HronException {
    Schedule schedule = Schedule.parse("every day at 9:00");
    assertEquals(schedule, Schedule.parse("every day at 09:00"));
    assertEquals(schedule.hashCode(), Schedule.parse("every day at 09:00").hashCode());
    assertEquals(Schedule.fromCron("0 9 * * *"), schedule);
    assertNotEquals(schedule, Schedule.parse("every day at 09:00 in UTC"));
    assertNotEquals(schedule, Schedule.parse("every day at 09:01"));
  }

  @Test
  void listsCompareInOrderWithDuplicates() throws HronException {
    Schedule mondayFriday = Schedule.parse("every monday, friday at 09:00");
    assertNotEquals(mondayFriday, Schedule.parse("every friday, monday at 09:00"));
    assertNotEquals(mondayFriday, Schedule.parse("every monday, friday, friday at 09:00"));
    assertNotEquals(
        Schedule.parse("every day at 09:00 during jan, feb"),
        Schedule.parse("every day at 09:00 during feb, jan"));
  }

  @Test
  void aScheduleEqualsNothingButASchedule() throws HronException {
    Schedule schedule = Schedule.parse("every day at 09:00");
    assertFalse(schedule.equals(null));
    assertFalse(schedule.equals("every day at 09:00"));
    assertTrue(schedule.equals(schedule));
  }

  @Test
  void nullInputIsAUsageError() {
    assertAll(
        () -> assertThrows(NullPointerException.class, () -> Schedule.parse(null)),
        () -> assertThrows(NullPointerException.class, () -> Schedule.validate(null)),
        () -> assertThrows(NullPointerException.class, () -> Schedule.fromCron(null)));
  }

  @Test
  void aNullArgumentToAnErrorConstructorIsAUsageError() {
    Span span = new Span(0, 1);
    List<Executable> calls =
        List.of(
            () -> HronException.lex(null, span, "x"),
            () -> HronException.lex("m", null, "x"),
            () -> HronException.lex("m", span, null),
            () -> HronException.parse(null, span, "x", "y"),
            () -> HronException.parse("m", null, "x", "y"),
            () -> HronException.parse("m", span, null, "y"),
            () -> HronException.eval(null),
            () -> HronException.cron(null));
    for (int i = 0; i < calls.size(); i++) {
      Throwable thrown = assertThrows(Throwable.class, calls.get(i), "call " + i);
      assertEquals(NullPointerException.class, thrown.getClass(), "call " + i);
    }
    assertTrue(HronException.parse("m", span, "x", null).suggestion().isEmpty());
  }

  @Test
  void theApiHasEveryMemberOfApiJson() {
    assertEquals(List.of(), missing(SPEC));
  }

  @Test
  void aMemberMissingFromTheApiIsReported() {
    ObjectNode spec = SPEC.deepCopy();
    ObjectNode schedule = (ObjectNode) spec.get("schedule");
    ObjectNode error = (ObjectNode) spec.get("error");
    ((ArrayNode) schedule.get("staticMethods"))
        .addObject()
        .put("name", "fakeStatic")
        .put("returns", "bool");
    ((ArrayNode) schedule.get("instanceMethods"))
        .addObject()
        .put("name", "fakeMethod")
        .put("returns", "bool");
    ((ArrayNode) schedule.get("getters")).addObject().put("name", "fakeGetter").put("type", "int");
    ((ArrayNode) error.get("properties"))
        .addObject()
        .put("name", "fakeProperty")
        .put("type", "int");
    ((ArrayNode) error.get("methods"))
        .addObject()
        .put("name", "fakeErrorMethod")
        .put("returns", "string");
    ((ArrayNode) error.get("constructors")).add("fakeConstructor");
    ((ArrayNode) error.get("kinds")).add("fakeKind");
    ((ObjectNode) schedule.get("getters").get(0)).put("type", "string");
    assertEquals(
        List.of(
            "static method fakeStatic",
            "instance method fakeMethod",
            "getter timezone",
            "getter fakeGetter",
            "error property fakeProperty",
            "error method fakeErrorMethod",
            "error constructor fakeConstructor",
            "error kind fakeKind"),
        missing(spec));
  }

  private static final Map<String, String> JAVA_NOTE_NAMES = Map.of("message", "getMessage");

  private static List<String> missing(JsonNode spec) {
    JsonNode schedule = spec.get("schedule");
    JsonNode error = spec.get("error");
    List<String> missing = new ArrayList<>();
    for (JsonNode method : schedule.get("staticMethods")) {
      check(missing, "static method", Schedule.class, method, true);
    }
    for (JsonNode method : schedule.get("instanceMethods")) {
      check(missing, "instance method", Schedule.class, method, false);
    }
    for (JsonNode getter : schedule.get("getters")) {
      check(missing, "getter", Schedule.class, getter, false);
    }
    for (JsonNode property : error.get("properties")) {
      check(missing, "error property", HronException.class, property, false);
    }
    for (JsonNode method : error.get("methods")) {
      check(missing, "error method", HronException.class, method, false);
    }
    for (JsonNode constructor : error.get("constructors")) {
      String name = constructor.asText();
      boolean found =
          Arrays.stream(HronException.class.getMethods())
              .anyMatch(
                  m ->
                      m.getName().equals(name)
                          && Modifier.isStatic(m.getModifiers())
                          && m.getReturnType() == HronException.class);
      if (!found) {
        missing.add("error constructor " + name);
      }
    }
    Set<String> kinds =
        Arrays.stream(ErrorKind.values()).map(ErrorKind::value).collect(Collectors.toSet());
    for (JsonNode kind : error.get("kinds")) {
      if (!kinds.remove(kind.asText())) {
        missing.add("error kind " + kind.asText());
      }
    }
    kinds.forEach(kind -> missing.add("error kind not in api.json: " + kind));
    return missing;
  }

  private static void check(
      List<String> missing, String what, Class<?> owner, JsonNode member, boolean isStatic) {
    String name = member.get("name").asText();
    // api.json gives a getter or property a "type", which is what it returns.
    String returns = (member.has("returns") ? member.get("returns") : member.get("type")).asText();
    try {
      List<Class<?>> params = new ArrayList<>();
      for (JsonNode param : member.path("params")) {
        params.add(javaType(param.get("type").asText()));
      }
      // The java note: equality is equals(Object) with hashCode.
      if (name.equals("equals")) {
        params = List.of(Object.class);
      }
      Method method =
          owner.getMethod(
              JAVA_NOTE_NAMES.getOrDefault(name, name), params.toArray(Class<?>[]::new));
      boolean declared = owner == HronException.class || method.getDeclaringClass() == owner;
      boolean hashed =
          !name.equals("equals") || owner.getMethod("hashCode").getDeclaringClass() == owner;
      if (!declared
          || !hashed
          || Modifier.isStatic(method.getModifiers()) != isStatic
          || method.getReturnType() != javaType(returns)) {
        missing.add(what + " " + name);
      }
    } catch (NoSuchMethodException e) {
      missing.add(what + " " + name);
    }
  }

  // Optional for "?" is the "java" note's rule. List for "[]" and Stream for an Iterator are
  // this test's own mapping; the note does not name them.
  private static Class<?> javaType(String type) {
    if (type.endsWith("?")) {
      return Optional.class;
    }
    if (type.endsWith("[]")) {
      return List.class;
    }
    if (type.startsWith("Iterator<")) {
      return Stream.class;
    }
    return switch (type) {
      case "string" -> String.class;
      case "bool" -> boolean.class;
      case "int" -> int.class;
      case "ZonedDateTime" -> ZonedDateTime.class;
      case "Schedule" -> Schedule.class;
      case "ScheduleExpr" -> ScheduleExpr.class;
      case "ErrorKind" -> ErrorKind.class;
      default -> throw new IllegalArgumentException("unmapped api.json type " + type);
    };
  }
}
