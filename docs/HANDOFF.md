# WinSCP macOS — oturum devir notu

Son güncelleme: 21 Ekim 2026. Bu belge, geliştirmeyi yeni bir oturumda mevcut dosyalardan sürdürmek için hazırlanmıştır.

## Amaç ve mevcut yaklaşım

Kullanıcının hedefi WinSCP'nin macOS üzerinde mümkün olduğunca bire bir çalışan, açık kaynak bir karşılığını oluşturmak. Proje dizini:

```text
/Users/oguzhankaracabay/Desktop/projects/WinSCP-Mac-Port
```

Mevcut uygulama **0.4.0 geliştirme önizlemesi**. SwiftUI/AppKit ile yazılmış bağımsız, yerel bir macOS uygulaması. Windows/VCL kaynaklarının doğrudan derlenmesi veya tamamlanmış bire bir port değil. Resmî WinSCP sürümü olarak tanıtılmamalı. Lisans **GPL-3.0-or-later**; özgün uygulama ikonu kullanılıyor.

Swift Package Manager kullanılıyor; hedef macOS 13+, paket araç sürümü 5.9. Son doğrulamalar Apple Silicon üzerinde Swift 6.2 ile yapıldı. Uygulama macOS'un OpenSSH ve libcurl bileşenlerini kullanıyor; indirilmiş Swift paket bağımlılığı, Electron, Wine veya Python çalışma zamanı bağımlılığı yok. Python yalnızca bağımsız test sunucuları için kullanılıyor.

**Çok önemli Git durumu:** `main` dalında henüz commit yok; proje dosyaları untracked. Git remote tanımlı değil. Public repo, PR veya yayımlanmış release oluşturulmadı. `git diff` mevcut kaynakları göstermez. `git clean`, reset veya checkout ile dosya kaybettirecek işlemler yapma; mevcut çalışma klasörü geliştirmelerin asıl kaynağı.

## Çalışan özellikler

- Commander tipi yerel/uzak çift panel; çoklu seçim, ad/boyut sıralama, yol ile gezinme, filtre ve gizli dosya görünümü.
- JSON üzerinde kayıtlı bağlantılar; eski kayıtlar yeni alanlar yoksa SFTP olarak açılıyor. Parolalar site JSON'una yazılmıyor.
- Tek etkin bağlantı ve aktarımları sırayla işleyen tek worker. Kuyruk, ilerleme, iptal ve sonuç gösterimi.
- Dosya ve özyinelemeli klasör yükleme/indirme; geçici hedef kullanımı ve kullanıcı tarafından onaylanmış üzerine yazma akışı.
- Yerel klasör oluşturma, yeniden adlandırma ve Trash; uzak mkdir, rename, delete ve protokol destekliyorsa POSIX izin değişikliği.
- En fazla 4 MB UTF-8 uzak dosya editörü; açılan sürüme karşı kontrol ederek sunucuya kaydetme.
- Önizlemeli, **tek yönlü yerelden uzağa** eşitleme. Kaynak/hedef sürümleri yeniden kontrol edilir; uzaktaki fazladan dosyalar silinmez, symlink'ler atlanır, tür çakışmaları engellenir.
- Sınırlı oturum günlüğü, sunucu anahtarı doğrulaması ve TLS sertifika/hostname doğrulaması.

### Protokoller

| Protokol | Durum ve önemli sınırlar |
| --- | --- |
| SFTP | Gerçek ikili SFTP v3, OpenSSH üzerinden. Agent, OpenSSH anahtarı, şifreli anahtar passphrase'i ve parola akışı mevcut. Üçüncü taraf sunucu ve gelişmiş kimlik doğrulama kapsamı eksik. |
| SCP | Gerçek legacy SCP aktarımı; `scp -t` / `scp -f`. SFTP fallback yok. Dosya yönetimi uzak Unix shell ve GNU/BSD stat ile yapılıyor. CR/LF içeren uzak aktarım yolları desteklenmiyor; sunucuda gerekli Unix araçları ve hard-link desteği gerekiyor. Linux/GNU sunucuyla uçtan uca doğrulama henüz yapılmadı. |
| FTP / FTPS | Plain FTP, explicit ve implicit FTPS; passive mode, MLSD ve Unix/DOS LIST, özel CA dosyası. TLS doğrulamasını kapatan seçenek yok. RNFR/RNTO üzerinden sonlandırılan yüklemelerde koşullu üzerine yazma garantisi sunucuya bağlı ve best effort. |
| WebDAV / WebDAVS | HTTP/HTTPS, Basic auth, PROPFIND/XML, dosya/klasör işlemleri, editör ve eşitleme. HTTPS sertifikayı ve hostname'i doğrular; özel CA desteklenir. Üzerine yazmak için güçlü ETag gerekir. Hedef yazma/rename yollarında `?` ve `;` reddedilir. Upload sırasında yerel mtime korunamaz; chmod yok. |
| S3 | Henüz uygulanmadı. |

SSH parolası/passphrase'i bağlantı kurulurken rastgele kimlikli geçici Keychain kaydıyla uygulamanın kendi SSH_ASKPASS yardımcısına aktarılır; başarı veya hata sonrasında silinir. Login sırasında anormal çökme olursa artık kayıt kalabilir; stale credential temizliği eksik. FTP/WebDAV parolaları oturum boyunca bellekte tutulur.

Uygulamanın site ve known_hosts verileri `~/Library/Application Support/WinSCPMac/` altında. Kullanıcının SSH config'i değiştirilmez; SSH bağlantıları `-F /dev/null` ile açılır. Bu nedenle SSH config alias, jump host ve proxy desteği henüz yok.

## Kodun haritası

Aşağıdaki yolların tamamı proje dizinine göredir:

- `Package.swift`: `CCurlTransport`, `WinSCPCore`, `WinSCPMac`, `WinSCPCoreTests` hedefleri.
- `Sources/WinSCPCore/Models.swift`: protokol/site/dosya modelleri, yerel dosya bilgisi, hata ve iptal yapıları.
- `Sources/WinSCPCore/RemoteSession.swift`: protokolden bağımsız `RemoteFileClient` arayüzü ve backend seçimi. Yeni protokoller bu katmana bağlanmalı.
- `Sources/WinSCPCore/Synchronization.swift`, `SiteStore.swift`: eşitleme planı ve kayıtlı bağlantılar.
- `SFTPClient.swift`, `SFTPPacket.swift`, `SSHTransport.swift`: SFTP ve OpenSSH taşıması.
- `SCPClient.swift`, `SSHCommandChannel.swift`: legacy SCP, uzak komut kanalları ve ortak SSH master bağlantısı.
- `FTPClient.swift`, `FTPListing.swift`, `CurlFTPTransport.swift`: FTP/FTPS.
- `WebDAVClient.swift`, `WebDAVListing.swift`, `CurlHTTPTransport.swift`: WebDAV, URL/ETag/XML doğrulamaları.
- `Sources/CCurlTransport/`: macOS libcurl için özgün C köprüsü; FTP ve HTTP girişleri ayrı.
- `Sources/WinSCPMac/CommanderModel.swift`: MainActor uygulama durumu, kuyruk, editör, klasör aktarımları ve eşitleme.
- `CommanderView.swift`, `ConnectionSheet.swift`, `HostTrust.swift`, `WinSCPMacApp.swift`: arayüz, bağlantı, güven, menüler ve askpass.
- `Tests/WinSCPCoreTests/`: birim ve gerçek sunucu entegrasyon testleri.
- `scripts/`: Swift wrapper, uygulama/paket üretimi ve geçici test sunucuları.

İlk okunacak belgeler: `README.tr.md`, `docs/ARCHITECTURE.md`, `docs/PARITY.md`, `docs/VERIFICATION.md`. Protokol ayrıntıları ve sınırlar: `docs/FTP.md`, `docs/SCP.md`, `docs/WEBDAV.md`. Upstream kaynak referansları: `upstream/REFERENCE.md`.

## Son doğrulama ve mevcut çıktılar

0.4.0'ın son kaynakları üzerinde hem debug hem release testleri tamamlandı:

```text
./scripts/test-ssh.sh --all             → 72 XCTest, 0 failure, 0 skip
./scripts/test-ssh.sh --all -c release  → 72 XCTest, 0 failure, 0 skip
```

Son çalıştırmalarda compiler warning yok. Testler gerçek OpenSSH/SFTP, SFTP subsystem'i kapalı ayrı SCP sunucusu, pyftpdlib 2.2.0 FTP/FTPS ve WsgiDAV 4.3.5 / Cheroot 11.1.2 HTTP/HTTPS sunucularını kullanıyor. Geçici anahtarlar, CA ve dosyalar üretildi; kullanıcının üretim sunucusu/kimlik bilgileri kullanılmadı.

Native uygulama arayüzünde bağlantı/güven akışı, SCP ve WebDAV dosya/klasör aktarımı, editör kaydı ve önizlemeli eşitleme kontrol edildi; yerel ve sunucu dosya içerikleri karşılaştırıldı. WebDAV için hatalı sertifikanın reddi ve özel CA ile başarılı HTTPS bağlantısı da denendi. Manuel test sunucuları durduruldu; uygulama son paketleme öncesinde kapatıldı.

Mevcut çıktılar:

```text
dist/WinSCP for macOS.app
dist/WinSCPMac-0.4.0-universal.zip
dist/WinSCPMac-0.4.0-source.zip
```

Universal sürüm arm64 ve x86_64 içeriyor, ad-hoc imzalı ve strict codesign kontrolünden geçti. **Fiziksel Intel testi, eski macOS testi, Developer ID imzası ve notarization yapılmadı.** GitHub Actions workflow'u mevcut fakat GitHub üzerinde çalıştırıldığı iddia edilmemeli. Önceki 0.1–0.3 ZIP'leri de duruyor; güncel paket 0.4.0.

Son kayıtlar `.build/webdav-verification-tests.log`, `.build/webdav-verification-release-tests.log`, `.build/webdav-verification-build.log`, `.build/webdav-verification-package.log` içinde.

## Çalıştırma ve geliştirme komutları

```sh
cd /Users/oguzhankaracabay/Desktop/projects/WinSCP-Mac-Port

# Sunucu gerektirmeyen testler; fixture değişkenleri olmadan entegrasyonlar skip olur.
./scripts/swift.sh test

# İlk kurulum veya test ortamını yeniden hazırlama; Python 3.11+ gerekir.
./scripts/setup-protocol-tests.sh

# Tüm gerçek protokol sunucularıyla testler.
./scripts/test-ssh.sh --all
./scripts/test-ssh.sh --all -c release

# Geliştirme / universal release / ZIP üretimi.
./scripts/build-app.sh --debug
./scripts/build-app.sh --universal
./scripts/package-release.sh
open "dist/WinSCP for macOS.app"
```

Manuel sunucu için `./scripts/test-ssh.sh --serve`, `./scripts/test-ftp.sh --serve` veya `./scripts/test-webdav.sh --serve` kullanılabilir. Çıktıları port, geçici dizin ve güven bilgilerini verir; Ctrl-C sunucuyu ve dosyalarını temizler. Sistem Remote Login ayarı değiştirilmez. Swift wrapper önbellekleri `.build` altında tutar. Test bağımlılıkları proje içindeki izole venv'lere kurulur; uygulamaya paketlenmez.

Yerel tool sandbox'ında port açma, bağımlılık indirme veya `iconutil` izin sorunu çıkabilir. Daha önce doğru iconset sandbox içinde hatalı `InvalidIconset` vermişti; böyle bir durumda ikon dosyalarını rastgele değiştirmek yerine izinli çalıştırmayı değerlendir.

## Önceki hatalardan öğrenilen, korunması gereken davranışlar

1. **Yerel dosya listesi ve eşitleme aynı metadata kaynağını kullanmalı.** `LocalFiles.info` Darwin `lstat` ile no-follow bilgi toplar. Foundation attribute okumaları home/cloud dosyalarında xattr nedeniyle UI'ı kilitlemişti. Eşitleme revalidation'ı da aynı helper'ı kullanmalı; Foundation/POSIX tarih dönüşümlerini karıştırmak nanosaniye farklarıyla sahte “dosya değişti” çakışmaları oluşturmuştu.
2. **SCP bağlantı ömrünü koru.** SSH master'ın uzak `cat >/dev/null` komutu uygulamanın sahip olduğu stdin pipe'a bağlı. Sadece `ssh -N` kullanmaya dönmek çökme sonrası yetim bağlantı bırakabilir. Kontrol soketi yoksa alt kanallar `BatchMode=yes` ve `ProxyCommand=/usr/bin/false` ile yeniden parola istemeden başarısız olmalı. No-clobber dosya yayımlama `link` aracıyla yapılır; `ln` hedef klasörü farklı yorumlayabilir.
3. **WebDAV geçici yükleme bir koleksiyonun içinde olmalı.** Özel `.winscp-UUID.filepart/payload` yolu kullanılıyor. İptalde sahip olunan üst koleksiyon silinir; böylece gecikmiş PUT temizlenmiş payload'ı yeniden oluşturamaz. Tek başına geçici dosyaya dönmek artık dosya yarışını geri getirir.
4. **WebDAV hedef sürüm kontrolünü bozma.** MOVE üzerindeki `If-Match` kaynak nesneyi koşullar. Hedef ETag için tagged WebDAV `If` başlığı kullanılıyor; kaynak tag'i ayrıca korunuyor. RFC'nin izin verdiği absolute-path resource tag biçimi WsgiDAV ile doğrulandı.
5. **WebDAV `?` / `;` yazma engelini testsiz kaldırma.** WsgiDAV Destination'ı parse etmeden önce percent-decode ederek farklı hedefe yazabilir. Mevcut sürüm bu hedeflere upload/rename'i yazma başlamadan reddeder; mevcut dosyaları listeleme/okuma mümkün.
6. XML/URL sınırları, DTD/entity reddi, origin/path doğrulaması, güçlü ETag gereksinimi, TLS/host-key kontrolleri ve symlink politikası korunmalı. HTTP hata/redirect gövdeleri indirilen dosyaya eklenmemeli; 207 MOVE/DELETE tam başarı sayılmamalı.
7. Üzerine yazarken delete-first fallback ekleme. SFTP, SCP, FTP ve WebDAV aynı atomiklik garantisini sunmuyor; protokole özgü sınırları dürüstçe belgele. WebDAV sunucu kontrollü mtime nedeniyle aynı içerik eşitleme önizlemesinde tekrar önerilebilir.
8. WebDAV test sunucusu bilinçli olarak Cheroot kullanıyor; önceki wsgiref denemesi PUT işlemlerinde takılmıştı.

## Kalan işler ve önerilen ilerleme sırası

**Sıradaki protokol için öneri S3; olası sürüm 0.5.0.** Bu bir öneri, uygulanmış özellik veya kullanıcı tarafından ayrıca seçilmiş kesin bir sonraki görev değil. Endpoint/region/bucket ayarları, access/secret key ve session token, AWS SigV4, listeleme pagination, akışlı ve multipart upload, checksum, abort/iptal temizliği ve nesne üzerine yazma semantiği gerekir. Kimlik bilgileri JSON'a yazılmamalı. MinIO gibi bağımsız bir fixture ile gerçek round-trip, hata ve iptal testleri kurulmalı. Entegrasyon `RemoteSession` üzerinden olmalı; kayıtlı bağlantıların geriye uyumluluğu korunmalı. Bağımlılık ve servis tercihleri uygulamadan önce doğrulanmalı.

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
