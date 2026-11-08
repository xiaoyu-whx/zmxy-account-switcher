# =====================================================================
#  造梦西游OL 换号器  (雷电9 / MuMu)
# ---------------------------------------------------------------------
#  原理：
#    1) 每个号手动登录一次（账号密码 / 4399 网页登录都行）
#    2) 点「抓取当前账号」→ 把该号的登录态数据打包成一个独立存档
#    3) 以后换号：点那一行的「一键登录」→ 写回存档 + 重启游戏
#       → 游戏读到旧登录态，直接进，不用再输账号密码
#
#  前提：模拟器必须开 root（雷电9：设置 → 其他设置 → root权限 → 开启 → 重启模拟器）
# =====================================================================
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$Cli,
    [string]$Name,
    [string]$Pkg,
    [string]$Serial,
    [switch]$SmokeTest
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}

$Script:Dir     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:ProfDir = Join-Path $Script:Dir 'profiles'
$Script:CfgFile = Join-Path $Script:Dir 'config.json'
$Script:LogDir  = Join-Path $Script:Dir 'logs'
foreach ($p in @($Script:ProfDir, $Script:LogDir)) {
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# ---------------------------- 配置 ----------------------------
$Script:Cfg = [ordered]@{
    Adb         = ''
    Serial      = ''
    Package     = ''
    WithSdcard  = $false
    AutoRefresh = $true
    WaitSec     = 20
}
if (Test-Path -LiteralPath $Script:CfgFile) {
    try {
        $j = Get-Content -LiteralPath $Script:CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($Script:Cfg.Keys)) {
            if (($j.PSObject.Properties.Name -contains $k) -and ($null -ne $j.$k)) { $Script:Cfg[$k] = $j.$k }
        }
    } catch { }
}
function Save-Cfg {
    try { $Script:Cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Script:CfgFile -Encoding UTF8 } catch { }
}

$Script:Busy = $false

# ---------------------------- adb 层 ----------------------------
function Get-Adb {
    if ($Script:Adb) { return $Script:Adb }
    $cands = @(
        $Script:Cfg.Adb,
        'D:\leidian\LDPlayer9\adb.exe',
        'C:\leidian\LDPlayer9\adb.exe',
        'D:\LDPlayer\LDPlayer9\adb.exe',
        'C:\Program Files\Netease\MuMu\nx_main\adb.exe',
        'D:\Android\Sdk\platform-tools\adb.exe',
        (Get-Command adb.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    )
    foreach ($x in $cands) {
        if ($x -and (Test-Path -LiteralPath $x)) { $Script:Adb = $x; return $x }
    }
    return $null
}

# 参数转义（老版 powershell.exe 没有 ArgumentList 时用）
function ConvertTo-ArgText {
    param([string]$s)
    if ($s -eq '') { return '""' }
    if (($s -notmatch '[\s"]') -and (-not $s.EndsWith('\'))) { return $s }
    $t = $s
    if ($t.EndsWith('\')) { $t = $t + '\' }
    $t = $t.Replace('"', '\"')
    return '"' + $t + '"'
}

# 调 adb 的唯一入口：用 .NET Process 显式重定向。
# 不能用 PowerShell 的 2>&1 / 2>$null —— 在没有控制台的 WinForms 进程里会抛
# "StandardOutputEncoding is only supported when standard output is redirected"
function Invoke-Adb {
    param([string[]]$Argv)
    $Script:LastAdbExit = -1
    $adb = Get-Adb
    if (-not $adb) { return '' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adb
    if ($psi.PSObject.Properties.Name -contains 'ArgumentList') {
        foreach ($a in $Argv) { [void]$psi.ArgumentList.Add([string]$a) }
    } else {
        $psi.Arguments = (($Argv | ForEach-Object { ConvertTo-ArgText ([string]$_) }) -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    try {
        $pr = [System.Diagnostics.Process]::Start($psi)
        $outTask = $pr.StandardOutput.ReadToEndAsync()
        $errTask = $pr.StandardError.ReadToEndAsync()
        [void]$pr.WaitForExit(180000)
        $txt = (($outTask.Result) + "`n" + ($errTask.Result)).Trim()
        $Script:LastAdbExit = $pr.ExitCode
        $pr.Dispose()
        return $txt
    } catch {
        return ''
    }
}

function Get-Serials {
    if (-not (Get-Adb)) { return @() }
    $out = Invoke-Adb @('devices')
    $list = @()
    foreach ($l in ($out -split "`r?`n")) {
        if ($l -match '^\s*([\w\.\-]+:\d+|emulator-\d+)\s+device') { $list += $Matches[1] }
        elseif ($l -match '^\s*([\w\.\-]+)\s+device') { $list += $Matches[1] }
    }
    return ($list | Select-Object -Unique)
}

function Connect-Emu {
    if (-not (Get-Adb)) { return }
    if ((Get-Serials).Count -gt 0) { return }
    foreach ($port in 5555, 5557, 5559, 5561, 16384, 16416) {
        [void](Invoke-Adb @('connect', "127.0.0.1:$port"))
    }
    Start-Sleep -Milliseconds 700
}

function Sh {
    param([string]$Serial, [string]$Cmd)
    if (-not (Get-Adb)) { return '' }
    return (Invoke-Adb @('-s', $Serial, 'shell', $Cmd)).Trim()
}

function Test-Root {
    param([string]$Serial)
    try { return ((Sh $Serial 'su -c id') -match 'uid=0') } catch { return $false }
}

function Get-Packages {
    param([string]$Serial)
    $out = Invoke-Adb @('-s', $Serial, 'shell', 'pm list packages -3')
    $list = @()
    foreach ($l in ($out -split "`r?`n")) {
        $t = $l.Trim()
        if ($t -match '^package:(.+)$') {
            $p = $Matches[1].Trim()
            if (($p -match '\.') -and ($p -notmatch '\s')) { $list += $p }
        }
    }
    return ($list | Sort-Object -Unique)
}

function Get-Uid {
    param([string]$Serial, [string]$Pkg)
    $u = Sh $Serial ("su -c 'stat -c %u /data/data/{0}'" -f $Pkg)
    if ($u -match '^\d+') { return $Matches[0] }
    return ''
}

function Get-Model {
    param([string]$Serial)
    return (Sh $Serial 'getprop ro.product.model')
}

function Start-App {
    param([string]$Serial, [string]$Pkg)
    $act = ''
    try {
        $raw = Invoke-Adb @('-s', $Serial, 'shell', "cmd package resolve-activity --brief $Pkg")
        $lines = @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '/' })
        if ($lines.Count -gt 0) { $act = $lines[-1] }
    } catch { }
    if ($act -match '/') {
        [void](Invoke-Adb @('-s', $Serial, 'shell', "am start -n $act"))
        return $act
    }
    [void](Invoke-Adb @('-s', $Serial, 'shell', "monkey -p $Pkg -c android.intent.category.LAUNCHER 1"))
    return 'launcher'
}

# 存档时不打包的东西：缓存类，以及游戏自己的静态资源包（太大且与登录无关）
$Script:SkipItems = @('cache', 'code_cache', 'app_libs')

# 把 /data/data/包名 下除 SkipItems 以外的所有条目都算作存档内容（自动适配各家游戏的不同目录结构）
function Get-ExistingItems {
    param([string]$Serial, [string]$Pkg)
    $cmd = 'su -c ''ls -1 /data/data/{0}''' -f $Pkg
    $raw = Sh $Serial $cmd
    $found = @()
    foreach ($l in ($raw -split "`r?`n")) {
        $t = $l.Trim()
        if (-not $t) { continue }
        if ($t -match '[\s;|&]') { continue }
        if ($Script:SkipItems -contains $t) { continue }
        if ($t -eq '.' -or $t -eq '..') { continue }
        $found += $t
    }
    return $found
}

# ---------------------------- 抓取 ----------------------------
function Save-Snapshot {
    param([string]$Serial, [string]$Pkg, [string]$Name, [bool]$WithSdcard, [scriptblock]$LogFn)

    if (-not (Get-Adb)) { throw '找不到 adb.exe' }
    if (-not $Pkg) { throw '还没选游戏包名' }

    $dir = Join-Path $Script:ProfDir $Name
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $items = Get-ExistingItems -Serial $Serial -Pkg $Pkg
    if ($items.Count -eq 0) { throw "在 /data/data/$Pkg 下没找到数据目录：包名可能不对，或者模拟器没开 root" }

    $remote = '/sdcard/.zsw_snap.tgz'
    [void](Invoke-Adb @('-s', $Serial, 'shell', ("su -c 'rm -f {0}'" -f $remote)))

    if ($LogFn) { & $LogFn ("打包 {0} …（{1}）" -f $Pkg, ($items -join ', ')) }
    $inner = 'tar czf {0} -C /data/data/{1} {2}' -f $remote, $Pkg, ($items -join ' ')
    $r = Invoke-Adb @('-s', $Serial, 'shell', ("su -c '{0}'" -f $inner))
    Start-Sleep -Milliseconds 300

    $sz = Sh $Serial ("su -c 'stat -c %s {0}'" -f $remote)
    if (-not ($sz -match '^\d+') -or [int64]$Matches[0] -lt 1024) {
        throw ("打包失败：$($r.Trim())")
    }

    $local = Join-Path $dir 'snap.tgz'
    $pull = Invoke-Adb @('-s', $Serial, 'pull', $remote, $local)
    if (-not (Test-Path -LiteralPath $local)) { throw "下载存档失败：$($pull.Trim())" }

    if ($WithSdcard) {
        $sdLocal = Join-Path $dir 'sdcard.tgz'
        $sdRemote = '/sdcard/.zsw_sd.tgz'
        [void](Invoke-Adb @('-s', $Serial, 'shell', ("su -c 'cd /sdcard/Android/data/{0} 2>/dev/null && tar czf {1} .'" -f $Pkg, $sdRemote)))
        $s2 = Sh $Serial ("su -c 'stat -c %s {0}'" -f $sdRemote)
        if ($s2 -match '^\d+' -and [int64]$Matches[0] -gt 1024) {
            [void](Invoke-Adb @('-s', $Serial, 'pull', $sdRemote, $sdLocal))
            Sh $Serial ("su -c 'rm -f {0}'" -f $sdRemote) | Out-Null
        }
    }

    Sh $Serial ("su -c 'rm -f {0}'" -f $remote) | Out-Null

    $meta = [ordered]@{
        name     = $Name
        pkg      = $Pkg
        serial   = $Serial
        model    = (Get-Model $Serial)
        captured = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        items    = ($items -join ',')
        size     = [int64]$sz
        sdcard   = [bool]$WithSdcard
    }
    $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8

    if ($LogFn) { & $LogFn ("已保存存档：{0}  大小 {1:N1} MB" -f $Name, ([int64]$sz / 1MB)) }
    return [int64]$sz
}

# ---------------------------- 写回 ----------------------------
function Restore-Snapshot {
    param([string]$Serial, [string]$Pkg, [string]$Name, [scriptblock]$LogFn)

    if (-not (Get-Adb)) { throw '找不到 adb.exe' }

    $dir = Join-Path $Script:ProfDir $Name
    $tgz = Join-Path $dir 'snap.tgz'
    if (-not (Test-Path -LiteralPath $tgz)) { throw "存档不存在：$Name" }

    $metaPath = Join-Path $dir 'meta.json'
    $meta = $null
    if (Test-Path -LiteralPath $metaPath) {
        try { $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($meta -and $meta.pkg -and ($meta.pkg -ne $Pkg)) {
        if ($LogFn) { & $LogFn ("注意：这个存档当初是从 [{0}] 抓的，现在写进 [{1}]" -f $meta.pkg, $Pkg) }
    }

    if ($LogFn) { & $LogFn '关闭游戏…' }
    [void](Invoke-Adb @('-s', $Serial, 'shell', "am force-stop $Pkg"))
    Start-Sleep -Milliseconds 700

    if ($LogFn) { & $LogFn '上传存档…' }
    $up = Invoke-Adb @('-s', $Serial, 'push', $tgz, '/sdcard/.zsw_rest.tgz')
    if ($LASTEXITCODE -ne 0) { throw "上传失败：$($up.Trim())" }

    # 要清理/写回的条目 = 当初打包进去的那些（存在 meta.json 里）
    $items = @()
    if ($meta -and $meta.items) { $items = @($meta.items -split ',') | Where-Object { $_ } }
    if ($items.Count -eq 0) { $items = @('shared_prefs', 'databases', 'app_webview', 'files', 'no_backup') }
    $itemStr = ($items -join ' ')

    if ($LogFn) { & $LogFn ("清理旧登录态…（{0}）" -f $itemStr) }
    Sh $Serial ("su -c 'cd /data/data/{0} && rm -rf {1}'" -f $Pkg, $itemStr) | Out-Null

    if ($LogFn) { & $LogFn '写回登录态…' }
    $ex = Sh $Serial ("su -c 'cd /data/data/{0} && tar xzf /sdcard/.zsw_rest.tgz && (restorecon -R /data/data/{0} 2>/dev/null || true)'" -f $Pkg)
    if ($ex -match 'tar:|Error|error') { if ($LogFn) { & $LogFn ("解包提示：$ex") } }

    # 权限兜底：文件归属回游戏自己的 uid（tar 解包可能变 root 所有）
    $uid = Get-Uid -Serial $Serial -Pkg $Pkg
    if ($uid) {
        $fix = 'su -c ''cd /data/data/{0} && chown -R {1}:{1} {2} 2>/dev/null; chmod -R u+rwX {2} 2>/dev/null''' -f $Pkg, $uid, $itemStr
        Sh $Serial $fix | Out-Null
        if ($LogFn) { & $LogFn ("权限已归位：uid {0}" -f $uid) }
    }

    if ($meta -and $meta.sdcard) {
        $sdLocal = Join-Path $dir 'sdcard.tgz'
        if (Test-Path -LiteralPath $sdLocal) {
            if ($LogFn) { & $LogFn '写回 sdcard 数据…' }
            [void](Invoke-Adb @('-s', $Serial, 'push', $sdLocal, '/sdcard/.zsw_sd_rest.tgz'))
            Sh $Serial ("su -c 'mkdir -p /sdcard/Android/data/{0} && cd /sdcard/Android/data/{0} && tar xzf /sdcard/.zsw_sd_rest.tgz'" -f $Pkg) | Out-Null
        }
    }

    Sh $Serial 'su -c ''rm -f /sdcard/.zsw_rest.tgz /sdcard/.zsw_sd_rest.tgz''' | Out-Null
    return $true
}

# ---------------------------- 诊断 ----------------------------
function Find-GamePackage {
    param([string]$Serial, [scriptblock]$LogFn)
    $pk = Get-Packages -Serial $Serial
    $hits = @()
    foreach ($p in $pk) {
        $cmd = 'su -c ''find /data/data/{0} -maxdepth 2 -mmin -20 -type f 2>/dev/null | head -5''' -f $p
        $r = Sh $Serial $cmd
        if ($r -and ($r -notmatch 'No such|Permission denied')) { $hits += $p }
    }
    return $hits
}

function Run-Diag {
    param([string]$Serial, [string]$Pkg, [scriptblock]$LogFn)
    & $LogFn '--------- 诊断开始 ---------'
    & $LogFn ("设备: {0}   型号: {1}" -f $Serial, (Get-Model $Serial))
    & $LogFn ("root: {0}" -f (Test-Root $Serial))

    if (-not $Pkg) {
        & $LogFn '还没选包名，正在找"最近 20 分钟有数据变动"的应用（登录后的那个就是游戏）…'
        $hits = Find-GamePackage -Serial $Serial -LogFn $LogFn
        if ($hits.Count -gt 0) {
            & $LogFn ("疑似游戏包名: {0}" -f ($hits -join ' , '))
        } else {
            & $LogFn '没有找到。先在模拟器里把游戏打开、登录进去，再点一次诊断。'
        }
        & $LogFn '--------- 诊断结束 ---------'
        return
    }

    & $LogFn ("包名: {0}   uid: {1}" -f $Pkg, (Get-Uid -Serial $Serial -Pkg $Pkg))
    & $LogFn '--- 数据目录 ---'
    & $LogFn (Sh $Serial ("su -c 'ls -la /data/data/{0}'" -f $Pkg))
    & $LogFn '--- shared_prefs ---'
    & $LogFn (Sh $Serial ("su -c 'ls -la /data/data/{0}/shared_prefs'" -f $Pkg))
    & $LogFn '--- databases ---'
    & $LogFn (Sh $Serial ("su -c 'ls -la /data/data/{0}/databases'" -f $Pkg))
    & $LogFn '--- 最近 20 分钟改动过的文件（大概率就是登录态）---'
    & $LogFn (Sh $Serial ("su -c 'find /data/data/{0} -mmin -20 -type f 2>/dev/null | head -40'" -f $Pkg))
    & $LogFn '--------- 诊断结束 ---------'
}

# =====================================================================
#                          环境自检（命令行）
#   用法： powershell -NoProfile -ExecutionPolicy Bypass -File 换号器.ps1 -SelfTest
# =====================================================================
if ($SelfTest) {
    Write-Host '--- 换号器 环境自检 ---'
    $adb = Get-Adb
    Write-Host ("adb : {0}" -f $(if ($adb) { $adb } else { '没找到！' }))
    if (-not $adb) { exit 1 }
    Connect-Emu
    $devs = Get-Serials
    Write-Host ("设备: {0}" -f $(if ($devs.Count) { ($devs -join ', ') } else { '没检测到（模拟器没开？）' }))
    foreach ($d in $devs) {
        Write-Host ("  {0}   root={1}   型号={2}" -f $d, (Test-Root $d), (Get-Model $d))
    }
    if ($devs.Count -gt 0) {
        $conf = $Script:Cfg.Package
        if ($conf) {
            $its = Get-ExistingItems -Serial $devs[0] -Pkg $conf
            Write-Host ("包 {0} 数据目录: {1}" -f $conf, $(if ($its.Count) { ($its -join ', ') } else { '读不到' }))
        }
    }
    Write-Host '--- 自检结束 ---'
    exit 0
}

# =====================================================================
#                        命令行模式（不开窗口）
#   -Cli list                          看设备和应用列表
#   -Cli diag  -Pkg 包名               诊断
#   -Cli capture -Name 大号 -Pkg 包名   抓取当前账号
#   -Cli login  -Name 大号             一键登录
# =====================================================================
if ($Cli) {
    $LogC = { param($m) Write-Host $m }
    $adb = Get-Adb
    if (-not $adb) { Write-Host '没找到 adb.exe'; exit 1 }
    Connect-Emu
    $devs = Get-Serials
    if (-not $Serial) {
        if ($Script:Cfg.Serial -and ($devs -contains $Script:Cfg.Serial)) { $Serial = $Script:Cfg.Serial }
        elseif ($devs.Count -gt 0) { $Serial = [string]$devs[0] }
    }
    if (-not $Pkg) { $Pkg = [string]$Script:Cfg.Package }

    switch ($Cli.ToLower()) {
        'list' {
            Write-Host ("adb : {0}" -f $adb)
            Write-Host ("设备: {0}" -f $(if ($devs.Count) { ($devs -join ', ') } else { '没有' }))
            if ($devs.Count -gt 0) { Get-Packages -Serial $devs[0] | ForEach-Object { Write-Host ("  {0}" -f $_) } }
        }
        'diag' {
            if (-not $Serial) { Write-Host '没有设备'; exit 1 }
            Run-Diag -Serial $Serial -Pkg $Pkg -LogFn $LogC
        }
        'capture' {
            if (-not $Serial) { Write-Host '没有设备'; exit 1 }
            if (-not $Name) { Write-Host '缺 -Name'; exit 1 }
            if (-not $Pkg) { Write-Host '缺游戏包名 -Pkg'; exit 1 }
            Save-Snapshot -Serial $Serial -Pkg $Pkg -Name $Name -WithSdcard ([bool]$Script:Cfg.WithSdcard) -LogFn $LogC | Out-Null
        }
        'login' {
            if (-not $Serial) { Write-Host '没有设备'; exit 1 }
            if (-not $Name) { Write-Host '缺 -Name'; exit 1 }
            $mf = Join-Path (Join-Path $Script:ProfDir $Name) 'meta.json'
            if (-not $Pkg -and (Test-Path -LiteralPath $mf)) {
                $Pkg = (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json).pkg
            }
            if (-not $Pkg) { Write-Host '缺游戏包名'; exit 1 }
            Restore-Snapshot -Serial $Serial -Pkg $Pkg -Name $Name -LogFn $LogC | Out-Null
            $act = Start-App -Serial $Serial -Pkg $Pkg
            Write-Host ("已启动: {0}" -f $act)
        }
        default { Write-Host '用法: -Cli list|diag|capture|login  [-Name 名字] [-Pkg 包名] [-Serial 设备]' }
    }
    exit 0
}

# =====================================================================
#                              界面
#  说明：坐标按 96DPI 设计，运行时按实际 DPI 乘系数，避免高分屏错位
# =====================================================================
$Script:K = 1.0
try {
    $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $Script:K = [double]$g0.DpiX / 96.0
    $g0.Dispose()
} catch { $Script:K = 1.0 }
if ($Script:K -le 0) { $Script:K = 1.0 }

function Px {
    param([double]$v)
    return [int][math]::Round($v * $Script:K)
}
function Pt {
    param([double]$x, [double]$y)
    return (New-Object System.Drawing.Point((Px $x), (Px $y)))
}
function Sz {
    param([double]$w, [double]$h)
    return (New-Object System.Drawing.Size((Px $w), (Px $h)))
}

$F = New-Object System.Windows.Forms.Form
$F.Text = '造梦西游OL 换号器'
$F.AutoScaleMode = 'None'
$F.ClientSize = (Sz 720 760)
$F.StartPosition = 'CenterScreen'
$F.FormBorderStyle = 'FixedSingle'
$F.MaximizeBox = $false
$F.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$F.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 249)

function New-Btn {
    param([string]$Text, [double]$X, [double]$Y, [double]$W = 80, [double]$H = 30, [bool]$Primary = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = (Pt $X $Y)
    $b.Size = (Sz $W $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.UseVisualStyleBackColor = $false
    if ($Primary) {
        $b.BackColor = [System.Drawing.Color]::FromArgb(45, 110, 235)
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(45, 110, 235)
    } else {
        $b.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 246)
        $b.ForeColor = [System.Drawing.Color]::FromArgb(35, 40, 48)
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 210, 218)
    }
    return $b
}

function New-Label {
    param([string]$Text, [double]$X, [double]$Y, [double]$W, [double]$H, [double]$Size = 9, [bool]$Bold = $false, [int]$Gray = 0)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = (Pt $X $Y)
    $l.Size = (Sz $W $H)
    if ($Bold) {
        $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, [System.Drawing.FontStyle]::Bold)
    } elseif ($Size -ne 9) {
        $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $Size)
    }
    if ($Gray -eq 1) { $l.ForeColor = [System.Drawing.Color]::FromArgb(130, 136, 145) }
    return $l
}

# ---------------- 顶部：设备 + 包名 ----------------
$pnTop = New-Object System.Windows.Forms.Panel
$pnTop.Location = (Pt 0 0)
$pnTop.Size = (Sz 720 92)
$pnTop.BackColor = [System.Drawing.Color]::White
[void]$F.Controls.Add($pnTop)

[void]$pnTop.Controls.Add((New-Label '设备' 14 16 40 22))
$cmbDev = New-Object System.Windows.Forms.ComboBox
$cmbDev.DropDownStyle = 'DropDownList'
$cmbDev.Location = (Pt 56 12)
$cmbDev.Size = (Sz 260 26)
[void]$pnTop.Controls.Add($cmbDev)

$btnRefresh = New-Btn '刷新' 330 11 64
[void]$pnTop.Controls.Add($btnRefresh)

$lbDevState = New-Label '' 406 16 300 22 9 $false 1
[void]$pnTop.Controls.Add($lbDevState)

[void]$pnTop.Controls.Add((New-Label '游戏包名' 14 56 70 22))
$cmbPkg = New-Object System.Windows.Forms.ComboBox
$cmbPkg.Location = (Pt 82 52)
$cmbPkg.Size = (Sz 320 26)
[void]$pnTop.Controls.Add($cmbPkg)

$btnDetect = New-Btn '检测应用' 412 51 84
[void]$pnTop.Controls.Add($btnDetect)

$btnDiag = New-Btn '诊断' 502 51 64
[void]$pnTop.Controls.Add($btnDiag)

# ---------------- 中部：账号列表 ----------------
$pnListHost = New-Object System.Windows.Forms.Panel
$pnListHost.Location = (Pt 0 92)
$pnListHost.Size = (Sz 720 320)
$pnListHost.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 249)
[void]$F.Controls.Add($pnListHost)

$pnList = New-Object System.Windows.Forms.Panel
$pnList.Location = (Pt 8 6)
$pnList.Size = (Sz 704 306)
$pnList.AutoScroll = $true
$pnList.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 249)
[void]$pnListHost.Controls.Add($pnList)

# ---------------- 底部：抓取 + 日志 ----------------
$pnBottom = New-Object System.Windows.Forms.Panel
$pnBottom.Location = (Pt 0 412)
$pnBottom.Size = (Sz 720 348)
$pnBottom.BackColor = [System.Drawing.Color]::White
[void]$F.Controls.Add($pnBottom)

[void]$pnBottom.Controls.Add((New-Label '号的名字' 14 18 60 22))
$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = (Pt 82 14)
$txtName.Size = (Sz 240 26)
[void]$pnBottom.Controls.Add($txtName)

$btnCapture = New-Btn '抓取当前账号' 334 13 116 30 $true
[void]$pnBottom.Controls.Add($btnCapture)

$btnOpen = New-Btn '打开存档文件夹' 458 13 116
[void]$pnBottom.Controls.Add($btnOpen)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '登录后自动回写最新登录态'
$chkAuto.Location = (Pt 14 54)
$chkAuto.Size = (Sz 210 24)
$chkAuto.Checked = [bool]$Script:Cfg.AutoRefresh
[void]$pnBottom.Controls.Add($chkAuto)

[void]$pnBottom.Controls.Add((New-Label '等待秒数' 240 56 62 22))
$numWait = New-Object System.Windows.Forms.NumericUpDown
$numWait.Location = (Pt 304 52)
$numWait.Size = (Sz 64 26)
$numWait.Minimum = 4
$numWait.Maximum = 300
$numWait.Value = [decimal]([int]$Script:Cfg.WaitSec)
[void]$pnBottom.Controls.Add($numWait)

$chkSd = New-Object System.Windows.Forms.CheckBox
$chkSd.Text = '连 sdcard 一起存（一般不用勾）'
$chkSd.Location = (Pt 384 54)
$chkSd.Size = (Sz 300 24)
$chkSd.Checked = [bool]$Script:Cfg.WithSdcard
[void]$pnBottom.Controls.Add($chkSd)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = (Pt 14 88)
$txtLog.Size = (Sz 692 230)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.WordWrap = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 252)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
[void]$pnBottom.Controls.Add($txtLog)

function Log {
    param([string]$Msg)
    $line = ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Msg)
    try {
        if ($txtLog -and -not $txtLog.IsDisposed) { [void]$txtLog.AppendText($line + "`r`n") }
    } catch { }
    try { Add-Content -LiteralPath (Join-Path $Script:LogDir ('{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))) -Value $line -Encoding UTF8 } catch { }
    try { [void][System.Windows.Forms.Application]::DoEvents() } catch { }
}

function Pump {
    param([int]$Sec = 0)
    if ($Sec -le 0) { try { [void][System.Windows.Forms.Application]::DoEvents() } catch { }; return }
    $end = (Get-Date).AddSeconds($Sec)
    while (((Get-Date) -lt $end) -and (-not $F.IsDisposed)) {
        try { [void][System.Windows.Forms.Application]::DoEvents() } catch { }
        Start-Sleep -Milliseconds 100
    }
}

function Set-Busy {
    param([bool]$On, [string]$Msg = '')
    $Script:Busy = $On
    try { $F.Cursor = if ($On) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default } } catch { }
    foreach ($c in @($btnCapture, $btnDetect, $btnDiag, $btnRefresh, $pnList)) {
        try { $c.Enabled = -not $On } catch { }
    }
    if ($Msg) { Log $Msg }
    Pump 0
}

function Get-ChosenSerial {
    if ($cmbDev.SelectedItem) { return [string]$cmbDev.SelectedItem }
    return ''
}

function Get-ChosenPkg {
    $p = $cmbPkg.Text.Trim()
    if ($p) { return $p }
    Log '还没填游戏包名，先点「检测应用」选一个。'
    return ''
}

# ---------------- 账号列表 ----------------
function Refresh-List {
    $pnList.Controls.Clear()
    $dirs = @()
    if (Test-Path -LiteralPath $Script:ProfDir) {
        $dirs = @(Get-ChildItem -LiteralPath $Script:ProfDir -Directory | Sort-Object LastWriteTime -Descending)
    }
    if ($dirs.Count -eq 0) {
        $lbl = New-Label "还没有存档。`r`n`r`n先在模拟器里手动登录一个号 → 在上面填个名字（比如 大号）→ 点「抓取当前账号」。" 16 16 620 60 9 $false 1
        [void]$pnList.Controls.Add($lbl)
        return
    }

    $y = 4
    foreach ($d in $dirs) {
        $meta = $null
        $mf = Join-Path $d.FullName 'meta.json'
        if (Test-Path -LiteralPath $mf) {
            try { $meta = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        $name = $d.Name

        $row = New-Object System.Windows.Forms.Panel
        $row.Location = (Pt 6 $y)
        $row.Size = (Sz 660 56)
        $row.BackColor = [System.Drawing.Color]::White
        [void]$pnList.Controls.Add($row)

        [void]$row.Controls.Add((New-Label $name 14 8 300 22 10.5 $true))

        $info = '（缺少 meta.json）'
        if ($meta) { $info = ('存档 {0} · {1} · {2}' -f $meta.captured, $meta.model, $meta.pkg) }
        [void]$row.Controls.Add((New-Label $info 14 32 400 18 8 $false 1))

        $btnGo = New-Btn '一键登录' 462 12 96 32 $true
        $btnUpd = New-Btn '更新数据' 566 12 90 32
        [void]$row.Controls.Add($btnGo)
        [void]$row.Controls.Add($btnUpd)

        $btnGo.Add_Click({ Do-Login -Name $name }.GetNewClosure())
        $btnUpd.Add_Click({ Do-Capture -Name $name }.GetNewClosure())

        $y += (Px 60)
    }
}

# ---------------- 动作 ----------------
function Do-Capture {
    param([string]$Name)
    if ($Script:Busy) { return }
    $s = Get-ChosenSerial
    if (-not $s) { Log '没连上设备：先开模拟器，再点「刷新」。'; return }
    $pkg = Get-ChosenPkg
    if (-not $pkg) { return }
    if (-not $Name) { $Name = $txtName.Text.Trim() }
    if (-not $Name) { Log '先给这个号起个名字。'; return }
    if ($Name -match '[\\/:*?"<>|]') { Log '名字里不能有 \ / : * ? " < > |'; return }

    if (Test-Path -LiteralPath (Join-Path $Script:ProfDir $Name)) {
        $r = [System.Windows.Forms.MessageBox]::Show("已经有 [$Name] 这个存档了，覆盖吗？", '确认', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
    }

    Set-Busy $true "开始抓取 [$Name] …"
    try {
        Save-Snapshot -Serial $s -Pkg $pkg -Name $Name -WithSdcard $chkSd.Checked -LogFn ${function:Log} | Out-Null
        $Script:Cfg.Package = $pkg
        Save-Cfg
        Refresh-List
        Log '搞定。以后想上这个号，点它的「一键登录」就行。'
    } catch {
        Log ("抓取失败：{0}" -f $_.Exception.Message)
    } finally {
        Set-Busy $false
    }
}

function Do-Login {
    param([string]$Name)
    if ($Script:Busy) { return }
    $s = Get-ChosenSerial
    if (-not $s) { Log '没连上设备：先开模拟器，再点「刷新」。'; return }
    if (-not (Test-Path -LiteralPath (Join-Path $Script:ProfDir $Name))) { Log "找不到存档 [$Name]"; return }

    $pkg = $null
    $mf = Join-Path (Join-Path $Script:ProfDir $Name) 'meta.json'
    if (Test-Path -LiteralPath $mf) {
        try { $pkg = (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json).pkg } catch { }
    }
    if (-not $pkg) { $pkg = $cmbPkg.Text.Trim() }
    if (-not $pkg) { Log '不知道要重启哪个游戏：存档里没记包名，先在上面选一下包名。'; return }

    Set-Busy $true "=== 切换到 [$Name] ==="
    try {
        Restore-Snapshot -Serial $s -Pkg $pkg -Name $Name -LogFn ${function:Log} | Out-Null
        $act = Start-App -Serial $s -Pkg $pkg
        Log ("游戏已启动（{0}），等它自己进…" -f $act)

        if ($chkAuto.Checked) {
            $w = [int]$numWait.Value
            Pump $w
            Log '回写最新登录态（窗口会短暂无响应，别关）…'
            try {
                Save-Snapshot -Serial $s -Pkg $pkg -Name $Name -WithSdcard $chkSd.Checked -LogFn ${function:Log} | Out-Null
                Refresh-List
            } catch {
                Log ("回写失败（不影响这次登录）：{0}" -f $_.Exception.Message)
            }
        }
        Log '好了。'
    } catch {
        Log ("切换失败：{0}" -f $_.Exception.Message)
    } finally {
        Set-Busy $false
    }
}

function Do-RefreshDevices {
    if ($Script:Busy) { return }
    if (-not (Get-Adb)) { Log '找不到 adb.exe。请确认装了雷电9，或把 adb 路径填进 config.json。'; return }

    $cmbDev.Items.Clear()
    Connect-Emu
    $list = Get-Serials
    if ($list.Count -eq 0) {
        $raw = Invoke-Adb @('devices')
        Log ("adb devices 原始返回（exit={0}）：{1}" -f $Script:LastAdbExit, ($raw -replace "`r?`n", ' | '))
    }
    foreach ($s in $list) { [void]$cmbDev.Items.Add($s) }
    if ($list.Count -eq 0) {
        $lbDevState.Text = '没检测到模拟器'
        Log '没检测到设备：先把雷电9 打开（多开的话每个窗口都要开）。'
        return
    }
    $pick = 0
    if ($Script:Cfg.Serial -and ($list -contains $Script:Cfg.Serial)) { $pick = [array]::IndexOf($list, $Script:Cfg.Serial) }
    $cmbDev.SelectedIndex = $pick
    $Script:Cfg.Serial = [string]$cmbDev.SelectedItem
    $rootOk = Test-Root $Script:Cfg.Serial
    $lbDevState.Text = ('已连接 · root {0}' -f $(if ($rootOk) { '正常' } else { '未开启！' }))
    if (-not $rootOk) { Log '警告：这台设备没有 root，抓数据会失败。雷电9 设置 → 其他设置 → root权限 → 开启，然后重启模拟器。' }
    else { Log ("设备就绪：{0}" -f $Script:Cfg.Serial) }
    Save-Cfg
}

function Do-DetectPackages {
    if ($Script:Busy) { return }
    $s = Get-ChosenSerial
    if (-not $s) { Log '没连上设备。'; return }
    Set-Busy $true '读取已安装应用…'
    try {
        $pk = Get-Packages -Serial $s
        $cmbPkg.Items.Clear()
        foreach ($p in $pk) { [void]$cmbPkg.Items.Add($p) }
        Log ("共 {0} 个第三方应用" -f $pk.Count)

        $guess = @($pk | Where-Object { $_ -match 'zmxy|zaomeng|zhaomeng|mengxiyou|xyol|4399|west|yjmobile' })
        if ($guess.Count -ge 1) {
            $cmbPkg.Text = $guess[0]
            $Script:Cfg.Package = $guess[0]
            Save-Cfg
            Log ("自动认定游戏包名：{0}" -f $guess[0])
        } else {
            Log '没猜出来。点「诊断」——它会告诉你哪个应用刚登录过（最近 20 分钟有数据改动的那个）。'
        }
    } catch {
        Log ("读取失败：{0}" -f $_.Exception.Message)
    } finally {
        Set-Busy $false
    }
}

# ---------------- 事件 ----------------
$btnRefresh.Add_Click({ Do-RefreshDevices })
$btnDetect.Add_Click({ Do-DetectPackages })
$btnCapture.Add_Click({ Do-Capture -Name ($txtName.Text.Trim()) })
$btnOpen.Add_Click({ try { Start-Process explorer.exe $Script:ProfDir } catch { } })
$btnDiag.Add_Click({
    if ($Script:Busy) { return }
    $s = Get-ChosenSerial
    if (-not $s) { Log '没连上设备。'; return }
    Set-Busy $true '诊断中…'
    try { Run-Diag -Serial $s -Pkg $cmbPkg.Text.Trim() -LogFn ${function:Log} }
    catch { Log ("诊断出错：{0}" -f $_.Exception.Message) }
    finally { Set-Busy $false }
})

$cmbDev.Add_SelectedIndexChanged({
    $s = [string]$cmbDev.SelectedItem
    if ($s) {
        $Script:Cfg.Serial = $s
        Save-Cfg
        $rootOk = Test-Root $s
        $lbDevState.Text = ('已连接 · root {0}' -f $(if ($rootOk) { '正常' } else { '未开启！' }))
    }
})
$cmbPkg.Add_TextChanged({
    $p = $cmbPkg.Text.Trim()
    if ($p) { $Script:Cfg.Package = $p; Save-Cfg }
})

$F.Add_Shown({
    if ($Script:Cfg.Package) { $cmbPkg.Text = $Script:Cfg.Package }
    Log ("界面缩放 {0:P0}（DPI {1}）" -f $Script:K, [int]($Script:K * 96))
    Refresh-List
    Log '就绪。① 刷新 ② 检测应用 ③ 手动登录一个号 ④ 填名字点「抓取当前账号」'
    Do-RefreshDevices
})

if ($SmokeTest) {
    Refresh-List
    Write-Host ("pnTop     : {0}" -f $pnTop.Bounds)
    Write-Host ("pnListHost: {0}" -f $pnListHost.Bounds)
    Write-Host ("pnBottom  : {0}" -f $pnBottom.Bounds)
    Write-Host ("txtLog    : {0}" -f $txtLog.Bounds)
    Write-Host ("cmbDev    : {0}" -f $cmbDev.Bounds)
    Write-Host ("btnCapture: {0}" -f $btnCapture.Bounds)
    $okOrder = ($pnTop.Top -lt $pnListHost.Top) -and ($pnListHost.Top -lt $pnBottom.Top)
    Write-Host ("布局顺序 ok = {0}" -f $okOrder)
    Write-Host ("UI OK  缩放={0:F2}  顶层控件={1}  列表行={2}  存档数={3}" -f $Script:K, $F.Controls.Count, $pnList.Controls.Count, @(Get-ChildItem -LiteralPath $Script:ProfDir -Directory).Count)
    exit 0
}

try {
    [void]$F.ShowDialog()
} catch {
    try { [System.Windows.Forms.MessageBox]::Show("启动出错：`r`n$($_.Exception.Message)", '换号器') } catch { }
}
