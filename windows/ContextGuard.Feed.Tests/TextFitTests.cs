using System.Globalization;
using System.Text.Json.Nodes;
using Xunit;

namespace ContextGuard.Feed.Tests;

/// <summary>The popups' middle cut, measured here in characters (one unit each).</summary>
public sealed class TextFitTests
{
    static double Characters(string s) => new StringInfo(s).LengthInTextElements;

    [Fact]
    public void TextThatFitsIsLeftWhole()
    {
        Assert.Equal("billing", TextFit.Middle("billing", 7, Characters));
        Assert.Equal("", TextFit.Middle("", 0, Characters));
    }

    [Fact]
    public void LongTextKeepsItsStartAndEnd()
    {
        Assert.Equal("ab…ij", TextFit.Middle("abcdefghij", 5, Characters));
        // The start gets the odd character.
        Assert.Equal("abc…ij", TextFit.Middle("abcdefghij", 6, Characters));
        Assert.Equal(@"billing-3…\billing", TextFit.Middle(@"billing-3f · C:\code\billing", 18, Characters));
    }

    [Fact]
    public void TooNarrowForAnyOfItLeavesTheEllipsis()
    {
        Assert.Equal("…", TextFit.Middle("abcdefghij", 1, Characters));
        Assert.Equal("…", TextFit.Middle("abcdefghij", 0, Characters));
    }

    [Fact]
    public void ItNeverSplitsACharacter()
    {
        // Two emoji (surrogate pairs) and an e with a combining accent.
        var text = "a\U0001F600b\U0001F600ce\u0301";
        Assert.Equal("a\U0001F600…e\u0301", TextFit.Middle(text, 4, Characters));
        Assert.Equal("a\U0001F600…ce\u0301", TextFit.Middle(text, 5, Characters));
    }

    [Fact]
    public void ItUsesTheMeasureItIsGiven()
    {
        // Wide W's: two units each.
        static double Wide(string s) => s.Sum(c => c == 'W' ? 2 : 1);
        Assert.Equal("WW…aa", TextFit.Middle("WWWWaaaa", 7, Wide));
    }
}

/// <summary>The app's tone colors against contract/ui/names.json.</summary>
public sealed class TonesTests
{
    [Fact]
    public void EveryToneHasAColor()
    {
        var names = JsonNode.Parse(File.ReadAllText(Path.Combine(ContractTests.Contract, "names.json")))!;
        var tones = names["tones"]!.AsArray().Select(n => n!.GetValue<string>()).ToArray();
        Assert.NotEmpty(tones);
        Assert.Equal(tones.Order(StringComparer.Ordinal), Tones.All.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void AToneThisBuildDoesntKnowIsMuted()
    {
        Assert.Equal(Tones.Muted, Tones.For("somethingNewer"));
        Assert.Equal(Tones.Muted, Tones.For(null));
        Assert.Equal(Tones.Warning, Tones.For("warning"));
    }
}
