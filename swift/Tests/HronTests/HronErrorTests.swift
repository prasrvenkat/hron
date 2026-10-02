import Foundation
import Hron
import Testing

@Suite struct HronErrorTests {
  @Test func evalAndCronErrorsRenderTheirMessageAlone() {
    #expect(HronError.eval("no zone").displayRich() == "error: no zone")
    #expect(HronError.cron("bad cron").displayRich() == "error: bad cron")
  }

  @Test func descriptionAndLocalizedDescriptionAreTheMessage() {
    let error = HronError.cron("expected 5 cron fields, got 1")
    #expect(error.description == "expected 5 cron fields, got 1")
    #expect(error.errorDescription == "expected 5 cron fields, got 1")
    #expect((error as any Error).localizedDescription == "expected 5 cron fields, got 1")
  }

  @Test func onlyLexAndParseErrorsHaveASpanAndInput() throws {
    let lex = try #require(
      thrownError { () throws(HronError) in _ = try Schedule.parse("every day at 9h") })
    #expect(lex.kind == .lex && lex.span != nil && lex.input == "every day at 9h")
    #expect(lex.suggestion == nil)
    let cron = try #require(
      thrownError { () throws(HronError) in _ = try Schedule.fromCron("* *") })
    #expect(cron.kind == .cron && cron.span == nil && cron.input == nil && cron.suggestion == nil)
  }

  /// Spans count Unicode scalars: an emoji is one, though it is two UTF-16 units, and a
  /// combining accent is one of its own, though it joins the `e` before it in one `Character`.
  @Test(arguments: [
    ("\u{1F600} every", 0, 1, "unexpected character U+1F600"),
    ("e\u{301}very", 0, 1, "unknown keyword 'e'"),
    ("every\u{301} day", 5, 6, "unexpected character U+0301"),
    ("in \u{1F600} every \u{1F600}", 11, 12, "unexpected character U+1F600"),
    (
      "every day at 09:00 in \u{1F600}x", 22, 24,
      "timezone must be UTC or an Area/Location name such as America/New_York, got \u{1F600}x"
    ),
  ])
  func spansCountCodePoints(_ input: String, _ start: Int, _ end: Int, _ message: String) throws {
    let error = try #require(thrownError { () throws(HronError) in _ = try Schedule.parse(input) })
    #expect(error.message == message)
    #expect(error.span == HronError.Span(start: start, end: end))
  }

  @Test func displayRichAlignsCaretsByCodePoint() throws {
    let error = try #require(
      thrownError { () throws(HronError) in _ = try Schedule.parse("\u{1F600}\tevery") })
    #expect(error.displayRich() == "error: unexpected character U+1F600\n  \u{1F600} every\n  ^")
  }

  @Test(arguments: [
    (-3, -5, "^"), (Int.min, 0, "^"), (Int.min, Int.max, "^^"), (0, Int.max, "^^"),
    (1, Int.max, " ^"), (Int.max, Int.max, "  ^"), (Int.max, Int.min, "  ^"), (2, 1, "  ^"),
  ])
  func displayRichToleratesASpanItDidNotMake(_ start: Int, _ end: Int, _ carets: String) {
    let error = HronError.lex("odd", span: HronError.Span(start: start, end: end), input: "xy")
    #expect(error.displayRich() == "error: odd\n  xy\n  \(carets)")
  }
}
