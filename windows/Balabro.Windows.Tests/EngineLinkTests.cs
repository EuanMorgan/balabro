using System;
using System.IO;
using Xunit;

namespace Balabro.Windows.Tests;

public class EngineLinkTests
{
    /// An engine that leaves half a line on stderr and ignores stdin closing, so the stderr reader is still waiting
    /// for the rest when each stop disposes the process. A reader thread that throws ends the test host, failing the run.
    [Fact]
    public void RestartingAnEngineThatIsStillTalkingDoesNotCrash()
    {
        var cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        using var link = new EngineLink(cmd, new[] { "/d", "/c", "<nul set /p =half a line 1>&2 & ping -n 30 127.0.0.1 >nul" });
        int? lastExit = -1;
        link.Exited += code => lastExit = code;
        for (var i = 0; i < 4; i++)
        {
            link.Start();
            System.Threading.Thread.Sleep(300);
        }
        link.Stop();
        System.Threading.Thread.Sleep(500);
        Assert.Equal(-1, lastExit);
    }
}
