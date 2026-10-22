using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace WiFiSwitch.Windows;

internal static class Ui
{
    public static readonly Color Background = Color.FromArgb(30, 32, 36), Card = Color.FromArgb(39, 42, 47);
    public static readonly Color Text = Color.FromArgb(239, 241, 244), Muted = Color.FromArgb(160, 167, 179);
    public static readonly Color Blue = Color.FromArgb(0, 117, 240), Green = Color.FromArgb(31, 207, 106), Red = Color.FromArgb(244, 82, 82);
    public static Label Label(string text, int size = 10, bool bold = false) => new()
    {
        Text = text, ForeColor = Text, Font = new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular),
        AutoSize = true, Margin = new Padding(0, 6, 0, 6), UseMnemonic = false
    };
    public static Button Button(string text, Action action, bool primary = false, int width = 88)
    {
        var button = new Button { Text = text, Width = width, Height = 34, FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Blue : Card, ForeColor = Text, Cursor = Cursors.Hand, UseMnemonic = false,
            Margin = new Padding(4), AccessibleName = text, TabStop = true };
        button.FlatAppearance.BorderSize = 0;
        button.Click += (_, _) => action();
        return button;
    }
    public static void Style(Form form)
    {
        form.BackColor = Background; form.ForeColor = Text;
        form.Font = new Font("Microsoft YaHei UI", 10);
        form.AutoScaleMode = AutoScaleMode.Dpi;
        form.AutoScaleDimensions = new SizeF(96, 96);
        form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
    }
    public static TextBox Input(string placeholder = "") => new()
    {
        PlaceholderText = placeholder, BorderStyle = BorderStyle.FixedSingle,
        BackColor = Card, ForeColor = Text, Width = 510, Height = 32,
        Margin = new Padding(0, 0, 0, 12)
    };
    public static async void Run(Func<Task> operation, Action<Exception> onError)
    {
        try { await operation(); }
        catch (Exception error) { onError(error); }
    }
    public static void Error(IWin32Window owner, Exception error)
        => MessageBox.Show(owner, error.Message, "WiFi Switch", MessageBoxButtons.OK, MessageBoxIcon.Warning);

    public static Icon TrayIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(Color.White, 2.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        g.DrawEllipse(pen, 3, 3, 26, 26);
        g.DrawLines(pen, new PointF[] { new(19, 9), new(12, 9), new(8, 13), new(12, 17) });
        g.DrawLine(pen, 8, 13, 22, 13);
        g.DrawLines(pen, new PointF[] { new(13, 23), new(20, 23), new(24, 19), new(20, 15) });
        g.DrawLine(pen, 24, 19, 10, 19);
        var handle = bitmap.GetHicon();
        try { using var icon = Icon.FromHandle(handle); return (Icon)icon.Clone(); }
        finally { DestroyIcon(handle); }
    }
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
}

internal sealed class StatusButton : Button
{
    private readonly bool healthy, accountCheck;
    private readonly System.Windows.Forms.Timer pulse = new() { Interval = 900 };
    private bool bright;
    public StatusButton(bool healthy, bool accountCheck, string description, Action click)
    {
        this.healthy = healthy; this.accountCheck = accountCheck;
        Text = ""; Width = 88; Height = 34; FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
        BackColor = Ui.Card; AccessibleName = description; Cursor = Cursors.Hand;
        Click += (_, _) => click();
        if (!accountCheck && SystemInformation.UIEffectsEnabled)
        {
            pulse.Tick += (_, _) => { bright = !bright; Invalidate(); };
            pulse.Start();
        }
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(BackColor);
        var x = Width / 2f; var y = Height / 2f; var color = healthy ? Ui.Green : Ui.Red;
        using var brush = new SolidBrush(color);
        if (accountCheck)
        {
            e.Graphics.FillEllipse(brush, x - 11, y - 11, 22, 22);
            using var pen = new Pen(Color.Black, 2.5f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            e.Graphics.DrawLines(pen, new PointF[] { new(x - 5, y), new(x - 1, y + 4), new(x + 6, y - 5) });
        }
        else
        {
            using var halo = new SolidBrush(Color.FromArgb(bright ? 85 : 40, color));
            e.Graphics.FillEllipse(halo, x - 11, y - 11, 22, 22);
            e.Graphics.FillEllipse(brush, x - 5, y - 5, 10, 10);
        }
        if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle);
    }
    protected override void Dispose(bool disposing) { if (disposing) pulse.Dispose(); base.Dispose(disposing); }
}
