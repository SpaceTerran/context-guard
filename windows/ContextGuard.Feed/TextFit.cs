using System.Globalization;

namespace ContextGuard.Feed;

/// <summary>Text cut to fit a width where XAML can't do it: in the middle, as the Mac cuts a name and folder.</summary>
public static class TextFit
{
    public const string Ellipsis = "…";

    /// <summary>
    /// <paramref name="text"/> if it fits in <paramref name="width"/>; otherwise as much of its start and its end
    /// as fits around "…" (the start gets the odd character), or "…" alone. It never splits a character, whether
    /// a surrogate pair or a letter and its accents. <paramref name="measure"/> gives a string's width.
    /// </summary>
    public static string Middle(string text, double width, Func<string, double> measure)
    {
        if (measure(text) <= width) return text;
        // Where each character starts, as a reader sees characters.
        var starts = StringInfo.ParseCombiningCharacters(text);
        var count = starts.Length;

        string Keep(int kept)
        {
            int head = (kept + 1) / 2, tail = kept / 2;
            var headEnd = head < count ? starts[head] : text.Length;
            var tailStart = tail == 0 ? text.Length : starts[count - tail];
            return string.Concat(text.AsSpan(0, headEnd), Ellipsis, text.AsSpan(tailStart));
        }

        // The most characters kept that still fit: the width only grows as more are kept.
        int low = 0, high = count - 1;
        while (low < high)
        {
            var mid = (low + high + 1) / 2;
            if (measure(Keep(mid)) <= width) low = mid;
            else high = mid - 1;
        }
        return Keep(low);
    }
}
