namespace Hron.Ast;

/// <summary>
/// Represents a date specification (either named like "feb 14" or ISO like "2026-03-15").
/// </summary>
public sealed record DateSpec(DateSpecKind Kind, MonthName? Month, int Day, string? Date)
{
    /// <summary>
    /// Creates a named date specification.
    /// </summary>
    public static DateSpec Named(MonthName month, int day)
        => new(DateSpecKind.Named, month, day, null);

    /// <summary>
    /// Creates an ISO date specification.
    /// </summary>
    public static DateSpec Iso(string date)
        => new(DateSpecKind.Iso, null, 0, date);
}

/// <summary>
/// The type of date specification.
/// </summary>
public enum DateSpecKind
{
    /// <summary>A named date (e.g., feb 14).</summary>
    Named,
    /// <summary>An ISO date (e.g., 2026-03-15).</summary>
    Iso
}
