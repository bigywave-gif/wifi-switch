using System.ComponentModel;
using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;

namespace WiFiSwitch.Core;

// Callers supply only fixed stage names, booleans and numeric codes.
// Never pass credentials, profile XML, identifiers or exception.Message.
public sealed class ConnectionDiagnostics : IDisposable
{
    private readonly object gate = new(), ioGate = new();
    private readonly string directory;
    private readonly Timer timer;
    private readonly Queue<string> lines = new();
    private readonly Stopwatch elapsed = new();
    private string? session;
    private string stage = "idle";
    private long stageStarted;
    private bool active;
    private long revision, flushedRevision = -1;
    private int dropped;
    public string? WriteError { get; private set; }

    public ConnectionDiagnostics(string directory)
    {
        this.directory = directory;
        timer = new Timer(_ => Flush(), null, 1000, 1000);
    }

    public void Begin(bool automatic, Authentication authentication)
    {
        Flush();
        lock (gate)
        {
            session = $"connection-{DateTime.UtcNow:yyyyMMddTHHmmssfff}-{Guid.NewGuid():N}";
            lines.Clear(); dropped = 0; elapsed.Restart(); stageStarted = 0; stage = "准备连接"; active = true;
            Add($"BEGIN automatic={automatic} authentication={authentication}");
            Add($"environment app={typeof(ConnectionDiagnostics).Assembly.GetName().Version} " +
                $"os={Environment.OSVersion.Version} runtime={Environment.Version} " +
                $"processArch={RuntimeInformation.ProcessArchitecture} osArch={RuntimeInformation.OSArchitecture}");
        }
    }

    public void Stage(string value)
    {
        lock (gate)
        {
            if (!active) return;
            Add($"STAGE_END durationMs={elapsed.ElapsedMilliseconds - stageStarted}");
            stage = value; stageStarted = elapsed.ElapsedMilliseconds;
            Add("STAGE_BEGIN");
        }
    }

    public void Write(string message) { lock (gate) { if (active) Add(message); } }
    public void Failure(Exception error)
    {
        Write($"ERROR type={error.GetType().Name} hresult=0x{error.HResult:X8}" +
            (error is Win32Exception win32 ? $" nativeCode={win32.NativeErrorCode} nativeHex=0x{win32.NativeErrorCode:X}" : "") +
            (error is ConnectionException connection
                ? $" wlanReason={(connection.Reason is { } reason ? $"0x{reason:X}" : "none")} " +
                  $"credentialsRejected={connection.CredentialsRejected} detailCode={connection.DiagnosticCode ?? "unspecified"}" : ""));
    }
    public void End(bool success)
    {
        lock (gate)
        {
            if (!active) return;
            Add($"END success={success} stageDurationMs={elapsed.ElapsedMilliseconds - stageStarted}");
            active = false;
        }
        Flush();
    }
    private void Add(string message)
    {
        // A bounded in-memory tail survives filesystem errors and can still be exported.
        if (lines.Count >= 1500) { lines.Dequeue(); dropped++; }
        lines.Enqueue($"{DateTimeOffset.Now:O} +{elapsed.ElapsedMilliseconds}ms [{session}] [{stage}] {message}");
        revision++;
    }
    private string SnapshotText() => $"session={session} active={active} stage={stage} droppedOldLines={dropped}\n" +
        string.Join("\n", lines) + "\n";
    public void Flush()
    {
        lock (ioGate)
        {
            string? name; string content; long snapshotRevision;
            lock (gate)
            {
                if (flushedRevision == revision && WriteError is null) return;
                name = session; content = SnapshotText(); snapshotRevision = revision;
            }
            if (name is null) return;
            try
            {
                Directory.CreateDirectory(Path.Combine(directory, "diagnostics"));
                Save(Path.Combine(directory, "diagnostics", name + ".log"), content);
                foreach (var old in History().Where(p => Path.GetFileName(p) != name + ".log").Skip(9)) File.Delete(old);
                Save(Path.Combine(directory, "last-connection.log"), content);
                WriteError = null;
                lock (gate) flushedRevision = snapshotRevision;
            }
            catch (Exception error) { WriteError = $"{error.GetType().Name} hresult=0x{error.HResult:X8}"; }
        }
    }
    private static void Save(string path, string content)
    {
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, content, Encoding.UTF8);
        File.Move(temporary, path, true);
    }
    private IEnumerable<string> History()
        => Directory.Exists(Path.Combine(directory, "diagnostics"))
            ? Directory.EnumerateFiles(Path.Combine(directory, "diagnostics"), "connection-*.log")
                .Where(p => Guid.TryParseExact(Path.GetFileNameWithoutExtension(p).Split('-').Last(), "N", out _))
                .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
            : [];

    public void Export(string destination)
    {
        Flush();
        lock (ioGate)
        {
            var files = new Dictionary<string, string>();
            string? currentName;
            lock (gate)
            {
                currentName = session is null ? null : session + ".log";
                if (currentName is not null) files[currentName] = SnapshotText();
            }
            foreach (var path in History().Where(p => Path.GetFileName(p) != currentName).Take(10 - files.Count))
                if (new FileInfo(path).Length <= 2_000_000) files[Path.GetFileName(path)] = File.ReadAllText(path);
            if (files.Count == 0) throw new InvalidOperationException("尚无连接诊断记录，请先尝试一次连接。");
            var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var archive = ZipFile.Open(temporary, ZipArchiveMode.Create))
                {
                    files["README.txt"] = "WiFi Switch 连接诊断\n" +
                        "包含最近最多 10 次应用连接记录；不包含账号配置、密码、SSID、网卡地址或原始认证载荷。\n" +
                        "时间含时区，+Nms 为本次操作累计耗时。每个阶段记录开始/结束；ERROR 保留错误码。\n" +
                        "等待时每 5 秒记录系统状态；ONEX 记录认证状态及 EAP 错误，MSM 记录无线关联阶段。\n" +
                        "API 返回 0 仅代表该次调用成功，只有最终 END success=True 表示应用完成连接验证和状态保存。\n" +
                        "没有收到失败码时，日志不能单独判定密码、证书或服务器故障；可能仍需系统/服务器日志。\n" +
                        "日志写入状态：" + (WriteError ?? "正常") + "\n";
                    foreach (var file in files)
                    {
                        using var writer = new StreamWriter(archive.CreateEntry(file.Key).Open(), Encoding.UTF8);
                        writer.Write(file.Value);
                    }
                }
                File.Move(temporary, destination, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
    public void Dispose() { timer.Dispose(); Flush(); }
}
