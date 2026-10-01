package io.hron;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;

class ErrorFuzzTest {
  private static final int INPUTS = 6000;
  private static final long SEED = 0x5EED_4A0EL;

  private static final String WHAT =
      String.join(
          "|",
          "'every' or 'on'",
          "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
          "a unit \\('min', 'hours', 'days', 'weeks', 'months' or 'years'\\)",
          "'at'",
          "a time \\(HH:MM\\)",
          "'from'",
          "'to'",
          "'day', 'weekday', 'weekend' or a day name",
          "'on'",
          "a day name",
          "'the'",
          "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
          "'day', 'weekday' or a day name",
          "'nearest'",
          "'weekday'",
          "a day such as 15th",
          "a month name or 'the'",
          "a day such as 15th, 'last' or an ordinal such as 'first'",
          "'weekday' or a day name",
          "'of'",
          "a month name",
          "a day number",
          "a date \\(YYYY-MM-DD, or a month and day\\)",
          "a date \\(YYYY-MM-DD\\)",
          "a timezone");
  private static final String MONTH = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec";
  private static final String DAY = "[0-9]+(?i:st|nd|rd|th)?";
  private static final String TIME = "[0-9]{1,2}:[0-9]{2}";

  private static final List<String> CLAUSE_ORDER =
      List.of("except", "until", "starting", "during", "in");

  private record Failure(String input, Span span, String spanned) {}

  private interface Check {
    void check(Matcher m, Failure f);
  }

  private record Template(ErrorKind kind, Pattern pattern, Check check) {}

  private static final class Problem extends RuntimeException {
    Problem(String message) {
      super(message);
    }
  }

  private static void ensure(boolean holds, String problem) {
    if (!holds) {
      throw new Problem(problem);
    }
  }

  /** Saturates, since a digit run can be thousands of digits long. */
  private static long value(String text) {
    long n = 0;
    for (int i = 0; i < text.length() && isAsciiDigit(text.charAt(i)); i++) {
      n = n > (Long.MAX_VALUE - 9) / 10 ? Long.MAX_VALUE : n * 10 + (text.charAt(i) - '0');
    }
    return n;
  }

  private static boolean isAsciiDigit(char c) {
    return c >= '0' && c <= '9';
  }

  private static boolean isSeparator(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
  }

  private static String asciiLowercase(String s) {
    StringBuilder out = new StringBuilder();
    for (char c : s.toCharArray()) {
      out.append(c >= 'A' && c <= 'Z' ? (char) (c + 32) : c);
    }
    return out.toString();
  }

  private static String asciiUppercase(String s) {
    StringBuilder out = new StringBuilder();
    for (char c : s.toCharArray()) {
      out.append(c >= 'a' && c <= 'z' ? (char) (c - 32) : c);
    }
    return out.toString();
  }

  private static String group(Matcher m, String name) {
    if (!m.namedGroups().containsKey(name)) {
      return "";
    }
    String text = m.group(name);
    return text == null ? "" : text;
  }

  private static int trimmedEnd(String input) {
    int end = input.length();
    while (end > 0 && isSeparator(input.charAt(end - 1))) {
      end--;
    }
    return end;
  }

  private static boolean isCalendarDate(String date) {
    try {
      return LocalDate.parse(date).getYear() >= 1;
    } catch (DateTimeParseException e) {
      return false;
    }
  }

  private static int minutes(String time) {
    String[] parts = time.split(":");
    return (int) (value(parts[0]) * 60 + value(parts[1]));
  }

  private static Template template(ErrorKind kind, String pattern, Check check) {
    // DOTALL and \z make `.` and the end anchor behave as in the Rust reference's regexes: Java's
    // `.` skips \r, U+0085, U+2028 and U+2029, and its `$` also matches before a final newline.
    return new Template(kind, Pattern.compile("(?s)" + pattern + "\\z"), check);
  }

  /**
   * From spec/README.md, "Lex errors" and "Parse errors". A {@code span} group must equal the
   * spanned text; every other group is read by its template's check.
   */
  private static List<Template> templates() {
    Check noCheck = (m, f) -> {};
    return List.of(
        template(
            ErrorKind.LEX,
            "^unexpected character '(?<span>[!-&(-~])'",
            (m, f) -> {
              char c = f.spanned().isEmpty() ? ' ' : f.spanned().charAt(0);
              boolean startsToken =
                  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isAsciiDigit(c) || c == ',';
              ensure(!startsToken, "'" + c + "' starts a token, so it is never unexpected");
            }),
        template(
            ErrorKind.LEX,
            "^unexpected character U\\+(?<code>[0-9A-F]{4,})",
            (m, f) -> {
              int shown = Integer.parseInt(group(m, "code"), 16);
              boolean quotable = shown >= 0x21 && shown <= 0x7e && shown != 0x27;
              String s = f.spanned();
              ensure(
                  s.codePointCount(0, s.length()) == 1 && s.codePointAt(0) == shown && !quotable,
                  "U+" + group(m, "code") + " does not describe '" + s + "'");
            }),
        template(ErrorKind.LEX, "^unknown keyword '(?<span>[A-Za-z][A-Za-z0-9_]*)'", noCheck),
        template(
            ErrorKind.LEX,
            "^time must be H:MM or HH:MM, got (?<span>(?<hour>[0-9]+):(?<minute>[0-9]*))",
            (m, f) -> {
              String hour = group(m, "hour");
              String minute = group(m, "minute");
              ensure(
                  hour.isEmpty() || hour.length() > 2 || minute.length() != 2,
                  hour + ":" + minute + " is H:MM or HH:MM");
            }),
        template(
            ErrorKind.LEX,
            "^time must be 00:00-23:59, got (?<span>(?<hour>[0-9]{1,2}):(?<minute>[0-9]{2}))",
            (m, f) -> {
              long hour = value(group(m, "hour"));
              long minute = value(group(m, "minute"));
              ensure(hour > 23 || minute > 59, hour + ":" + minute + " is in range");
            }),
        template(
            ErrorKind.LEX,
            "^number must be at most 2147483647",
            (m, f) -> {
              String s = f.spanned();
              boolean digits = !s.isEmpty() && s.chars().allMatch(c -> isAsciiDigit((char) c));
              ensure(
                  digits && value(s) > 2147483647L, "'" + s + "' is not digits above 2147483647");
            }),
        template(
            ErrorKind.PARSE,
            "^empty expression",
            (m, f) ->
                ensure(
                    trimmedEnd(f.input()) == 0 && f.span().equals(new Span(0, 0)),
                    "empty expression with span " + f.span() + " for " + f.input())),
        template(
            ErrorKind.PARSE,
            "^expected (?:" + WHAT + "), got (?:'(?<span>.+)'|(?<end>end of input))",
            (m, f) -> {
              if (m.group("end") == null) {
                return;
              }
              String input = f.input();
              int end = input.codePointCount(0, trimmedEnd(input));
              ensure(
                  f.span().equals(new Span(end, end)),
                  "end of input at " + f.span() + ", expected " + end + ".." + end);
            }),
        template(
            ErrorKind.PARSE,
            "^interval must be 1-2147483647, got (?<span>[0-9]+)",
            (m, f) -> ensure(value(f.spanned()) == 0, "interval " + f.spanned() + " is valid")),
        template(
            ErrorKind.PARSE,
            "^day must be 1-31, got (?<span>" + DAY + ")",
            (m, f) -> {
              long day = value(f.spanned());
              ensure(day == 0 || day > 31, "day " + day + " is within 1-31");
            }),
        template(
            ErrorKind.PARSE,
            "^day must be 1-(?<max>[0-9]+) for (?<month>" + MONTH + "), got (?<span>" + DAY + ")",
            (m, f) -> {
              String month = group(m, "month");
              int length =
                  switch (month) {
                    case "feb" -> 29;
                    case "apr", "jun", "sep", "nov" -> 30;
                    default -> 31;
                  };
              long max = value(group(m, "max"));
              long day = value(f.spanned());
              ensure(
                  max == length && day > max && day <= 31,
                  "day " + day + " against 1-" + max + " for " + month);
            }),
        template(
            ErrorKind.PARSE,
            "^day range must not run backwards: (?<a>" + DAY + ") to (?<b>" + DAY + ")",
            (m, f) -> {
              String a = group(m, "a");
              String b = group(m, "b");
              boolean spansBoth = f.spanned().startsWith(a) && f.spanned().endsWith(b);
              ensure(
                  spansBoth && value(a) > value(b),
                  a + " to " + b + " against the span '" + f.spanned() + "'");
            }),
        template(
            ErrorKind.PARSE,
            "^time window must not run backwards: (?<from>"
                + TIME
                + ") to (?<to>"
                + TIME
                + ") \\(a window cannot cross midnight\\)",
            (m, f) -> {
              String from = group(m, "from");
              String to = group(m, "to");
              boolean spansBoth = f.spanned().startsWith(from) && f.spanned().endsWith(to);
              ensure(
                  spansBoth && minutes(from) > minutes(to),
                  from + " to " + to + " against the span '" + f.spanned() + "'");
            }),
        template(
            ErrorKind.PARSE,
            "^date must be a calendar date from 0001-01-01 to 9999-12-31, got"
                + " (?<span>[0-9]{4}-[0-9]{2}-[0-9]{2})",
            (m, f) -> ensure(!isCalendarDate(f.spanned()), f.spanned() + " is a calendar date")),
        template(
            ErrorKind.PARSE,
            "^timezone must be UTC or an Area/Location name such as America/New_York, got"
                + " (?<span>.+)",
            noCheck),
        template(
            ErrorKind.PARSE,
            "^duplicate '(?<keyword>except|until|starting|during|in)' clause",
            (m, f) ->
                ensure(
                    group(m, "keyword").equals(asciiLowercase(f.spanned())),
                    "duplicate '"
                        + group(m, "keyword")
                        + "' but the span holds '"
                        + f.spanned()
                        + "'")),
        template(
            ErrorKind.PARSE,
            "^'(?<keyword>[a-z]+)' must come before '(?<last>[a-z]+)'",
            (m, f) -> {
              String keyword = group(m, "keyword");
              String last = group(m, "last");
              int k = CLAUSE_ORDER.indexOf(keyword);
              int l = CLAUSE_ORDER.indexOf(last);
              boolean earlier = k >= 0 && l >= 0 && k < l;
              ensure(
                  earlier && keyword.equals(asciiLowercase(f.spanned())),
                  "'" + keyword + "' before '" + last + "' with the span '" + f.spanned() + "'");
            }),
        template(ErrorKind.PARSE, "^unexpected '(?<span>.+)' after the schedule", noCheck),
        template(
            ErrorKind.PARSE,
            "^until (?<month>"
                + MONTH
                + ") (?<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date",
            (m, f) -> {
              String spanned = f.spanned();
              List<String> words =
                  Arrays.stream(spanned.split("[ \t\r\n]")).filter(w -> !w.isEmpty()).toList();
              boolean endsAtDay =
                  !spanned.isEmpty() && !isSeparator(spanned.charAt(spanned.length() - 1));
              boolean matchesMessage =
                  endsAtDay
                      && words.size() == 3
                      && asciiLowercase(words.get(0)).equals("until")
                      && asciiLowercase(words.get(1)).startsWith(group(m, "month"))
                      && isAsciiDigit(words.get(2).charAt(0))
                      && Long.toString(value(words.get(2))).equals(group(m, "day"));
              ensure(
                  matchesMessage,
                  "the span '"
                      + spanned
                      + "' is not 'until "
                      + group(m, "month")
                      + " "
                      + group(m, "day")
                      + "'");
            }));
  }

  private static final String[] FRAGMENTS = {
    "every",
    "on",
    "at",
    "from",
    "to",
    "in",
    "IN",
    "of",
    "the",
    "last",
    "except",
    "until",
    "starting",
    "during",
    "nearest",
    "next",
    "previous",
    "day",
    "Days",
    "weekdays",
    "weekend",
    "week",
    "month",
    "years",
    "min",
    "hrs",
    "monday",
    "FRI",
    "jan",
    "february",
    "first",
    "fifth",
    "0",
    "1",
    "00",
    "15th",
    "31ST",
    "2nd",
    "2147483647",
    "2147483648",
    "99999999999999999999",
    "09:00",
    "9:5",
    "24:00",
    "9:",
    "17:30",
    "2026-02-28",
    "2026-02-30",
    "0000-01-01",
    "12026-03-15",
    ",",
    ":",
    "-",
    "/",
    "'",
    "\"",
    "#",
    "~",
    "_",
    "UTC",
    "America/New_York",
    "Nope/Zone",
    "Europe/" + Character.toString(0x130) + "stanbul",
    Character.toString(0xE9),
    "e" + Character.toString(0x301),
    Character.toString(0x212A),
    Character.toString(0xA0),
    Character.toString(0x2028),
    Character.toString(0xFEFF),
    Character.toString(0xFF10),
    "😀",
    Character.toString(0x10FFFF),
    Character.toString(0x1D7D8),
    "\uD800",
    "\uDFFF",
    "\u0000",
    "\u000b",
    "\u000c",
    "\u007f",
    "\u001b",
  };
  private static final String[] SEPARATORS = {"", " ", " ", " ", "  ", "\t", "\r\n", "\n"};

  private static final String[] CLAUSES = {
    "except dec 25",
    "except 2026-12-25, jan 1",
    "until 2027-12-31",
    "until dec 31",
    "starting 2026-01-01",
    "during jan, jul",
    "in UTC",
    "IN America/New_York",
  };

  private static final class Rng {
    private long state;

    Rng(long seed) {
      state = seed;
    }

    // SplitMix64: a fixed seed gives the same inputs on every platform.
    long next() {
      state += 0x9E3779B97F4A7C15L;
      long z = state;
      z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
      z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
      return z ^ (z >>> 31);
    }

    int below(int n) {
      return (int) Long.remainderUnsigned(next(), n);
    }

    String pick(String[] items) {
      return items[below(items.length)];
    }
  }

  private static List<String> corpus() throws IOException {
    JsonNode spec = new ObjectMapper().readTree(Files.readString(Path.of("../spec/tests.json")));
    List<String> inputs = new ArrayList<>();
    spec.get("parse")
        .forEach(
            section -> {
              if (section.has("tests")) {
                section.get("tests").forEach(c -> inputs.add(c.get("input").asText()));
              }
            });
    spec.get("parse_errors").get("tests").forEach(c -> inputs.add(c.get("input").asText()));
    return inputs;
  }

  private static String randomText(Rng rng) {
    StringBuilder out = new StringBuilder();
    for (int i = rng.below(12); i >= 0; i--) {
      out.append(rng.pick(SEPARATORS)).append(rng.pick(FRAGMENTS));
    }
    return out.toString();
  }

  private static String mutate(Rng rng, String input) {
    List<String> words = new ArrayList<>(Arrays.asList(input.split(" ", -1)));
    int i = rng.below(words.size());
    switch (rng.below(7)) {
      case 0 -> words.remove(i);
      case 1 -> {
        int j = rng.below(words.size());
        String w = words.get(i);
        words.set(i, words.get(j));
        words.set(j, w);
      }
      case 2 -> words.add(rng.below(words.size() + 1), words.get(i));
      case 3 -> {
        int keep = rng.below(input.codePointCount(0, input.length()) + 1);
        return input.substring(0, input.offsetByCodePoints(0, keep));
      }
      case 4 -> words.set(i, asciiUppercase(words.get(i)));
      case 5 -> words.set(i, rng.pick(FRAGMENTS));
      default -> {
        String fragment = rng.pick(FRAGMENTS);
        String word = words.get(i);
        int at = word.offsetByCodePoints(0, rng.below(word.codePointCount(0, word.length()) + 1));
        words.set(i, word.substring(0, at) + fragment + word.substring(at));
      }
    }
    return String.join(" ", words);
  }

  private static String withClauses(Rng rng, String input) {
    StringBuilder out = new StringBuilder(input);
    for (int i = rng.below(4); i >= 0; i--) {
      out.append(' ').append(rng.pick(CLAUSES));
    }
    return out.toString();
  }

  private static String generate(Rng rng, List<String> corpus) {
    return switch (rng.below(4)) {
      case 0 -> randomText(rng);
      case 1 -> withClauses(rng, corpus.get(rng.below(corpus.size())));
      default -> {
        String input = corpus.get(rng.below(corpus.size()));
        for (int i = rng.below(4); i > 0; i--) {
          input = mutate(rng, input);
        }
        yield input;
      }
    };
  }

  private static String spanned(String input, Span span) {
    return input.substring(
        input.offsetByCodePoints(0, span.start()), input.offsetByCodePoints(0, span.end()));
  }

  private static int checkedTemplateIndex(
      String input, HronException error, List<Template> templates) {
    ensure(
        error.kind() == ErrorKind.LEX || error.kind() == ErrorKind.PARSE,
        "neither lex nor parse: " + error.kind());
    ensure(!Schedule.validate(input), "validate is true");
    ensure(
        error.input().equals(Optional.of(input)), "error input is " + error.input().orElse(null));
    Span span = error.span().orElseThrow(() -> new Problem("no span"));
    int length = input.codePointCount(0, input.length());
    ensure(
        0 <= span.start() && span.start() <= span.end() && span.end() <= length,
        "span " + span + " outside 0..=" + length);
    Failure failure = new Failure(input, span, spanned(input, span));

    String message = error.getMessage();
    int index = -1;
    Matcher matcher = null;
    for (int i = 0; i < templates.size() && index < 0; i++) {
      Matcher m = templates.get(i).pattern().matcher(message);
      if (templates.get(i).kind() == error.kind() && m.find()) {
        index = i;
        matcher = m;
      }
    }
    ensure(index >= 0, error.kind() + " message '" + message + "' matches no template");
    if (matcher.namedGroups().containsKey("span") && matcher.group("span") != null) {
      String echoed = matcher.group("span");
      ensure(
          echoed.equals(failure.spanned()),
          "message echoes '" + echoed + "' but the span holds '" + failure.spanned() + "'");
    }
    templates.get(index).check().check(matcher, failure);

    Optional<String> expectedSuggestion =
        message.startsWith("until ")
            ? Optional.of(
                "until "
                    + group(matcher, "month")
                    + " "
                    + group(matcher, "day")
                    + " starting YYYY-MM-DD")
            : Optional.empty();
    ensure(
        error.suggestion().equals(expectedSuggestion),
        "suggestion " + error.suggestion() + ", expected " + expectedSuggestion);

    String rich = error.displayRich();
    ensure(
        rich.split("\n", -1).length == 3 && rich.startsWith("error: " + message + "\n"),
        "displayRich is not three lines: " + rich);
    return index;
  }

  @Test
  void generatedInputsFailOnlyWithSpecErrors() throws IOException {
    List<Template> templates = templates();
    List<String> corpus = corpus();
    Rng rng = new Rng(SEED);
    int[] hits = new int[templates.size()];
    int parsed = 0;
    List<String> failures = new ArrayList<>();

    for (int n = 0; n < INPUTS; n++) {
      String input = generate(rng, corpus);
      try {
        Schedule.parse(input);
        parsed++;
      } catch (HronException error) {
        try {
          hits[checkedTemplateIndex(input, error, templates)]++;
        } catch (Problem problem) {
          failures.add(quoted(input) + ": " + problem.getMessage());
        }
      } catch (RuntimeException | StackOverflowError e) {
        failures.add(quoted(input) + ": parse threw " + e);
      }
    }

    assertEquals(
        List.of(),
        failures.subList(0, Math.min(20, failures.size())),
        failures.size() + " failures, first ones");
    assertTrue(
        parsed > INPUTS / 20, "only " + parsed + " inputs parsed; the generator has drifted");
    List<String> unused = new ArrayList<>();
    for (int i = 0; i < templates.size(); i++) {
      if (hits[i] == 0) {
        unused.add(templates.get(i).pattern().pattern());
      }
    }
    assertEquals(List.of(), unused, "templates no input produced");
  }

  private static String quoted(String input) {
    StringBuilder out = new StringBuilder("\"");
    input
        .codePoints()
        .forEach(
            c -> {
              if (c < 0x20 || c == 0x7f || (c >= 0xD800 && c <= 0xDFFF)) {
                out.append(String.format("\\u%04x", c));
              } else {
                out.appendCodePoint(c);
              }
            });
    return out.append('"').toString();
  }
}
