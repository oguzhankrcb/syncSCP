# WinSCP macOS topluluk portu

WinSCP'nin çift panelli Commander iş akışını macOS'a taşımayı hedefleyen, SwiftUI/AppKit tabanlı açık kaynak proje. Lisans: **GPL-3.0-or-later**.

**0.5.0 geliştirme önizlemesidir. Resmî WinSCP sürümü veya henüz bire bir tamamlanmış bir port değildir.** Windows/VCL kaynakları doğrudan derlenmez; seçili işlevler macOS için yeniden uygulanmıştır.

```sh
./scripts/swift.sh test
./scripts/build-app.sh
open "dist/WinSCP for macOS.app"
```

macOS 13+ ve Swift 5.9+ içeren Xcode araçları gerekir. Apple Silicon + Intel paketi için `./scripts/build-app.sh --universal` kullanın.

Mevcut kapsam: gerçek SFTP, SCP, FTP/FTPS, WebDAV ve S3, çift panel, anahtar/agent/parola ile bağlantı, sunucu anahtarı doğrulaması, dosya ve klasör aktarımı, iptal edilebilir kuyruk, uzak dosya işlemleri, UTF-8 düzenleyici ve önizlemeli yerelden uzağa eşitleme. SSH parolaları oturum açılırken geçici olarak Keychain'e konur ve bağlantı denemesi sonrasında silinir; oturum dosyasına yazılmaz.

0.2.0 ile FTP, explicit FTPS ve implicit FTPS eklendi. Protokol seçimi, sertifika ve sunucu adı doğrulaması, özel CA dosyası, MLSD/Unix/DOS dizin listeleri, iptal edilebilir aktarımlar ve dosya işlemleri aynı arayüzde çalışır. FTP parolaları bağlantı boyunca bellekte tutulur; kayıtlı oturumlara yazılmaz. FTP üzerinden yeniden adlandırmanın atomikliği sunucuya bağlıdır. [FTP ayrıntıları](docs/FTP.md).

Tüm protokol testleri için Python 3.11+ ile `./scripts/setup-protocol-tests.sh`, ardından `./scripts/test-ssh.sh --all` çalıştırın. Python yalnızca test sunucuları içindir; uygulama macOS'un kendi kütüphanelerini kullanır.

0.3.0 ile SCP eklendi. Dosyalar gerçek eski SCP protokolüyle aktarılır; dizin ve dosya işlemleri aynı SSH bağlantısındaki ayrı komut kanallarını kullanır. Sunucuda Unix kabuğu, scp ve GNU/BSD stat ile temel dosya araçları gerekir. Parola bir kez kullanılır; sonraki işlemler açık SSH oturumunu paylaşır. SFTP kapalı bir test sunucusunda dosya bütünlüğü, iptal, üzerine yazma koruması, izinler ve güven doğrulandı. SCP aktarımında satır sonu içeren uzak yollar desteklenmez; bu dosyalar için SFTP seçin. [SCP ayrıntıları](docs/SCP.md).

0.4.0 ile HTTP/HTTPS WebDAV eklendi. PROPFIND dizin listeleri, dosya/klasör aktarımı, yeniden adlandırma, silme, editör ve eşitleme aynı arayüzü kullanır. HTTPS sertifika ve sunucu adını doğrular; WebDAV parolaları yalnızca bağlantı boyunca bellekte tutulur; üzerine yazma güçlü ETag koşuluyla yapılır. Sunucu yolunu gelişmiş ayarlardaki WebDAV path alanına girin. Bu sürüm WebDAV hedef yollarında `?`/`;` karakterlerine yazmayı reddeder; POSIX izinleri ve yüklemede yerel zaman damgasını koruma desteklenmez. [WebDAV ayrıntıları](docs/WEBDAV.md).

0.5.0 ile HTTPS/HTTP üzerinden S3 eklendi (AWS ve S3 uyumlu servisler). İstekler AWS Signature V4 ve SHA-256 imzalı içerikle gönderilir. Bucket/klasör listeleri sayfalı alınır, büyük dosyalar multipart yüklenir. Üzerine yazma koruması ve onaylı değiştirme sunucu tarafında `If-None-Match`/`If-Match` ile uygulanır. Yeniden adlandırma sunucu tarafı kopyayla yapılır. Kullanıcı adı alanına access key ID, parola alanına secret key girilir; secret key ve isteğe bağlı session token yalnızca bellekte tutulur. Klasör yeniden adlandırma, bucket yönetimi ve AWS üzerinde doğrulama henüz yoktur. S3 testleri Docker'da geçici MinIO sunucuları kullanır. [S3 ayrıntıları](docs/S3.md).

Tam WinSCP betik uyumluluğu, tünelleme, aktarımı kaldığı yerden sürdürme ve tam özellik eşitliği henüz yoktur. Ayrıntılar: [özellik tablosu](docs/PARITY.md), [İngilizce kullanım ve mimari](README.md).
