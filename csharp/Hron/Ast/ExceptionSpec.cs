namespace Hron.Ast;

/// <summary>
/// Represents an exception date.
/// </summary>
public sealed record ExceptionSpec(ExceptionSpecKind Kind, MonthName? Month, int Day, string? Date)
{
    /// <summary>
    /// Creates a named exception specification.
    /// </summary>
    public static ExceptionSpec Named(MonthName month, int day)
        => new(ExceptionSpecKind.Named, month, day, null);

    /// <summary>
    /// Creates an ISO exception specification.
    /// </summary>
    public static ExceptionSpec Iso(string date)
        => new(ExceptionSpecKind.Iso, null, 0, date);
}

/// <summary>
/// The type of exception specification.
/// </summary>
public enum ExceptionSpecKind
{
    /// <summary>A named exception (e.g., dec 25).</summary>
    Named,
    /// <summary>An ISO exception (e.g., 2026-12-25).</summary>
    Iso
}
