namespace Hron.Eval;

/// <summary>
/// A date the expression fires on, with the month whose day it names. They differ only when a
/// directional nearest weekday crosses into the adjacent month.
/// </summary>
internal readonly record struct Candidate(DateOnly Date, int TargetMonth);
