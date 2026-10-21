# WinSCP macOS topluluk portu

WinSCP'nin çift panelli Commander iş akışını macOS'a taşımayı hedefleyen, SwiftUI/AppKit tabanlı açık kaynak proje. Lisans: **GPL-3.0-or-later**.

**0.10.0 geliştirme önizlemesidir. Resmî WinSCP sürümü veya henüz bire bir tamamlanmış bir port değildir.** Windows/VCL kaynakları doğrudan derlenmez; seçili işlevler macOS için yeniden uygulanmıştır.

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

0.6.0 ile WinSCP'nin Advanced Site Settings penceresi sayfa sayfa geldi. Login ekranındaki **Advanced…** düğmesiyle açılır. Çalışan ayarlar:

- SCP/Shell, örneğin `sudo su -`; sudo şifre sormamalı (NOPASSWD)
- SFTP server komutu, örneğin `sudo /usr/lib/openssh/sftp-server`
- zaman aşımı, keepalive ve IPv4/IPv6 seçimi
- SOCKS/HTTP/yerel komut proxy'si ve SSH tunnel
- TLS sürümleri
- cipher ve key exchange sıralaması, rekey sınırları
- kimlik doğrulama seçenekleri, S3 seçenekleri, not ve site rengi

PuTTY'ye özgü veya henüz uygulanmayan ayarlar gri görünür ve nedenini belirten bir etiket taşır. [Ayar ayrıntıları](docs/SETTINGS.md).

0.7.0 ile ana pencere ve Login ekranı onaylanan mockup'a göre yenilendi. Yeni öğeler:

- WinSCP düzeninde araç çubuğu ve oturum sekmesi
- panel başına gezinme çubuğu (geri/ileri geçmişi, üst klasör, kök, ev, yenile) ve işlem çubuğu
- aktif panelde mavi yol şeridi, Type/Changed/Rights sütunları ve "X / Y içinde a / b" özeti
- kuyruk/günlük paneli ve bağlantı süresini gösteren durum çubuğu
- Login'de klasörlü site ağacı (`Klasör/Ad`), arama, ayrı protokol/şifreleme seçimi, açık Save / Save As… ve Manage

0.8.0 ile Windows WinSCP'den içe aktarma geldi: **File ▸ Import from WinSCP…** veya Login'de **Tools ▸ Import Sites from WinSCP…**. Kaynak olabilecekler:

- dışa aktarılmış `WinSCP.ini`
- `reg export` dosyası
- Wine, Whisky veya CrossOver altında çalışan WinSCP ("Find on This Mac")

Siteler klasörleri ve tüm Advanced ayarlarıyla gelir. Şifresiz PuTTY `.ppk` anahtarları OpenSSH formatına çevrilir; WinSCP'de güvenilen host key'ler eklenir. Önce yedek alınır. Parolalar hiçbir zaman içe aktarılmaz. [Ayrıntılar](docs/IMPORT.md).

0.9.0 ile sürükle-bırak geldi:

- yerel öğeleri ya da Finder'dan dosyaları uzak panele bırakmak yükler
- uzak öğeleri yerel panele bırakmak indirir

WinSCP Commander tuşları Files ▸ Commander Keys altında (F2 yeniden adlandır, F4 düzenle, F5 diğer panele kopyala, F7 klasör, F8 sil; Mac klavyede fn ile). Go menüsü: ⌘[ geri, ⌘] ileri, ⌘↑ üst klasör, ⌘⇧H ev, ⌃⇥ panel değiştir. "Remember last used directory" ayarı artık uygulanıyor.

0.10.0 ile SCP'de klasör açmak çok daha hızlı. WinSCP gibi tek bir kalıcı shell (örneğin `sudo su -`) açılıyor ve bütün komutlar ona gönderiliyor; eskiden her komut yeni bir SSH kanalı ve yeni bir shell açıyordu. Listelerin başında ".." satırı var. Yol şeridindeki her parçaya tıklayınca o klasöre gidiliyor.

Tam WinSCP betik uyumluluğu, tünelleme, aktarımı kaldığı yerden sürdürme ve tam özellik eşitliği henüz yoktur. Ayrıntılar: [özellik tablosu](docs/PARITY.md), [İngilizce kullanım ve mimari](README.md).
