# discord-game-variety-badge

Discord'un deneysel **Game Variety** rozeti (Sampler → Universalist, 100+ farklı oyun) için, Discord'un algılanabilir oyun listesinden seçilen oyunların exe adını taşıyan sahte programları sırayla çalıştıran bir PowerShell scripti.

Discord istemcisine kod enjekte etmez, sahte API isteği göndermez. Discord masaüstü uygulaması bu programları kendi normal oyun algılamasıyla "Oynuyor" olarak görür.

> ⚠️ Bu yöntem Discord Kullanım Koşulları'na aykırıdır. Riski düşük olsa da sıfır değildir; sorumluluk kullanıcıya aittir.

## Gereksinimler

- Windows + **Discord masaüstü uygulaması** (tarayıcı, Vesktop vb. sayılmaz)
- Discord ayarlarında **Etkinlik Gizliliği → Etkinlik durumunu paylaş** ve **Veri ve Gizlilik → analitik verileri kullan** açık olmalı
- Rozet rastgele dağıtılan bir deney; hesabında yoksa çıkmaz
- Discord'a erişim engelliyse liste indirilirken WARP/VPN açık olmalı

## Kullanım

```powershell
# Önce ne seçeceğine bak
powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1 -DryRun

# Varsayılan: 110 oyun, oyun başı 3 dk, aynı anda 1 oyun (~6 saat)
powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1

# Daha hızlı: aynı anda 3 oyun (~2 saat)
powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1 -Concurrent 3

# Bitince sahte dosyaları sil
powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1 -Cleanup
```

| Parametre | Varsayılan | Açıklama |
|---|---|---|
| `-Count` | 110 | Kaç farklı oyun (100 + pay) |
| `-Minutes` | 3 | Her oyunun açık kalacağı süre |
| `-Concurrent` | 1 | Aynı anda açık sahte oyun sayısı |
| `-ListPath` | – | `discord.com/api/v9/applications/detectable` indirilemezse elle kaydedilmiş JSON |
| `-WorkDir` | `%LOCALAPPDATA%\DiscordOyunRozeti` | Sahte exe'lerin ve ilerleme kaydının klasörü |
| `-DryRun` | – | Sadece seçilecek oyunları listeler |
| `-Cleanup` | – | Açık sahte oyunları kapatır, klasörü siler |

İlerleme `progress.json`'a yazılır. Script yarıda kesilirse (Ctrl+C) tekrar çalıştırıldığında kaldığı yerden devam eder, oynanmış oyunları tekrar seçmez.

## Nasıl çalışır

1. Discord'un algılanabilir oyun listesini indirir.
2. Windows exe'si olan, launcher olmayan oyunları alır. `game.exe`, `java.exe` gibi genel isimleri, birden fazla oyunun paylaştığı exe adlarını ve o an bilgisayarda gerçekten çalışan programlarla çakışanları eler.
3. Küçük, simge durumunda açılan bir WinForms programı derler (pencere başlığı = oyun adı).
4. Her oyun için bu programı Discord'un beklediği klasör yolu ve exe adıyla kopyalar, `-Minutes` süre çalıştırıp kapatır.
