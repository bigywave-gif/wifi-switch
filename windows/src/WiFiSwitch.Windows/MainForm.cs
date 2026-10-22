using Microsoft.Win32;
using WiFiSwitch.Core;

namespace WiFiSwitch.Windows;

internal sealed class MainForm : Form
{
    private readonly Controller model;
    private readonly bool demo;
    private readonly ConnectionDiagnostics? diagnostics;
    private readonly Label summary = Ui.Label("正在读取 Wi-Fi 状态…"), notice = Ui.Label("");
    private readonly Label accountCount = Ui.Label("0 个账号");
    private readonly FlowLayoutPanel adapterPanel = new() { Dock = DockStyle.Top, Height = 44,
        Padding = new(24, 4, 24, 4), Visible = false };
    private readonly FlowLayoutPanel list = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new(20) };
    private readonly FlowLayoutPanel noticePanel = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new(20, 8, 20, 8) };
    private readonly ComboBox adapters = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
    private readonly Button add, fix, claim;
    private readonly HashSet<Guid> collapsed = [];
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 5000 };
    private readonly CancellationTokenSource lifetime = new();
    private TrayPanel? popup;
    private bool quitting, polling, loadingAdapters, editorOpen;
    private string lastRender = "";

    public MainForm(Controller model, bool demo, ConnectionDiagnostics? diagnostics = null)
    {
        this.model = model; this.demo = demo; this.diagnostics = diagnostics;
        Ui.Style(this); Text = "WiFi Switch"; Name = "WiFiSwitchMain"; Size = new(820, 700); MinimumSize = new(650, 480);
        StartPosition = FormStartPosition.CenterScreen;
        var header = new TableLayoutPanel { Dock = DockStyle.Top, Height = 135, Padding = new(24, 16, 24, 10), ColumnCount = 2, RowCount = 3 };
        header.ColumnStyles.Add(new(SizeType.Percent, 100)); header.ColumnStyles.Add(new(SizeType.AutoSize));
        header.Controls.Add(Ui.Label("WiFi Switch", 25, true), 0, 0);
        add = Ui.Button("＋ 添加账号", () => Edit(null), true, 130); add.Anchor = AnchorStyles.Right;
        header.Controls.Add(add, 1, 0);
        var subtitle = Ui.Label(demo ? "界面演示 · 不连接网络，不保存真实账号" : "一个账号，多个 Wi-Fi，快速连接。");
        subtitle.ForeColor = demo ? Color.Orange : Ui.Muted;
        header.Controls.Add(subtitle, 0, 1);
        header.Controls.Add(summary, 0, 2);
        adapters.Anchor = AnchorStyles.Right; adapters.AccessibleName = "Wi-Fi 网卡";
        adapters.SelectedIndexChanged += async (_, _) => {
            if (!loadingAdapters && adapters.SelectedItem is AdapterChoice choice) {
                try { model.SelectAdapter(choice.Adapter.Id); await Poll(); }
                catch (Exception error) { model.SetProblem(error.Message); }
            }
        };
        accountCount.Anchor = AnchorStyles.Right;
        accountCount.ForeColor = Ui.Muted;
        accountCount.AccessibleName = "已保存账号总数";
        header.Controls.Add(accountCount, 1, 2);
        adapterPanel.Controls.Add(Ui.Label("连接使用的 Wi-Fi 网卡"));
        adapterPanel.Controls.Add(adapters);
        notice.AutoSize = true; notice.MaximumSize = new(570, 0);
        noticePanel.Controls.Add(notice);
        fix = Ui.Button("修改账号", () => { if (model.EditSuggested is { } id) Edit(model.Configuration.Accounts.Single(a => a.Id == id)); }, false, 100);
        noticePanel.Controls.Add(fix);
        claim = Ui.Button("认领当前连接", () => Ui.Run(() => model.ClaimCurrentAsync(lifetime.Token), e => model.SetProblem(e)), false, 130);
        claim.AccessibleName = "把当前系统连接认领为记录的账号";
        noticePanel.Controls.Add(claim);
        noticePanel.Controls.Add(Ui.Button("×", model.DismissNotice, false, 32));
        var footer = Ui.Label("密码保存在 Windows 凭据管理器中。关闭窗口后仍可从托盘连接。", 9);
        footer.Dock = DockStyle.Fill; footer.Padding = new(22, 12, 12, 12); footer.ForeColor = Ui.Muted;
        var footerPanel = new Panel { Dock = DockStyle.Bottom, Height = 48 };
        var export = Ui.Button("导出诊断", ExportDiagnostics, false, 105);
        export.Dock = DockStyle.Right; export.Enabled = !demo && diagnostics is not null;
        footerPanel.Controls.Add(footer); footerPanel.Controls.Add(export);
        Controls.Add(list); Controls.Add(noticePanel); Controls.Add(adapterPanel); Controls.Add(header); Controls.Add(footerPanel);
        tray = new NotifyIcon { Icon = Ui.TrayIcon(), Text = "WiFi Switch", Visible = true };
        tray.MouseClick += (_, e) => {
            if (e.Button is MouseButtons.Left or MouseButtons.Right) ShowTray();
        };
        tray.DoubleClick += (_, _) => ShowManagement();
        model.Changed += Render;
        timer.Tick += async (_, _) => await Poll();
        SystemEvents.PowerModeChanged += PowerChanged;
        Shown += async (_, _) => {
            await LoadAdapters();
            await model.CleanupLegacyProfilesAsync();
            await Poll(); timer.Start();
        };
        Resize += (_, _) => { lastRender = ""; Render(); };
        FormClosing += (_, e) => {
            if (quitting || e.CloseReason is CloseReason.WindowsShutDown or CloseReason.TaskManagerClosing) return;
            e.Cancel = true; Hide();
        };
        FormClosed += (_, _) => {
            lifetime.Cancel(); timer.Dispose(); tray.Visible = false; tray.Icon?.Dispose(); tray.Dispose();
            model.Changed -= Render; SystemEvents.PowerModeChanged -= PowerChanged; popup?.Dispose(); lifetime.Dispose();
        };
    }

    private async Task LoadAdapters()
    {
        try
        {
            loadingAdapters = true;
            var items = await model.AdaptersAsync();
            adapterPanel.Visible = items.Count > 1;
            adapters.Items.Clear();
            foreach (var item in items) adapters.Items.Add(new AdapterChoice(item));
            var selected = items.FirstOrDefault(a => a.Id == model.Configuration.PreferredInterface) ??
                items.FirstOrDefault(a => a.Id == model.Configuration.Current?.InterfaceId) ?? items.FirstOrDefault();
            if (selected is not null)
            {
                adapters.SelectedIndex = items.ToList().FindIndex(a => a.Id == selected.Id);
                model.SelectAdapter(selected.Id);
            }
        }
        catch (Exception e) { model.SetProblem(e.Message); }
        finally { loadingAdapters = false; }
    }

    private async Task Poll()
    {
        if (polling || editorOpen) return;
        polling = true;
        try { await model.RefreshAsync(lifetime.Token); }
        catch (OperationCanceledException) { }
        catch (Exception e) { model.SetProblem(e.Message); }
        finally { polling = false; }
    }

    private void PowerChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (IsDisposed || !IsHandleCreated) return;
        BeginInvoke(() => {
            if (e.Mode == PowerModes.Suspend) model.Suspend();
            if (e.Mode == PowerModes.Resume) { model.Resume(); Ui.Run(Poll, ex => model.SetProblem(ex.Message)); }
        });
    }

    public void ShowManagement() { Show(); WindowState = FormWindowState.Normal; Activate(); lastRender = ""; Render(); }
    public void ExitApplication()
    {
        if (model.Busy) { model.SetProblem("正在连接，请等待完成后退出。"); return; }
        quitting = true; Close();
    }
    private void ShowTray()
    {
        popup?.Close(); popup?.Dispose();
        popup = new TrayPanel(model, this);
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        popup.StartPosition = FormStartPosition.Manual;
        popup.Location = new(Math.Clamp(Cursor.Position.X - popup.Width, area.Left, area.Right - popup.Width),
            Math.Max(area.Top, area.Bottom - popup.Height));
        popup.Show(); popup.Activate();
    }

    public void Edit(Account? account)
    {
        if (model.Busy || editorOpen) return;
        editorOpen = true;
        try { using var editor = new AccountForm(model, account); editor.ShowDialog(this); }
        finally { editorOpen = false; lastRender = ""; Render(); }
    }

    public void Connect(Account account, Network network)
        => Ui.Run(() => model.ConnectAsync(account.Id, network.Ssid, false, lifetime.Token), e => model.SetProblem(e.Message));

    public void ExportDiagnostics()
    {
        if (diagnostics is null) return;
        using var picker = new SaveFileDialog { Title = "导出连接诊断", Filter = "诊断压缩包 (*.zip)|*.zip",
            FileName = $"WiFi-Switch-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.zip", AddExtension = true };
        if (picker.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            diagnostics.Export(picker.FileName);
            MessageBox.Show(this, "诊断已导出，包含最近最多 10 次连接记录。\n不包含账号密码或完整网络配置。",
                "导出诊断", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception error) { Ui.Error(this, error); }
    }

    public void Details(Account account, Network network)
    {
        var failed = model.Configuration.Failure?.Selection.AccountId == account.Id &&
            model.Configuration.Failure.Selection.Ssid == network.Ssid ? model.Configuration.Failure : null;
        var message = failed?.Message ?? (model.Active?.AccountId == account.Id && model.Active.Ssid == network.Ssid
            ? "此账号由本应用上次连接成功后记录，当前 Wi-Fi 和 IP 状态正常。\n不代表实时查询到认证服务器的用户名；未检测互联网或公司业务服务。"
            : model.State.Problem ?? "连接已中断或未取得 IP 地址。");
        using var dialog = new Form { Text = "连接状态", Size = new(540, 380), StartPosition = FormStartPosition.CenterParent,
            FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
        Ui.Style(dialog);
        var text = new TextBox { Text = account.DisplayName + " · " + network.Ssid + "\r\n\r\n" + message.Replace("\n", "\r\n"),
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill,
            BackColor = Ui.Card, ForeColor = Ui.Text, BorderStyle = BorderStyle.None };
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 50, Padding = new(10, 8, 0, 0) };
        dialog.Padding = new(16);
        dialog.Controls.Add(text); dialog.Controls.Add(actions);
        var export = Ui.Button("导出诊断", ExportDiagnostics, false, 100);
        export.Enabled = !demo && diagnostics is not null; actions.Controls.Add(export);
        var retry = Ui.Button("重新连接", () => { dialog.Close(); Connect(account, network); }, true, 110);
        retry.Enabled = !model.Busy; actions.Controls.Add(retry);
        if (failed?.CredentialsRejected == true)
        {
            var edit = Ui.Button("修改账号", () => { dialog.Close(); Edit(account); }, false, 110);
            actions.Controls.Add(edit);
        }
        dialog.ShowDialog(this);
    }

    internal Control NetworkRow(Account account, Network network, int width, bool compact)
    {
        var row = new TableLayoutPanel { Width = width, Height = 52, ColumnCount = compact ? 2 : 3, BackColor = Ui.Card,
            Margin = Padding.Empty, Padding = new(compact ? 8 : 18, 7, 8, 7) };
        row.ColumnStyles.Add(new(SizeType.Percent, 100)); row.ColumnStyles.Add(new(SizeType.Absolute, 92));
        if (!compact) row.ColumnStyles.Add(new(SizeType.Absolute, 36));
        var name = Ui.Label(network.Ssid, 10, true); name.Dock = DockStyle.Fill; name.AutoEllipsis = true; name.AutoSize = false;
        name.TextAlign = ContentAlignment.MiddleLeft; row.Controls.Add(name, 0, 0);
        var selected = model.Configuration.Current;
        bool connecting = model.IsConnecting(account.Id, network.Ssid);
        bool remembered = selected?.AccountId == account.Id && selected.Ssid == network.Ssid;
        bool active = remembered && model.Active is not null;
        bool abnormal = remembered && (model.Configuration.Failure is not null ||
            (model.State.Available && model.State.Readable && model.State.InterfaceId == selected!.InterfaceId &&
             (model.State.Ssid is null || Rules.Matches(selected!, model.State))));
        var action = !connecting && (active || abnormal) ? new StatusButton(active, false, active ? "连接正常，查看详情" : "连接异常，查看详情",
            () => Details(account, network)) : Ui.Button(connecting ? "连接中…" : "连接", () => Connect(account, network), true);
        action.Enabled = !model.Busy; row.Controls.Add(action, 1, 0);
        if (!compact)
        {
            var more = Ui.Button("⋯", () => { }, false, 30); more.AccessibleName = $"管理 {account.DisplayName} 的 {network.Ssid}";
            var menu = new ContextMenuStrip();
            menu.Items.Add("重新连接", null, (_, _) => Connect(account, network));
            menu.Items.Add("移除 Wi-Fi", null, (_, _) => {
                try { model.RemoveNetwork(account.Id, network.Ssid); } catch (Exception ex) { Ui.Error(this, ex); }
            });
            more.Click += (_, _) => menu.Show(more, new Point(0, more.Height));
            more.Disposed += (_, _) => menu.Dispose(); more.Enabled = !model.Busy;
            row.Controls.Add(more, 2, 0);
        }
        return row;
    }

    private void Render()
    {
        if (IsDisposed) return;
        var current = model.Active;
        accountCount.Text = $"{model.Configuration.Accounts.Count} 个账号";
        var account = model.Configuration.Accounts.FirstOrDefault(a => a.Id == current?.AccountId);
        summary.Text = model.Claiming ? "正在确认当前账号…" : model.Busy ? "正在连接账号…" : model.State.Ssid is { } ssid
            ? $"已连接 · {ssid} · {account?.DisplayName ?? "当前账号未识别"}" : model.State.Problem ?? "尚未连接 Wi-Fi";
        notice.Text = model.Notice ?? (model.CanClaim ? "系统已连接此 Wi-Fi，但无法确认是记录中的账号。确认是本人连接后可认领。" : "");
        notice.ForeColor = model.Notice is null ? Ui.Text : model.NoticeIsError ? Ui.Red : Ui.Text;
        noticePanel.Visible = model.Notice is not null || model.CanClaim; fix.Visible = model.EditSuggested is not null;
        claim.Visible = model.CanClaim;
        add.Enabled = adapters.Enabled = !model.Busy;
        var signature = System.Text.Json.JsonSerializer.Serialize(model.Configuration) +
            current?.ProfileName + model.State + model.Connecting + model.Claiming + list.ClientSize.Width + string.Join("", collapsed);
        if (signature == lastRender) return;
        lastRender = signature;
        var scroll = list.AutoScrollPosition;
        list.SuspendLayout();
        foreach (var control in list.Controls.Cast<Control>().ToArray()) control.Dispose();
        int width = Math.Max(400, list.ClientSize.Width - 58);
        if (model.Configuration.Accounts.Count == 0)
        {
            list.Controls.Add(Ui.Label("还没有账号\n\n点击“添加账号”，保存凭据并关联一个或多个 Wi-Fi。", 12));
        }
        foreach (var item in model.OrderedAccounts)
        {
            var expanded = !collapsed.Contains(item.Id);
            var card = new FlowLayoutPanel { Width = width, AutoSize = true, FlowDirection = FlowDirection.TopDown,
                WrapContents = false, BackColor = Ui.Card, Margin = new(0, 0, 0, 18) };
            var head = new TableLayoutPanel { Width = width, Height = 66, ColumnCount = 3, Padding = new(12, 12, 8, 8) };
            head.ColumnStyles.Add(new(SizeType.Percent, 100)); head.ColumnStyles.Add(new(SizeType.Absolute, 92));
            head.ColumnStyles.Add(new(SizeType.Absolute, 36));
            var toggle = Ui.Button((expanded ? "⌄  " : "›  ") + item.DisplayName + $"   · {item.Networks.Count} 个 Wi-Fi",
                () => { if (!collapsed.Add(item.Id)) collapsed.Remove(item.Id); lastRender = ""; Render(); }, false, width - 150);
            toggle.TextAlign = ContentAlignment.MiddleLeft; toggle.Font = new Font(Font, FontStyle.Bold); toggle.AutoEllipsis = true;
            head.Controls.Add(toggle);
            if (item.Id == current?.AccountId) head.Controls.Add(new StatusButton(true, true, "当前使用账号", () => { }), 1, 0);
            var more = Ui.Button("⋯", () => { }, false, 30);
            var menu = new ContextMenuStrip();
            menu.Items.Add("修改账号", null, (_, _) => Edit(item));
            menu.Items.Add("添加 Wi-Fi", null, (_, _) => Edit(item));
            menu.Items.Add("删除账号", null, (_, _) => {
                if (MessageBox.Show(this, $"删除“{item.DisplayName}”及本工具保存的密码？", "删除账号",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK)
                    try { model.DeleteAccount(item.Id); } catch (Exception ex) { Ui.Error(this, ex); }
            });
            more.Click += (_, _) => menu.Show(more, new Point(0, more.Height)); more.Enabled = !model.Busy;
            more.Disposed += (_, _) => menu.Dispose(); head.Controls.Add(more, 2, 0); card.Controls.Add(head);
            if (expanded)
            {
                foreach (var network in item.Networks) card.Controls.Add(NetworkRow(item, network, width, false));
                card.Controls.Add(Ui.Button("＋ 添加 Wi-Fi", () => Edit(item), false, 150));
            }
            list.Controls.Add(card);
        }
        list.ResumeLayout();
        list.AutoScrollPosition = new(-scroll.X, -scroll.Y);
    }
    private sealed record AdapterChoice(Adapter Adapter) { public override string ToString() => Adapter.Name; }
}

internal sealed class TrayPanel : Form
{
    private readonly Controller model;
    private readonly MainForm main;
    private readonly HashSet<Guid> expanded = [];
    private readonly FlowLayoutPanel list = new() { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new(12) };
    private string signature = "";
    public TrayPanel(Controller model, MainForm main)
    {
        this.model = model; this.main = main; Ui.Style(this);
        Text = "WiFi Switch"; ShowInTaskbar = false; FormBorderStyle = FormBorderStyle.FixedToolWindow; TopMost = true;
        Size = new(310, 340);
        var header = new Panel { Dock = DockStyle.Top, Height = 60 };
        var title = Ui.Label("⇄  WiFi Switch", 15, true); title.Location = new(16, 14); header.Controls.Add(title);
        var gear = Ui.Button("⚙", () => { }, false, 36); gear.Location = new(250, 12); gear.AccessibleName = "设置";
        var menu = new ContextMenuStrip();
        menu.Items.Add("配置管理", null, (_, _) => { Hide(); main.ShowManagement(); });
        menu.Items.Add("导出诊断", null, (_, _) => { Hide(); main.ShowManagement(); main.ExportDiagnostics(); });
        menu.Items.Add("退出系统", null, (_, _) => main.ExitApplication());
        gear.Click += (_, _) => menu.Show(gear, new Point(0, gear.Height));
        gear.Disposed += (_, _) => menu.Dispose(); header.Controls.Add(gear);
        Controls.Add(list); Controls.Add(header);
        Deactivate += (_, _) => Hide();
        model.Changed += Render;
        FormClosed += (_, _) => model.Changed -= Render;
        Render();
    }
    private void Render()
    {
        if (IsDisposed) return;
        var next = System.Text.Json.JsonSerializer.Serialize(model.Configuration) + model.Active + model.State + model.Notice + model.Connecting + model.Claiming + string.Join("", expanded);
        if (signature == next) return; signature = next;
        list.SuspendLayout();
        foreach (var control in list.Controls.Cast<Control>().ToArray()) control.Dispose();
        foreach (var account in model.OrderedAccounts)
        {
            var row = new TableLayoutPanel { Width = 260, Height = 48, ColumnCount = 2, Margin = Padding.Empty };
            row.ColumnStyles.Add(new(SizeType.Percent, 100)); row.ColumnStyles.Add(new(SizeType.Absolute, 92));
            var toggle = Ui.Button((expanded.Contains(account.Id) ? "⌄ " : "› ") + account.DisplayName,
                () => { if (!expanded.Add(account.Id)) expanded.Remove(account.Id); signature = ""; Render(); }, false, 168);
            toggle.AutoEllipsis = true; toggle.TextAlign = ContentAlignment.MiddleLeft; row.Controls.Add(toggle);
            if (model.Active?.AccountId == account.Id) row.Controls.Add(new StatusButton(true, true, "当前使用账号", () => { }), 1, 0);
            list.Controls.Add(row);
            if (expanded.Contains(account.Id))
                foreach (var network in account.Networks) list.Controls.Add(main.NetworkRow(account, network, 260, true));
        }
        if (model.Configuration.Accounts.Count == 0) list.Controls.Add(Ui.Label("点击右上角齿轮，进入配置管理添加账号。"));
        if (model.Notice is { } message)
        {
            var note = Ui.Label(message, 9); note.MaximumSize = new(260, 0); note.ForeColor = model.NoticeIsError ? Ui.Red : Ui.Muted;
            list.Controls.Add(note);
        }
        list.ResumeLayout();
    }
}
