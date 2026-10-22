using WiFiSwitch.Core;

namespace WiFiSwitch.Windows;

internal sealed class AccountForm : Form
{
    private readonly Controller model;
    private readonly Account? original;
    private readonly TextBox label = Ui.Input("例如：办公账号、项目账号");
    private readonly TextBox username = Ui.Input("输入 Wi-Fi 登录用户名");
    private readonly TextBox password = Ui.Input("输入密码");
    private readonly Label userTitle = Ui.Label("用户名"), passwordTitle = Ui.Label("密码"), hint = Ui.Label("");
    private readonly CheckedListBox networks = new() { CheckOnClick = true, Width = 510, Height = 180, IntegralHeight = false,
        BackColor = Ui.Card, ForeColor = Ui.Text, BorderStyle = BorderStyle.FixedSingle, HorizontalScrollbar = true,
        AccessibleName = "关联 Wi-Fi，可多选" };
    private readonly Button save, scan;
    private readonly Label selectionInfo = Ui.Label("可多选，也可以先保存账号稍后关联。", 9);
    private readonly TextBox manual = Ui.Input("手动输入 Wi-Fi 名称（SSID）");
    private bool scanning, saving, revealed, showingStored;
    private readonly CancellationTokenSource lifetime = new();

    public AccountForm(Controller model, Account? original)
    {
        this.model = model; this.original = original;
        Ui.Style(this); Text = original is null ? "添加账号" : "修改账号";
        ClientSize = new(570, Math.Min(740, Screen.PrimaryScreen!.WorkingArea.Height - 100));
        MinimumSize = new(560, 500); StartPosition = FormStartPosition.CenterParent; MaximizeBox = false; MinimizeBox = false;
        var body = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false,
            AutoScroll = true, Padding = new(22, 12, 16, 20) };
        body.Controls.Add(Ui.Label(Text, 23, true));
        var description = Ui.Label("此账号的凭据共用于它关联的所有 Wi-Fi。", 10); description.ForeColor = Ui.Muted;
        body.Controls.Add(description);
        body.Controls.Add(Ui.Label("备注（选填）", 10, true)); body.Controls.Add(label);
        body.Controls.Add(userTitle); body.Controls.Add(username);
        body.Controls.Add(passwordTitle);
        var passwordRow = new FlowLayoutPanel { Width = 515, Height = 44, Margin = Padding.Empty, WrapContents = false };
        password.Width = 450; password.UseSystemPasswordChar = true; passwordRow.Controls.Add(password);
        var eye = Ui.Button("◉", TogglePassword, false, 42); eye.AccessibleName = "显示或隐藏密码"; passwordRow.Controls.Add(eye);
        body.Controls.Add(passwordRow);
        var networkHeader = new FlowLayoutPanel { Width = 515, Height = 42, Margin = Padding.Empty };
        var title = Ui.Label("关联 Wi-Fi（选填）", 10, true); title.Width = 300; title.AutoSize = false;
        networkHeader.Controls.Add(title);
        scan = Ui.Button("扫描附近 Wi-Fi", () => Ui.Run(Scan, e => SetError(e.Message)), false, 150);
        networkHeader.Controls.Add(scan); body.Controls.Add(networkHeader);
        selectionInfo.ForeColor = Ui.Muted; body.Controls.Add(selectionInfo); body.Controls.Add(networks);
        var manualRow = new FlowLayoutPanel { Width = 515, Height = 44, Margin = new(0, 10, 0, 0), WrapContents = false };
        manual.Width = 340; manualRow.Controls.Add(manual);
        manualRow.Controls.Add(Ui.Button("添加", AddManual, false, 70));
        manualRow.Controls.Add(Ui.Button("设置", EditNetwork, false, 70)); body.Controls.Add(manualRow);
        var help = Ui.Label("普通 Wi-Fi、热点和开放网络均可选择。\n“设置”可指定隐藏网络或企业认证的服务器与根证书。\n名称区分大小写；不同密码的网络请分别创建账号。", 9);
        help.MaximumSize = new(510, 0); help.ForeColor = Ui.Muted; body.Controls.Add(help);
        var privacy = Ui.Label("密码仅保存在此 Windows 用户的凭据管理器中。", 9);
        privacy.ForeColor = Ui.Muted; body.Controls.Add(privacy);
        if (original?.Id == model.Configuration.Current?.AccountId)
        {
            var reconnect = Ui.Label("修改当前账号的用户名或密码后保存，将使用新凭据重新连接当前 Wi-Fi。", 9);
            reconnect.MaximumSize = new(510, 0); reconnect.ForeColor = Color.Orange; body.Controls.Add(reconnect);
        }
        var footer = new Panel { Dock = DockStyle.Bottom, Height = 86, Padding = new(20) };
        hint.AutoSize = false; hint.SetBounds(22, 3, 515, 36); hint.ForeColor = Ui.Muted; footer.Controls.Add(hint);
        var cancel = Ui.Button("取消", Close, false); cancel.SetBounds(348, 44, 88, 32); footer.Controls.Add(cancel);
        save = Ui.Button("保存", () => Ui.Run(Save, e => { saving = false; SetError(e.Message); ValidateForm(); }), true);
        save.SetBounds(448, 44, 88, 32); footer.Controls.Add(save); CancelButton = cancel;
        Controls.Add(body); Controls.Add(footer);
        label.Text = original?.Label ?? ""; username.Text = original?.Username ?? "";
        if (original?.HasPassword == true) password.PlaceholderText = "留空保留已保存的密码";
        foreach (var network in (original?.Networks ?? []).Concat(model.Configuration.Accounts.SelectMany(a => a.Networks))
            .DistinctBy(n => n.Ssid)) networks.Items.Add(new Choice(network), original?.Networks.Any(n => n.Ssid == network.Ssid) == true);
        username.TextChanged += (_, _) => ValidateForm();
        password.TextChanged += (_, _) => {
            if (!showingStored) ValidateForm();
        };
        networks.ItemCheck += (_, _) => BeginInvoke(ValidateForm);
        Deactivate += (_, _) => HidePassword();
        FormClosed += (_, _) => { lifetime.Cancel(); lifetime.Dispose(); password.Clear(); };
        Shown += (_, _) => { ValidateForm(); Ui.Run(Scan, e => SetError(e.Message)); };
        ValidateForm();
    }
    private List<Network> Selected() => networks.CheckedItems.Cast<Choice>().Select(c => c.Network).ToList();
    private void ValidateForm()
    {
        var selected = Selected();
        bool needsUser = Rules.RequiresUsername(selected), needsPassword = Rules.RequiresPassword(selected);
        userTitle.Text = needsUser ? "用户名（必填）" : "用户名（选填，普通网络不使用）";
        passwordTitle.Text = needsPassword
            ? original?.HasPassword == true ? "密码（已保存，留空保留）" : "密码（必填）"
            : "密码（选填，开放网络不使用）";
        selectionInfo.Text = $"已选 {selected.Count} 个 · 可多选，也可以先保存账号稍后关联。";
        var reason = saving ? "正在保存…" : scanning ? "正在扫描…" : model.Busy ? "正在连接，请稍后保存。" :
            needsUser && string.IsNullOrWhiteSpace(username.Text) ? "请填写必填项：用户名。" :
            needsPassword && password.Text.Length == 0 && original?.HasPassword != true ? "请填写必填项：密码。" : null;
        save.Enabled = reason is null; scan.Enabled = !scanning && !saving; networks.Enabled = !saving;
        hint.Text = reason ?? (original?.Id == model.Configuration.Current?.AccountId
            ? "只改备注或关联不会重新连接。" : "保存不会主动连接 Wi-Fi。");
    }
    private void SetError(string message) { hint.Text = message; hint.ForeColor = Ui.Red; }
    private async Task Scan()
    {
        if (scanning || saving) return; scanning = true; ValidateForm();
        try
        {
            var nearby = await model.ScanAsync(lifetime.Token);
            foreach (var found in nearby)
            {
                var existingIndex = Enumerable.Range(0, networks.Items.Count).FirstOrDefault(
                    i => ((Choice)networks.Items[i]).Network.Ssid == found.Ssid, -1);
                if (existingIndex < 0) networks.Items.Add(new Choice(new() { Ssid = found.Ssid, Authentication = found.Authentication }));
                else
                {
                    var old = (Choice)networks.Items[existingIndex]; var check = networks.GetItemChecked(existingIndex);
                    networks.Items[existingIndex] = new Choice(old.Network with { Authentication = found.Authentication });
                    networks.SetItemChecked(existingIndex, check);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { MessageBox.Show(this, e.Message, "扫描 Wi-Fi", MessageBoxButtons.OK, MessageBoxIcon.Information); }
        finally { scanning = false; if (!IsDisposed) ValidateForm(); }
    }
    private void AddManual()
    {
        try
        {
            Rules.ValidateSsid(manual.Text);
            var index = Enumerable.Range(0, networks.Items.Count).FirstOrDefault(i => ((Choice)networks.Items[i]).Network.Ssid == manual.Text, -1);
            if (index >= 0) { networks.SetItemChecked(index, true); networks.SelectedIndex = index; }
            else
            {
                using var form = new NetworkForm(new() { Ssid = manual.Text, Authentication = Authentication.Unknown });
                if (form.ShowDialog(this) != DialogResult.OK) return;
                networks.Items.Add(new Choice(form.Value), true);
            }
            manual.Clear(); ValidateForm();
        }
        catch (Exception e) { SetError(e.Message); }
    }
    private void EditNetwork()
    {
        if (networks.SelectedIndex < 0) { SetError("请先选中一行 Wi-Fi，再点击设置。"); return; }
        var index = networks.SelectedIndex; var choice = (Choice)networks.Items[index];
        using var form = new NetworkForm(choice.Network);
        if (form.ShowDialog(this) != DialogResult.OK) return;
        bool check = networks.GetItemChecked(index);
        networks.Items[index] = new Choice(form.Value); networks.SetItemChecked(index, check);
        ValidateForm();
    }
    private void TogglePassword()
    {
        try
        {
            if (revealed) { HidePassword(); return; }
            if (password.Text.Length == 0 && original?.HasPassword == true)
            {
                showingStored = true; password.Text = model.ReadPassword(original.Id); password.ReadOnly = true;
            }
            revealed = true; password.UseSystemPasswordChar = false;
        }
        catch (Exception e) { showingStored = false; SetError(e.Message); }
    }
    private void HidePassword()
    {
        password.UseSystemPasswordChar = true; password.ReadOnly = false; revealed = false;
        if (showingStored) { password.Clear(); showingStored = false; }
    }
    private async Task Save()
    {
        if (!save.Enabled) return;
        saving = true; ValidateForm();
        try
        {
            var value = (original ?? new Account()) with { Label = label.Text.Trim(), Username = username.Text,
                Networks = Selected() };
            var newPassword = showingStored || password.Text.Length == 0 ? null : password.Text;
            await model.SaveAccountAsync(value, newPassword);
            DialogResult = DialogResult.OK; Close();
        }
        finally { saving = false; if (!IsDisposed) ValidateForm(); }
    }
    private sealed record Choice(Network Network)
    {
        public override string ToString() => Network.Ssid + "  · " + (Network.Authentication switch
        { Authentication.Enterprise => "企业认证", Authentication.Personal => "Wi-Fi 密码", Authentication.Open => "开放网络", _ => "连接时识别" });
    }
}

internal sealed class NetworkForm : Form
{
    public Network Value { get; private set; }
    public NetworkForm(Network original)
    {
        Value = original; Ui.Style(this); Text = "Wi-Fi 设置"; ClientSize = new(530, 410);
        StartPosition = FormStartPosition.CenterParent; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new(20), FlowDirection = FlowDirection.TopDown };
        layout.Controls.Add(Ui.Label(original.Ssid, 15, true));
        var mode = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 470 };
        mode.Items.AddRange(["连接时识别", "开放网络", "普通密码 Wi-Fi / 手机热点", "企业 Wi-Fi（PEAP/MSCHAPv2）"]);
        mode.SelectedIndex = (int)original.Authentication; layout.Controls.Add(mode);
        var hidden = new CheckBox { Text = "隐藏网络（需指定实际认证方式）", Checked = original.Hidden, Width = 470 };
        layout.Controls.Add(hidden);
        layout.Controls.Add(Ui.Label("企业认证服务器名称（选填，按 IT 提供的信息填写）", 9));
        var servers = Ui.Input(); servers.Width = 470; servers.Text = original.ServerNames; layout.Controls.Add(servers);
        layout.Controls.Add(Ui.Label("根证书 SHA-1 指纹（选填）", 9));
        var ca = Ui.Input(); ca.Width = 470; ca.Text = original.RootCertificateThumbprint; layout.Controls.Add(ca);
        var note = Ui.Label("优先沿用 Windows 中此网络的企业认证配置。\n未配置时使用 PEAP/MSCHAPv2，并保留系统证书校验。", 9);
        note.MaximumSize = new(470, 0); note.ForeColor = Ui.Muted; layout.Controls.Add(note);
        layout.Controls.Add(Ui.Button("确定", () => {
            if (hidden.Checked && mode.SelectedIndex == 0) { Ui.Error(this, new ArgumentException("隐藏网络请选择实际认证方式。")); return; }
            var fingerprint = ca.Text.Replace(" ", "", StringComparison.Ordinal);
            if (fingerprint.Length > 0 && (fingerprint.Length != 40 || !fingerprint.All(Uri.IsHexDigit)))
            { Ui.Error(this, new ArgumentException("根证书指纹应为 40 位 SHA-1 十六进制值。")); return; }
            Value = original with { Authentication = (Authentication)mode.SelectedIndex, Hidden = hidden.Checked,
                ServerNames = servers.Text.Trim(), RootCertificateThumbprint = fingerprint };
            DialogResult = DialogResult.OK; Close();
        }, true));
        Controls.Add(layout);
    }
}
