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
# Discord'a erisilemezse: listenin her gun guncellenen kopyasi (github.com/teyd/dgdb)
$MirrorUrl    = 'https://cdn.jsdelivr.net/gh/teyd/dgdb@main/detectable-win32.json'
$GamesDir     = Join-Path $WorkDir 'games'
$RunnerPath   = Join-Path $WorkDir 'runner.exe'
$ProgressPath = Join-Path $WorkDir 'progress.json'
$SettingsPath = Join-Path $WorkDir 'settings.json'
$PlanPath     = Join-Path $WorkDir 'plan.json'
$CachePath    = Join-Path $WorkDir 'detectable.json'
$UiPath       = Join-Path $PSScriptRoot 'ui.html'

# Baska bir programla karisabilecek ya da birden fazla oyunun kullandigi genel adlar
$GenericNames = @(
    'java.exe','javaw.exe','python.exe','pythonw.exe','node.exe','electron.exe',
    'game.exe','launcher.exe','client.exe','start.exe','main.exe','app.exe',
    'setup.exe','update.exe','updater.exe','unitycrashhandler64.exe','crashhandler.exe',
    'chrome.exe','firefox.exe','msedge.exe','explorer.exe','cmd.exe','powershell.exe'
)

# Profilde "Oynuyor" olarak gorunecegi icin mustehcen/rahatsiz edici adli oyunlar secilmez
$BlockedNamePattern = '(?i)\b(sex|hentai|nsfw|porn|lust|cuckold|genital|negligee|nude|naked|erotic|strip|boob|breeder|hitler|nazi|milf|harem|lewd|futa|yaoi|fetish|bdsm|onlyfans|waifu|succubus|brothel|incest|eros\b|taboo|slave|f\*ck|fuck|whoopass)'
# Latin alfabesi disinda harf iceren adlar (Cince, Japonca, Korece, Kiril...) da elenir;
# ne oldugu anlasilmayan bir oyun profilde gorunmesin. Aksanli Latin harfler serbest.
$NonLatinPattern = '(?=\p{L})[^\u0000-ɏḀ-ỿ]'

function Test-BlockedName([string]$name) {
    return ($name -match $BlockedNamePattern -or $name -match $NonLatinPattern)
}

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
    # Ayni anda birden fazla oyunun ayri sayildigi dogrulanmadi; varsayilan tek oyun
    Settings       = @{ Count = 250; MinMinutes = 46; MaxMinutes = 71; Concurrent = 1 }
    Done           = New-Object System.Collections.ArrayList
    DoneIds        = New-Object 'System.Collections.Generic.HashSet[string]'
    Active         = New-Object System.Collections.ArrayList
    Log            = New-Object System.Collections.ArrayList
    # Oynanacak oyunlarin sabit listesi (tamamlananlar dahil); plan.json'da saklanir
    Plan           = New-Object System.Collections.ArrayList
    PlanVersion    = 0
    Candidates     = $null
    LastTick       = 0
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
    if (Test-Path $PlanPath) {
        foreach ($item in @(Read-Json $PlanPath)) {
            [void]$State.Plan.Add((New-PlanItem $item['id'] $item['name'] $item['rel']))
        }
        $State.PlanVersion++
    }
}

function New-PlanItem($id, $name, $rel) {
    $rel = [string]$rel
    $base = ''
    if ($rel) { $base = (Split-Path $rel -Leaf).ToLowerInvariant() }
    [pscustomobject]@{ Id = [string]$id; Name = [string]$name; Rel = $rel; Base = $base }
}

function Save-Plan {
    $items = @($State.Plan | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; rel = $_.Rel } })
    [IO.File]::WriteAllText($PlanPath, (ConvertTo-Json -InputObject $items -Depth 3 -Compress))
    $State.PlanVersion++
}

# Listeyi hedef sayiya getirir: tamamlananlar hep kalir, bekleyenler korunur
# (-Reroll ile yenileri secilir), eksik kalirsa rastgele yeni oyun eklenir.
function Update-Plan([int]$count, [switch]$Reroll) {
    $old = @{}
    foreach ($p in $State.Plan) { $old[$p.Id] = $p }

    $items = New-Object System.Collections.ArrayList
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in $State.Done) {
        $rel = ''
        if ($old.ContainsKey($d.id)) { $rel = $old[$d.id].Rel }
        if ($ids.Add($d.id)) { [void]$items.Add((New-PlanItem $d.id $d.name $rel)) }
    }
    if (-not $Reroll) {
        foreach ($p in $State.Plan) {
            if ($items.Count -ge $count) { break }
            if (Test-BlockedName $p.Name) { continue }
            if ($ids.Add($p.Id)) { [void]$items.Add($p) }
        }
    }
    if ($items.Count -lt $count) {
        if ($null -eq $State.Candidates) {
            $State.Candidates = Get-Candidates (Get-DetectableList)
            Write-Log "Uygun oyun sayisi: $($State.Candidates.Count)"
        } elseif ($State.Candidates.Count -gt 0) {
            # Ayni oturumda yeniden secimde farkli sira
            $State.Candidates = [System.Collections.ArrayList]@($State.Candidates | Get-Random -Count $State.Candidates.Count)
        }
        # Yeniden secimde eski bekleyenler yenileriyle ayni olmasin
        $skip = @{}
        if ($Reroll) { foreach ($p in $State.Plan) { $skip[$p.Id] = $true } }
        foreach ($c in $State.Candidates) {
            if ($items.Count -ge $count) { break }
            if ($skip.ContainsKey($c.Id)) { continue }
            if ($ids.Add($c.Id)) { [void]$items.Add((New-PlanItem $c.Id $c.Name $c.Rel)) }
        }
        if ($items.Count -lt $count) { Write-Log "Listede sadece $($items.Count) uygun oyun var." 'warn' }
    }
    $State.Plan = $items
    Save-Plan
    Write-Log ("Oyun listesi hazir: {0} oyun ({1} tamamlanmis)" -f $items.Count, $State.Done.Count) 'ok'
}

# Listedeki bekleyen tek bir oyunu baska rastgele bir oyunla degistirir
function Set-PlanItemReplaced([string]$id) {
    $idx = -1
    for ($i = 0; $i -lt $State.Plan.Count; $i++) { if ($State.Plan[$i].Id -eq $id) { $idx = $i; break } }
    if ($idx -lt 0) { throw 'Oyun listede yok.' }
    $old = $State.Plan[$idx]
    if ($State.DoneIds.Contains($id) -or @($State.Active | Where-Object Id -eq $id).Count -gt 0) {
        throw 'Tamamlanan ya da oynanan oyun degistirilemez.'
    }
    if ($null -eq $State.Candidates) { $State.Candidates = Get-Candidates (Get-DetectableList) }
    $inPlan = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $State.Plan) { [void]$inPlan.Add($p.Id) }
    $pool = @($State.Candidates | Where-Object { -not $inPlan.Contains($_.Id) -and -not $State.DoneIds.Contains($_.Id) })
    if ($pool.Count -eq 0) { throw 'Yerine konacak oyun kalmadi.' }
    $c = $pool | Get-Random
    $State.Plan[$idx] = New-PlanItem $c.Id $c.Name $c.Rel
    Save-Plan
    Write-Log "Degistirildi: $($old.Name) -> $($c.Name)"
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
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($src in @(@{ Url = $ListUrl; Label = "Discord'dan" }, @{ Url = $MirrorUrl; Label = 'yedek kopyadan (teyd/dgdb)' })) {
        Write-Log "Oyun listesi $($src.Label) indiriliyor..."
        try {
            $wc = New-Object Net.WebClient
            $wc.Encoding = [Text.Encoding]::UTF8
            $wc.Headers['User-Agent'] = 'Mozilla/5.0'
            [IO.File]::WriteAllText($CachePath, $wc.DownloadString($src.Url))
            return Read-Json $CachePath
        } catch {
            Write-Log "Indirilemedi: $($_.Exception.Message)" 'warn'
        }
    }
    if (Test-Path $CachePath) {
        Write-Log 'Eski onbellek kullaniliyor.' 'warn'
        return Read-Json $CachePath
    }
    throw "Liste indirilemedi. Internet baglantini kontrol et ya da tarayicidan $ListUrl adresini kaydedip -ListPath ile ver."
}

function Get-Candidates($apps) {
    # Her uygulama icin ilk uygun Windows exe'sini al
    $all = foreach ($app in $apps) {
        $exe = @($app['executables'] | Where-Object {
            $_['os'] -eq 'win32' -and -not $_['is_launcher'] -and ([string]$_['name']) -like '*.exe'
        }) | Select-Object -First 1
        if (-not $exe -or (Test-BlockedName ([string]$app['name']))) { continue }
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

    # Listedeki sirayla ilk bekleyen oyun
    foreach ($p in $State.Plan) {
        if (-not $p.Rel -or $State.DoneIds.Contains($p.Id) -or $activeIds -contains $p.Id -or $running.Contains($p.Base)) { continue }
        return $p
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
    # Tick normalde 2 sn'de bir; uzun bosluk = bilgisayar uyudu. Discord da uyudugu icin
    # o sure oynanmis sayilmasin: acik oyunlarin baslangic/bitisini ileri kaydir.
    $gap = $now - $State.LastTick
    if ($State.LastTick -gt 0 -and $gap -gt 60000) {
        foreach ($a in $State.Active) { $a.Start += $gap; $a.End += $gap }
        Write-Log ("Bilgisayar ~{0:N0} dk uykudaydi; acik oyunlarin suresi uzatildi." -f ($gap / 60000)) 'warn'
    }
    $State.LastTick = $now

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
        planVersion    = $State.PlanVersion
        planSize       = $State.Plan.Count
    }
}

function Get-PlanPayload {
    @{
        version = $State.PlanVersion
        items   = @($State.Plan | ForEach-Object { @{ id = $_.Id; name = $_.Name; rel = $_.Rel } })
    }
}

function Invoke-Request($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath

    if ($req.HttpMethod -eq 'GET') {
        if ($path -eq '/') { return Send-Bytes $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($UiPath)) }
        if ($path -eq '/api/state') { return Send-Json $ctx (Get-StatePayload) }
        if ($path -eq '/api/plan') { return Send-Json $ctx (Get-PlanPayload) }
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
                if ($State.Plan.Count -ne $s.Count) { Update-Plan $s.Count }
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
        { $_ -eq '/api/plan/create' -or $_ -eq '/api/plan/reroll' } {
            if ($State.Status -eq 'running') { return Send-Json $ctx @{ error = 'Once durdur.' } 409 }
            $in = (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($body)
            $count = [int]$in['count']
            if ($count -lt 1 -or $count -gt 1000) { return Send-Json $ctx @{ error = 'Gecersiz oyun sayisi.' } 400 }
            try { Update-Plan $count -Reroll:($path -eq '/api/plan/reroll') }
            catch {
                $State.Error = $_.Exception.Message
                Write-Log $State.Error 'error'
                return Send-Json $ctx @{ error = $State.Error } 500
            }
        }
        '/api/plan/replace' {
            $in = (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($body)
            try { Set-PlanItemReplaced ([string]$in['id']) }
            catch { return Send-Json $ctx @{ error = $_.Exception.Message } 400 }
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
            $State.Done.Clear(); $State.DoneIds.Clear(); $State.Status = 'idle'
            if (Test-Path $ProgressPath) { Remove-Item -LiteralPath $ProgressPath }
            # Liste kalir; tum oyunlar tekrar "bekliyor" olur
            $State.PlanVersion++
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
