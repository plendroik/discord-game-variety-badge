# discord-game-variety-badge

Discord'un deneysel **Game Variety** rozeti (Sampler → Universalist, 100+ farklı oyun) için, Discord'un algılanabilir oyun listesinden seçilen oyunların exe adını taşıyan sahte programları sırayla çalıştıran bir PowerShell scripti. Kontrol paneli tarayıcıda açılır.

Discord istemcisine kod enjekte etmez, sahte API isteği göndermez. Discord masaüstü uygulaması bu programları kendi normal oyun algılamasıyla "Oynuyor" olarak görür. Her oyun rastgele bir süre (varsayılan 5–15 dk) açık kaldığı için **Game Time** rozetine de oynama süresi eklenir.

> ⚠️ Bu yöntem Discord Kullanım Koşulları'na aykırıdır. Riski düşük olsa da sıfır değildir; sorumluluk kullanıcıya aittir.

## Gereksinimler

- Windows + **Discord masaüstü uygulaması** (tarayıcı, Vesktop vb. sayılmaz)
- Discord ayarlarında **Etkinlik Gizliliği → Etkinlik durumunu paylaş** ve **Veri ve Gizlilik → analitik verileri kullan** açık olmalı
- Rozet rastgele dağıtılan bir deney; hesabında yoksa çıkmaz
- Discord'a erişim engelliyse liste indirilirken WARP/VPN açık olmalı (liste 24 saat önbellekte tutulur)

## Kullanım

```powershell
powershell -ExecutionPolicy Bypass -File .\DiscordOyunRozeti.ps1
```

Tarayıcıda `http://localhost:8765/` açılır. Hedef oyun sayısını, süre aralığını ve aynı anda kaç oyun açık olacağını seçip **Başlat**'a bas. PowerShell penceresi açık kaldığı sürece çalışır.

Panelde:
- toplam ilerleme ve 10 rozet seviyesi,
- toplam oynama süresi ve tahmini kalan süre,
- şu an açık oyunlar ve geri sayımları,
- tamamlanan oyunlar ve kayıt.

Varsayılan ayarlarla (110 oyun, 5–15 dk, aynı anda 2) yaklaşık 9–10 saat sürer.

| Script parametresi | Varsayılan | Açıklama |
|---|---|---|
| `-Port` | 8765 | Panel portu (doluysa sonraki 10 port denenir) |
| `-ListPath` | – | `discord.com/api/v9/applications/detectable` indirilemezse elle kaydedilmiş JSON |
| `-WorkDir` | `%LOCALAPPDATA%\DiscordOyunRozeti` | Sahte exe'ler, ilerleme, ayarlar, liste önbelleği |
| `-NoBrowser` | – | Tarayıcıyı otomatik açma |
| `-Cleanup` | – | Açık sahte oyunları kapatır, çalışma klasörünü tamamen siler |

İlerleme `progress.json`'a yazılır; script kapatılıp tekrar açıldığında kaldığı yerden devam eder ve oynanmış oyunları tekrar seçmez. Yarıda durdurulan bir oyun, en az süre alt sınırı kadar açık kaldıysa tamamlanmış sayılır.

## Nasıl çalışır

1. Discord'un algılanabilir oyun listesini indirir.
2. Windows exe'si olan, launcher olmayan oyunları alır. `game.exe`, `java.exe` gibi genel isimleri, birden fazla oyunun paylaştığı exe adlarını ve o an bilgisayarda gerçekten çalışan programlarla çakışanları eler.
3. Küçük, simge durumunda açılan bir WinForms programı derler (pencere başlığı = oyun adı).
4. Her oyun için bu programı Discord'un beklediği klasör yolu ve exe adıyla kopyalar, rastgele süre çalıştırıp kapatır.
5. Discord kapanırsa yeni oyun başlatmaz, Discord açılınca devam eder.

Panel sadece `localhost`'ta dinler; POST istekleri özel bir başlık ister, böylece başka siteler panele istek gönderemez.
