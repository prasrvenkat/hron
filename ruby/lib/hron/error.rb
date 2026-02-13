# frozen_string_literal: true

module Hron
  # Span in source input for error reporting
  Span = Data.define(:start, :end_pos) do # end_pos to avoid Ruby keyword
    def length
      end_pos - start
    end
  end

  # Error kinds
  module ErrorKind
    LEX = :lex
    PARSE = :parse
    EVAL = :eval
    CRON = :cron
  end

  # Main error class for hron
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

    def display_rich
      if [ErrorKind::LEX, ErrorKind::PARSE].include?(kind) && span && input
        buf = []
        buf << "error: #{message}"
        buf << "  #{input}"
        padding = " " * (span.start + 2)
        len = [span.length, 1].max
        underline = "^" * len
        line = "#{padding}#{underline}"
        line += " try: \"#{suggestion}\"" if suggestion
        buf << line
        buf.join("\n")
      else
        "error: #{message}"
      end
    end
  end
end
