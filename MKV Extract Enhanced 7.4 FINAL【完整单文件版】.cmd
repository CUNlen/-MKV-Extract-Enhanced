@echo off
setlocal EnableExtensions
title MKV Extract Enhanced 7.4 FINAL
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -Command ^
"$raw = Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8; $ps = ($raw -split '###PS_START###',2)[1]; $ps = ($ps -split '###PS_END###',2)[0]; & ([scriptblock]::Create($ps))"
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
  echo.
  echo MKV Extract Enhanced 7.4 FINAL 运行失败，错误代码：%ERR%
  pause
)
exit /b %ERR%

###PS_START###
#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = "Stop"

# -----------------------------
# MKV Extract Enhanced 7.4 FINAL
# 修复重点：
# 1. 真正启用 Drag & Drop：AllowDrop + DragEnter + DragDrop
# 2. 文件按钮与拖放共用同一套 Add-InputFiles
# 3. 自动扫描 MKVToolNix JSON
# 4. 大日志窗口，不再只有一小条
# 5. 扫描/提取放到后台线程，界面不会假死
# -----------------------------

$script:InputFiles = New-Object System.Collections.Generic.List[string]
$script:Tracks = New-Object System.Collections.Generic.List[object]
$script:CurrentScanId = 0

function Find-Exe([string]$name) {
    $candidates = @(
        "$env:ProgramFiles\MKVToolNix\$name",
        "${env:ProgramFiles(x86)}\MKVToolNix\$name"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    try {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    } catch {}
    return ""
}

function Get-CodecExtension([string]$codecId) {
    switch -Regex ($codecId) {
        "S_TEXT/UTF8" { return ".srt" }
        "S_TEXT/ASS"  { return ".ass" }
        "S_TEXT/SSA"  { return ".ssa" }
        "S_TEXT/WEBVTT" { return ".vtt" }
        "S_HDMV/PGS"  { return ".sup" }
        "S_VOBSUB"    { return ".sub" }
        "S_TEXT/USF"  { return ".usf" }
        "S_KATE"      { return ".ogg" }
        "A_"          { return ".mka" }
        "V_"          { return ".mkv" }
        default       { return ".bin" }
    }
}

function Add-Log([string]$text) {
    if ($null -eq $text) { return }
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $logBox.AppendText("[$stamp] $text`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-InputFiles([string[]]$paths) {
    foreach ($raw in $paths) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $p = $raw.Trim('"')
        if (-not (Test-Path -LiteralPath $p)) { continue }

        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in ".mkv",".mka",".mks",".webm" } |
                ForEach-Object {
                    if (-not $script:InputFiles.Contains($_.FullName)) {
                        [void]$script:InputFiles.Add($_.FullName)
                    }
                }
        }
        else {
            $ext = [IO.Path]::GetExtension($p).ToLowerInvariant()
            if ($ext -in ".mkv",".mka",".mks",".webm") {
                $full = [IO.Path]::GetFullPath($p)
                if (-not $script:InputFiles.Contains($full)) {
                    [void]$script:InputFiles.Add($full)
                }
            }
        }
    }

    $inputList.Items.Clear()
    foreach ($f in $script:InputFiles) {
        [void]$inputList.Items.Add($f)
    }

    $fileCountLabel.Text = "$($script:InputFiles.Count) 个文件"
    if ($script:InputFiles.Count -gt 0) {
        Add-Log "已添加 $($script:InputFiles.Count) 个输入文件。"
        Start-ScanAll
    }
}

function Start-ScanAll {
    if ($script:InputFiles.Count -eq 0) { return }

    $mkvmerge = $mkvmergeBox.Text.Trim()
    if (-not (Test-Path -LiteralPath $mkvmerge)) {
        [System.Windows.Forms.MessageBox]::Show(
            "找不到 mkvmerge.exe。`r`n请先选择 MKVToolNix 的 mkvmerge.exe。",
            "MKV Extract Enhanced",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $script:CurrentScanId++
    $scanId = $script:CurrentScanId
    $script:Tracks.Clear()
    $grid.Rows.Clear()
    $trackInfo.Clear()
    $statusLabel.Text = "● 扫描中"
    $statusLabel.ForeColor = [Drawing.Color]::Gold
    $scanButton.Enabled = $false
    $extractButton.Enabled = $false

    Add-Log "========== 开始扫描 =========="
    Add-Log "mkvmerge：$mkvmerge"
    Add-Log "输入文件数量：$($script:InputFiles.Count)"

    $files = @($script:InputFiles | ForEach-Object { [string]$_ })
    $scanContext = [pscustomobject]@{
        MkvMerge = [string]$mkvmerge
        Files    = $files
    }

    $worker = New-Object System.ComponentModel.BackgroundWorker

    $worker.DoWork += {
        param($sender, $e)

        $ctx = $e.Argument
        $exe = [string]$ctx.MkvMerge
        $result = New-Object System.Collections.Generic.List[object]

        function Invoke-MkvMergeJson([string]$exePath, [string]$filePath, [string]$arguments) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = $arguments
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            try { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch {}
            try { $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch {}

            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $psi
            try {
                [void]$p.Start()
                $stdout = $p.StandardOutput.ReadToEnd()
                $stderr = $p.StandardError.ReadToEnd()
                $p.WaitForExit()
                [pscustomobject]@{ ExitCode=$p.ExitCode; StdOut=$stdout; StdErr=$stderr }
            }
            finally { $p.Dispose() }
        }

        foreach ($file in $files) {
            if ([string]::IsNullOrWhiteSpace($file)) { continue }
            try {
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    $result.Add([pscustomobject]@{ Kind="Error"; File=$file; Message="文件不存在或无法访问。" }); continue
                }
                $escapedFile = $file.Replace('"','\"')
                $r = Invoke-MkvMergeJson $exe $file "--identification-format json --identify `"$escapedFile`""
                if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.StdOut)) {
                    $r = Invoke-MkvMergeJson $exe $file "-J `"$escapedFile`""
                }
                if ($r.ExitCode -ne 0) {
                    $msg = $r.StdErr.Trim()
                    if (-not $msg) { $msg = "mkvmerge 退出码：$($r.ExitCode)" }
                    $result.Add([pscustomobject]@{ Kind="Error"; File=$file; Message=$msg }); continue
                }
                if ([string]::IsNullOrWhiteSpace($r.StdOut)) {
                    $result.Add([pscustomobject]@{ Kind="Error"; File=$file; Message="mkvmerge 没有返回 JSON 数据。" }); continue
                }
                try { $json = $r.StdOut | ConvertFrom-Json }
                catch {
                    $preview = $r.StdOut.Trim()
                    if ($preview.Length -gt 1500) { $preview = $preview.Substring(0,1500) }
                    $result.Add([pscustomobject]@{ Kind="Error"; File=$file; Message="JSON 解析失败：$($_.Exception.Message)`r`n返回内容：`r`n$preview" }); continue
                }
                $trackArray = @($json.tracks)
                if ($trackArray.Count -eq 0) {
                    $result.Add([pscustomobject]@{ Kind="Error"; File=$file; Message="mkvmerge 扫描完成，但 JSON 中没有 tracks。" }); continue
                }
                foreach ($t in $trackArray) {
                    $props = $t.properties
                    if ($null -eq $props) { $props = [pscustomobject]@{} }
                    $lang = ""
                    if ($props.PSObject.Properties.Name -contains "language_ietf") { $lang = [string]$props.language_ietf }
                    if (-not $lang -and ($props.PSObject.Properties.Name -contains "language")) { $lang = [string]$props.language }
                    $codecId = ""
                    if ($props.PSObject.Properties.Name -contains "codec_id") { $codecId = [string]$props.codec_id }
                    $trackName = ""
                    if ($props.PSObject.Properties.Name -contains "track_name") { $trackName = [string]$props.track_name }
                    $defaultTrack = $false
                    if ($props.PSObject.Properties.Name -contains "default_track") { $defaultTrack = [bool]$props.default_track }
                    $forcedTrack = $false
                    if ($props.PSObject.Properties.Name -contains "forced_track") { $forcedTrack = [bool]$props.forced_track }
                    $result.Add([pscustomobject]@{
                        Kind="Track"; File=$file; TrackId=[int]$t.id; Type=[string]$t.type; Codec=[string]$t.codec;
                        CodecId=$codecId; Language=$lang; Name=$trackName; Default=$defaultTrack; Forced=$forcedTrack; Properties=$props
                    })
                }
            }
            catch { $result.Add([pscustomobject]@{ Kind="Error"; File=$file; Message=$_.Exception.Message }) }
        }
        $e.Result = @($result)
    }

    $worker.RunWorkerCompleted += {
        param($sender, $e)
        try {
            if ($scanId -ne $script:CurrentScanId) { return }
            if ($e.Error) { Add-Log "扫描线程失败：$($e.Error.Message)" }
            else {
                foreach ($item in @($e.Result)) {
                    if ($item.Kind -eq "Error") { Add-Log "【扫描失败】$($item.File)"; Add-Log $item.Message; continue }
                    [void]$script:Tracks.Add($item)
                    $row = $grid.Rows.Add()
                    $grid.Rows[$row].Cells["选择"].Value = $false
                    $grid.Rows[$row].Cells["文件"].Value = [IO.Path]::GetFileName($item.File)
                    $grid.Rows[$row].Cells["Track"].Value = $item.TrackId
                    $grid.Rows[$row].Cells["类型"].Value = $item.Type
                    $grid.Rows[$row].Cells["编码"].Value = $item.Codec
                    $grid.Rows[$row].Cells["语言"].Value = $item.Language
                    $grid.Rows[$row].Cells["名称"].Value = $item.Name
                    $grid.Rows[$row].Cells["默认"].Value = if ($item.Default) {"是"} else {"否"}
                    $grid.Rows[$row].Cells["强制"].Value = if ($item.Forced) {"是"} else {"否"}
                    $grid.Rows[$row].Tag = $item
                }
                Add-Log "扫描完成：$($script:InputFiles.Count) 个文件，$($script:Tracks.Count) 个 Track。"
                if ($script:Tracks.Count -eq 0) { Add-Log "【重要】MKV 已成功加入，但没有生成 Track。" }
            }
        }
        finally {
            $statusLabel.Text = "● 就绪"
            $statusLabel.ForeColor = [Drawing.Color]::LimeGreen
            $scanButton.Enabled = $true
            $extractButton.Enabled = ($script:Tracks.Count -gt 0)
            $fileCountLabel.Text = "$($script:InputFiles.Count) 个文件 · $($script:Tracks.Count) 个 Track"
            $sender.Dispose()
        }
    }
    try { $worker.RunWorkerAsync($scanContext) }
    catch {
        Add-Log "无法启动扫描线程：$($_.Exception.Message)"
        $statusLabel.Text = "● 就绪"; $statusLabel.ForeColor = [Drawing.Color]::LimeGreen
        $scanButton.Enabled = $true; $extractButton.Enabled = $false; $worker.Dispose()
    }
}

function Run-Extract {
    $mkvextract = $mkvextractBox.Text.Trim()
    if (-not (Test-Path -LiteralPath $mkvextract)) {
        [System.Windows.Forms.MessageBox]::Show("找不到 mkvextract.exe。`r`n请先选择 MKVToolNix 的 mkvextract.exe。","MKV Extract Enhanced",[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $outDir = $outBox.Text.Trim()
    if (-not $outDir) { $outDir = [Environment]::GetFolderPath("Desktop") }
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($row in $grid.Rows) {
        if ($row.IsNewRow) { continue }
        if ($row.Cells["选择"].Value -eq $true -and $row.Tag) { $selected.Add($row.Tag) | Out-Null }
    }
    if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("请先勾选要提取的 Track。","提示") | Out-Null; return }
    $extractButton.Enabled = $false; $scanButton.Enabled = $false
    $statusLabel.Text = "● 提取中"; $statusLabel.ForeColor = [Drawing.Color]::Gold
    Add-Log "========== 开始提取 =========="
    $worker = New-Object System.ComponentModel.BackgroundWorker
    $worker.DoWork += {
        param($sender,$e)
        $done = 0
        foreach ($t in $selected) {
            try {
                $base = [IO.Path]::GetFileNameWithoutExtension($t.File)
                $ext = Get-CodecExtension $t.CodecId
                $safeLang = if ($t.Language) { $t.Language } else { "und" }
                $safeName = if ($t.Name) { $t.Name } else { "Track$($t.TrackId)" }
                $safeName = [Regex]::Replace($safeName, '[\\/:*?"<>|]', '_')
                $dest = Join-Path $outDir ("{0}_Track{1}_{2}_{3}{4}" -f $base,$t.TrackId,$safeLang,$safeName,$ext)
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $mkvextract
                $psi.Arguments = "tracks `"$($t.File)`" `"$($t.TrackId):$dest`""
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
                $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start()
                $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit()
                if ($p.ExitCode -eq 0) { $done++; $script:ExtractMessageQueue.Enqueue("完成：Track $($t.TrackId) -> $dest") }
                else { $script:ExtractMessageQueue.Enqueue("失败：Track $($t.TrackId)`r`n$stderr") }
                $p.Dispose()
            }
            catch { $script:ExtractMessageQueue.Enqueue("失败：Track $($t.TrackId)`r`n$($_.Exception.Message)") }
        }
        $script:ExtractMessageQueue.Enqueue("=== 提取结束：$done / $($selected.Count) ===")
    }
    $worker.RunWorkerCompleted += {
        param($sender,$e)
        $statusLabel.Text = "● 就绪"; $statusLabel.ForeColor = [Drawing.Color]::LimeGreen
        $extractButton.Enabled = $true; $scanButton.Enabled = $true
        if ($openAfterCheck.Checked) { try { Start-Process explorer.exe -ArgumentList "`"$outDir`"" } catch {} }
        $sender.Dispose()
    }
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 150
    $timer.Add_Tick({
        while ($script:ExtractMessageQueue.Count -gt 0) { Add-Log $script:ExtractMessageQueue.Dequeue() }
        if (-not $worker.IsBusy) { $timer.Stop(); $timer.Dispose() }
    })
    $timer.Start(); $worker.RunWorkerAsync()
}

$script:ExtractMessageQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]

$form = New-Object Windows.Forms.Form
$form.Text = "MKV Extract Enhanced 7.4 FINAL"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(1500, 980)
$form.MinimumSize = New-Object Drawing.Size(1100, 720)
$form.BackColor = [Drawing.Color]::FromArgb(25,25,25)
$form.ForeColor = [Drawing.Color]::White
$form.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9)

$header = New-Object Windows.Forms.Panel; $header.Dock = "Top"; $header.Height = 78; $header.BackColor = [Drawing.Color]::FromArgb(18,43,78); $form.Controls.Add($header)
$title = New-Object Windows.Forms.Label; $title.Text = "MKV Extract Enhanced"; $title.Font = New-Object Drawing.Font("Microsoft YaHei UI",18,[Drawing.FontStyle]::Bold); $title.Location = New-Object Drawing.Point(18,10); $title.AutoSize = $true; $header.Controls.Add($title)
$sub = New-Object Windows.Forms.Label; $sub.Text = "7.4 FINAL  ·  MKVToolNix 原生扫描 / 提取  ·  稳定拖放版"; $sub.Font = New-Object Drawing.Font("Microsoft YaHei UI",9); $sub.Location = New-Object Drawing.Point(20,43); $sub.AutoSize = $true; $sub.ForeColor = [Drawing.Color]::Gainsboro; $header.Controls.Add($sub)
$statusLabel = New-Object Windows.Forms.Label; $statusLabel.Text = "● 就绪"; $statusLabel.ForeColor = [Drawing.Color]::LimeGreen; $statusLabel.Font = New-Object Drawing.Font("Microsoft YaHei UI",10,[Drawing.FontStyle]::Bold); $statusLabel.AutoSize = $true; $statusLabel.Anchor = "Top,Right"; $statusLabel.Location = New-Object Drawing.Point(1400,25); $header.Controls.Add($statusLabel)

$main = New-Object Windows.Forms.TableLayoutPanel; $main.Dock="Fill"; $main.Padding=New-Object Windows.Forms.Padding(12); $main.RowCount=7; $main.ColumnCount=1
$main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,62))); $main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,140))); $main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,38))); $main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,46))); $main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,150))); $main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,48))); $main.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,55))); $form.Controls.Add($main)

$toolPanel = New-Object Windows.Forms.Panel; $main.Controls.Add($toolPanel,0,0)
function Add-PathRow($panel,$y,$labelText,$default,$buttonText) {
    $lab=New-Object Windows.Forms.Label; $lab.Text=$labelText; $lab.Location=New-Object Drawing.Point(0,$y+7); $lab.Width=90; $panel.Controls.Add($lab)
    $tb=New-Object Windows.Forms.TextBox; $tb.Text=$default; $tb.Location=New-Object Drawing.Point(82,$y+3); $tb.Width=1280; $tb.Anchor="Top,Left,Right"; $panel.Controls.Add($tb)
    $btn=New-Object Windows.Forms.Button; $btn.Text=$buttonText; $btn.Location=New-Object Drawing.Point(1370,$y); $btn.Width=110; $btn.Anchor="Top,Right"; $panel.Controls.Add($btn); return @($tb,$btn)
}
$mkvDefault=Find-Exe "mkvmerge.exe"; $mkvxDefault=Find-Exe "mkvextract.exe"
if(-not $mkvDefault){$mkvDefault="C:\Program Files\MKVToolNix\mkvmerge.exe"}; if(-not $mkvxDefault){$mkvxDefault="C:\Program Files\MKVToolNix\mkvextract.exe"}
$r1=Add-PathRow $toolPanel 0 "mkvmerge" $mkvDefault "选择 mkvmerge.exe"; $mkvmergeBox=$r1[0]
$r1[1].Add_Click({$d=New-Object Windows.Forms.OpenFileDialog; $d.Filter="mkvmerge.exe|mkvmerge.exe|EXE 文件|*.exe"; if($d.ShowDialog()-eq "OK"){$mkvmergeBox.Text=$d.FileName}})
$r2=Add-PathRow $toolPanel 31 "mkvextract" $mkvxDefault "选择 mkvextract.exe"; $mkvextractBox=$r2[0]
$r2[1].Add_Click({$d=New-Object Windows.Forms.OpenFileDialog; $d.Filter="mkvextract.exe|mkvextract.exe|EXE 文件|*.exe"; if($d.ShowDialog()-eq "OK"){$mkvextractBox.Text=$d.FileName}})

$inputPanel=New-Object Windows.Forms.Panel; $inputPanel.BackColor=[Drawing.Color]::FromArgb(32,32,32); $inputPanel.BorderStyle="FixedSingle"; $inputPanel.AllowDrop=$true; $main.Controls.Add($inputPanel,0,1)
$dropLabel=New-Object Windows.Forms.Label; $dropLabel.Text="把 MKV / MKA / MKS / WEBM 拖到这里"; $dropLabel.Font=New-Object Drawing.Font("Microsoft YaHei UI",14,[Drawing.FontStyle]::Bold); $dropLabel.ForeColor=[Drawing.Color]::LightSkyBlue; $dropLabel.TextAlign="MiddleCenter"; $dropLabel.Dock="Top"; $dropLabel.Height=55; $dropLabel.AllowDrop=$true; $inputPanel.Controls.Add($dropLabel)
$inputList=New-Object Windows.Forms.ListBox; $inputList.Dock="Fill"; $inputList.BackColor=[Drawing.Color]::FromArgb(245,245,245); $inputList.ForeColor=[Drawing.Color]::FromArgb(30,30,30); $inputList.AllowDrop=$true; $inputPanel.Controls.Add($inputList)
$buttonPanel=New-Object Windows.Forms.FlowLayoutPanel; $buttonPanel.Dock="Right"; $buttonPanel.Width=125; $buttonPanel.FlowDirection="TopDown"; $buttonPanel.WrapContents=$false; $buttonPanel.Padding=New-Object Windows.Forms.Padding(5); $inputPanel.Controls.Add($buttonPanel)
$addFileButton=New-Object Windows.Forms.Button; $addFileButton.Text="添加 MKV"; $addFileButton.Width=105; $addFileButton.Height=30; $buttonPanel.Controls.Add($addFileButton)
$addFolderButton=New-Object Windows.Forms.Button; $addFolderButton.Text="添加文件夹"; $addFolderButton.Width=105; $addFolderButton.Height=30; $buttonPanel.Controls.Add($addFolderButton)
$clearButton=New-Object Windows.Forms.Button; $clearButton.Text="清空"; $clearButton.Width=105; $clearButton.Height=30; $buttonPanel.Controls.Add($clearButton)
$addFileButton.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter="MKV / MKA / MKS / WEBM|*.mkv;*.mka;*.mks;*.webm|所有文件|*.*";$d.Multiselect=$true;if($d.ShowDialog()-eq "OK"){Add-InputFiles $d.FileNames}})
$addFolderButton.Add_Click({$d=New-Object Windows.Forms.FolderBrowserDialog;if($d.ShowDialog()-eq "OK"){Add-InputFiles @($d.SelectedPath)}})
$clearButton.Add_Click({$script:InputFiles.Clear();$script:Tracks.Clear();$inputList.Items.Clear();$grid.Rows.Clear();$trackInfo.Clear();$fileCountLabel.Text="0 个文件";$extractButton.Enabled=$false})
$dragEnterHandler={param($sender,$e)if($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)){$e.Effect=[Windows.Forms.DragDropEffects]::Copy;$dropLabel.Text="松开鼠标即可添加文件"}else{$e.Effect=[Windows.Forms.DragDropEffects]::None}}
$dragLeaveHandler={$dropLabel.Text="把 MKV / MKA / MKS / WEBM 拖到这里"}
$dragDropHandler={param($sender,$e)try{$files=$e.Data.GetData([Windows.Forms.DataFormats]::FileDrop);Add-InputFiles ([string[]]$files)}catch{Add-Log "拖放失败：$($_.Exception.Message)"};$dropLabel.Text="把 MKV / MKA / MKS / WEBM 拖到这里"}
foreach($ctrl in @($form,$inputPanel,$inputList,$dropLabel)){$ctrl.Add_DragEnter($dragEnterHandler);$ctrl.Add_DragLeave($dragLeaveHandler);$ctrl.Add_DragDrop($dragDropHandler)}

$trackTitle=New-Object Windows.Forms.Label;$trackTitle.Text="Track 列表  ·  双击查看信息";$trackTitle.Dock="Fill";$trackTitle.ForeColor=[Drawing.Color]::LightGray;$trackTitle.Padding=New-Object Windows.Forms.Padding(5,8,0,0);$main.Controls.Add($trackTitle,0,2)
$grid=New-Object Windows.Forms.DataGridView;$grid.Dock="Fill";$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.SelectionMode="FullRowSelect";$grid.MultiSelect=$false;$grid.AutoSizeRowsMode="None";$grid.BackgroundColor=[Drawing.Color]::FromArgb(42,42,42);$grid.GridColor=[Drawing.Color]::FromArgb(65,65,65);$grid.BorderStyle="None";$grid.EnableHeadersVisualStyles=$false;$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(55,55,55);$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::White;$grid.DefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(42,42,42);$grid.DefaultCellStyle.ForeColor=[Drawing.Color]::White;$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(0,90,160);$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::White;$grid.RowTemplate.Height=26;$main.Controls.Add($grid,0,3)
foreach($col in @(@{N="选择";W=55;T="CheckBox"},@{N="文件";W=340},@{N="Track";W=65},@{N="类型";W=90},@{N="编码";W=180},@{N="语言";W=90},@{N="名称";W=360},@{N="默认";W=70},@{N="强制";W=70})){if($col.T-eq"CheckBox"){$c=New-Object Windows.Forms.DataGridViewCheckBoxColumn}else{$c=New-Object Windows.Forms.DataGridViewTextBoxColumn};$c.Name=$col.N;$c.HeaderText=$col.N;$c.Width=$col.W;[void]$grid.Columns.Add($c)}
$grid.Add_CellDoubleClick({param($sender,$e)if($e.RowIndex-ge 0-and $sender.Rows[$e.RowIndex].Tag){$t=$sender.Rows[$e.RowIndex].Tag;$lines=New-Object System.Collections.Generic.List[string];[void]$lines.Add("文件：$($t.File)");[void]$lines.Add("Track：$($t.TrackId)");[void]$lines.Add("类型：$($t.Type)");[void]$lines.Add("编码：$($t.Codec)");[void]$lines.Add("Codec ID：$($t.CodecId)");[void]$lines.Add("语言：$($t.Language)");[void]$lines.Add("名称：$($t.Name)");[void]$lines.Add("默认：$($t.Default)");[void]$lines.Add("强制：$($t.Forced)");[void]$lines.Add("");[void]$lines.Add("—— MKVToolNix 完整 Track Properties ——");if($t.Properties){foreach($p in $t.Properties.PSObject.Properties){$v=$p.Value;if($v-is[System.Array]){$v=($v-join ", ")}elseif($v-is[pscustomobject]){try{$v=($v|ConvertTo-Json -Compress -Depth 20)}catch{}};[void]$lines.Add(("{0} = {1}"-f $p.Name,$v))}};$trackInfo.Text=($lines-join [Environment]::NewLine)}})
$trackInfo=New-Object Windows.Forms.TextBox;$trackInfo.Multiline=$true;$trackInfo.ReadOnly=$true;$trackInfo.ScrollBars="Vertical";$trackInfo.Dock="Fill";$trackInfo.BackColor=[Drawing.Color]::FromArgb(35,35,35);$trackInfo.ForeColor=[Drawing.Color]::White;$trackInfo.BorderStyle="FixedSingle";$trackInfo.Text="选择一个 Track 查看详细信息。";$main.Controls.Add($trackInfo,0,4)
$outPanel=New-Object Windows.Forms.Panel;$main.Controls.Add($outPanel,0,5);$outLabel=New-Object Windows.Forms.Label;$outLabel.Text="输出目录";$outLabel.Location=New-Object Drawing.Point(0,8);$outLabel.Width=70;$outPanel.Controls.Add($outLabel)
$outBox=New-Object Windows.Forms.TextBox;$outBox.Text=[Environment]::GetFolderPath("Desktop");$outBox.Location=New-Object Drawing.Point(72,4);$outBox.Width=1220;$outBox.Anchor="Top,Left,Right";$outPanel.Controls.Add($outBox)
$outBrowse=New-Object Windows.Forms.Button;$outBrowse.Text="选择目录";$outBrowse.Location=New-Object Drawing.Point(1300,2);$outBrowse.Width=95;$outBrowse.Anchor="Top,Right";$outPanel.Controls.Add($outBrowse);$outBrowse.Add_Click({$d=New-Object Windows.Forms.FolderBrowserDialog;$d.SelectedPath=$outBox.Text;if($d.ShowDialog()-eq "OK"){$outBox.Text=$d.SelectedPath}})
$openAfterCheck=New-Object Windows.Forms.CheckBox;$openAfterCheck.Text="完成后打开目录";$openAfterCheck.Checked=$true;$openAfterCheck.Location=New-Object Drawing.Point(1400,6);$openAfterCheck.Width=120;$openAfterCheck.Anchor="Top,Right";$outPanel.Controls.Add($openAfterCheck)
$bottom=New-Object Windows.Forms.Panel;$main.Controls.Add($bottom,0,6)
function Make-Btn($text,$x,$w){$b=New-Object Windows.Forms.Button;$b.Text=$text;$b.Location=New-Object Drawing.Point($x,5);$b.Width=$w;$b.Height=35;$bottom.Controls.Add($b);return $b}
$selectSub=Make-Btn "全选字幕" 0 90;$selectAudio=Make-Btn "全选音频" 95 90;$selectVideo=Make-Btn "全选视频" 190 90;$selectAll=Make-Btn "全选" 285 70;$unselect=Make-Btn "取消全选" 360 90;$scanButton=Make-Btn "重新扫描" 455 90;$logButton=Make-Btn "查看日志（大窗口）" 550 145;$extractButton=Make-Btn "提取选中轨道" 1300 145;$extractButton.BackColor=[Drawing.Color]::FromArgb(0,120,215);$extractButton.ForeColor=[Drawing.Color]::White;$extractButton.Font=New-Object Drawing.Font("Microsoft YaHei UI",10,[Drawing.FontStyle]::Bold);$extractButton.Anchor="Top,Right"
$fileCountLabel=New-Object Windows.Forms.Label;$fileCountLabel.Text="0 个文件";$fileCountLabel.Location=New-Object Drawing.Point(720,14);$fileCountLabel.AutoSize=$true;$fileCountLabel.ForeColor=[Drawing.Color]::LightGray;$bottom.Controls.Add($fileCountLabel)
$selectSub.Add_Click({foreach($r in $grid.Rows){if($r.Tag-and $r.Tag.Type-eq"subtitles"){$r.Cells["选择"].Value=$true}}});$selectAudio.Add_Click({foreach($r in $grid.Rows){if($r.Tag-and $r.Tag.Type-eq"audio"){$r.Cells["选择"].Value=$true}}});$selectVideo.Add_Click({foreach($r in $grid.Rows){if($r.Tag-and $r.Tag.Type-eq"video"){$r.Cells["选择"].Value=$true}}});$selectAll.Add_Click({foreach($r in $grid.Rows){$r.Cells["选择"].Value=$true}});$unselect.Add_Click({foreach($r in $grid.Rows){$r.Cells["选择"].Value=$false}});$scanButton.Add_Click({Add-Log "手动重新扫描。";Start-ScanAll});$extractButton.Add_Click({Run-Extract})
$logButton.Add_Click({$logForm=New-Object Windows.Forms.Form;$logForm.Text="MKV Extract Enhanced - 运行日志";$logForm.StartPosition="CenterParent";$logForm.Size=New-Object Drawing.Size(1100,720);$logForm.BackColor=[Drawing.Color]::FromArgb(20,20,20);$tb=New-Object Windows.Forms.TextBox;$tb.Multiline=$true;$tb.ReadOnly=$true;$tb.ScrollBars="Both";$tb.Dock="Fill";$tb.Font=New-Object Drawing.Font("Consolas",10);$tb.BackColor=[Drawing.Color]::FromArgb(20,20,20);$tb.ForeColor=[Drawing.Color]::White;$tb.Text=$logBox.Text;$logForm.Controls.Add($tb);$logForm.ShowDialog($form)|Out-Null;$logForm.Dispose()})
$logBox=New-Object Windows.Forms.TextBox;$logBox.Visible=$false;$form.Controls.Add($logBox)
$form.Add_Shown({$form.Activate();Add-Log "MKV Extract Enhanced 7.4 FINAL 已启动。";Add-Log "拖放修复已启用：请直接把 MKV 文件拖到白色输入区域。";if(-not(Test-Path -LiteralPath $mkvmergeBox.Text)){Add-Log "提示：mkvmerge.exe 路径不存在，请选择正确路径。"};if(-not(Test-Path -LiteralPath $mkvextractBox.Text)){Add-Log "提示：mkvextract.exe 路径不存在，请选择正确路径。"}})
[void]$form.ShowDialog()
###PS_END###
