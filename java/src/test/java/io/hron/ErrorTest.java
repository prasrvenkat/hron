package io.hron;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.Locale;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class ErrorTest {
  private static HronException parseError(String input) {
    return assertThrows(HronException.class, () -> Schedule.parse(input));
  }

  private static void assertError(
      HronException error, ErrorKind kind, String message, int start, int end) {
    assertEquals(kind, error.kind());
    assertEquals(message, error.getMessage());
    assertEquals(Optional.of(new Span(start, end)), error.span());
  }

  @Test
  void loneHighSurrogateIsOneCodePointReportedByItsOwnValue() {
    HronException error = parseError("every \uD800 day");
    assertError(error, ErrorKind.LEX, "unexpected character U+D800", 6, 7);
    assertEquals(
        "error: unexpected character U+D800\n  every \uD800 day\n        ^", error.displayRich());
  }

  @Test
  void loneLowSurrogateIsOneCodePointReportedByItsOwnValue() {
    assertError(parseError("\uDFFF"), ErrorKind.LEX, "unexpected character U+DFFF", 0, 1);
  }

  @Test
  void loneSurrogateAndAstralCharacterBeforeAnErrorCountOneCodePointEach() {
    assertError(
        parseError("every day at 09:00 in \uD800😀 x"),
        ErrorKind.LEX,
        "unknown keyword 'x'",
        25,
        26);
  }

  @Test
  void astralCharacterIsOneCodePoint() {
    assertError(parseError("😀"), ErrorKind.LEX, "unexpected character U+1F600", 0, 1);
  }

  @Test
  void astralCharacterInsideATokenCountsOnce() {
    HronException error = parseError("every day at 09:00 in Nope/😀");
    assertError(
        error,
        ErrorKind.PARSE,
        "timezone must be UTC or an Area/Location name such as America/New_York, got Nope/😀",
        22,
        28);
    assertEquals("  " + " ".repeat(22) + "^".repeat(6), error.displayRich().split("\n", -1)[2]);
  }

  @Test
  void wordsFoldOnlyAsciiCaseWhateverTheDefaultLocale() throws HronException {
    Locale saved = Locale.getDefault();
    try {
      Locale.setDefault(Locale.forLanguageTag("tr-TR"));
      assertEquals(
          "every day at 09:00 in UTC", Schedule.parse("EVERY DAY AT 09:00 IN UTC").toString());
      assertError(
          parseError("every day at 09:00 in UTC İN"),
          ErrorKind.LEX,
          "unexpected character U+0130",
          26,
          27);
    } finally {
      Locale.setDefault(saved);
    }
  }

  @Test
  void evalAndCronErrorsRenderTheirMessageAlone() {
    assertEquals("error: no zone", HronException.eval("no zone").displayRich());
    assertEquals("error: bad cron", HronException.cron("bad cron").displayRich());
  }
}
