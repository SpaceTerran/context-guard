using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace ContextGuard.Feed.Tests;

/// <summary>
/// The files in contract/ui/ at the top of the repo. The Swift tests write the boards and messages from
/// what the program really says, and read the intents into what the program does with them. This side
/// reads every one with members it doesn't know refused, and writes it back the same, so a change on
/// either side that the other doesn't know about fails a test.
/// </summary>
public sealed class ContractTests
{
    const string Session = "00000000-0000-4000-8000-000000000001";

    internal static readonly string Contract = FindContract();

    /// <summary>What each file in intents/ says.</summary>
    static readonly Dictionary<string, Intent> Intents = new()
    {
        ["answer"] = Intent.Answer(Session, AnswerAction.Later, AnswerSource.Popup) with { Id = "1" },
        ["compact-now"] = Intent.Answer(Session, AnswerAction.Yes, AnswerSource.Menu) with { Id = "2" },
        ["turn-off"] = Intent.TurnOff() with { Id = "3" },
        ["enable"] = Intent.Enable(false) with { Id = "4" },
        ["watch"] = Intent.Watch(Session, false) with { Id = "5" },
        ["hide"] = Intent.Hide(Session) with { Id = "6" },
        ["show"] = Intent.Show(Session) with { Id = "7" },
        ["close"] = Intent.Close("notice:off:1") with { Id = "8" },
        ["settings-open"] = Intent.SettingsOpen() with { Id = "9" },
        ["settings-close"] = Intent.SettingsClose() with { Id = "10" },
        ["set"] = Intent.Set(SettingsField.AskK, "200") with { Id = "11" },
        ["set-message"] = Intent.Set(SettingsField.Message, "Save your work first.") with { Id = "12" },
        ["step"] = Intent.Step(SettingsField.AutoYes, up: true) with { Id = "13" },
        ["restore"] = Intent.Restore(SettingsField.Message) with { Id = "14" },
        ["no-id"] = Intent.SettingsOpen(),
    };

    public static TheoryData<string> BoardFiles => Data(Names("boards"));
    public static TheoryData<string> MessageFiles => Data(Names("messages"));
    public static TheoryData<string> IntentFiles => Data(Names("intents"));

    [Theory]
    [MemberData(nameof(BoardFiles))]
    public void ABoardReadsAndWritesBackTheSame(string name)
    {
        var message = ReadsBack("boards", name);
        Assert.Equal("board", message.Type);
        Assert.NotNull(message.Board);
    }

    [Theory]
    [MemberData(nameof(BoardFiles))]
    public void EachOneOfHoldsExactlyOne(string name)
    {
        var board = ReadsBack("boards", name).Board!;
        foreach (var popup in board.Popups)
        {
            Assert.True((popup.Question is null) != (popup.Notice is null), $"{name}: popup {popup.Key}");
        }
        var blocks = board.Settings?.Tabs.SelectMany(t => t.Blocks) ?? [];
        foreach (var block in blocks)
        {
            Assert.True((block.Card is null) != (block.Note is null), $"{name}: a block");
        }
        foreach (var row in blocks.SelectMany(b => b.Card?.Rows ?? []))
        {
            Assert.Single(new object?[] { row.Toggle, row.Login, row.Status, row.Note, row.Field, row.Text }, x => x is not null);
        }
    }

    [Theory]
    [MemberData(nameof(MessageFiles))]
    public void AMessageReadsAndWritesBackTheSame(string name)
    {
        var message = ReadsBack("messages", name);
        Assert.Equal(name.Split('-')[0], message.Type);
    }

    [Theory]
    [MemberData(nameof(IntentFiles))]
    public void AnIntentIsWrittenAsTheProgramReadsIt(string name)
    {
        Assert.True(Intents.TryGetValue(name, out var intent), $"intents/{name}.json has no intent here");
        var text = File.ReadAllText(Path.Combine(Contract, "intents", name + ".json"));
        AssertSameJson(text, JsonSerializer.Serialize(intent, FeedJson.Default.Intent), $"intents/{name}.json");
        Assert.Equal(intent, JsonSerializer.Deserialize(text, StrictFeedJson.Default.Intent));
    }

    [Fact]
    public void EveryIntentHasAFile() => Assert.Equal(Intents.Keys.Order(StringComparer.Ordinal), Names("intents"));

    /// <summary>Reads a file as a message, refusing members it doesn't know, and writes it back.</summary>
    static FeedMessage ReadsBack(string folder, string name)
    {
        var text = File.ReadAllText(Path.Combine(Contract, folder, name + ".json"));
        var message = JsonSerializer.Deserialize(text, StrictFeedJson.Default.FeedMessage);
        Assert.NotNull(message);
        Assert.Equal(FeedClient.Version, message.V);
        AssertSameJson(text, JsonSerializer.Serialize(message, FeedJson.Default.FeedMessage), $"{folder}/{name}.json");
        return message;
    }

    static void AssertSameJson(string expected, string actual, string what) =>
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(expected), JsonNode.Parse(actual)), $"{what} doesn't come back the same:\n{actual}");

    static string[] Names(string folder) =>
        [.. Directory.GetFiles(Path.Combine(Contract, folder), "*.json").Select(f => Path.GetFileNameWithoutExtension(f)).Order(StringComparer.Ordinal)];

    static TheoryData<string> Data(string[] names)
    {
        var data = new TheoryData<string>();
        foreach (var name in names) data.Add(name);
        return data;
    }

    static string FindContract()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var contract = Path.Combine(dir.FullName, "contract", "ui");
            if (Directory.Exists(contract)) return contract;
        }
        throw new DirectoryNotFoundException($"No contract/ui above {AppContext.BaseDirectory}");
    }
}
