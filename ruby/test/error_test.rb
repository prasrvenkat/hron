# frozen_string_literal: true

require_relative "test_helper"

class ErrorTest < Minitest::Test
  def parse_error(input)
    error = assert_raises(Hron::HronError) { Hron::Schedule.parse(input) }
    refute Hron::Schedule.validate(input), "validate"
    error
  end

  def assert_error(error, kind, message, span)
    assert_equal [kind, message, span], [error.kind, error.message, [error.span.start, error.span.end_pos]]
  end

  def test_invalid_utf8_byte_is_an_unexpected_replacement_character
    input = "every day at 09:00 \xFF".b.force_encoding(Encoding::UTF_8)
    error = parse_error(input)
    assert_error error, :lex, "unexpected character U+FFFD", [19, 20]
    assert_same input, error.input
    assert_equal "error: unexpected character U+FFFD\n  every day at 09:00 �\n                     ^", error.display_rich
  end

  def test_each_invalid_byte_counts_as_one_code_point
    # \xE3\x81 is a truncated three-byte sequence, which `scrub` alone would replace once.
    error = parse_error("every day at 09:00 in \xE3\x81 x".b.force_encoding(Encoding::UTF_8))
    assert_error error, :lex, "unknown keyword 'x'", [25, 26]

    error = parse_error("every day at 09:00 in \xED\xA0\x80".b.force_encoding(Encoding::UTF_8))
    assert_error error, :parse,
      "timezone must be UTC or an Area/Location name such as America/New_York, got ���", [22, 25]
  end

  def test_binary_input_is_read_as_utf8_bytes
    assert_equal "every day at 09:00", Hron::Schedule.parse("every day at 09:00".b).to_s
    error = parse_error("every day at 09:00 é".b)
    assert_error error, :lex, "unexpected character U+00E9", [19, 20]
    error = parse_error("every day at 09:00 \xFF".b)
    assert_error error, :lex, "unexpected character U+FFFD", [19, 20]
  end

  def test_other_encodings_are_converted_to_utf8
    assert_equal "every day at 09:00 in UTC", Hron::Schedule.parse("every day at 09:00 in UTC".encode(Encoding::UTF_16LE)).to_s
    error = parse_error("every day at 09:00 é".encode(Encoding::ISO_8859_1))
    assert_error error, :lex, "unexpected character U+00E9", [19, 20]
    error = parse_error("every \u{1f600}".encode(Encoding::UTF_32BE))
    assert_error error, :lex, "unexpected character U+1F600", [6, 7]
  end

  def test_lone_utf16_surrogate_becomes_a_replacement_character
    lone_surrogate = "\xD8\x00".dup.force_encoding(Encoding::UTF_16BE)
    error = parse_error("every day at 09:00 ".encode(Encoding::UTF_16BE) + lone_surrogate)
    assert_error error, :lex, "unexpected character U+FFFD", [19, 20]
  end

  def test_invalid_bytes_in_other_encodings_never_raise_anything_else
    inputs = [
      "every day at 09:00 \xFF".dup.force_encoding(Encoding::US_ASCII),
      "every day at 09:00 \x81".dup.force_encoding(Encoding::Shift_JIS),
      "every day at 09:00 +AGEA-".dup.force_encoding(Encoding::UTF_7)
    ]
    inputs.each do |input|
      error = parse_error(input)
      assert_includes %i[lex parse], error.kind, input.inspect
      assert_equal 3, error.display_rich.split("\n", -1).length, input.inspect
    end
  end

  def test_display_rich_shows_tab_cr_and_lf_as_one_space
    error = parse_error("every\tday\r\nat 25:00")
    assert_equal "error: time must be 00:00-23:59, got 25:00\n  every day  at 25:00\n                ^^^^^", error.display_rich
  end

  def test_display_rich_counts_carets_in_code_points
    error = parse_error("every day at 09:00 in \u{1f600}\u{1f600} #")
    assert_equal "error: unexpected character '#'\n  every day at 09:00 in \u{1f600}\u{1f600} #\n                           ^", error.display_rich
  end

  def test_eval_and_cron_errors_render_their_message_alone
    assert_equal "error: no zone", Hron::HronError.eval("no zone").display_rich
    assert_equal "error: bad cron", Hron::HronError.cron("bad cron").display_rich
  end
end
