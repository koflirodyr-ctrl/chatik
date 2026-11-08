#requires -version 5.1
# Chatik — оверлей чата Twitch поверх окон.
# Запуск: start.bat (или: powershell -STA -ExecutionPolicy Bypass -File chatik.ps1)

$ErrorActionPreference = 'Stop'

$script:AppDir     = $PSScriptRoot
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:LogPath    = Join-Path $script:AppDir 'error.log'

function Write-Log([string]$Text) {
  try {
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text
    [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

try {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase
  Add-Type -AssemblyName System.Xaml
  Add-Type -AssemblyName System.Windows.Forms

  # Чёткий текст на мониторах с масштабированием
  Add-Type -Namespace Native -Name Dpi -MemberDefinition @'
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
'@
  try { [Native.Dpi]::SetProcessDpiAwareness(1) | Out-Null } catch { }

  # Win32: исключение окна из захвата экрана + скрытие из Alt+Tab
  Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint dwAffinity);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@

  # ---------- конфиг ----------
  $script:cfg = @{
    channel    = ''
    width      = 380
    height     = 520
    fontSize   = 14
    opacity    = 0.82
    bgColor    = '#18181B'
    textColor  = '#FFFFFF'
    topmost    = $true
    x          = $null
    y          = $null
  }

  if (Test-Path $script:ConfigPath) {
    try {
      $loaded = Get-Content -Path $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $loaded.PSObject.Properties) {
        if ($script:cfg.ContainsKey($p.Name)) { $script:cfg[$p.Name] = $p.Value }
      }
    } catch { Write-Log "Не удалось прочитать config.json: $($_.Exception.Message)" }
  }

  $script:cfg.width    = [int]$script:cfg.width
  $script:cfg.height   = [int]$script:cfg.height
  $script:cfg.fontSize = [int]$script:cfg.fontSize
  $script:cfg.opacity  = [double]$script:cfg.opacity
  $script:cfg.topmost  = [bool]$script:cfg.topmost

  # ---------- вспомогательные функции ----------
  function Parse-HexColor([string]$hex) {
    $h = ([string]$hex).Trim().TrimStart('#')
    if ($h.Length -eq 3) {
      $h = $h.Substring(0,1) + $h.Substring(0,1) + $h.Substring(1,1) + $h.Substring(1,1) + $h.Substring(2,1) + $h.Substring(2,1)
    }
    if ($h.Length -ne 6) { return [System.Windows.Media.Color]::FromRgb(255, 255, 255) }
    try {
      return [System.Windows.Media.Color]::FromRgb(
        [Convert]::ToByte($h.Substring(0,2), 16),
        [Convert]::ToByte($h.Substring(2,2), 16),
        [Convert]::ToByte($h.Substring(4,2), 16))
    } catch {
      return [System.Windows.Media.Color]::FromRgb(255, 255, 255)
    }
  }

  function Normalize-Hex([string]$raw) {
    $h = ([string]$raw).Trim().TrimStart('#')
    if ($h -match '^[0-9a-fA-F]{3}$') {
      $h = $h.Substring(0,1) + $h.Substring(0,1) + $h.Substring(1,1) + $h.Substring(1,1) + $h.Substring(2,1) + $h.Substring(2,1)
    }
    if ($h -match '^[0-9a-fA-F]{6}$') { return '#' + $h.ToUpperInvariant() }
    return $null
  }

  function Normalize-Channel([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $s = $raw.Trim().ToLowerInvariant()
    $s = $s -replace '^.*twitch\.tv/([^/?#]+).*$', '$1'
    $s = $s.TrimStart('#').Trim()
    $s = $s -replace '[^a-z0-9_]', ''
    return $s
  }

  function To-Int([string]$value, [int]$fallback) {
    $out = 0
    if ([int]::TryParse(([string]$value).Trim(), [ref]$out)) { return $out }
    return $fallback
  }

  function Clamp-Int([int]$value, [int]$min, [int]$max) {
    if ($value -lt $min) { return $min }
    if ($value -gt $max) { return $max }
    return $value
  }

  function Save-Config {
    try {
      $json = $script:cfg | ConvertTo-Json -Depth 4
      [System.IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log "Не удалось сохранить config.json: $($_.Exception.Message)" }
  }

  # ---------- состояние ----------
  $script:messages    = New-Object System.Collections.ArrayList
  $script:brushCache  = @{}
  $script:ircJob      = $null
  $script:settingsWin = $null
  $script:resizing    = $false
  $script:editBg      = '#18181B'
  $script:editFg      = '#FFFFFF'

  $script:palette = @(
    '#FF0000','#0000FF','#00FF00','#B22222','#FF7F50','#9ACD32','#FF4500',
    '#2E8B57','#DAA520','#D2691E','#5F9EA0','#1E90FF','#FF69B4','#8A2BE2','#00FF7F'
  )

  $script:brushOnline = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor '#22C55E'))
  $script:brushWait   = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor '#F59E0B'))
  $script:brushOff    = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor '#EF4444'))
  $script:brushIdle   = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor '#6B7280'))
  $script:fgBrush     = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor '#FFFFFF'))

  function Get-NickBrush([string]$nick, [string]$twitchColor) {
    if ($script:brushCache.ContainsKey($nick)) { return $script:brushCache[$nick] }
    $hex = Normalize-Hex $twitchColor
    if (-not $hex) {
      $sum = 0
      foreach ($ch in $nick.ToCharArray()) { $sum += [int]$ch }
      $hex = $script:palette[$sum % $script:palette.Count]
    }
    $brush = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor $hex))
    $brush.Freeze()
    $script:brushCache[$nick] = $brush
    return $brush
  }

  function Add-MessageBlock($msg) {
    $p = [System.Windows.Documents.Paragraph]::new()
    $p.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

    $nickRun = [System.Windows.Documents.Run]::new([string]$msg.Nick)
    $nickRun.FontWeight = [System.Windows.FontWeights]::Bold
    $nickRun.Foreground = Get-NickBrush ([string]$msg.Nick) ([string]$msg.Color)

    $textRun = [System.Windows.Documents.Run]::new(': ' + [string]$msg.Text)
    $textRun.Foreground = $script:fgBrush

    $p.Inlines.Add($nickRun)
    $p.Inlines.Add($textRun)
    [void]$script:ChatBox.Document.Blocks.Add($p)
  }

  function Trim-Messages {
    $max = 150
    $doc = $script:ChatBox.Document
    while ($script:messages.Count -gt $max) {
      $script:messages.RemoveAt(0)
      if ($doc.Blocks.Count -gt 0) { $doc.Blocks.Remove($doc.Blocks.FirstBlock) }
    }
  }

  function Render-Messages {
    $script:ChatBox.Document.Blocks.Clear()
    foreach ($m in $script:messages) { Add-MessageBlock $m }
    $script:ChatBox.UpdateLayout()
    $script:ChatBox.ScrollToEnd()
  }

  function Set-Status([string]$state) {
    switch ($state) {
      'online'     { $script:StatusDot.Fill = $script:brushOnline; $script:StatusDot.ToolTip = 'Подключено к чату' }
      'connecting' { $script:StatusDot.Fill = $script:brushWait;   $script:StatusDot.ToolTip = 'Подключение…' }
      'idle'       { $script:StatusDot.Fill = $script:brushIdle;   $script:StatusDot.ToolTip = 'Канал не выбран' }
      default      { $script:StatusDot.Fill = $script:brushOff;    $script:StatusDot.ToolTip = 'Нет соединения, переподключение…' }
    }
  }

  function Update-Appearance {
    $bg = Parse-HexColor ([string]$script:cfg.bgColor)
    $alpha = [byte]([math]::Round(([double]$script:cfg.opacity) * 255))
    $script:Root.Background = [System.Windows.Media.SolidColorBrush]::new(
      [System.Windows.Media.Color]::FromArgb($alpha, $bg.R, $bg.G, $bg.B))

    $script:fgBrush = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor ([string]$script:cfg.textColor)))
    $script:fgBrush.Freeze()

    $script:ChatBox.FontSize = [double]$script:cfg.fontSize
    $script:win.Width  = [double]$script:cfg.width
    $script:win.Height = [double]$script:cfg.height
    $script:win.Topmost = [bool]$script:cfg.topmost
    if ([string]::IsNullOrWhiteSpace([string]$script:cfg.channel)) {
      $script:ChannelLabel.Text = 'канал не задан'
    } else {
      $script:ChannelLabel.Text = '#' + $script:cfg.channel
    }
    Render-Messages
  }

  # ---------- Twitch IRC ----------
  $script:ircWorker = {
    param([string]$Channel)

    function Unescape-Tag([string]$value) {
      return [regex]::Replace($value, '\\(.)', {
        param($m)
        switch ($m.Groups[1].Value) {
          's' { ' ' }
          ':' { ';' }
          '\' { '\' }
          'r' { "`r" }
          'n' { "`n" }
          default { $m.Groups[0].Value }
        }
      })
    }

    while ($true) {
      $tcp = $null; $ssl = $null; $reader = $null; $writer = $null
      try {
        [pscustomobject]@{ Kind = 'status'; Text = 'connecting' }

        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect('irc.chat.twitch.tv', 6697)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream())
        $ssl.AuthenticateAsClient('irc.chat.twitch.tv')
        $reader = New-Object System.IO.StreamReader($ssl, [System.Text.Encoding]::UTF8)
        $writer = New-Object System.IO.StreamWriter($ssl, [System.Text.Encoding]::UTF8)
        $writer.NewLine = "`r`n"
        $writer.AutoFlush = $true

        $nick = 'justinfan' + (Get-Random -Minimum 10000 -Maximum 99999)
        $writer.WriteLine('PASS SCHMOOPIIE')
        $writer.WriteLine("NICK $nick")
        $writer.WriteLine('CAP REQ :twitch.tv/tags twitch.tv/commands')
        $writer.WriteLine("JOIN #$Channel")
        [pscustomobject]@{ Kind = 'status'; Text = 'online' }

        while ($true) {
          $line = $reader.ReadLine()
          if ($null -eq $line) { throw 'Соединение закрыто' }
          if ($line.StartsWith('PING')) { $writer.WriteLine('PONG :tmi.twitch.tv'); continue }
          if ($line.Contains(' PRIVMSG ')) {
            $tags = @{}
            $rest = $line
            if ($rest.StartsWith('@')) {
              $sp = $rest.IndexOf(' ')
              if ($sp -lt 0) { continue }
              $tagStr = $rest.Substring(1, $sp - 1)
              $rest = $rest.Substring($sp + 1)
              foreach ($pair in $tagStr.Split(';')) {
                $eq = $pair.IndexOf('=')
                if ($eq -gt 0) {
                  $tags[$pair.Substring(0, $eq)] = Unescape-Tag $pair.Substring($eq + 1)
                }
              }
            }
            if ($rest -match '^:([^!]+)![^ ]+ PRIVMSG #\S+ :(.*)$') {
              $nickRaw = $Matches[1]
              $msg = $Matches[2]
              $display = if ($tags['display-name']) { $tags['display-name'] } else { $nickRaw }
              $color = if ($tags.ContainsKey('color')) { $tags['color'] } else { '' }
              [pscustomobject]@{ Kind = 'msg'; Nick = $display; Color = $color; Text = $msg }
            }
          }
        }
      }
      catch {
        [pscustomobject]@{ Kind = 'status'; Text = 'offline'; Error = $_.Exception.Message }
        Start-Sleep -Seconds 5
      }
      finally {
        if ($writer) { try { $writer.Dispose() } catch { } }
        if ($reader) { try { $reader.Dispose() } catch { } }
        if ($ssl)    { try { $ssl.Dispose() }    catch { } }
        if ($tcp)    { try { $tcp.Close() }      catch { } }
      }
    }
  }

  function Receive-Chat {
    if (-not $script:ircJob) { return }
    $items = @()
    try { $items = @(Receive-Job -Job $script:ircJob -ErrorAction SilentlyContinue) } catch { }
    foreach ($it in $items) {
      if ($null -eq $it) { continue }
      if (-not $it.PSObject.Properties['Kind']) { continue }
      switch ([string]$it.Kind) {
        'msg' {
          $msg = [pscustomobject]@{
            Nick  = [string]$it.Nick
            Color = [string]$it.Color
            Text  = [string]$it.Text
          }
          [void]$script:messages.Add($msg)
          Add-MessageBlock $msg
          Trim-Messages
        }
        'status' {
          Set-Status ([string]$it.Text)
        }
      }
    }
    if ($items.Count -gt 0) {
      $script:ChatBox.UpdateLayout()
      $script:ChatBox.ScrollToEnd()
    }
  }

  function Stop-Chat {
    if ($script:ircJob) {
      try { Stop-Job -Job $script:ircJob -ErrorAction SilentlyContinue } catch { }
      try { Remove-Job -Job $script:ircJob -Force -ErrorAction SilentlyContinue } catch { }
      $script:ircJob = $null
    }
  }

  function Start-Chat {
    Stop-Chat
    $ch = [string]$script:cfg.channel
    if ([string]::IsNullOrWhiteSpace($ch)) { Set-Status 'idle'; return }
    Set-Status 'connecting'
    $script:ircJob = Start-Job -ScriptBlock $script:ircWorker -ArgumentList $ch
  }

  # ---------- настройки ----------
  function Show-ColorDialog([string]$current) {
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    try { $dlg.Color = [System.Drawing.ColorTranslator]::FromHtml($current) } catch { }

    $mainTop = $script:win.Topmost
    $setTop = $false
    if ($script:settingsWin) { $setTop = $script:settingsWin.Topmost; $script:settingsWin.Topmost = $false }
    $script:win.Topmost = $false
    $result = $dlg.ShowDialog()
    $script:win.Topmost = $mainTop
    if ($script:settingsWin) { $script:settingsWin.Topmost = $setTop }

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
      return ('#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)
    }
    return $null
  }

  function Apply-Form($sw) {
    if (-not $sw) { return }
    $prevChannel = [string]$script:cfg.channel

    $channel = Normalize-Channel ([string]$sw.FindName('ChannelBox').Text)
    $width   = Clamp-Int (To-Int ([string]$sw.FindName('WidthBox').Text)  ([int]$script:cfg.width))    220 1600
    $height  = Clamp-Int (To-Int ([string]$sw.FindName('HeightBox').Text) ([int]$script:cfg.height))   160 1600
    $font    = Clamp-Int (To-Int ([string]$sw.FindName('FontBox').Text)   ([int]$script:cfg.fontSize)) 8 40
    $opacity = [math]::Round(([double]$sw.FindName('OpacitySlider').Value), 2)
    $topmost = [bool]$sw.FindName('TopmostBox').IsChecked

    $bg = Normalize-Hex ([string]$sw.FindName('BgHexBox').Text)
    if (-not $bg) { $bg = [string]$script:cfg.bgColor }
    $fg = Normalize-Hex ([string]$sw.FindName('FgHexBox').Text)
    if (-not $fg) { $fg = [string]$script:cfg.textColor }

    $script:cfg.channel   = $channel
    $script:cfg.width     = $width
    $script:cfg.height    = $height
    $script:cfg.fontSize  = $font
    $script:cfg.opacity   = $opacity
    $script:cfg.bgColor   = $bg
    $script:cfg.textColor = $fg
    $script:cfg.topmost   = $topmost

    $sw.FindName('ChannelBox').Text = $channel
    $sw.FindName('WidthBox').Text   = [string]$width
    $sw.FindName('HeightBox').Text  = [string]$height
    $sw.FindName('FontBox').Text    = [string]$font
    $sw.FindName('BgHexBox').Text   = $bg
    $sw.FindName('FgHexBox').Text   = $fg

    $script:editBg = $bg
    $script:editFg = $fg
    Update-Appearance
    Save-Config

    if ($channel -ne $prevChannel) {
      $script:messages.Clear()
      $script:ChatBox.Document.Blocks.Clear()
      Start-Chat
    }

    $hint = $sw.FindName('HintText')
    if ([string]::IsNullOrWhiteSpace($channel)) {
      $hint.Text = 'Укажи канал Twitch, например: имя_стримера'
    } else {
      $hint.Text = 'Сохранено: #' + $channel
    }
  }

  $script:settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Настройки Chatik"
        Width="360" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="12" Foreground="#FFB4B7BE"
        TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#FF2A2A30"/>
      <Setter Property="Foreground" Value="#FFF2F3F5"/>
      <Setter Property="BorderBrush" Value="#FF3E3E46"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="SelectionBrush" Value="#FF7C3AED"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#FFF2F3F5"/>
      <Setter Property="Background" Value="#FF34343B"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.65"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFE8E9EC"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
  </Window.Resources>
  <Border Background="#F516161A" CornerRadius="10" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="16">
    <StackPanel>
      <Grid x:Name="TitleBar" Background="Transparent" Margin="0,0,0,14" Cursor="SizeAll">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Настройки" Foreground="#FFF2F3F5" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Button x:Name="CloseBtn" Grid.Column="1" Content="✕" FontSize="11" Padding="0"
                Width="24" Height="24" Background="Transparent" ToolTip="Закрыть"/>
      </Grid>

      <TextBlock Text="Канал Twitch" Margin="0,0,0,4"/>
      <TextBox x:Name="ChannelBox"/>

      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="Ширина" Margin="0,0,0,4"/>
          <TextBox x:Name="WidthBox"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="Высота" Margin="0,0,0,4"/>
          <TextBox x:Name="HeightBox"/>
        </StackPanel>
      </Grid>

      <Grid Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="12"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="Размер шрифта" Margin="0,0,0,4"/>
          <TextBox x:Name="FontBox" Margin="0"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="Прозрачность" Margin="0,0,0,4"/>
          <Grid Height="28">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Slider x:Name="OpacitySlider" Minimum="0.1" Maximum="1" SmallChange="0.05"
                    LargeChange="0.1" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBlock x:Name="OpacityValue" Grid.Column="1" Foreground="#FFF2F3F5"
                       VerticalAlignment="Center" MinWidth="34" TextAlignment="Right" Text="82%"/>
          </Grid>
        </StackPanel>
      </Grid>

      <TextBlock Text="Цвет фона" Margin="0,0,0,4"/>
      <Grid Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="BgSwatch" Width="28" Height="28" CornerRadius="6" BorderBrush="#33FFFFFF"
                BorderThickness="1" Background="#18181B" Cursor="Hand" ToolTip="Выбрать цвет"/>
        <TextBox x:Name="BgHexBox" Grid.Column="2" Margin="0" FontFamily="Consolas"/>
      </Grid>

      <TextBlock Text="Цвет текста" Margin="0,0,0,4"/>
      <Grid Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="FgSwatch" Width="28" Height="28" CornerRadius="6" BorderBrush="#33FFFFFF"
                BorderThickness="1" Background="#FFFFFF" Cursor="Hand" ToolTip="Выбрать цвет"/>
        <TextBox x:Name="FgHexBox" Grid.Column="2" Margin="0" FontFamily="Consolas"/>
      </Grid>

      <CheckBox x:Name="TopmostBox" Content="Поверх всех окон" Margin="0,0,0,10"/>

      <TextBlock x:Name="HintText" FontSize="11" Foreground="#FF82868F" TextWrapping="Wrap"
                 Margin="0,0,0,12"
                 Text="Окно не попадает в захват экрана (Windows 10 2004+). Сверху за заголовок — перетащить, за угол чата — изменить размер."/>

      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="CancelBtn" Content="Отмена" Background="Transparent"/>
        <Button x:Name="ApplyBtn" Grid.Column="2" Content="Применить"/>
        <Button x:Name="SaveBtn" Grid.Column="4" Content="Сохранить" Background="#FF7C3AED"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@

  function Open-Settings {
    if ($script:settingsWin) {
      $script:settingsWin.Show()
      $script:settingsWin.Activate()
      return
    }
    if (-not $script:win.IsVisible) { $script:win.Show() }

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:settingsXaml)
    $sw = [System.Windows.Markup.XamlReader]::Load($reader)
    $sw.Owner = $script:win
    $sw.Topmost = $true
    $script:settingsWin = $sw

    $script:editBg = Normalize-Hex ([string]$script:cfg.bgColor)
    if (-not $script:editBg) { $script:editBg = '#18181B' }
    $script:editFg = Normalize-Hex ([string]$script:cfg.textColor)
    if (-not $script:editFg) { $script:editFg = '#FFFFFF' }

    $sw.FindName('ChannelBox').Text    = [string]$script:cfg.channel
    $sw.FindName('WidthBox').Text      = [string]$script:cfg.width
    $sw.FindName('HeightBox').Text     = [string]$script:cfg.height
    $sw.FindName('FontBox').Text       = [string]$script:cfg.fontSize
    $sw.FindName('OpacitySlider').Value = [double]$script:cfg.opacity
    $sw.FindName('OpacityValue').Text  = ('{0}%' -f [int][math]::Round([double]$script:cfg.opacity * 100))
    $sw.FindName('TopmostBox').IsChecked = [bool]$script:cfg.topmost
    $sw.FindName('BgHexBox').Text      = $script:editBg
    $sw.FindName('FgHexBox').Text      = $script:editFg
    $sw.FindName('BgSwatch').Background = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor $script:editBg))
    $sw.FindName('FgSwatch').Background = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor $script:editFg))

    if ([string]::IsNullOrWhiteSpace([string]$script:cfg.channel)) {
      $sw.FindName('HintText').Text = 'Укажи канал Twitch, например: имя_стримера'
    }

    $sw.FindName('OpacitySlider').Add_ValueChanged({
      $w = $script:settingsWin
      if ($w) {
        $v = [double]$w.FindName('OpacitySlider').Value
        $w.FindName('OpacityValue').Text = '{0}%' -f [int][math]::Round($v * 100)
      }
    })

    $sw.FindName('BgSwatch').Add_MouseLeftButtonUp({
      $newHex = Show-ColorDialog $script:editBg
      if ($newHex) { $script:settingsWin.FindName('BgHexBox').Text = $newHex }
    })
    $sw.FindName('FgSwatch').Add_MouseLeftButtonUp({
      $newHex = Show-ColorDialog $script:editFg
      if ($newHex) { $script:settingsWin.FindName('FgHexBox').Text = $newHex }
    })

    $sw.FindName('BgHexBox').Add_TextChanged({
      $w = $script:settingsWin
      if (-not $w) { return }
      $h = Normalize-Hex ([string]$w.FindName('BgHexBox').Text)
      if ($h) {
        $script:editBg = $h
        $w.FindName('BgSwatch').Background = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor $h))
      }
    })
    $sw.FindName('FgHexBox').Add_TextChanged({
      $w = $script:settingsWin
      if (-not $w) { return }
      $h = Normalize-Hex ([string]$w.FindName('FgHexBox').Text)
      if ($h) {
        $script:editFg = $h
        $w.FindName('FgSwatch').Background = [System.Windows.Media.SolidColorBrush]::new((Parse-HexColor $h))
      }
    })

    $sw.FindName('TitleBar').Add_MouseLeftButtonDown({
      try { $script:settingsWin.DragMove() } catch { }
    })
    $sw.FindName('CloseBtn').Add_Click({ $script:settingsWin.Close() })
    $sw.FindName('CancelBtn').Add_Click({ $script:settingsWin.Close() })
    $sw.FindName('ApplyBtn').Add_Click({ Apply-Form $script:settingsWin })
    $sw.FindName('SaveBtn').Add_Click({
      Apply-Form $script:settingsWin
      $script:settingsWin.Close()
    })
    $sw.Add_KeyDown({
      if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $script:settingsWin.Close() }
    })

    [void]$sw.ShowDialog()
    $script:settingsWin = $null
  }

  # ---------- трей ----------
  function New-ChatikIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $accent = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 124, 58, 237))
    $white  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255, 255))

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(2, 2, 12, 12, 180, 90)
    $path.AddArc(18, 2, 12, 12, 270, 90)
    $path.AddArc(18, 14, 12, 12, 0, 90)
    $path.AddArc(2, 14, 12, 12, 90, 90)
    $path.CloseFigure()
    $g.FillPath($accent, $path)

    $tail = [System.Drawing.Point[]]@(
      [System.Drawing.Point]::new(8, 22),
      [System.Drawing.Point]::new(8, 31),
      [System.Drawing.Point]::new(17, 22)
    )
    $g.FillPolygon($accent, $tail)
    foreach ($x in @(9, 14, 19)) { $g.FillEllipse($white, $x, 11, 4, 4) }

    $g.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bmp.Dispose()
    return $icon
  }

  function Toggle-Overlay {
    if ($script:win.IsVisible) {
      $script:win.Hide()
    } else {
      $script:win.Show()
      $script:win.Activate()
    }
  }

  function Clear-Chat {
    $script:messages.Clear()
    $script:ChatBox.Document.Blocks.Clear()
  }

  function Copy-ChatText {
    try {
      $text = ''
      $sel = $script:ChatBox.Selection
      if ($sel -and -not $sel.IsEmpty -and $sel.Text.Trim()) {
        $text = $sel.Text.Trim()
      } elseif ($script:ctxSelection) {
        $text = [string]$script:ctxSelection
      } elseif ($script:ctxParagraph) {
        $range = New-Object System.Windows.Documents.TextRange($script:ctxParagraph.ContentStart, $script:ctxParagraph.ContentEnd)
        $text = $range.Text.Trim()
        if ($text) { $script:ChatBox.Selection.Select($script:ctxParagraph.ContentStart, $script:ctxParagraph.ContentEnd) }
      }
      if ($text) { [System.Windows.Clipboard]::SetText($text) }
    } catch { Write-Log "Буфер обмена: $($_.Exception.Message)" }
  }

  function Init-Tray {
    $script:trayIcon = New-ChatikIcon

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = $script:trayIcon
    $tray.Text = 'Chatik — чат Twitch'
    $tray.Visible = $true

    $menu2 = New-Object System.Windows.Forms.ContextMenuStrip
    $miToggle = New-Object System.Windows.Forms.ToolStripMenuItem
    $miToggle.Text = 'Скрыть чат'
    $miToggle.Add_Click({ Toggle-Overlay })

    $miSet2 = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSet2.Text = 'Настройки…'
    $miSet2.Add_Click({ Open-Settings })

    $miQuit = New-Object System.Windows.Forms.ToolStripMenuItem
    $miQuit.Text = 'Выход'
    $miQuit.Add_Click({ $script:win.Close() })

    [void]$menu2.Items.Add($miToggle)
    [void]$menu2.Items.Add($miSet2)
    [void]$menu2.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu2.Items.Add($miQuit)

    $tray.ContextMenuStrip = $menu2
    $tray.Add_MouseDoubleClick({ Toggle-Overlay })
    $menu2.Add_Opening({
      $m = $script:trayMenu
      if ($m -and $m.Items.Count -gt 0) {
        if ($script:win.IsVisible) { $m.Items[0].Text = 'Скрыть чат' } else { $m.Items[0].Text = 'Показать чат' }
      }
    })

    $script:tray = $tray
    $script:trayMenu = $menu2
  }

  # ---------- главное окно ----------
  $script:mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Chatik"
        Width="380" Height="520"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" Topmost="True"
        FontFamily="Segoe UI" FontSize="14"
        TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Border x:Name="Root" CornerRadius="10" BorderThickness="1" BorderBrush="#26FFFFFF"
          Background="#D118181B" Padding="12,8,12,10">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <Grid x:Name="Header" Background="Transparent" Margin="0,0,0,6" Cursor="SizeAll">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="ChannelLabel" Text="#channel" Foreground="#8FFFFFFF" FontSize="11"
                   FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <Ellipse x:Name="StatusDot" Grid.Column="1" Width="8" Height="8"
                 Fill="#FF6B7280" VerticalAlignment="Center" Margin="6,0,0,0"/>
      </Grid>

      <RichTextBox x:Name="ChatBox" Grid.Row="1"
                   IsReadOnly="True" IsReadOnlyCaretVisible="False"
                   IsInactiveSelectionHighlightEnabled="True"
                   Background="Transparent" BorderThickness="0" Padding="0"
                   VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled"
                   FocusVisualStyle="{x:Null}" IsDocumentEnabled="False">
        <FlowDocument PagePadding="0"/>
      </RichTextBox>

      <Border x:Name="Grip" Grid.RowSpan="2" Width="18" Height="18"
              HorizontalAlignment="Right" VerticalAlignment="Bottom"
              Background="Transparent" Cursor="SizeNWSE" ToolTip="Изменить размер">
        <Path Stroke="#4DFFFFFF" StrokeThickness="1"
              Data="M6,15 L15,6 M10,15 L15,10 M14,15 L15,14"/>
      </Border>
    </Grid>
  </Border>
</Window>
'@

  $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:mainXaml)
  $win = [System.Windows.Markup.XamlReader]::Load($reader)
  $script:win         = $win
  $script:Root        = $win.FindName('Root')
  $script:Header      = $win.FindName('Header')
  $script:ChannelLabel = $win.FindName('ChannelLabel')
  $script:StatusDot   = $win.FindName('StatusDot')
  $script:ChatBox     = $win.FindName('ChatBox')
  $script:Grip        = $win.FindName('Grip')

  $win.Width  = [double]$script:cfg.width
  $win.Height = [double]$script:cfg.height
  $win.Topmost = [bool]$script:cfg.topmost

  $hasPos = ($null -ne $script:cfg.x) -and ($null -ne $script:cfg.y)
  if ($hasPos) {
    try {
      $px = [double]$script:cfg.x
      $py = [double]$script:cfg.y
      $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
      $vt = [System.Windows.SystemParameters]::VirtualScreenTop
      $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
      $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
      if ($px -lt ($vl - 200) -or $px -gt ($vl + $vw - 100) -or $py -lt ($vt - 50) -or $py -gt ($vt + $vh - 80)) {
        $win.WindowStartupLocation = 'CenterScreen'
      } else {
        $win.WindowStartupLocation = 'Manual'
        $win.Left = $px
        $win.Top  = $py
      }
    } catch { $win.WindowStartupLocation = 'CenterScreen' }
  } else {
    $win.WindowStartupLocation = 'CenterScreen'
  }

  Update-Appearance
  Set-Status 'idle'

  $win.Add_SourceInitialized({
    try {
      $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($script:win).Handle
      $ok = [Native.Win]::SetWindowDisplayAffinity($hwnd, 0x11)
      if (-not $ok) { Write-Log 'SetWindowDisplayAffinity=false — нужна Windows 10 2004 или новее' }
      $ex = [Native.Win]::GetWindowLong($hwnd, -20)
      [void][Native.Win]::SetWindowLong($hwnd, -20, ($ex -bor 0x80))
    } catch { Write-Log "SourceInitialized: $($_.Exception.Message)" }
  })

  $win.Add_Loaded({
    if ([string]::IsNullOrWhiteSpace([string]$script:cfg.channel)) {
      $script:win.Dispatcher.BeginInvoke([System.Action]{ Open-Settings }) | Out-Null
    }
  })

  $win.Add_Closing({
    try { if ($script:tray) { $script:tray.Visible = $false } } catch { }
    try {
      $script:cfg.x      = [int]$script:win.Left
      $script:cfg.y      = [int]$script:win.Top
      $script:cfg.width  = [int]$script:win.Width
      $script:cfg.height = [int]$script:win.Height
    } catch { }
    Save-Config
    Stop-Chat
  })

  $script:Header.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) {
      try { $script:win.DragMove() } catch { }
    }
  })

  $script:Grip.Add_MouseLeftButtonDown({
    $script:resizing = $true
    $pos = [System.Windows.Input.Mouse]::GetPosition($script:win)
    $script:resizeW = $script:win.Width
    $script:resizeH = $script:win.Height
    $script:resizeX = $pos.X
    $script:resizeY = $pos.Y
    [void]$script:Grip.CaptureMouse()
    $_.Handled = $true
  })
  $script:Grip.Add_MouseMove({
    if (-not $script:resizing) { return }
    $pos = [System.Windows.Input.Mouse]::GetPosition($script:win)
    $script:win.Width  = [math]::Max(220, $script:resizeW + ($pos.X - $script:resizeX))
    $script:win.Height = [math]::Max(160, $script:resizeH + ($pos.Y - $script:resizeY))
  })
  $script:Grip.Add_MouseLeftButtonUp({
    if ($script:resizing) {
      $script:resizing = $false
      $script:cfg.width  = [int]$script:win.Width
      $script:cfg.height = [int]$script:win.Height
      [void]$script:Grip.ReleaseMouseCapture()
      Save-Config
    }
  })

  $menu = [System.Windows.Controls.ContextMenu]::new()
  $miSettings = [System.Windows.Controls.MenuItem]::new()
  $miSettings.Header = 'Настройки…'
  $miSettings.Add_Click({ Open-Settings })
  $miClear = [System.Windows.Controls.MenuItem]::new()
  $miClear.Header = 'Очистить чат'
  $miClear.Add_Click({ Clear-Chat })
  $miExit = [System.Windows.Controls.MenuItem]::new()
  $miExit.Header = 'Выход'
  $miExit.Add_Click({ $script:win.Close() })
  $miHide = [System.Windows.Controls.MenuItem]::new()
  $miHide.Header = 'Скрыть в трей'
  $miHide.Add_Click({ $script:win.Hide() })
  [void]$menu.Items.Add($miSettings)
  [void]$menu.Items.Add($miClear)
  [void]$menu.Items.Add($miHide)
  [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
  [void]$menu.Items.Add($miExit)
  $win.ContextMenu = $menu

  $script:ctxParagraph = $null
  $script:ctxSelection = ''

  $chatMenu = [System.Windows.Controls.ContextMenu]::new()
  $cmCopy = [System.Windows.Controls.MenuItem]::new()
  $cmCopy.Header = 'Копировать'
  $cmCopy.Add_Click({ Copy-ChatText })
  $cmSelectAll = [System.Windows.Controls.MenuItem]::new()
  $cmSelectAll.Header = 'Выделить всё'
  $cmSelectAll.Add_Click({
    $script:ChatBox.Focus() | Out-Null
    $script:ChatBox.SelectAll()
  })
  $cmClear = [System.Windows.Controls.MenuItem]::new()
  $cmClear.Header = 'Очистить чат'
  $cmClear.Add_Click({ Clear-Chat })
  $cmSettings = [System.Windows.Controls.MenuItem]::new()
  $cmSettings.Header = 'Настройки…'
  $cmSettings.Add_Click({ Open-Settings })
  $cmHide = [System.Windows.Controls.MenuItem]::new()
  $cmHide.Header = 'Скрыть в трей'
  $cmHide.Add_Click({ $script:win.Hide() })
  $cmExit = [System.Windows.Controls.MenuItem]::new()
  $cmExit.Header = 'Выход'
  $cmExit.Add_Click({ $script:win.Close() })
  [void]$chatMenu.Items.Add($cmCopy)
  [void]$chatMenu.Items.Add($cmSelectAll)
  [void]$chatMenu.Items.Add([System.Windows.Controls.Separator]::new())
  [void]$chatMenu.Items.Add($cmClear)
  [void]$chatMenu.Items.Add($cmSettings)
  [void]$chatMenu.Items.Add($cmHide)
  [void]$chatMenu.Items.Add([System.Windows.Controls.Separator]::new())
  [void]$chatMenu.Items.Add($cmExit)
  $script:ChatBox.ContextMenu = $chatMenu

  $script:ChatBox.Add_PreviewMouseRightButtonDown({
    try {
      $script:ctxParagraph = $null
      $script:ctxSelection = ''
      $pt = $_.GetPosition($script:ChatBox)
      $tp = $script:ChatBox.GetPositionFromPoint($pt, $true)
      if ($tp) {
        $script:ctxParagraph = $tp.Paragraph
        $script:ChatBox.CaretPosition = $tp
      }
      $sel = $script:ChatBox.Selection
      if ($sel -and -not $sel.IsEmpty -and $sel.Text.Trim()) { $script:ctxSelection = $sel.Text.Trim() }
    } catch { }
  })

  # обычный клик по сообщению выделяет его целиком (перетаскивание — обычное выделение)
  $script:chatDown = $null
  $script:ChatBox.Add_PreviewMouseLeftButtonDown({
    try { $script:chatDown = $_.GetPosition($script:ChatBox) } catch { $script:chatDown = $null }
  })
  $script:ChatBox.Add_PreviewMouseLeftButtonUp({
    try {
      if ($null -eq $script:chatDown) { return }
      $pt = $_.GetPosition($script:ChatBox)
      $dx = [math]::Abs($pt.X - $script:chatDown.X)
      $dy = [math]::Abs($pt.Y - $script:chatDown.Y)
      $script:chatDown = $null
      if ($dx -gt 4 -or $dy -gt 4) { return }
      $tp = $script:ChatBox.GetPositionFromPoint($pt, $true)
      if ($tp -and $tp.Paragraph) {
        $p = $tp.Paragraph
        $script:ChatBox.Selection.Select($p.ContentStart, $p.ContentEnd)
      }
    } catch { }
  })

  # Ctrl+C копирует выделение без лишних переводов строк
  $script:ChatBox.Add_PreviewKeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::C -and
        ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
      Copy-ChatText
      $_.Handled = $true
    }
  })

  try { Init-Tray } catch { Write-Log "Трей: $($_.Exception.Message)" }

  $script:timer = [System.Windows.Threading.DispatcherTimer]::new()
  $script:timer.Interval = [TimeSpan]::FromMilliseconds(300)
  $script:timer.Add_Tick({ Receive-Chat })
  $script:timer.Start()

  Start-Chat
  [void]$win.ShowDialog()
  $script:timer.Stop()
  Stop-Chat
  try { if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() } } catch { }
}
catch {
  $text = $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace
  Write-Log $text
  try { [System.Windows.MessageBox]::Show($text, 'Chatik — ошибка') | Out-Null } catch { }
}
