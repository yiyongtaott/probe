# waiting.ps1 —— 等待用户输入通知弹窗（Freebuff）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 基本信息 ──
$model = $env:ANTHROPIC_MODEL
if (-not $model) { $model = "opus" }
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# ── 配色 ──
$amber = [System.Drawing.Color]::FromArgb(230, 162, 60)   # 主色（等待）
$dark  = [System.Drawing.Color]::FromArgb(51, 62, 72)     # 正文
$gray  = [System.Drawing.Color]::FromArgb(120, 132, 142)  # 辅助信息

# ── 窗体 ──
$form = New-Object Windows.Forms.Form
$form.Text = "Freebuff"
$form.TopMost = $true
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.ControlBox = $false
$form.Width = 640
$form.Height = 340
$form.BackColor = [System.Drawing.Color]::White

# ── 顶部横幅 ──
$banner = New-Object Windows.Forms.Panel
$banner.BackColor = $amber
$banner.Dock = "Top"
$banner.Height = 88
$form.Controls.Add($banner)

$title = New-Object Windows.Forms.Label
$title.Text = "Freebuff"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei", 20, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 12)
$banner.Controls.Add($title)

$status = New-Object Windows.Forms.Label
$status.Text = "✓ 等待用户输入"
$status.ForeColor = [System.Drawing.Color]::White
$status.Font = New-Object System.Drawing.Font("Microsoft YaHei", 11, [System.Drawing.FontStyle]::Bold)
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(24, 52)
$banner.Controls.Add($status)

# ── 正文提示 ──
$label = New-Object Windows.Forms.Label
$label.Text = "正在等待你的输入，请完成操作。"
$label.ForeColor = $dark
$label.Font = New-Object System.Drawing.Font("Microsoft YaHei", 13)
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(24, 124)
$form.Controls.Add($label)

# ── 辅助信息（模型 / 时间）──
$info = New-Object Windows.Forms.Label
$info.Text = "模型：$model    时间：$timestamp"
$info.ForeColor = $gray
$info.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9)
$info.AutoSize = $true
$info.Location = New-Object System.Drawing.Point(24, 168)
$form.Controls.Add($info)

# ── 确认按钮 ──
$btn = New-Object Windows.Forms.Button
$btn.Text = "Confirm"
$btn.Width = 120
$btn.Height = 40
$btn.Left = 260
$btn.Top = 240
$btn.FlatStyle = "Flat"
$btn.BackColor = $amber
$btn.ForeColor = [System.Drawing.Color]::White
$btn.Font = New-Object System.Drawing.Font("Microsoft YaHei", 11, [System.Drawing.FontStyle]::Bold)
$btn.Cursor = [System.Windows.Forms.Cursors]::Hand
$btn.Add_Click({ $form.Close() })
$form.Controls.Add($btn)

# ── 提示音（与 notify 一致：Windows Ding.wav，无声环境忽略）──
try {
    $ding = Join-Path $env:WINDIR "Media\Windows Ding.wav"
    if (Test-Path $ding) {
        $player = New-Object System.Media.SoundPlayer $ding
        $player.PlaySync()
    } else {
        [System.Media.SystemSounds]::Asterisk.Play()
    }
} catch {
    # 无声环境，忽略
}

$form.ShowDialog()
