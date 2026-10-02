import Foundation

public struct HronError: Error, Hashable, Sendable, CustomStringConvertible {
  public enum Kind: Hashable, Sendable {
    case lex, parse, eval, cron
  }

  /// The part of the input an error points at: `start..<end`, counted in Unicode scalars (code
  /// points), not in `Character`s or UTF-16 units.
  public struct Span: Hashable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
      self.start = start
      self.end = end
    }
  }

  public let kind: Kind
  public let message: String
  /// Set for `lex` and `parse` errors only.
  public let span: Span?
  /// The expression as given; set for `lex` and `parse` errors only.
  public let input: String?
  /// Text to put in place of the span; only a `parse` error may have one.
  public let suggestion: String?

  public static func lex(_ message: String, span: Span, input: String) -> HronError {
    HronError(kind: .lex, message: message, span: span, input: input, suggestion: nil)
  }

  public static func parse(
    _ message: String, span: Span, input: String, suggestion: String? = nil
  ) -> HronError {
    HronError(kind: .parse, message: message, span: span, input: input, suggestion: suggestion)
  }

  public static func eval(_ message: String) -> HronError {
    HronError(kind: .eval, message: message, span: nil, input: nil, suggestion: nil)
  }

  public static func cron(_ message: String) -> HronError {
    HronError(kind: .cron, message: message, span: nil, input: nil, suggestion: nil)
  }

  /// Exactly ``message``.
  public var description: String { message }

  /// `error: {message}`, then for an error with a span the input and a line of carets under the
  /// span, ending with any suggestion as ` try: "..."`. No trailing newline.
  public func displayRich() -> String {
    guard let span, let input else { return "error: \(message)" }
    // A tab, CR or LF would move the input off the line the carets are aligned to.
    let shown = String(
      String.UnicodeScalarView(
        input.unicodeScalars.map { "\t\r\n".unicodeScalars.contains($0) ? " " : $0 }))
    // A span built by hand can be negative, run backwards or end past the input.
    let length = input.unicodeScalars.count
    let start = min(max(span.start, 0), length)
    let end = min(max(span.end, start), length)
    let spaces = String(repeating: " ", count: start)
    let carets = String(repeating: "^", count: max(end - start, 1))
    var rich = "error: \(message)\n  \(shown)\n  \(spaces)\(carets)"
    if let suggestion {
      rich += " try: \"\(suggestion)\""
    }
    return rich
  }
}

extension HronError: LocalizedError {
  public var errorDescription: String? { message }
}
