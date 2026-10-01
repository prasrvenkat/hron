import io.hron.HronException;
import io.hron.Schedule;
import java.io.BufferedReader;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

public class Runner {
  // Cases are flat objects of strings and integers; the JDK has no JSON parser.
  private static final Pattern FIELD =
      Pattern.compile("\"(\\w+)\":\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|(-?\\d+))");
  private static final Pattern ZONED = Pattern.compile("(.+)\\[(.+)]");
  private static final DateTimeFormatter ISO =
      DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ssxxx");

  public static void main(String[] args) throws Exception {
    var in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    var out =
        new PrintStream(new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8);
    for (String line; (line = in.readLine()) != null; ) {
      Map<String, String> c = parseCase(line);
      long start = System.nanoTime();
      Evaluated evaluated = run(c);
      long micros = (System.nanoTime() - start) / 1000;
      out.println(
          "{\"id\":" + json(c.get("id")) + "," + outcome(evaluated) + ",\"micros\":" + micros + "}");
    }
  }

  private record Evaluated(Object result, Throwable error) {}

  private static Evaluated run(Map<String, String> c) {
    try {
      return new Evaluated(evaluate(c), null);
    } catch (Exception | StackOverflowError e) {
      return new Evaluated(null, e);
    }
  }

  private static String outcome(Evaluated evaluated) {
    return switch (evaluated.error()) {
      case null -> "\"ok\":true,\"result\":" + json(evaluated.result());
      case HronException e -> "\"ok\":false,\"error\":" + details(e);
      case Throwable e ->
          "\"ok\":false,\"error\":{\"kind\":\"crash\",\"message\":" + json(e.toString()) + "}";
    };
  }

  private static String details(HronException e) {
    var span = e.span().map(s -> List.of(s.start(), s.end())).orElse(null);
    return "{\"kind\":" + json(e.kind().value())
        + ",\"message\":" + json(e.getMessage())
        + ",\"span\":" + json(span)
        + ",\"suggestion\":" + json(e.suggestion().orElse(null)) + "}";
  }

  private static Object evaluate(Map<String, String> c) throws HronException {
    String op = c.get("op");
    if (op.equals("fromCron")) {
      return Schedule.fromCron(c.get("expr")).toString();
    }
    Schedule schedule = Schedule.parse(c.get("expr"));
    return switch (op) {
      case "parse" -> schedule.toString();
      case "toCron" -> schedule.toCron();
      case "next" -> format(schedule.nextFrom(zoned(c.get("now"))));
      case "nextN" -> format(schedule.nextNFrom(zoned(c.get("now")), n(c)).stream());
      case "prev" -> format(schedule.previousFrom(zoned(c.get("now"))));
      case "matches" -> schedule.matches(zoned(c.get("datetime")));
      case "between" -> format(schedule.between(zoned(c.get("from")), zoned(c.get("to"))));
      case "occurrences" -> format(schedule.occurrences(zoned(c.get("from"))).limit(n(c)));
      default -> throw new IllegalArgumentException("unknown op " + op);
    };
  }

  private static int n(Map<String, String> c) {
    return Integer.parseInt(c.get("n"));
  }

  private static ZonedDateTime zoned(String s) {
    Matcher m = ZONED.matcher(s);
    if (!m.matches()) {
      throw new IllegalArgumentException("not a zoned timestamp: " + s);
    }
    return ZonedDateTime.parse(m.group(1), DateTimeFormatter.ISO_OFFSET_DATE_TIME)
        .withZoneSameInstant(ZoneId.of(m.group(2)));
  }

  private static String format(ZonedDateTime t) {
    return ISO.format(t) + "[" + t.getZone().getId() + "]";
  }

  private static String format(Optional<ZonedDateTime> t) {
    return t.map(Runner::format).orElse(null);
  }

  private static List<String> format(Stream<ZonedDateTime> times) {
    return times.map(Runner::format).toList();
  }

  private static Map<String, String> parseCase(String line) {
    Map<String, String> fields = new HashMap<>();
    Matcher m = FIELD.matcher(line);
    while (m.find()) {
      fields.put(m.group(1), m.group(2) != null ? unescape(m.group(2)) : m.group(3));
    }
    return fields;
  }

  private static String unescape(String s) {
    var out = new StringBuilder();
    for (int i = 0; i < s.length(); i++) {
      char ch = s.charAt(i);
      if (ch != '\\') {
        out.append(ch);
        continue;
      }
      char escaped = s.charAt(++i);
      switch (escaped) {
        case 'b' -> out.append('\b');
        case 'f' -> out.append('\f');
        case 'n' -> out.append('\n');
        case 'r' -> out.append('\r');
        case 't' -> out.append('\t');
        case 'u' -> {
          out.append((char) Integer.parseInt(s.substring(i + 1, i + 5), 16));
          i += 4;
        }
        default -> out.append(escaped);
      }
    }
    return out.toString();
  }

  private static String json(Object value) {
    return switch (value) {
      case null -> "null";
      case Boolean b -> b.toString();
      case Integer i -> i.toString();
      case List<?> list ->
          list.stream().map(Runner::json).collect(Collectors.joining(",", "[", "]"));
      default -> {
        var out = new StringBuilder("\"");
        for (char ch : value.toString().toCharArray()) {
          if (ch == '"' || ch == '\\') {
            out.append('\\').append(ch);
          } else if (ch < 0x20) {
            out.append(String.format("\\u%04x", (int) ch));
          } else {
            out.append(ch);
          }
        }
        yield out.append('"').toString();
      }
    };
  }
}
