<#
.SYNOPSIS
  Discord "Game Variety" rozeti icin, algilanabilir oyunlarin adini tasiyan sahte
  exe'leri sirayla calistirir. Discord masaustu uygulamasi bunlari normal oyun
  algilamasiyla "Oynuyor" olarak gorur.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1
  powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1 -Count 110 -Minutes 3 -Concurrent 2
  powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1 -Cleanup
#>
[CmdletBinding()]
param(
    # Kac farkli oyun oynanmis gibi gosterilecek (Universalist icin 100+; biraz pay birak)
    [int]$Count = 110,
    # Her oyunun acik kalacagi sure (dakika)
    [double]$Minutes = 3,
    # Ayni anda kac sahte oyun acik olsun
    [int]$Concurrent = 1,
    # Discord'a erisilemezse elle indirilmis detectable.json yolu
    [string]$ListPath,
    # Sahte exe'lerin kurulacagi klasor
    [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'DiscordOyunRozeti'),
    # Sadece secilecek oyunlari listele, hicbir sey calistirma
    [switch]$DryRun,
    # Sahte exe klasorunu ve ilerleme kaydini sil
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
$ListUrl      = 'https://discord.com/api/v9/applications/detectable'
$GamesDir     = Join-Path $WorkDir 'games'
$RunnerPath   = Join-Path $WorkDir 'runner.exe'
$ProgressPath = Join-Path $WorkDir 'progress.json'

# Baska bir programla karisabilecek ya da birden fazla oyunun kullandigi genel adlar
$GenericNames = @(
    'java.exe','javaw.exe','python.exe','pythonw.exe','node.exe','electron.exe',
    'game.exe','launcher.exe','client.exe','start.exe','main.exe','app.exe',
    'setup.exe','update.exe','updater.exe','unitycrashhandler64.exe','crashhandler.exe',
    'chrome.exe','firefox.exe','msedge.exe','explorer.exe','cmd.exe','powershell.exe'
)

if ($Cleanup) {
    Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($GamesDir, 'OrdinalIgnoreCase') } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($WorkDir)) { [IO.Directory]::Delete($WorkDir, $true) }
    Write-Host "Temizlendi: $WorkDir" -ForegroundColor Green
    return
}

function Get-DetectableList {
    if ($ListPath) {
        Write-Host "Oyun listesi dosyadan okunuyor: $ListPath"
        return [IO.File]::ReadAllText($ListPath) | ConvertFrom-Json
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "Oyun listesi Discord'dan indiriliyor..."
    try {
        $raw = (Invoke-WebRequest -UseBasicParsing -Uri $ListUrl -TimeoutSec 30).Content
    } catch {
        throw "Liste indirilemedi ($($_.Exception.Message)). WARP/VPN'i acip tekrar dene ya da tarayicidan $ListUrl adresini kaydedip -ListPath ile ver."
    }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $WorkDir 'detectable.json'), $raw)
    return $raw | ConvertFrom-Json
}

function Select-Games($apps, [int]$n, $doneIds) {
    # Her uygulama icin ilk uygun Windows exe'sini al
    $candidates = foreach ($app in $apps) {
        $exe = @($app.executables | Where-Object {
            $_.os -eq 'win32' -and -not $_.is_launcher -and $_.name -like '*.exe'
        }) | Select-Object -First 1
        if (-not $exe) { continue }
        $rel = $exe.name.TrimStart('>').Replace('/', '\').Trim('\')
        if ($rel -match '[:*?"<>|]' -or $rel.Contains('..')) { continue }
        [pscustomobject]@{
            Id   = [string]$app.id
            Name = [string]$app.name
            Rel  = $rel
            Base = (Split-Path $rel -Leaf).ToLowerInvariant()
        }
    }
    # Ayni exe adini paylasan oyunlari ve genel adlari at; Discord hangisini sececegini bilemez
    $dupes = $candidates | Group-Object Base | Where-Object Count -gt 1 | ForEach-Object Name
    $clean = $candidates | Where-Object { $GenericNames -notcontains $_.Base -and $dupes -notcontains $_.Base }

    # Gercekten calisan bir programla cakismasin
    $running = @(Get-Process | Where-Object Path | ForEach-Object { [IO.Path]::GetFileName($_.Path).ToLowerInvariant() })
    $clean = $clean | Where-Object { $running -notcontains $_.Base -and $doneIds -notcontains $_.Id }

    $take = [Math]::Min($n, @($clean).Count)
    if ($take -lt 1) { return @() }
    return @($clean | Get-Random -Count $take)
}

function New-Runner {
    if (Test-Path $RunnerPath) { return }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    # Kucuk, simge durumunda acilan bir pencere; basligi oyun adi olur
    $src = @'
using System;
using System.Windows.Forms;
public static class Runner {
    [STAThread]
    public static void Main(string[] args) {
        var f = new Form();
        f.Text = args.Length > 0 ? string.Join(" ", args) : "Game";
        f.Width = 320; f.Height = 80;
        f.WindowState = FormWindowState.Minimized;
        Application.Run(f);
    }
}
'@
    Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms `
        -OutputAssembly $RunnerPath -OutputType WindowsApplication
}

function Start-FakeGame($game) {
    $target = Join-Path (Join-Path $GamesDir $game.Id) $game.Rel
    New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
    Copy-Item $RunnerPath $target -Force
    return Start-Process -FilePath $target -ArgumentList "`"$($game.Name)`"" `
        -WorkingDirectory (Split-Path $target -Parent) -PassThru
}

# --- Ana akis ---

if (-not $DryRun -and -not (Get-Process -Name 'Discord' -ErrorAction SilentlyContinue)) {
    throw "Discord masaustu uygulamasi acik degil. (Tarayici, Vesktop vb. sayilmaz.) Discord'u acip tekrar calistir."
}

$doneIds = @()
if (Test-Path $ProgressPath) {
    # PS 5.1'de ConvertFrom-Json diziyi tek nesne olarak dondurur; ForEach ile ac
    $doneIds = @([IO.File]::ReadAllText($ProgressPath) | ConvertFrom-Json | ForEach-Object { $_ })
    Write-Host "Daha once tamamlanan oyun: $($doneIds.Count)"
}

$remaining = $Count - $doneIds.Count
if ($remaining -le 0) {
    Write-Host "Hedef zaten tamamlanmis ($($doneIds.Count)/$Count)." -ForegroundColor Green
    return
}

$games = Select-Games (Get-DetectableList) $remaining $doneIds
if ($games.Count -eq 0) { throw "Uygun oyun bulunamadi." }
Write-Host "Secilen oyun: $($games.Count)  |  Oyun basi: $Minutes dk  |  Ayni anda: $Concurrent"
$etaMin = [Math]::Ceiling($games.Count / $Concurrent) * ($Minutes + 0.1)
Write-Host ("Tahmini sure: ~{0:N0} dakika" -f $etaMin)

if ($DryRun) {
    $games | Format-Table Name, Rel -AutoSize
    return
}

New-Runner
$procs = @()
try {
    for ($i = 0; $i -lt $games.Count; $i += $Concurrent) {
        $batch = @($games[$i..([Math]::Min($i + $Concurrent, $games.Count) - 1)])
        $procs = foreach ($g in $batch) {
            Write-Host ("[{0}/{1}] {2}  ({3})" -f ($doneIds.Count + 1), $Count, $g.Name, $g.Rel)
            $doneIds += $g.Id
            Start-FakeGame $g
        }
        Start-Sleep -Seconds ([int]($Minutes * 60))
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        $procs = @()
        [IO.File]::WriteAllText($ProgressPath, (ConvertTo-Json @($doneIds) -Compress))
        # Discord'un oyunun kapandigini gormesi icin kisa ara
        Start-Sleep -Seconds 5
    }
    Write-Host "Bitti: $($doneIds.Count) oyun. Rozetin guncellenmesi biraz zaman alabilir." -ForegroundColor Green
    Write-Host "Sahte dosyalari silmek icin: -Cleanup"
}
finally {
    # Ctrl+C ile kesilirse acik sahte oyunlari kapat
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
}
