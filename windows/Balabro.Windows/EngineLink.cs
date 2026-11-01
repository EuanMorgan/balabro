using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Balabro.Windows;

/// `balabro-engine.exe`, joined to the app by JSON lines on its stdin and stdout.
///
/// The engine runs in a job object that kills everything in it when the app's handle closes, so the engine,
/// claude and the bot's game copies go with the app even if it crashes or is killed.
internal sealed class EngineLink : IDisposable
{
    private readonly string[] _arguments;
    private readonly object _writeLock = new();
    private Process? _process;
    private IntPtr _job;

    /// On the reader thread.
    public event Action<HostMessage>? Received;
    /// On the reader thread, once per start, with the exit code (or null if it never started).
    public event Action<int?>? Exited;

    public EngineLink(string[] arguments) => _arguments = arguments;

    public static string ExecutablePath => Path.Combine(AppContext.BaseDirectory, "balabro-engine.exe");

    public void Start()
    {
        Stop();
        var info = new ProcessStartInfo(ExecutablePath)
        {
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            StandardInputEncoding = new UTF8Encoding(false),
        };
        foreach (var argument in _arguments) info.ArgumentList.Add(argument);

        _job = CreateKillOnCloseJob();
        Process process;
        try
        {
            process = Process.Start(info) ?? throw new InvalidOperationException("Process.Start returned null");
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        {
            Log.Write($"Couldn't start {ExecutablePath}: {error.Message}");
            ThreadPool.QueueUserWorkItem(_ => Exited?.Invoke(null));
            return;
        }
        if (_job != IntPtr.Zero && !AssignProcessToJobObject(_job, process.Handle))
            Log.Write($"Couldn't put the engine in a job object: error {Marshal.GetLastWin32Error()}");
        process.StandardInput.AutoFlush = true;
        process.StandardInput.NewLine = "\n";
        _process = process;
        Log.Write($"Started the engine, pid {process.Id}, arguments [{string.Join(" ", _arguments)}]");

        new Thread(() => ReadLines(process)) { IsBackground = true, Name = "engine stdout" }.Start();
        // The engine logs to its own file too. Its stderr is drained so a full pipe can never block it.
        new Thread(() => { try { while (process.StandardError.ReadLine() is not null) { } } catch (IOException) { } })
        { IsBackground = true, Name = "engine stderr" }.Start();
    }

    private void ReadLines(Process process)
    {
        try
        {
            while (process.StandardOutput.ReadLine() is { } line)
            {
                if (line.Length == 0) continue;
                HostMessage message;
                try { message = Wire.Decode(line); }
                catch (Exception error)
                {
                    Log.Write($"Couldn't read a line from the engine ({error.Message}): {Shorten(line)}");
                    continue;
                }
                try { Received?.Invoke(message); }
                catch (Exception error) { Log.Write($"Handling a {message.GetType().Name} line failed: {error}"); }
            }
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException) { }
        int? code = null;
        try { process.WaitForExit(2000); code = process.HasExited ? process.ExitCode : null; } catch (InvalidOperationException) { }
        if (ReferenceEquals(process, _process))
        {
            Log.Write($"The engine stopped, exit code {code?.ToString() ?? "unknown"}");
            Exited?.Invoke(code);
        }
    }

    public void Send(string line)
    {
        var process = _process;
        if (process is null) return;
        lock (_writeLock)
        {
            try { process.StandardInput.WriteLine(line); }
            catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException)
            {
                Log.Write($"Couldn't send a line to the engine: {error.Message}");
            }
        }
    }

    /// Closing stdin asks the engine to stop its children and exit. Closing the job makes sure of it.
    public void Stop()
    {
        var process = _process;
        _process = null;
        if (process is not null)
        {
            try { process.StandardInput.Close(); } catch (Exception error) when (error is IOException or InvalidOperationException) { }
            try { process.WaitForExit(3000); } catch (InvalidOperationException) { }
            Log.Write(process.HasExited ? "The engine exited when asked" : "The engine didn't exit in 3 s, so the job closes it");
        }
        if (_job != IntPtr.Zero)
        {
            CloseHandle(_job);
            _job = IntPtr.Zero;
        }
        process?.Dispose();
    }

    public void Dispose() => Stop();

    private static string Shorten(string line) => line.Length > 300 ? line[..300] + "…" : line;

    private static IntPtr CreateKillOnCloseJob()
    {
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
        {
            Log.Write($"Couldn't create a job object: error {Marshal.GetLastWin32Error()}");
            return IntPtr.Zero;
        }
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION { BasicLimitInformation = { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE } };
        var size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                Log.Write($"Couldn't set the job object's limits: error {Marshal.GetLastWin32Error()}");
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return job;
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
