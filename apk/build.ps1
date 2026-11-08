# =====================================================================
#  换号器 APK 构建脚本（不依赖 Gradle，直接用 build-tools）
#  用法： powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'

$BT   = 'D:\Android\Sdk\build-tools\34.0.0'
$PLAT = 'D:\Android\Sdk\platforms\android-34\android.jar'
$SDK  = 'D:\Android\Sdk'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Out  = Join-Path $Here 'build'
$ApkName = '换号器.apk'

function Step($m) { Write-Host "== $m" -ForegroundColor Cyan }

# ---- 找 javac ----
# 注意：build-tools 34 里的 d8(R8 8.2) 处理不了 javac 21 编出来的 class（内部 NPE），
#       所以优先用 JDK 17 / JBR 编译，再交给 d8。
$javac = $null
$cands = @(
    'C:\Program Files\Android\Android Studio\jbr\bin\javac.exe',
    'D:\Java\1\IntelliJ IDEA 2023.3.4\jbr\bin\javac.exe'
)
foreach ($root in @('D:\Java\1', 'C:\Program Files\JetBrains', 'C:\Program Files\Android')) {
    if (Test-Path -LiteralPath $root) {
        $cands += Get-ChildItem -LiteralPath $root -Recurse -Depth 3 -Filter 'javac.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\jbr\\bin\\javac\.exe$' } |
            ForEach-Object { $_.FullName }
    }
}
$cands += @(
    $(if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\javac.exe' }),
    (Get-Command javac.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
)
foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath $c)) { $javac = $c; break }
}
if (-not $javac) { throw '找不到 javac.exe（需要 JDK 17 或 JBR）' }
Step "javac: $javac"

if (-not (Test-Path $BT)) { throw "找不到 build-tools: $BT" }
if (-not (Test-Path $PLAT)) { throw "找不到 android.jar: $PLAT" }

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Path $Out | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Out 'classes') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Out 'dex') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Out 'gen') | Out-Null

# ---- 1) aapt2 处理资源 + 生成 base.apk ----
Step 'aapt2 link'
$baseApk = Join-Path $Out 'base.apk'
& (Join-Path $BT 'aapt2.exe') link `
    -o $baseApk `
    --manifest (Join-Path $Here 'AndroidManifest.xml') `
    -I $PLAT `
    --java (Join-Path $Out 'gen') `
    --min-sdk-version 24 --target-sdk-version 28 `
    --auto-add-overlay
if ($LASTEXITCODE -ne 0) { throw "aapt2 link 失败 ($LASTEXITCODE)" }

# ---- 2) 编译 java ----
Step 'javac'
$srcs = @()
$srcs += Get-ChildItem -Recurse -Filter *.java (Join-Path $Here 'src') | ForEach-Object { $_.FullName }
$srcs += Get-ChildItem -Recurse -Filter *.java (Join-Path $Out 'gen') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
$argFile = Join-Path $Out 'srcs.txt'
Set-Content -LiteralPath $argFile -Value $srcs -Encoding UTF8
& $javac --release 8 -nowarn -encoding UTF-8 -cp $PLAT -d (Join-Path $Out 'classes') "@$argFile"
if ($LASTEXITCODE -ne 0) { throw "javac 失败 ($LASTEXITCODE)" }

# ---- 3) d8 转 dex ----
Step 'd8'
$classes = Get-ChildItem -Recurse -Filter *.class (Join-Path $Out 'classes') | ForEach-Object { $_.FullName }
if (-not $classes) { throw '没有编译出 class' }
$d8args = @('--lib', $PLAT, '--min-api', '24', '--release', '--output', (Join-Path $Out 'dex')) + $classes
& (Join-Path $BT 'd8.bat') @d8args
if ($LASTEXITCODE -ne 0) { throw "d8 失败 ($LASTEXITCODE)" }

# ---- 4) 把 classes.dex 塞进 apk ----
Step 'pack'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$dex = Join-Path $Out 'dex\classes.dex'
if (-not (Test-Path $dex)) { throw '没有生成 classes.dex' }
$zip = [System.IO.Compression.ZipFile]::Open($baseApk, 'Update')
$entry = $zip.GetEntry('classes.dex')
if ($entry) { $entry.Delete() }
[void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dex, 'classes.dex', 'Optimal')
$zip.Dispose()

# ---- 5) zipalign ----
Step 'zipalign'
$aligned = Join-Path $Out 'aligned.apk'
& (Join-Path $BT 'zipalign.exe') -f -p 4 $baseApk $aligned
if ($LASTEXITCODE -ne 0) { throw "zipalign 失败 ($LASTEXITCODE)" }

# ---- 6) 签名（没有 keystore 就生成一个） ----
Step 'sign'
$ks = Join-Path $Here 'debug.keystore'
if (-not (Test-Path $ks)) {
    $keytool = Join-Path (Split-Path -Parent $javac) 'keytool.exe'
    if (-not (Test-Path $keytool)) { $keytool = (Get-Command keytool.exe -ErrorAction SilentlyContinue).Source }
    if (-not $keytool) { throw '找不到 keytool.exe' }
    & $keytool -genkeypair -v -keystore $ks -alias zsw -keyalg RSA -keysize 2048 `
        -validity 10000 -storepass android -keypass android `
        -dname "CN=zsw, OU=dev, O=dev, L=cn, ST=cn, C=CN"
    if ($LASTEXITCODE -ne 0) { throw 'keytool 生成 keystore 失败' }
}

$final = Join-Path $Here $ApkName
if (Test-Path $final) { Remove-Item -Force $final }
& (Join-Path $BT 'apksigner.bat') sign --ks $ks --ks-pass pass:android --key-pass pass:android `
    --v1-signing-enabled true --v2-signing-enabled true --out $final $aligned
if ($LASTEXITCODE -ne 0) { throw "apksigner 失败 ($LASTEXITCODE)" }

Step 'verify'
& (Join-Path $BT 'apksigner.bat') verify --print-certs $final | Select-Object -First 3

Write-Host ""
Write-Host "APK: $final" -ForegroundColor Green
Write-Host ("大小: {0:N0} KB" -f ((Get-Item $final).Length / 1KB)) -ForegroundColor Green
