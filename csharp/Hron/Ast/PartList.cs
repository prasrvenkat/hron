using System.Collections;

namespace Hron.Ast;

/// <summary>
/// Every list in a part is one of these. It keeps its own copy and is no mutable collection type, so
/// no cast can change a schedule; it compares by items in order, so the records that hold it compare
/// by parts (spec/README.md, "Equality").
/// </summary>
internal sealed class PartList<T> : IReadOnlyList<T>
{
    private readonly T[] _items;

    private PartList(T[] items) => _items = items;

    public static IReadOnlyList<T> Of(IReadOnlyList<T> items) => items as PartList<T> ?? new PartList<T>([.. items]);

    public int Count => _items.Length;

    public T this[int index] => _items[index];

    public IEnumerator<T> GetEnumerator() => ((IEnumerable<T>)_items).GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public override bool Equals(object? obj) => obj is PartList<T> other && _items.SequenceEqual(other._items);

    public override string ToString() => $"[{string.Join(", ", _items)}]";

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var item in _items)
        {
            hash.Add(item);
        }
        return hash.ToHashCode();
    }
}
