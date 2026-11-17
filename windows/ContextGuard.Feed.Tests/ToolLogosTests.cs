using System.Text.Json.Nodes;
using Xunit;

namespace ContextGuard.Feed.Tests;

/// <summary>The tools' marks against contract/ui/names.json, which the Swift tests write from Core's tools.</summary>
public sealed class ToolLogosTests
{
    [Fact]
    public void EveryToolHasAMark()
    {
        var names = JsonNode.Parse(File.ReadAllText(Path.Combine(ContractTests.Contract, "names.json")))!;
        var tools = names["tools"]!.AsArray().Select(n => n!.GetValue<string>()).ToArray();
        Assert.NotEmpty(tools);
        Assert.Equal(tools.Order(StringComparer.Ordinal), ToolLogos.Tools.Order(StringComparer.Ordinal));
        Assert.All(tools, tool => Assert.StartsWith("F1 M ", ToolLogos.For(tool)));
    }

    [Fact]
    public void AToolThisBuildDoesntKnowHasNoMark() => Assert.Null(ToolLogos.For("somethingNewer"));
}
