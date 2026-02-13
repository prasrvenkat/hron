namespace Hron.Ast;

/// <summary>
/// Represents an until date.
/// </summary>
public sealed record UntilSpec(UntilSpecKind Kind, string? Date, MonthName? Month, int Day)
{
    /// <summary>
    /// Creates an ISO until specification.
    /// </summary>
    public static UntilSpec Iso(string date)
        => new(UntilSpecKind.Iso, date, null, 0);

    /// <summary>
    /// Creates a named until specification.
    /// </summary>
    public static UntilSpec Named(MonthName month, int day)
        => new(UntilSpecKind.Named, null, month, day);
}

/// <summary>
/// The type of until specification.
/// </summary>
public enum UntilSpecKind
{
    /// <summary>An ISO until date (e.g., 2026-12-31).</summary>
    Iso,
    /// <summary>A named until date (e.g., dec 31).</summary>
    Named
}
