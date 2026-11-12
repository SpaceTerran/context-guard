using System.Text.Json.Nodes;
using Xunit;

namespace ContextGuard.Feed.Tests;

/// <summary>The app's icons against contract/ui/names.json, which the Swift tests write from Core's symbols.</summary>
public sealed class GlyphsTests
{
    [Fact]
    public void EverySymbolHasAnIcon()
    {
        var names = JsonNode.Parse(File.ReadAllText(Path.Combine(ContractTests.Contract, "names.json")))!;
        var symbols = names["symbols"]!.AsArray().Select(n => n!.GetValue<string>()).ToArray();
        Assert.NotEmpty(symbols);
        Assert.Equal(symbols.Order(StringComparer.Ordinal), Glyphs.Symbols.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void ASymbolThisBuildDoesntKnowGetsTheCircle() => Assert.Equal(Glyphs.For("watching"), Glyphs.For("somethingNewer"));
}
