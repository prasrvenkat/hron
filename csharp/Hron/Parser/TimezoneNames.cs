using System.Text;

namespace Hron.Parser;

/// <summary>
/// Matches timezone names in any case and returns their IANA capitalization. Names are ASCII, so
/// other input never matches (a Kelvin sign is not a k). On Unix, TimeZoneInfo loads a zone from
/// the file with the exact name and only matches other cases for zones it has already cached, so
/// names are indexed from the directory it reads (TZDIR, else /usr/share/zoneinfo). Where there is
/// no such directory (Windows, which maps IANA ids through ICU), a name must be given in its IANA
/// capitalization.
/// </summary>
internal static class TimezoneNames
{
    private static readonly Lazy<Dictionary<string, string>> Index = new(BuildIndex);

    /// <summary>
    /// The IANA capitalization of UTC or an Area/Location zone or link name, or null for anything
    /// else, including abbreviations such as EST that the tz database also carries.
    /// </summary>
    public static string? Canonical(string name)
    {
        if (!Ascii.IsValid(name))
        {
            return null;
        }
        if (name.Equals("UTC", StringComparison.OrdinalIgnoreCase))
        {
            return "UTC";
        }
        if (!name.Contains('/'))
        {
            return null;
        }
        if (Index.Value.Count > 0)
        {
            return Index.Value.TryGetValue(name, out var canonical) && TimeZoneInfo.TryFindSystemTimeZoneById(canonical, out _)
                ? canonical
                : null;
        }
        return TimeZoneInfo.TryFindSystemTimeZoneById(name, out var zone) ? zone.Id : null;
    }

    private static Dictionary<string, string> BuildIndex()
    {
        var index = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var root = Environment.GetEnvironmentVariable("TZDIR") ?? "/usr/share/zoneinfo";
        if (!Directory.Exists(root))
        {
            return index;
        }
        foreach (var area in Directory.EnumerateDirectories(root).Where(IsZoneDirectory))
        {
            foreach (var file in ZoneFiles(area))
            {
                var name = Path.GetRelativePath(root, file).Replace(Path.DirectorySeparatorChar, '/');
                index.TryAdd(name, name);
            }
        }
        return index;
    }

    // posix/ and right/ repeat the database with other leap-second handling, SystemV/ holds
    // names IANA removed, and a symlinked directory can point back up the tree.
    private static bool IsZoneDirectory(string directory) =>
        new DirectoryInfo(directory).LinkTarget is null && Path.GetFileName(directory) is not ("posix" or "right" or "SystemV");

    private static IEnumerable<string> ZoneFiles(string directory) =>
        Directory.EnumerateFiles(directory)
            .Concat(Directory.EnumerateDirectories(directory).Where(IsZoneDirectory).SelectMany(ZoneFiles));
}
