# frozen_string_literal: true

module Hron
  # The part of the input an error points at: [start, end_pos) counted in code points, which are
  # the indices of a valid UTF-8 String. Each byte of invalid UTF-8 counts as one code point.
  Span = Data.define(:start, :end_pos) do # end_pos to avoid Ruby keyword
    def length
      end_pos - start
    end
  end

  module ErrorKind
    LEX = :lex
    PARSE = :parse
    EVAL = :eval
    CRON = :cron
  end

  module Utf8
    REPLACEMENT = "�"

    # The spec counts each byte of invalid UTF-8 as one U+FFFD; `scrub` alone would replace a
    # truncated multi-byte sequence with a single one. A binary String is read as UTF-8 bytes.
    def self.convert(input)
      return input if input.encoding == Encoding::UTF_8 && input.valid_encoding?

      if input.encoding == Encoding::UTF_8 || input.encoding == Encoding::BINARY
        return input.b.force_encoding(Encoding::UTF_8).scrub { |bytes| REPLACEMENT * bytes.bytesize }
      end

      input.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
    rescue EncodingError
      input.b.force_encoding(Encoding::UTF_8).scrub { |bytes| REPLACEMENT * bytes.bytesize }
    end
  end
  private_constant :Utf8

  class HronError < StandardError
    attr_reader :kind, :span, :input, :suggestion

    def initialize(kind, message, span: nil, input: nil, suggestion: nil)
      super(message)
      @kind = kind
      @span = span
      @input = input
      @suggestion = suggestion
    end

    def self.lex(message, span, input)
      new(ErrorKind::LEX, message, span: span, input: input)
    end

    def self.parse(message, span, input, suggestion: nil)
      new(ErrorKind::PARSE, message, span: span, input: input, suggestion: suggestion)
    end

    def self.eval(message)
      new(ErrorKind::EVAL, message)
    end

    def self.cron(message)
      new(ErrorKind::CRON, message)
    end

    # The message, then for lex and parse errors the input and a line of carets under the span,
    # and any suggestion as ` try: "..."`. Lines are joined by "\n", with no trailing newline.
    def display_rich
      return "error: #{message}" unless [ErrorKind::LEX, ErrorKind::PARSE].include?(kind) && span && input

      # A tab, CR or LF would move the input off the line the carets are aligned to.
      shown = Utf8.convert(input).tr("\t\r\n", "   ")
      carets = "  #{" " * span.start}#{"^" * [span.length, 1].max}"
      carets += " try: \"#{suggestion}\"" if suggestion
      ["error: #{message}", "  #{shown}", carets].join("\n")
    end
  end
end
