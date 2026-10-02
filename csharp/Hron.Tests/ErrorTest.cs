using Xunit;

namespace Hron.Tests;

public class ErrorTest
{
    private static HronException ParseError(string input) => Assert.Throws<HronException>(() => Schedule.Parse(input));

    // Attribute data loses lone surrogates, so the cases are listed here.
    [Fact]
    public void LoneSurrogateIsOneCodePointReportedByItsOwnValue()
    {
        (string Input, string Shown)[] cases =
        [
            ("\uD800", "U+D800"),
            ("\uDFFF", "U+DFFF"),
            ("\uD800a", "U+D800"),
            ("\uDC00\uD800", "U+DC00"),
        ];
        foreach (var (input, shown) in cases)
        {
            var error = ParseError(input);
            Assert.Equal(ErrorKind.Lex, error.Kind);
            Assert.Equal($"unexpected character {shown}", error.Message);
            Assert.Equal(new Span(0, 1), error.Span);
        }
    }

    [Fact]
    public void LoneSurrogateInATimezoneCountsAsOneCodePoint()
    {
        var error = ParseError("every day at 09:00 in \uD800x");
        Assert.Equal("timezone must be UTC or an Area/Location name such as America/New_York, got \uD800x", error.Message);
        Assert.Equal(new Span(22, 24), error.Span);
    }

    [Fact]
    public void AstralCharacterIsOneCodePoint()
    {
        var error = ParseError("every \U0001F600 day");
        Assert.Equal(ErrorKind.Lex, error.Kind);
        Assert.Equal("unexpected character U+1F600", error.Message);
        Assert.Equal(new Span(6, 7), error.Span);
    }

    [Fact]
    public void SpansAfterAstralCharactersCountCodePoints()
    {
        var error = ParseError("every day at 09:00 in Europe/\U0001F600\U0001F600");
        Assert.Equal(new Span(22, 31), error.Span);
        Assert.Equal(
            "error: timezone must be UTC or an Area/Location name such as America/New_York, got Europe/\U0001F600\U0001F600\n"
            + "  every day at 09:00 in Europe/\U0001F600\U0001F600\n"
            + "                        ^^^^^^^^^",
            error.DisplayRich());
    }

    [Fact]
    public void EvalAndCronErrorsRenderTheirMessageAlone()
    {
        Assert.Equal("error: no zone", HronException.Eval("no zone").DisplayRich());
        Assert.Equal("error: bad cron", HronException.Cron("bad cron").DisplayRich());
    }
}
