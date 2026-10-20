<#
.SYNOPSIS
  Discord "Game Variety" rozeti icin, algilanabilir oyunlarin adini tasiyan sahte
  exe'leri sirayla calistirir. Discord masaustu uygulamasi bunlari normal oyun
  algilamasiyla "Oynuyor" olarak gorur. Kontrol paneli tarayicida acilir.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1
  powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1 -Port 9000 -NoBrowser
  powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1 -Cleanup
#>
[CmdletBinding()]
param(
    # Kontrol panelinin acilacagi port (doluysa sonraki 10 port denenir)
    [int]$Port = 8765,
    # Discord'a erisilemezse elle indirilmis detectable.json yolu
    [string]$ListPath,
    # Sahte exe'lerin, ilerleme kaydinin ve ayarlarin klasoru
    [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'DiscordOyunRozeti'),
    # Tarayiciyi otomatik acma
    [switch]$NoBrowser,
    # Sahte exe klasorunu ve ilerleme kaydini sil
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
$ListUrl      = 'https://discord.com/api/v9/applications/detectable'
$GamesDir     = Join-Path $WorkDir 'games'
$RunnerPath   = Join-Path $WorkDir 'runner.exe'
$ProgressPath = Join-Path $WorkDir 'progress.json'
$SettingsPath = Join-Path $WorkDir 'settings.json'
$CachePath    = Join-Path $WorkDir 'detectable.json'
$UiPath       = Join-Path $PSScriptRoot 'ui.html'

# Baska bir programla karisabilecek ya da birden fazla oyunun kullandigi genel adlar
$GenericNames = @(
    'java.exe','javaw.exe','python.exe','pythonw.exe','node.exe','electron.exe',
    'game.exe','launcher.exe','client.exe','start.exe','main.exe','app.exe',
    'setup.exe','update.exe','updater.exe','unitycrashhandler64.exe','crashhandler.exe',
    'chrome.exe','firefox.exe','msedge.exe','explorer.exe','cmd.exe','powershell.exe'
)

function Stop-AllFakeGames {
    Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($GamesDir, 'OrdinalIgnoreCase') } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Cleanup) {
    Stop-AllFakeGames
    if ([IO.Directory]::Exists($WorkDir)) { [IO.Directory]::Delete($WorkDir, $true) }
    Write-Host "Temizlendi: $WorkDir" -ForegroundColor Green
    return
}

New-Item -ItemType Directory -Force $WorkDir | Out-Null
Add-Type -AssemblyName System.Web.Extensions

$State = @{
    Status         = 'idle'   # idle | running | done
    # Ayni anda birden fazla oyunun ayri sayildigi dogrulanmadi; varsayilan tek oyun.
    # Hedef 200-250 arasi rastgele; ilk calistirmada secilip settings.json'a kaydedilir.
    Settings       = @{ Count = (Get-Random -Minimum 200 -Maximum 251); MinMinutes = 46; MaxMinutes = 71; Concurrent = 1 }
    Done           = New-Object System.Collections.ArrayList
    DoneIds        = New-Object 'System.Collections.Generic.HashSet[string]'
    Active         = New-Object System.Collections.ArrayList
    Log            = New-Object System.Collections.ArrayList
    Candidates     = $null
    DiscordRunning = $false
    DiscordWarned  = $false
    Error          = $null
}
$script:Quit = $false

function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Write-Log([string]$msg, [string]$level = 'info') {
    [void]$State.Log.Add(@{ t = (Get-NowMs); msg = $msg; level = $level })
    while ($State.Log.Count -gt 300) { $State.Log.RemoveAt(0) }
    $color = @{ info = 'Gray'; ok = 'Green'; warn = 'Yellow'; error = 'Red' }[$level]
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor $color
}

function Read-Json([string]$path) {
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    return $ser.DeserializeObject([IO.File]::ReadAllText($path))
}

function Save-Progress {
    $items = @($State.Done | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; seconds = $_.seconds; at = $_.at } })
    [IO.File]::WriteAllText($ProgressPath, (ConvertTo-Json -InputObject $items -Depth 3 -Compress))
}

function Import-Saved {
    if (Test-Path $SettingsPath) {
        $s = Read-Json $SettingsPath
        foreach ($k in @('Count','MinMinutes','MaxMinutes','Concurrent')) {
            if ($s.ContainsKey($k)) { $State.Settings[$k] = [int]$s[$k] }
        }
    } else {
        [IO.File]::WriteAllText($SettingsPath, (ConvertTo-Json -InputObject $State.Settings -Compress))
    }
    if (Test-Path $ProgressPath) {
        foreach ($item in @(Read-Json $ProgressPath)) {
            # Eski surum sadece id listesi tutuyordu
            if ($item -is [string]) { $item = @{ id = $item; name = "#$item"; seconds = 0; at = 0 } }
            if ($State.DoneIds.Add([string]$item['id'])) {
                [void]$State.Done.Add(@{ id = [string]$item['id']; name = [string]$item['name']; seconds = [int]$item['seconds']; at = [long]$item['at'] })
            }
        }
    }
}

function Get-DetectableList {
    if ($ListPath) {
        Write-Log "Oyun listesi dosyadan okunuyor: $ListPath"
        return Read-Json $ListPath
    }
    if ((Test-Path $CachePath) -and ((Get-Date) - (Get-Item $CachePath).LastWriteTime).TotalHours -lt 24) {
        Write-Log 'Oyun listesi onbellekten okunuyor.'
        return Read-Json $CachePath
    }
    Write-Log "Oyun listesi Discord'dan indiriliyor..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = 'Mozilla/5.0'
        [IO.File]::WriteAllText($CachePath, $wc.DownloadString($ListUrl))
    } catch {
        if (Test-Path $CachePath) {
            Write-Log 'Liste indirilemedi, eski onbellek kullaniliyor.' 'warn'
        } else {
            throw "Liste indirilemedi ($($_.Exception.Message)). WARP/VPN'i acip tekrar dene ya da tarayicidan $ListUrl adresini kaydedip -ListPath ile ver."
        }
    }
    return Read-Json $CachePath
}

function Get-Candidates($apps) {
    # Her uygulama icin ilk uygun Windows exe'sini al
    $all = foreach ($app in $apps) {
        $exe = @($app['executables'] | Where-Object {
            $_['os'] -eq 'win32' -and -not $_['is_launcher'] -and ([string]$_['name']) -like '*.exe'
        }) | Select-Object -First 1
        if (-not $exe) { continue }
        $rel = ([string]$exe['name']).TrimStart('>').Replace('/', '\').Trim('\')
        if ($rel -match '[:*?"<>|]' -or $rel.Contains('..')) { continue }
        [pscustomobject]@{
            Id   = [string]$app['id']
            Name = [string]$app['name']
            Rel  = $rel
            Base = (Split-Path $rel -Leaf).ToLowerInvariant()
        }
    }
    # Ayni exe adini paylasan oyunlari ve genel adlari at; Discord hangisini sececegini bilemez
    $dupes = New-Object 'System.Collections.Generic.HashSet[string]'
    $all | Group-Object Base | Where-Object Count -gt 1 | ForEach-Object { [void]$dupes.Add($_.Name) }
    $clean = @($all | Where-Object { $GenericNames -notcontains $_.Base -and -not $dupes.Contains($_.Base) })

    $list = New-Object System.Collections.ArrayList
    if ($clean.Count -gt 0) { $list.AddRange(@($clean | Get-Random -Count $clean.Count)) }
    return ,$list
}

function Get-NextCandidate {
    # Gercekten calisan bir programla cakismasin
    $running = New-Object 'System.Collections.Generic.HashSet[string]'
    Get-Process | Where-Object Path | ForEach-Object { [void]$running.Add([IO.Path]::GetFileName($_.Path).ToLowerInvariant()) }
    $activeIds = @($State.Active | ForEach-Object { $_.Id })

    while ($State.Candidates.Count -gt 0) {
        $c = $State.Candidates[0]
        $State.Candidates.RemoveAt(0)
        if ($State.DoneIds.Contains($c.Id) -or $activeIds -contains $c.Id -or $running.Contains($c.Base)) { continue }
        return $c
    }
    return $null
}

function New-Runner {
    if (Test-Path $RunnerPath) { return }
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
    $proc = Start-Process -FilePath $target -ArgumentList "`"$($game.Name)`"" `
        -WorkingDirectory (Split-Path $target -Parent) -PassThru
    $seconds = Get-Random -Minimum ($State.Settings.MinMinutes * 60) -Maximum ($State.Settings.MaxMinutes * 60 + 1)
    $now = Get-NowMs
    [void]$State.Active.Add([pscustomobject]@{
        Id = $game.Id; Name = $game.Name; Rel = $game.Rel
        Start = $now; End = $now + $seconds * 1000; Proc = $proc
    })
    Write-Log ("Basladi: {0} ({1:N0} dk)" -f $game.Name, ($seconds / 60))
}

function Stop-FakeGame($a, [string]$reason) {
    try { if (-not $a.Proc.HasExited) { $a.Proc.Kill() } } catch {}
    $State.Active.Remove($a)
    $played = [int](((Get-NowMs) - $a.Start) / 1000)
    # Yarida kesilen oyun en az alt sinir kadar oynandiysa sayilir
    if ($played -ge $State.Settings.MinMinutes * 60) {
        if ($State.DoneIds.Add($a.Id)) {
            [void]$State.Done.Add(@{ id = $a.Id; name = $a.Name; seconds = $played; at = (Get-NowMs) })
            Save-Progress
        }
        Write-Log ("Tamamlandi: {0} ({1:N0} dk) - {2}/{3}" -f $a.Name, ($played / 60), $State.Done.Count, $State.Settings.Count) 'ok'
    } else {
        Write-Log ("Sayilmadi ({0}): {1}" -f $reason, $a.Name) 'warn'
    }
}

function Invoke-Tick {
    $now = Get-NowMs
    foreach ($a in @($State.Active)) {
        if ($now -ge $a.End) { Stop-FakeGame $a 'sure doldu' }
        elseif ($a.Proc.HasExited) { Stop-FakeGame $a 'program kapandi' }
    }

    $State.DiscordRunning = [bool](Get-Process -Name 'Discord' -ErrorAction SilentlyContinue)
    if ($State.Status -ne 'running') { return }

    if (-not $State.DiscordRunning) {
        if (-not $State.DiscordWarned) {
            Write-Log 'Discord kapali; yeni oyun baslatilmiyor. Discord acilinca devam edilecek.' 'warn'
            $State.DiscordWarned = $true
        }
        return
    }
    $State.DiscordWarned = $false

    while ($State.Active.Count -lt $State.Settings.Concurrent -and
           ($State.Done.Count + $State.Active.Count) -lt $State.Settings.Count) {
        $next = Get-NextCandidate
        if (-not $next) {
            if ($State.Active.Count -eq 0) {
                $State.Status = 'idle'
                $State.Error = 'Listede uygun oyun kalmadi.'
                Write-Log $State.Error 'error'
            }
            break
        }
        try { Start-FakeGame $next } catch { Write-Log "Baslatilamadi: $($next.Name) - $($_.Exception.Message)" 'error' }
    }

    if ($State.Done.Count -ge $State.Settings.Count -and $State.Active.Count -eq 0) {
        $State.Status = 'done'
        Write-Log "Hedefe ulasildi: $($State.Done.Count) oyun. Rozetin guncellenmesi biraz zaman alabilir." 'ok'
    }
}

# --- HTTP ---

function Send-Bytes($ctx, [int]$code, [string]$type, [byte[]]$bytes) {
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $type
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    $r.OutputStream.Close()
}

function Send-Json($ctx, $obj, [int]$code = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 6 -Compress
    Send-Bytes $ctx $code 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Get-StatePayload {
    @{
        status         = $State.Status
        settings       = $State.Settings
        discordRunning = $State.DiscordRunning
        error          = $State.Error
        now            = (Get-NowMs)
        done           = @($State.Done | ForEach-Object { @{ id = $_.id; name = $_.name; seconds = $_.seconds; at = $_.at } })
        active         = @($State.Active | ForEach-Object { @{ id = $_.Id; name = $_.Name; rel = $_.Rel; start = $_.Start; end = $_.End } })
        log            = @($State.Log)
    }
}

function Invoke-Request($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath

    if ($req.HttpMethod -eq 'GET') {
        if ($path -eq '/') { return Send-Bytes $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($UiPath)) }
        if ($path -eq '/api/state') { return Send-Json $ctx (Get-StatePayload) }
        return Send-Json $ctx @{ error = 'Bulunamadi' } 404
    }

    # Baska sitelerin localhost'a istek atmasini engeller (ozel baslik on-kontrol gerektirir)
    if ($req.HttpMethod -ne 'POST' -or $req.Headers['X-Rozet'] -ne '1') {
        return Send-Json $ctx @{ error = 'Yasak' } 403
    }
    $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
    $State.Error = $null

    switch ($path) {
        '/api/start' {
            if ($State.Status -eq 'running') { break }
            $in = (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($body)
            $s = @{
                Count      = [int]$in['count']
                MinMinutes = [int]$in['minMinutes']
                MaxMinutes = [int]$in['maxMinutes']
                Concurrent = [int]$in['concurrent']
            }
            if ($s.Count -lt 1 -or $s.Count -gt 1000 -or $s.MinMinutes -lt 1 -or $s.MaxMinutes -lt $s.MinMinutes -or
                $s.MaxMinutes -gt 240 -or $s.Concurrent -lt 1 -or $s.Concurrent -gt 10) {
                return Send-Json $ctx @{ error = 'Gecersiz ayar.' } 400
            }
            if (-not $State.DiscordRunning) {
                return Send-Json $ctx @{ error = "Discord masaustu uygulamasi acik degil. (Tarayici, Vesktop vb. sayilmaz.)" } 400
            }
            $State.Settings = $s
            [IO.File]::WriteAllText($SettingsPath, (ConvertTo-Json -InputObject $s -Compress))
            try {
                if ($null -eq $State.Candidates -or $State.Candidates.Count -eq 0) {
                    $State.Candidates = Get-Candidates (Get-DetectableList)
                    Write-Log "Uygun oyun sayisi: $($State.Candidates.Count)"
                }
                New-Runner
            } catch {
                $State.Error = $_.Exception.Message
                Write-Log $State.Error 'error'
                return Send-Json $ctx @{ error = $State.Error } 500
            }
            $State.Status = 'running'
            Write-Log ("Baslatildi: hedef {0} oyun, {1}-{2} dk, ayni anda {3}" -f $s.Count, $s.MinMinutes, $s.MaxMinutes, $s.Concurrent) 'ok'
            Invoke-Tick
        }
        '/api/stop' {
            foreach ($a in @($State.Active)) { Stop-FakeGame $a 'durduruldu' }
            if ($State.Status -eq 'running') { $State.Status = 'idle'; Write-Log 'Durduruldu.' }
        }
        '/api/cleanup' {
            if ($State.Status -eq 'running') { return Send-Json $ctx @{ error = 'Once durdur.' } 409 }
            Stop-AllFakeGames
            if ([IO.Directory]::Exists($GamesDir)) { [IO.Directory]::Delete($GamesDir, $true) }
            Write-Log 'Sahte oyun dosyalari silindi.'
        }
        '/api/reset' {
            if ($State.Status -eq 'running') { return Send-Json $ctx @{ error = 'Once durdur.' } 409 }
            $State.Done.Clear(); $State.DoneIds.Clear(); $State.Candidates = $null; $State.Status = 'idle'
            if (Test-Path $ProgressPath) { Remove-Item -LiteralPath $ProgressPath }
            Write-Log 'Ilerleme sifirlandi.'
        }
        '/api/shutdown' {
            $script:Quit = $true
            Write-Log 'Kapatiliyor...'
        }
        default { return Send-Json $ctx @{ error = 'Bulunamadi' } 404 }
    }
    Send-Json $ctx (Get-StatePayload)
}

# --- Ana dongu ---

Import-Saved
if ($State.Done.Count -gt 0) { Write-Log "Daha once tamamlanan oyun: $($State.Done.Count)" }

$listener = $null
for ($p = $Port; $p -le $Port + 10; $p++) {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    try { $l.Start(); $listener = $l; $Port = $p; break } catch { $l.Close() }
}
if (-not $listener) { throw "Port $Port-$($Port + 10) arasinda bos port bulunamadi." }

$url = "http://localhost:$Port/"
Write-Log "Kontrol paneli: $url  (kapatmak icin panelden 'Kapat' ya da Ctrl+C)" 'ok'
if (-not $NoBrowser) { Start-Process $url }

$pending = $listener.GetContextAsync()
$lastTick = [DateTime]::MinValue
try {
    while (-not $script:Quit) {
        if ($pending.Wait(250)) {
            $ctx = $pending.Result
            $pending = $listener.GetContextAsync()
            try { Invoke-Request $ctx }
            catch {
                Write-Log "Istek hatasi: $($_.Exception.Message)" 'error'
                try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch {}
            }
        }
        if (((Get-Date) - $lastTick).TotalSeconds -ge 2) {
            Invoke-Tick
            $lastTick = Get-Date
        }
    }
}
finally {
    # Ctrl+C ya da Kapat: acik sahte oyunlari kapat, yeterince oynananlari kaydet
    foreach ($a in @($State.Active)) { Stop-FakeGame $a 'kapatildi' }
    $listener.Stop()
    $listener.Close()
}
