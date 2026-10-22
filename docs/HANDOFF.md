# syncSCP — oturum devir notu

Son güncelleme: 22 Ekim 2026 (0.18.0 / terminal ve port yönlendirme). Bu belge, geliştirmeyi yeni bir oturumda mevcut dosyalardan sürdürmek için hazırlanmıştır.

## Amaç ve mevcut yaklaşım

Kullanıcının hedefi WinSCP'nin macOS üzerinde mümkün olduğunca bire bir çalışan, açık kaynak bir karşılığını oluşturmak. Proje dizini:

```text
/Users/oguzhankaracabay/Desktop/projects/WinSCP-Mac-Port
```

Mevcut uygulama **0.18.0 geliştirme önizlemesi**. SwiftUI/AppKit ile yazılmış bağımsız, yerel bir macOS uygulaması. Windows/VCL kaynaklarının doğrudan derlenmesi veya tamamlanmış bire bir port değil. Resmî WinSCP sürümü olarak tanıtılmamalı. Lisans **GPL-3.0-or-later**; özgün uygulama ikonu kullanılıyor.

Swift Package Manager kullanılıyor; hedef macOS 13+, paket araç sürümü 5.9. Son doğrulamalar Apple Silicon üzerinde Swift 6.2 ile yapıldı. Uygulama macOS'un OpenSSH, libcurl ve CryptoKit bileşenlerini kullanıyor; tek indirilen Swift paketi terminal için SwiftTerm (MIT, `exact: 1.20.0`; swift-argument-parser onun aracı için çözülüyor ama uygulamaya girmiyor). AWS SDK, Electron, Wine veya Python çalışma zamanı bağımlılığı yok. Python ve Docker yalnızca bağımsız test sunucuları için kullanılıyor.

**Git durumu:** `origin` = kullanıcının **private** GitHub reposu `https://github.com/oguzhankrcb/syncSCP` (21 Ekim 2026'da `WinSCP-Mac-Port` olarak oluşturuldu, 0.13.0'da yeniden adlandırıldı; GitHub eski adresi yönlendiriyor). `main` dalında ilk commit (`c7b6c76`, 0.4.0 içeri aktarımı) push edildi. 0.5.0 S3 ve 0.6.0 ayar çalışmaları ayrı commit'lerdir; push durumunu `git status -sb` ile kontrol et. Proje kökündeki `syncSCP — UI mockup.html` kullanıcının dışa aktardığı mockup kopyasıdır; untracked bırakıldı, commit'lenmedi. Repo private kalmalı; public yapmak, release veya PR açmak ayrıca yetki ister. `dist/`, `.build/` ve `upstream/winscp/` git dışında tutuluyor. Yine de `git clean`, reset gibi dosya kaybettirecek işlemler yapma.

## 0.18.0: Terminal sekmeleri, bölme, arama, snippet ve port yönlendirme

- `TerminalWindowController` yeniden yazıldı: her pencere bir `TerminalPane` ağacı (iç içe `NSSplitView`); her pane ayrı ssh girişi. Pencereler `tabbingIdentifier` ile macOS sekmesi olarak gruplanıyor; `newWindowForTab` aynı siteye yeni giriş açıyor. Menü komutları (Split Right ⌘D, Split Down ⌃⌘D, Close Pane ⌥⌘W) responder chain ile öndeki terminale gidiyor.
- Girişleri `TerminalLauncher` hazırlıyor (`CommanderModel.terminalLauncher`): sekmenin parolası, Login'de yazılan parola veya Touch ID sonrası kayıtlı parola geçici askpass kaydıyla veriliyor; kayıt o ssh bitince siliniyor.
- Find (⌘F/⌘G/⇧⌘G) SwiftTerm'in `performFindPanelAction`'ını kullanıyor. Terminal ▸ Snippets → `TerminalSnippet` (UserDefaults `TerminalSnippets`), Settings ▸ Snippets'ta düzenleniyor.
- Login ▸ Terminal: host key onayı (`confirmHostKeys`, connect ile ortak) sonrası dosya oturumu olmadan terminal.
- Port yönlendirme: `PortForward` (core, `SiteSettings.portForwards`), `SSHConfiguration.forwardArguments` (`-N -L 127.0.0.1:…`, ClearAllForwardings yok, ExitOnForwardFailure). App'te `ActiveForward` süreçleri; `PortForwardingSheet` (⇧⌘P). Uygulama kapanırken `stopAllForwards()`.
- Session menüsündeki terminal komutları yeni Terminal menüsüne taşındı.

## 0.17.0: Arka plan aktarımları, yeniden deneme ve devam

- Aktarımlar artık sekmenin göz atma bağlantısını kullanmıyor: her iş, o sekmenin sitesine açılan ayrı bir arka plan bağlantısında çalışıyor (`acquireTransferConnection` / `releaseTransferConnection`, sekme başına boşta bağlantı havuzu). Bunun için sekme parolası ve S3 token'ı yalnızca bellekte, sekme açıkken tutuluyor (`SessionTab.password`), WinSCP gibi. Duplicate Session da bu yüzden parola sormadan açılıyor.
- `busy` artık aktarımları içermiyor; aktarım sürerken gezinme ve dosya işlemleri çalışıyor. `runningQueue` hesaplanan bir özellik.
- `scheduleQueue()` Settings ▸ Transfers'taki sayı kadar (varsayılan 2, `MaxParallelTransfers`) işi aynı anda başlatıyor. `ClientError.connection` alan iş, `TransferRetries` (varsayılan 3) kadar 2/4/6… sn beklemeyle yeni bağlantıda tekrar deneniyor; sekme kapanmıyor.
- `TransferMemory`: biten dosyalar, oluşturulan klasörler ve dosya başına `TransferResume`; yeniden denemede ve kuyruktaki Retry düğmesinde bitenler atlanıyor, klasör "zaten var" hatası vermiyor.
- Core: `TransferResume` + `SFTPClient.upload/download(resume:)`; bağlantı kopunca .filepart saklanıyor, aynı kaynak sürümüyle sonraki deneme kaldığı yerden yazıyor. Diğer protokoller baştan başlıyor (`RemoteSession.resumesTransfers`).
- Uygulamadan çıkarken çalışan/bekleyen aktarım varsa uyarı.

## 0.16.0: Kayıtlı parolalar

- `SavedPasswords` (app): site başına bir Keychain öğesi, servis `io.github.oguzhankrcb.syncscp.site-password`, hesap = site id, `WhenUnlockedThisDeviceOnly`. `sites(among:)` yalnızca öznitelik okur.
- Login ▸ "Save password in Keychain": başarılı girişten sonra kaydediliyor (`connect(..., savePassword:)`). Parola alanı boşsa ve kayıtlı varsa `login(...)` onu kullanıyor; Settings ▸ Passwords'te Touch ID/Mac parolası istenebilir (`LAContext`, entitlement gerektirmiyor). Site listesinde anahtar ikonu, Forget, Forget All.
- Terminal: kayıtlı parolası olan sitede geçici bir `SessionCredential` ile askpass kullanıyor; terminalin ssh süreci bitince siliniyor (`TerminalWindowController.open(onEnd:)`).
- İçe aktarma: `WinSCPImport.decodePassword` WinSCP'nin simple algoritması; `ImportedSite.password` yalnızca bellekte. Import ekranında isteğe bağlı "Keychain'e kaydet"; zaten var olan siteler (ad, protokol, host, port, kullanıcı) işaretli ve seçili değil; parolaları yine kaydedilebiliyor.
- Kullanıcının gerçek WinSCP.ini'sinde 8 kayıtlı parola var, 8'i de çözülüyor (yalnızca sayılar yazdırıldı). Kullanıcı isterse Import ▸ Find on This Mac ile bu parolaları Keychain'e alabilir; site kopyası oluşmaz.
- Ad-hoc imza her derlemede değiştiği için macOS güncellemeden sonra bir kez Keychain erişim izni sorabilir (Always Allow).

## 0.15.0: Oturum sekmeleri

Birden fazla bağlantı aynı anda açık kalabiliyor. `SessionTab` her bağlantının kendi `RemoteSession`'ını, uzak/yerel klasörünü, seçimini ve geçmişini tutuyor. Gösterilen sekmenin durumu modelin `@Published` alanlarında; sekme değişince `storeActiveTab()` / `show(_:)` ile kaydedilip yükleniyor. `model.client` artık gösterilen sekmenin bağlantısı.

- `TransferJob` kendi `client` ve `session` değerini taşıyor; kuyruk başka sekme gösterilirken de doğru sunucuya aktarıyor. Bağlantı hatası yalnızca o sekmeyi kapatıyor (`closeFailedConnection(_:)`).
- Harici düzenlemeler açıldıkları sekmeye bağlı; sekme kapanınca duruyor (yüklenmemiş kopyalar korunuyor).
- `connect` yeni sekme açıyor; diğer sekmelerde aktarım sürerken de bağlanılabiliyor (`canConnect`). Sekme değiştirme `operationBusy` sırasında kapalı.
- Kısayollar: ⌘⇧] / ⌘⇧[ sekme değiştirme, ⌘⌥D Duplicate Session (Login'i aynı siteyle açar).
- `CommanderModel(store:)` testler ve render harness'ları için ayrı bir site deposu alabiliyor; uygulama varsayılanı kullanıyor.

## 0.14.0: SSH terminali

Session ▸ **Open Terminal** (⌘T) veya araç çubuğundaki **Terminal**: bağlı SFTP/SCP sitesine ayrı bir etkileşimli `ssh -t` girişi, SwiftTerm penceresinde. Kod: `SSHTerminal.swift` (core: `SSHConfiguration.terminalLaunch`, `SSHTerminalLaunch.commandFile`) ve `TerminalWindow.swift` (app).

- Aynı site ayarları ve uygulamanın known_hosts dosyası (StrictHostKeyChecking=yes); proxy/tunnel aynı. Bilinmeyen host key reddedilir.
- Askpass yok: parola, passphrase ve sudo soruları terminalin içinde soruluyor; parola saklanmıyor. BatchMode yok, 3 parola denemesi.
- Uzak panelde açık klasörde başlar (`/bin/sh -c 'cd "$1"…; exec …' syncscp <dir>`). SCP/Shell ayarı (ör. `sudo su -`) varsa o başlatılır; `su -` kendi ev dizinine geçer.
- **Open in Terminal.app** (⌘⇧T): özel klasörde kendini silen `.command` dosyası; otomasyon izni gerekmiyor.
- Settings ▸ Terminal: font ailesi (Nerd Font seçilebilir) ve boyut. Option tuşu karakter üretir (Türkçe klavyede @, | vb.); meta değil.
- Pencere kapatılırken ve uygulama çıkarken çalışan oturum için onay isteniyor. Terminal penceresi öndeyken ⌘Q, "Close Terminal" (varsayılan) / "Quit syncSCP" / "Cancel" sorusu gösteriyor (kullanıcı ⌘Q ile yalnızca terminali kapatmak istedi).
- `build-app.sh` her mimariyi ayrı derleyip `lipo` ile birleştiriyor; SwiftPM'in çok mimarili (Xcode) build sistemi SwiftTerm'in build-tool plugin'ini derleyemiyor.
- `build-app.sh` SwiftTerm lisansını ve kaynak bundle'ını `Contents/Resources` altına kopyalıyor (bundle yalnızca Metal çizimi için; varsayılan çizim Metal kullanmıyor).

## 0.13.0: syncSCP adı

Proje "WinSCP for macOS" yerine **syncSCP** adını aldı (WinSCP markasıyla karışmaması için). Değişenler:

- Uygulama `dist/syncSCP.app`, executable `SyncSCP`, bundle id `io.github.oguzhankrcb.syncscp`; modüller `SyncSCPCore` / `SyncSCP`, testler `SyncSCPCoreTests`.
- Keychain servisi `io.github.oguzhankrcb.syncscp.session`; ortam değişkenleri `SYNCSCP_*` (ör. `SYNCSCP_SKIP_S3`); ZIP'ler `SyncSCP-<sürüm>-*.zip`.
- Veri klasörü `~/Library/Application Support/SyncSCP`. `SiteStore.migrateLegacy` ilk açılışta eski `WinSCPMac` klasörünü bir kez kopyalar ve `sites.json`'daki eski klasöre işaret eden mutlak yolları (anahtarlar vb.) yeni klasöre çevirir. Eski klasör yedek olarak kalır, silinmez.
- `ExternalEditorPath` tercihi eski `org.winscp.community.mac` UserDefaults alanından taşınır.
- Uyumluluk için WinSCP adı kalan yerler bilinçli: "Import from WinSCP", `WinSCPImport`, "like WinSCP" yorumları, winscp.net yardım linkleri, NOTICE.
- Yerel proje dizininin adı hâlâ `WinSCP-Mac-Port`; değiştirmek gerekmez.

## Çalışan özellikler

- Commander tipi yerel/uzak çift panel; çoklu seçim, ad/boyut sıralama, yol ile gezinme, filtre ve gizli dosya görünümü.
- JSON üzerinde kayıtlı bağlantılar; eski kayıtlar yeni alanlar yoksa SFTP olarak açılıyor. Parolalar site JSON'una yazılmıyor.
- Tek etkin bağlantı ve aktarımları sırayla işleyen tek worker. Kuyruk, ilerleme, iptal ve sonuç gösterimi.
- Dosya ve özyinelemeli klasör yükleme/indirme; geçici hedef kullanımı ve kullanıcı tarafından onaylanmış üzerine yazma akışı.
- Yerel klasör oluşturma, yeniden adlandırma ve Trash; uzak mkdir, rename, delete ve protokol destekliyorsa POSIX izin değişikliği.
- En fazla 4 MB UTF-8 uzak dosya editörü; açılan sürüme karşı kontrol ederek sunucuya kaydetme.
- Önizlemeli, **tek yönlü yerelden uzağa** eşitleme. Kaynak/hedef sürümleri yeniden kontrol edilir; uzaktaki fazladan dosyalar silinmez, symlink'ler atlanır, tür çakışmaları engellenir.
- Sınırlı oturum günlüğü, sunucu anahtarı doğrulaması ve TLS sertifika/hostname doğrulaması.
- WinSCP Advanced Site Settings penceresi sayfa sayfa var (Login → **Advanced…**). Uygulanan ayarlar:
  - SCP shell (`sudo su -`) ve SFTP server komutu
  - timeout, keepalive ve IPv4/IPv6 seçimi
  - SOCKS4/5, HTTP ve yerel komut proxy'si; SFTP/SCP için SSH tunnel
  - TLS min/max sürümü
  - cipher/kex sıralaması ve rekey
  - kimlik doğrulama seçenekleri, S3 requester pays, not ve renk

  Diğerleri "Planned", "Not available with OpenSSH" vb. etiketlerle disabled. Ayrıntı: `docs/SETTINGS.md`. Kullanıcı kararı (hafızada da var): PuTTY'ye özgü ayarlar gizlenmez, gri gösterilir; hiçbir kontrol sessizce etkisiz olamaz.

### Protokoller

| Protokol | Durum ve önemli sınırlar |
| --- | --- |
| SFTP | Gerçek ikili SFTP v3, OpenSSH üzerinden. Agent, OpenSSH anahtarı, şifreli anahtar passphrase'i ve parola akışı mevcut. Üçüncü taraf sunucu ve gelişmiş kimlik doğrulama kapsamı eksik. |
| SCP | Gerçek legacy SCP aktarımı; `scp -t` / `scp -f`. SFTP fallback yok. Dosya yönetimi uzak Unix shell ve GNU/BSD stat ile yapılıyor. CR/LF içeren uzak aktarım yolları desteklenmiyor; sunucuda gerekli Unix araçları ve hard-link desteği gerekiyor. Linux/GNU sunucuyla uçtan uca doğrulama henüz yapılmadı. |
| FTP / FTPS | Plain FTP, explicit ve implicit FTPS; passive mode, MLSD ve Unix/DOS LIST, özel CA dosyası. TLS doğrulamasını kapatan seçenek yok. RNFR/RNTO üzerinden sonlandırılan yüklemelerde koşullu üzerine yazma garantisi sunucuya bağlı ve best effort. |
| WebDAV / WebDAVS | HTTP/HTTPS, Basic auth, PROPFIND/XML, dosya/klasör işlemleri, editör ve eşitleme. HTTPS sertifikayı ve hostname'i doğrular; özel CA desteklenir. Üzerine yazmak için güçlü ETag gerekir. Hedef yazma/rename yollarında `?` ve `;` reddedilir. Upload sırasında yerel mtime korunamaz; chmod yok. |
| S3 | HTTPS/HTTP, AWS SigV4 (SHA-256 imzalı içerik), sayfalı ListObjectsV2, klasör marker'ları, multipart upload, `If-None-Match`/`If-Match` koşullu yazma, multipart copy ile dosya rename, SHA-256 checksum. Secret key/session token yalnızca bellekte. Klasör rename, bucket yönetimi, versioning yok. MinIO dışında (AWS dahil) doğrulanmadı. [docs/S3.md](S3.md). |

SSH parolası/passphrase'i bağlantı kurulurken rastgele kimlikli geçici Keychain kaydıyla uygulamanın kendi SSH_ASKPASS yardımcısına aktarılır; başarı veya hata sonrasında silinir. Login sırasında anormal çökme olursa artık kayıt kalabilir; stale credential temizliği eksik. FTP/WebDAV parolaları oturum boyunca bellekte tutulur.

Uygulamanın site ve known_hosts verileri `~/Library/Application Support/SyncSCP/` altında. Kullanıcının SSH config'i değiştirilmez; SSH bağlantıları `-F /dev/null` ile açılır. Bu nedenle SSH config alias, jump host ve proxy desteği henüz yok.

## Kodun haritası

Aşağıdaki yolların tamamı proje dizinine göredir:

- `Package.swift`: `CCurlTransport`, `SyncSCPCore`, `SyncSCP`, `SyncSCPCoreTests` hedefleri.
- `Sources/SyncSCPCore/Models.swift`: protokol/site/dosya modelleri, yerel dosya bilgisi, hata ve iptal yapıları.
- `Sources/SyncSCPCore/RemoteSession.swift`: protokolden bağımsız `RemoteFileClient` arayüzü ve backend seçimi. Yeni protokoller bu katmana bağlanmalı.
- `Sources/SyncSCPCore/Synchronization.swift`, `SiteStore.swift`: eşitleme planı ve kayıtlı bağlantılar.
- `Sources/SyncSCPCore/SiteSettings.swift`: tüm Advanced Site Settings alanları, lenient decoding ve doğrulama. `SSHTransport.swift` içindeki `SSHOptions` bunları OpenSSH seçeneklerine, `CurlFTPTransport.swift` içindeki `CurlNetwork` ise libcurl'e çevirir.
- `Sources/SyncSCP/AdvancedSiteSettings.swift`: protokole göre ağaçlı ayar penceresi, durum etiketleri, cipher/kex sıralama listesi ve site rengi.
- `SFTPClient.swift`, `SFTPPacket.swift`, `SSHTransport.swift`: SFTP ve OpenSSH taşıması.
- `SCPClient.swift`, `SSHCommandChannel.swift`: legacy SCP, uzak komut kanalları ve ortak SSH master bağlantısı.
- `FTPClient.swift`, `FTPListing.swift`, `CurlFTPTransport.swift`: FTP/FTPS.
- `WebDAVClient.swift`, `WebDAVListing.swift`, `CurlHTTPTransport.swift`: WebDAV, URL/ETag/XML doğrulamaları. HTTP taşıması S3 için de kullanılır (`basicAuth: false`, hazır imzalı URL, `offset` ile aralıklı upload).
- `S3Client.swift`, `S3Listing.swift`, `S3Signer.swift`: S3 actor'ı, yol/URL eşlemesi, liste/hata XML'i, SigV4 ve SHA-256.
- `Sources/CCurlTransport/`: macOS libcurl için özgün C köprüsü; FTP ve HTTP girişleri ayrı. HTTP girişinde `basic_auth`, `pread` ile aralıklı upload (`ranged_upload`/`upload_offset`), HEAD için NOBODY ve `PATH_AS_IS` var.
- `Sources/SyncSCP/CommanderModel.swift`: MainActor uygulama durumu, kuyruk, editör, klasör aktarımları ve eşitleme.
- `CommanderView.swift`, `ConnectionSheet.swift`, `HostTrust.swift`, `SyncSCPApp.swift`: arayüz, bağlantı, güven, menüler ve askpass. Proxy/tunnel varken `HostTrust` sunucu anahtarını OpenSSH `accept-new` ile geçici bir dosyaya yakalar; tunnel host'un anahtarı önce onaylatılır.
- `Tests/SyncSCPCoreTests/`: birim ve gerçek sunucu entegrasyon testleri.
- `scripts/`: Swift wrapper, uygulama/paket üretimi ve geçici test sunucuları.

İlk okunacak belgeler: `README.tr.md`, `docs/ARCHITECTURE.md`, `docs/PARITY.md`, `docs/VERIFICATION.md`. Protokol ayrıntıları ve sınırlar: `docs/FTP.md`, `docs/SCP.md`, `docs/WEBDAV.md`, `docs/S3.md`. Upstream kaynak referansları: `upstream/REFERENCE.md`.

## Son doğrulama ve mevcut çıktılar

0.18.0'ın son kaynakları üzerinde hem debug hem release testleri tamamlandı:

```text
./scripts/test-ssh.sh --all             → 126 XCTest, 0 failure, 0 skip   (0.18.0)
./scripts/test-ssh.sh --all -c release  → 126 XCTest, 0 failure, 0 skip   (0.18.0)
```

Son çalıştırmalarda compiler warning yok. Testler gerçek OpenSSH/SFTP, SFTP subsystem'i kapalı ayrı SCP sunucusu, pyftpdlib 2.2.0 FTP/FTPS, WsgiDAV 4.3.5 / Cheroot 11.1.2 HTTP/HTTPS ve Docker'da iki MinIO (HTTP + HTTPS) sunucusunu kullanıyor. MinIO imajı digest ile sabitlenmiş `bitnamilegacy/minio:2025.7.23`; resmî topluluk MinIO imajları artık yayımlanmıyor. Geçici anahtarlar, CA ve dosyalar üretildi; kullanıcının üretim sunucusu/kimlik bilgileri kullanılmadı.

0.5.0'daki S3 akışı ve 0.6.0'daki Login → Advanced… akışı **çalışan uygulamada etkileşimli olarak denenmedi**. Ayar penceresi offscreen render edilip incelendi; paketlenen uygulamanın açılıp kapandığı kontrol edildi. Gerçek bir `sudo` hesabıyla test yapılmadı; testler `sudo su -` gibi davranan bir sahte shell kullanıyor. Önceki sürümlerde native uygulama arayüzünde bağlantı/güven akışı, SCP ve WebDAV dosya/klasör aktarımı, editör kaydı ve önizlemeli eşitleme kontrol edildi; yerel ve sunucu dosya içerikleri karşılaştırıldı. WebDAV için hatalı sertifikanın reddi ve özel CA ile başarılı HTTPS bağlantısı da denendi. Manuel test sunucuları durduruldu; uygulama son paketleme öncesinde kapatıldı.

Mevcut çıktılar:

```text
dist/syncSCP.app
dist/SyncSCP-0.18.0-universal.zip
dist/SyncSCP-0.18.0-source.zip   (untracked mockup HTML'i de içeriyor; script untracked dosyaları da paketler)
```

Universal sürüm arm64 ve x86_64 içeriyor, ad-hoc imzalı ve strict codesign kontrolünden geçti. **Fiziksel Intel testi, eski macOS testi, Developer ID imzası ve notarization yapılmadı.** GitHub Actions workflow'u repo push edildiği için GitHub'da tetiklenebilir; sonucunu doğrulamadan başarılı olduğu iddia edilmemeli. Hosted macOS runner'larda Docker olmadığından CI `SYNCSCP_SKIP_S3=1` kullanır; S3 testleri orada skip olur. Önceki 0.1–0.4 ZIP'leri de duruyor; güncel paket 0.18.0 (eski ZIP'ler `WinSCPMac-*` adını taşır).

Son kayıtlar `.build/terminal-debug-tests.log`, `.build/terminal-release-tests.log`, `.build/terminal-package.log` içinde.

## Çalıştırma ve geliştirme komutları

```sh
cd /Users/oguzhankaracabay/Desktop/projects/WinSCP-Mac-Port

# Sunucu gerektirmeyen testler; fixture değişkenleri olmadan entegrasyonlar skip olur.
./scripts/swift.sh test

# İlk kurulum veya test ortamını yeniden hazırlama; Python 3.11+ gerekir. S3 için Docker çalışıyor olmalı.
# Docker yoksa S3'ü açıkça atlamak için: SYNCSCP_SKIP_S3=1 ./scripts/test-ssh.sh --all
./scripts/setup-protocol-tests.sh

# Tüm gerçek protokol sunucularıyla testler.
./scripts/test-ssh.sh --all
./scripts/test-ssh.sh --all -c release

# Geliştirme / universal release / ZIP üretimi.
./scripts/build-app.sh --debug
./scripts/build-app.sh --universal
./scripts/package-release.sh
open "dist/syncSCP.app"
```

Manuel sunucu için `./scripts/test-ssh.sh --serve`, `./scripts/test-ftp.sh --serve`, `./scripts/test-webdav.sh --serve` veya `./scripts/test-s3.sh --serve` kullanılabilir. Çıktıları port, geçici dizin ve güven bilgilerini verir; Ctrl-C sunucuyu ve dosyalarını temizler. Sistem Remote Login ayarı değiştirilmez. Swift wrapper önbellekleri `.build` altında tutar. Test bağımlılıkları proje içindeki izole venv'lere kurulur; uygulamaya paketlenmez.

Yerel tool sandbox'ında port açma, bağımlılık indirme veya `iconutil` izin sorunu çıkabilir. Daha önce doğru iconset sandbox içinde hatalı `InvalidIconset` vermişti; böyle bir durumda ikon dosyalarını rastgele değiştirmek yerine izinli çalıştırmayı değerlendir.

## Önceki hatalardan öğrenilen, korunması gereken davranışlar

1. **Yerel dosya listesi ve eşitleme aynı metadata kaynağını kullanmalı.** `LocalFiles.info` Darwin `lstat` ile no-follow bilgi toplar. Foundation attribute okumaları home/cloud dosyalarında xattr nedeniyle UI'ı kilitlemişti. Eşitleme revalidation'ı da aynı helper'ı kullanmalı; Foundation/POSIX tarih dönüşümlerini karıştırmak nanosaniye farklarıyla sahte “dosya değişti” çakışmaları oluşturmuştu.
2. **SCP bağlantı ömrünü koru.** SSH master'ın uzak `cat >/dev/null` komutu uygulamanın sahip olduğu stdin pipe'a bağlı. Sadece `ssh -N` kullanmaya dönmek çökme sonrası yetim bağlantı bırakabilir. Kontrol soketi yoksa alt kanallar `BatchMode=yes` ve `ProxyCommand=/usr/bin/false` ile yeniden parola istemeden başarısız olmalı. No-clobber dosya yayımlama `link` aracıyla yapılır; `ln` hedef klasörü farklı yorumlayabilir.
3. **WebDAV geçici yükleme bir koleksiyonun içinde olmalı.** Özel `.syncscp-UUID.filepart/payload` yolu kullanılıyor. İptalde sahip olunan üst koleksiyon silinir; böylece gecikmiş PUT temizlenmiş payload'ı yeniden oluşturamaz. Tek başına geçici dosyaya dönmek artık dosya yarışını geri getirir.
4. **WebDAV hedef sürüm kontrolünü bozma.** MOVE üzerindeki `If-Match` kaynak nesneyi koşullar. Hedef ETag için tagged WebDAV `If` başlığı kullanılıyor; kaynak tag'i ayrıca korunuyor. RFC'nin izin verdiği absolute-path resource tag biçimi WsgiDAV ile doğrulandı.
5. **WebDAV `?` / `;` yazma engelini testsiz kaldırma.** WsgiDAV Destination'ı parse etmeden önce percent-decode ederek farklı hedefe yazabilir. Mevcut sürüm bu hedeflere upload/rename'i yazma başlamadan reddeder; mevcut dosyaları listeleme/okuma mümkün.
6. XML/URL sınırları, DTD/entity reddi, origin/path doğrulaması, güçlü ETag gereksinimi, TLS/host-key kontrolleri ve symlink politikası korunmalı. HTTP hata/redirect gövdeleri indirilen dosyaya eklenmemeli; 207 MOVE/DELETE tam başarı sayılmamalı.
7. Üzerine yazarken delete-first fallback ekleme. SFTP, SCP, FTP ve WebDAV aynı atomiklik garantisini sunmuyor; protokole özgü sınırları dürüstçe belgele. WebDAV sunucu kontrollü mtime nedeniyle aynı içerik eşitleme önizlemesinde tekrar önerilebilir.
8. WebDAV test sunucusu bilinçli olarak Cheroot kullanıyor; önceki wsgiref denemesi PUT işlemlerinde takılmıştı.
9. **S3 anahtarları birebir gönderilmeli.** `S3Location(bucket:key:)` listeden gelen anahtarı normalize etmez. C köprüsündeki `CURLOPT_PATH_AS_IS` kaldırılırsa libcurl `a/./b` gibi yolları birleştirip başka bir nesneyi silebilir.
10. **S3 koşullu yazmaları koru.** Tek PUT'ta `If-None-Match: *` / `If-Match`, multipart'ta aynı koşul `CompleteMultipartUpload` üzerinde. MinIO CopyObject ve DELETE'teki koşulları yok sayıyor; bu yüzden rename multipart copy + koşullu complete kullanır. Kaynak silme koşulsuzdur ve bu belgelenmiştir. Başarısız multipart upload her zaman abort edilmeli.
11. **İmzalı payload hash'i (SHA-256) bütünlük güvencesidir.** `UNSIGNED-PAYLOAD`'a geçmek, aktarım sırasında değişen yerel dosyanın sunucuda kabul edilmesine yol açar. İndirilen dosyanın checksum'ı yazma-only handle'dan okunamaz; ayrı bir okuma handle'ı açılır.
12. MinIO PUT boyunca nesneyi kilitler. Yarış testleri değişikliği akışın ortasında değil, istemci kontrolünden sonra (ilk progress çağrısında) enjekte eder; aksi hâlde 30 saniyelik kilit zaman aşımına düşer.
13. **SCP shell sırası önemli.** Marker satırı okunmadan SCP verisi (özellikle `scp -f` için ilk `\0`) gönderilmemeli; blok halinde okuyan shell'ler sonradan gelen baytları yutar. Connection probe da shell üzerinden geçer.
14. **SSH seçeneklerinde ilk değer kazanır.** SCP kanallarının `ProxyCommand=/usr/bin/false` ve `BatchMode=yes` seçenekleri site ayarlarından önce gelmeli; aksi halde proxy/tunnel ayarı fail-closed davranışını bozar. Tunnel için `ProxyJump` kullanma; jump host komut satırındaki doğrulama seçeneklerini yok sayar.
15. Varsayılan cipher/kex sırası OpenSSH'ın kendi varsayılanlarını korur; yalnızca kullanıcı sırayı değiştirirse `Ciphers`/`KexAlgorithms` gönderilir.

## Kalan işler ve önerilen ilerleme sırası

**0.7.0'da ana pencere ve Login onaylanan mockup'a göre yenilendi.** Yeni öğeler:

- panel başına gezinme/işlem çubukları ve geri/ileri geçmişi (`CommanderModel.backHistory`/`forwardHistory`)
- `Klasör/Ad` site gruplama (`SiteName`)
- protokol ailesi + Encryption seçimi (`ProtocolFamily`)
- açık Save / Save As…

Artık login'de site otomatik kaydedilmiyor. **0.12.0:** işlem çubuğunda New ▾ menüsü (Folder/File); `CommanderModel.promptNewFile` boş dosyayı no-clobber upload ile oluşturuyor. 0.11.0 ve 0.12.0 tek commit olarak (`00656c7`) push edildi. Lisans GPL-3.0-or-later olarak kaldı; Apache 2.0 ve PolyForm denemeleri geri alındı. Yerelde `backup/before-license-reset` ve `backup/polyform-attempt` dalları yedek olarak duruyor.

**0.11.0:** harici editör desteği var. İlgili kod:

- `RemoteEdit` ve `FileChangeMonitor`: SyncSCPCore içinde
- Edit With / Open With: `EditorApps`
- Settings (⌘,): `PreferencesView` — varsayılan editör UserDefaults'ta `ExternalEditorPath` olarak tutuluyor
- Editing sekmesi

Düzenlemeler `Application Support/SyncSCP/edits` altında, bağlantıya bağlı. Bağlantı kesilince izleme duruyor; yüklenmemiş kopyalar korunuyor.

**0.10.0:** SCP komutları WinSCP gibi tek kalıcı shell'de çalışıyor (`SCPSSHSession.run` / `persistentShell`). Bu, kullanıcının bildirdiği yavaş klasör açılmasını çözmek içindi. Transfer akışları ayrı kanal kullanıyor. Listelerde ".." satırı (`ParentRow`) ve tıklanabilir yol şeridi var. Olası sonraki hız işi: GNU stat listesinde dosya başına bir `stat` yerine toplu stat (Linux fixture'ı yok, test edilmeden yapılmamalı).

**0.9.0:** sürükle-bırak (`DragPayload`; uzak öğeler yalnızca uygulama içi tiple taşınır), Files ▸ Commander Keys (F2/F4/F5/F7/F8), Go menüsü ve "Remember last used directory". Proje kökündeki `ui-mockup.html` .gitignore'da.

**0.8.0'da WinSCP içe aktarma tamamlandı** (`WinSCPImport.swift`, `PuTTYKey.swift`, `ImportSheet.swift`; ayrıntı `docs/IMPORT.md`). Kullanıcının Whisky altındaki WinSCP'sinden gerçek veriler, kullanıcının isteğiyle uygulamaya aktarıldı:

- 26 site
- 3 PPK anahtarı OpenSSH'a çevrildi ve 19 siteye bağlandı
- 34 host key eklendi

Yedek `~/Library/Application Support/SyncSCP/backups/` altında. İçe aktarılan sunuculara henüz giriş denenmedi. Bu sitelerin yerel klasörü Whisky bottle'ındaki `drive_c` altına çözülüyor; çünkü WinSCP'de `C:\` olarak kullanılıyordu.

**Önceki plan notu:** Mockup: https://claude.ai/artifact/RcPqadNgvmoPmpCzifPjEc. Bu sürüm oturum sekmeleri, panel başına gezinme ve işlem çubukları, aktif panel yol şeridi, Rights/Owner sütunları, kuyruk paneli ve durum çubuğunu içeriyor. Login ekranı da mockup'taki gibi gruplu site ağacına geçmeli. Advanced Site Settings'te "Planned" kalan ayarlar (`docs/SETTINGS.md`) sonraki sürümlerde backend'e bağlanmalı.

S3 0.5.0'da temel düzeyde tamamlandı. S3 için kalanlar: native arayüzde S3 akışının elle denenmesi; AWS ve diğer sağlayıcılarla (R2, B2, Wasabi, Ceph) doğrulama; otomatik region keşfi; klasör rename; versioning, ACL/tag ve storage class; SSE-C; bucket yönetimi; multipart resume. Protokol eşitliğinde S3 sonrası net bir "sıradaki protokol" kalmadı. Bundan sonra öncelik günlük kullanım (drag/drop, sekmeler), aktarım dayanıklılığı (resume/retry) veya kimlik doğrulama (SSH config/jump host, keyboard-interactive) olabilir. Bu bir öneridir, kullanıcı seçimi değildir.

Diğer önemli eksikler:

- **Günlük kullanım:** drag/drop, session tabs, workspaces, gezinme geçmişi, klasör ağacı, seçim maskeleri, tam klavye kısayolları, Explorer tek panel, WinSCP INI import ve PPK dönüşümü.
- **Aktarımlar:** resume, retry, paralel worker, hız sınırı, kalıcı kuyruk, bağlantı kesintisinden toparlanma; büyük dosya ve internet gecikmesi testleri.
- **Eşitleme:** çift yön, checksum karşılaştırması, exclude maskeleri, izleme ve gelişmiş çakışma arayüzü; WebDAV timestamp davranışının iyileştirilmesi.
- **Editör/dosya işlemleri:** UTF-8 dışı encoding, büyük dosya, external editor watch; remote copy, dosya sistemleri arası move, custom commands, recursive chmod, ownership/ACL/xattr ve açık symlink politikası.
- **Kimlik doğrulama/ağ:** SSH keyboard-interactive/MFA, hardware key, GSSAPI, stale Keychain temizliği, kalıcı parola yönetimi, SSH config/jump host/tunnel/proxy. SSH hesap parolası sunucusuyla uçtan uca test hâlâ eksik; şifreli anahtar passphrase'i GUI'de denendi.
- **Protokol uyumluluğu:** Linux/GNU SCP uçtan uca testi; farklı SFTP/FTP/WebDAV sunucuları; FTP active mode/client certificate; WebDAV LOCK/UNLOCK, Digest/NTLM/OAuth ve vendor davranışları.
- **WinSCP otomasyonu:** script parser/CLI uyumluluğu, protocol URL, exit code ve log formatları; taşınabilir .NET/API yaklaşımı.
- **Ürünleştirme:** Türkçe ve diğer diller, VoiceOver/tam klavye denetimi, macOS 13+ ve fiziksel Intel doğrulaması, ilk Git commit/remote/public repo, Developer ID, notarization, DMG ve updater. Dışarıya yayımlama için ayrıca yetki değerlendirilmeli; bu devir isteği yayınlama talimatı değil.

Yeni oturum, önce mevcut kodu ve belgeleri inceleyip kaldığı yerden ilerlemeli. Tamamlanmış testleri sırf oturum değişti diye tekrar tekrar çalıştırmak gerekmiyor; yapılan değişikliğin gerektirdiği doğrulamayı yap. Arayüzde bir seçeneğin bulunmasını protokolün uygulanmış olmasıyla, Intel cross-compile'ı fiziksel Intel testiyle veya localhost fixture sonucunu tüm üretim sunucularıyla uyumlulukla eş tutma.
