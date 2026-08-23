using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Zharp.Core.Pty;

/// <summary>
/// Hosts a child process attached to a Windows pseudoconsole (ConPTY).
/// Write VT input to <see cref="Input"/>, read VT output from <see cref="Output"/>.
/// </summary>
public sealed class ConPty : IDisposable
{
    private IntPtr _hpc;
    private IntPtr _processHandle;
    private IntPtr _threadHandle;
    private RegisteredWaitHandle? _exitWait;
    private bool _disposed;
    private readonly object _lock = new();

    public FileStream Input { get; private set; } = null!;
    public FileStream Output { get; private set; } = null!;
    public int ProcessId { get; private set; }

    /// <summary>Raised (on a thread pool thread) when the child process exits.</summary>
    public event Action<int>? Exited;

    private ConPty() { }

    /// <param name="extraEnvironment">
    /// Overrides applied on top of the inherited environment. A null value
    /// removes the variable from the child's environment.
    /// </param>
    public static ConPty Start(string commandLine, string? workingDirectory,
        IReadOnlyDictionary<string, string?>? extraEnvironment, int cols, int rows)
    {
        var pty = new ConPty();

        SafeFileHandle? inRead = null, inWrite = null, outRead = null, outWrite = null;
        IntPtr attrList = IntPtr.Zero;
        try
        {
            if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0))
                throw new Win32Exception();
            if (!CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
                throw new Win32Exception();

            var size = new COORD { X = (short)Math.Max(2, cols), Y = (short)Math.Max(2, rows) };
            int hr = CreatePseudoConsole(size, inRead.DangerousGetHandle(), outWrite.DangerousGetHandle(), 0, out pty._hpc);
            if (hr != 0)
                throw new Win32Exception(hr, "CreatePseudoConsole failed");

            // The pseudoconsole duplicated these; our copies can go.
            inRead.Dispose();
            outWrite.Dispose();
            inRead = null;
            outWrite = null;

            var lpSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
            attrList = Marshal.AllocHGlobal(lpSize);
            if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref lpSize))
                throw new Win32Exception();
            if (!UpdateProcThreadAttribute(attrList, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    pty._hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception();

            var siEx = new STARTUPINFOEX();
            siEx.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
            siEx.lpAttributeList = attrList;

            string envBlock = BuildEnvironmentBlock(extraEnvironment);

            if (!CreateProcessW(null, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                    envBlock, workingDirectory, ref siEx, out var pi))
                throw new Win32Exception();

            Marshal.FreeHGlobal(attrList);
            attrList = IntPtr.Zero;

            pty._processHandle = pi.hProcess;
            pty._threadHandle = pi.hThread;
            pty.ProcessId = pi.dwProcessId;

            pty.Input = new FileStream(inWrite, FileAccess.Write, 4096, isAsync: false);
            pty.Output = new FileStream(outRead, FileAccess.Read, 65536, isAsync: false);
            inWrite = null;
            outRead = null;

            var waitHandle = new ProcessWaitHandle(pi.hProcess);
            pty._exitWait = ThreadPool.RegisterWaitForSingleObject(waitHandle, (_, _) =>
            {
                GetExitCodeProcess(pty._processHandle, out int code);
                pty.Exited?.Invoke(code);
            }, null, -1, executeOnlyOnce: true);

            return pty;
        }
        catch
        {
            if (attrList != IntPtr.Zero)
                Marshal.FreeHGlobal(attrList);
            inRead?.Dispose();
            inWrite?.Dispose();
            outRead?.Dispose();
            outWrite?.Dispose();
            pty.Dispose();
            throw;
        }
    }

    public void Resize(int cols, int rows)
    {
        lock (_lock)
        {
            if (_disposed || _hpc == IntPtr.Zero)
                return;
            ResizePseudoConsole(_hpc, new COORD { X = (short)Math.Max(2, cols), Y = (short)Math.Max(2, rows) });
        }
    }

    public void Kill()
    {
        lock (_lock)
        {
            if (_processHandle != IntPtr.Zero)
                TerminateProcess(_processHandle, 1);
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed)
                return;
            _disposed = true;

            _exitWait?.Unregister(null);
            _exitWait = null;

            // Closing the pseudoconsole disconnects the client and unblocks reads.
            if (_hpc != IntPtr.Zero)
            {
                ClosePseudoConsole(_hpc);
                _hpc = IntPtr.Zero;
            }

            if (_processHandle != IntPtr.Zero)
            {
                TerminateProcess(_processHandle, 1);
                CloseHandle(_processHandle);
                _processHandle = IntPtr.Zero;
            }
            if (_threadHandle != IntPtr.Zero)
            {
                CloseHandle(_threadHandle);
                _threadHandle = IntPtr.Zero;
            }

            try { Input?.Dispose(); } catch { }
            try { Output?.Dispose(); } catch { }
        }
    }

    private static string BuildEnvironmentBlock(IReadOnlyDictionary<string, string?>? extra)
    {
        var env = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
            env[(string)entry.Key] = (string?)entry.Value ?? "";
        if (extra != null)
        {
            foreach (var kv in extra)
            {
                if (kv.Value == null)
                    env.Remove(kv.Key);
                else
                    env[kv.Key] = kv.Value;
            }
        }

        var sb = new StringBuilder();
        foreach (var kv in env)
        {
            sb.Append(kv.Key).Append('=').Append(kv.Value).Append('\0');
        }
        sb.Append('\0');
        return sb.ToString();
    }

    private sealed class ProcessWaitHandle : WaitHandle
    {
        public ProcessWaitHandle(IntPtr processHandle)
        {
            // Non-owning: the outer class closes the real handle.
            SafeWaitHandle = new SafeWaitHandle(processHandle, ownsHandle: false);
        }
    }

    // ---------------------------------------------------------------- interop

    private const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe,
        IntPtr lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput,
        uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll")]
    private static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

    [DllImport("kernel32.dll")]
    private static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList,
        int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags,
        IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string? lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, string? lpEnvironment, string? lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out int lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
