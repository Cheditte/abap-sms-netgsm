# abap-sms-netgsm

> [English](README.md) | **Türkçe**

**SAP'den [Netgsm](https://www.netgsm.com.tr) üzerinden, yalnızca ABAP ile SMS gönderir.** Middleware ya da sunucuda betik gerekmez; SAP, Netgsm'in HTTPS API'sini kendisi çağırır.

**Tek program, başka hiçbir şey oluşturmanız gerekmez.** Tek bir dosyayı SE38'e kopyalayıp aktifleştirirsiniz. Tablo, data element ya da fonksiyon grubu yok. Netgsm şifresi koda değil SM59'a girer.

> **Durum: v0.2, henüz yayınlanmadı.** SAP_BASIS 7.00 (ECC 6.0) ve üstü için yazıldı, ama şimdiye kadar yalnızca SAP ABAP Platform deneme sisteminde (SAP_BASIS 816) çalıştırıldı. Bkz. [Neler doğrulandı](#neler-doğrulandı). **Henüz gerçek bir SMS gönderilmedi ve hiçbir çağrı henüz bir Netgsm hesabına ulaşmadı.**

## Ne yapar

Ekranda bir **işlem** seçersiniz; ekran yalnızca o işlemin alanlarını gösterir.

| İşlem | Ne yapar | Netgsm paketi | Ücret |
|---|---|---|---|
| **SMS gönder** | Bir ya da daha fazla numaraya aynı metin; hemen ya da ileri bir saatte (Türkiye saati), kendi referansınızla | Toplu SMS | SMS başına |
| **OTP SMS gönder** | Tek numara, tek parça, Türkçe harf yok. 3 dakika içinde iletilir; filtre yok (İYS, kara liste, mükerrer) | OTP SMS | SMS başına |
| **Şablonlu SMS gönder** | Netgsm'de onaylı bir şablon; `${...}` alanlarına sizin değerleriniz | Toplu SMS | SMS başına |
| **İleri tarihli SMS'i iptal et** | İleri bir saate kurulmuş gönderimi geri alır | | ücretsiz |
| **Teslim raporu** | Numara numara durum; iş numarasıyla ya da tarih aralığıyla (en fazla 3 ay) | | ücretsiz |
| **Bir işin istatistiği** | Bir işin toplamları: iletilen, iletilemeyen, parça, kredi | | ücretsiz |
| **Gelen SMS** | Netgsm numaranıza gönderilen SMS'ler | | ücretsiz |
| **Test: gönderici adlarını listele** | Hesaptaki onaylı gönderici adları; ilk bağlantı testi | | ücretsiz |
| **Şablonları listele** | Sizin şablonlarınız ve Netgsm'in genel şablonları, alanlarıyla | | ücretsiz |
| **Karakterleri Netgsm'e saydır** | Bir metnin parça ve karakter sayısını Netgsm'in kendisine hesaplatır | | ücretsiz |

Her gönderime önce **önizlemeyle** bakılabilir; varsayılan budur. Önizleme her şeyi kontrol eder ve gidecek isteğin kendisini gösterir, ama hiçbir şey göndermez. Gerçek gönderim bir onay penceresi açar. Program **job adımı** olarak da, **kendi ABAP kodunuzdan** da çalışır: `PERFORM send_sms IN PROGRAM zche_sms_netgsm` (bkz. [Kendi programlarınızdan kullanım](#kendi-programlarınızdan-kullanım)).

Her gönderimde sırasıyla:

1. **Numaralar.** `+90 500 000 00 00`, `0500 000 00 00`, `500 000 00 00` ve `0090…`, Netgsm'in istediği 10 haneli biçime çevrilir. Sabit hat, yurt dışı numarası ve yazım hatası tek tek, sebebiyle reddedilir. İki kez verilen numaraya bir kez gönderilir.
2. **Metin.** Karakter setini program seçer: Türkçe harf varsa Türkçe, emoji varsa Unicode. Karakterleri ve parçaları Netgsm'in saydığı gibi sayar. 6 parçaya (OTP'de 1 parçaya) sığmayan metin gönderilmez.
3. **Kontroller.** SM59 hedefi var mı, kullanıcının onu kullanma yetkisi var mı (yetki nesnesi `S_ICF`)? İkisi önizlemede de kontrol edilir.
4. **Gönderim.** Netgsm'e tek istek gider ve **kendiliğinden tekrar denenmez**: ikinci istek ikinci, ücretli bir SMS demek olabilir.
5. **Günlük.** `ZCHE_SMS` günlük nesnesini oluşturduysanız sonuç uygulama günlüğüne (SLG1) yazılır. Numaralar maskelidir (`5** *** ** 34`); mesaj metni yalnızca isterseniz yazılır.

### Neleri yapmaz, neden

| Netgsm servisi | Neden yok |
|---|---|
| Kara listeye ekleme/çıkarma, İYS adres yükleme ve sorgulama | Netgsm kullanıcı kodunu ve şifreyi **isteğin gövdesinde** istiyor. SM59 bunları gövdeye yazamaz; programın şifreyi okuması gerekirdi. Bu, projenin kuralına aykırı. Netgsm panelini kullanın. |
| Gelen SMS'in bir URL'ye yönlendirilmesi, İYS webhook | Bu servislerde Netgsm SAP'yi çağırır. Bunun için bir ICF servisi ve bir sınıf gerekir, kopyala-yapıştır bir program yetmez. Program bunun yerine "Gelen SMS" ile mesajları kendisi okur. |
| WhatsApp OTP, sesli mesaj, eski XML servisleri | Başka ürünler ya da başka API'ler. |
| SMS API v3 (yeni API) | Token almak için şifreyi JSON gövdesinde istiyor (yukarıdaki sebep). Bkz. [Neden REST v2](#neden-netgsm-rest-v2-neden-v3-değil). |

## Neler gerekiyor

| Ne | Neden | Kimden |
|---|---|---|
| **Toplu SMS** ve/veya **OTP SMS** paketi olan bir Netgsm hesabı | SMS'i Netgsm gönderir ve faturalar. OTP SMS için ayrı paket gerekir. | Şirketinizde Netgsm hesabı kimdeyse |
| O hesapta bir **API alt kullanıcısı** | Netgsm 15 Şubat 2024'ten beri API erişimi için API tipi alt kullanıcı istiyor | Netgsm paneli, ana hesap ([1. adım](#1-netgsm-paneli)) |
| **Onaylı bir gönderici adı** (başlık), ör. `FIRMA` | Her SMS onaylı bir adla gider | Netgsm paneli ([1. adım](#1-netgsm-paneli)) |
| SAP_BASIS 7.00 ya da üstü | Kod klasik ABAP. [abaplint](https://abaplint.org) ile 7.00 modunda kontrol edildi, ama yalnızca 8.16'da çalıştırıldı | |
| Geliştirici anahtarı ve transport talebi (denemek için `$TMP`) | Programı SE38'de oluşturmak için | Basis |
| SAP sunucusundan `api.netgsm.com.tr` ve `ext-api.netgsm.com.tr` adreslerine 443 portundan erişim | SAP Netgsm'i doğrudan çağırır. İkinci adres yalnızca şablonlar için. | Ağ ekibi |
| STRUST'ta **USERTrust RSA Certification Authority** kök sertifikası | Olmazsa HTTPS bağlantısı kurulamaz ([3. adım](#3-strust-netgsm-sertifikasına-güvenmek)) | Basis |
| İki G tipi SM59 hedefi (şablon kullanmayacaksanız bir tane) | Adresi ve Netgsm şifresini tutar ([4. adım](#4-sm59-bağlantı-ve-şifre)) | Basis |
| SAP'nin internete çıktığı genel (public) IP adresi | Yalnızca Netgsm'de IP kısıtını açarsanız | Ağ ekibi |

## Kurulum, adım adım

### 1. Netgsm paneli

Netgsm web paneline **ana hesapla** girin. Alt kullanıcıyı yalnızca ana hesap oluşturabilir.

1. **Paket.** Uyarılar ve normal SMS için **Toplu SMS**, tek kullanımlık kodlar için **OTP SMS**. OTP daha ucuzdur, ama yalnızca tek numaraya, tek parça ve Türkçe harfsiz gider. Netgsm onu şifre, onay kodu gibi kodlar için tanımlıyor.
2. **API alt kullanıcısı.** *Abonelik İşlemleri → Alt Kullanıcı Hesapları* altında **API** tipinde bir alt kullanıcı oluşturun. Netgsm'e göre bunu bir temsilci onaylıyor ve oluşturunca API erişimi de veriliyor. İki değeri not edin:
   - **Kullanıcı kodu**: Netgsm abone numaranız, ör. `312XXXXXXX` ya da `850XXXXXXX`. SM59'a kullanıcı olarak girer.
   - Alt kullanıcının **şifresi**: SM59'a şifre olarak girer, başka hiçbir yere girmez.
3. **Gönderici adı.** *SMS Hizmeti → SMS Ayarları → Gönderici Adlarım* altında 3 ile 11 karakter arasında bir ad isteyin ve onaylanmasını bekleyin. Adı SAP'ye **onaylandığı gibi** yazın: Netgsm'in yeni API'si büyük ve küçük harfi ayırıyor, eski API denenmedi.
4. **IP kısıtı (önerilir).** *Abonelik İşlemleri → API işlemleri → API IP Erişim Yönetimi* altında API çağrılarını yalnızca listelenen adreslerden kabul edebilirsiniz. SAP'nin internete çıktığı **genel** adresi ekleyin; bu adresi ağ ekibi bilir. Eksikse Netgsm `30` koduyla cevap verir.
5. **Ticari ileti.** Reklam ve kampanya SMS'i için alıcının İYS'de (İleti Yönetim Sistemi) onayı olması gerekir, Netgsm de hesabınızda İYS marka kodu ister. Kendi çalışanlarınıza giden düz uyarılar "bilgilendirme" sayılır (`0`), varsayılan budur.
6. **Şablonlar (isteğe bağlı).** Şablonlu SMS, Netgsm'de onaylı metinlerle gönderilir. Kendi şablonunuzu nasıl ekleyeceğinizi Netgsm'e sorun. *Şablonları listele* işlemi hesabınızın kullanabileceklerini gösterir.

Menü adları Netgsm dokümanında Kasım 2026'da yazdığı gibidir; panel farklı görünebilir.

### 2. Programı kurun

1. [`src/zche_sms_netgsm.prog.abap`](src/zche_sms_netgsm.prog.abap) dosyasını açın ve tamamını kopyalayın (**Copy raw file**).
2. **SE38**'de `ZCHE_SMS_NETGSM` programını oluşturun: başlık `SMS from SAP through Netgsm`, tip **Yürütülebilir program**, paketiniz (denemek için **Yerel nesne**).
3. SE38'in koyduğu her şeyi silin, yapıştırın ve **aktifleştirin** (Ctrl+F3).
4. Kontrol: **Program → Yürüt → Birim testleri** (ADT'de Ctrl+Shift+F10). **50 testin** geçmesi gerekir. Testler sahte bir HTTP katmanı kullanır, Netgsm'i hiç çağırmaz.

Ekran metinleri koddan gelir: İngilizce, Türkçe oturum açınca Türkçe.

**Aktifleştirirken "satır çok uzun" hatası alırsanız:** editörünüz eski 72 karakterlik satır ayarında. *Yardımcı programlar → Ayarlar → ABAP Editor → Editör* altında **Downwards-compatible line length (72)** işaretini kaldırıp yeniden yapıştırın. Kaynak 72 sütunu aşmadığı için normalde bu olmaz.

**abapGit (isteğe bağlı):** depo aynı zamanda bir abapGit deposudur; aynı tek programı kurar.

### 3. STRUST: Netgsm sertifikasına güvenmek

Deneme sisteminde ilk çağrı `SSSLERR_PEER_CERT_UNTRUSTED` hatasıyla düştü. Program bunu `NO_TRUST` koduyla gösterir; bu durumda hiçbir şey gitmemiştir. İki adres de aynı sertifikayı kullanıyor (7 Kasım 2026'da bakıldı):

```
*.netgsm.com.tr   (api.netgsm.com.tr ve ext-api.netgsm.com.tr)
 └ Sectigo Public Server Authentication CA DV R36
    └ Sectigo Public Server Authentication Root R46
       └ USERTrust RSA Certification Authority   ← kök, bunu ekleyin
```

1. Kök sertifikayı alın. Ya tarayıcıda `https://api.netgsm.com.tr` adresini açıp sertifikayı gösterin, **USERTrust RSA Certification Authority**'yi seçip Base64 (`.cer`) olarak dışa aktarın, ya da Sectigo'nun sitesinden indirin.
2. **STRUST**'ta **SSL client Anonymous**'u açın. Bu `ANONYM`'dir; hedefinizin kendi PSE'si varsa onu kullanın.
3. **Sertifikayı içe aktar** → dosya → **Sertifika listesine ekle** → **Kaydet**.
4. Bağlantı testi hâlâ düşüyorsa Basis'ten ICM'nin PSE'yi yeniden yüklemesini isteyin.

### 4. SM59: bağlantı ve şifre

İki **dış sunucuya HTTP bağlantısı** (tip **G**) oluşturun. Şablon kullanmayacaksanız ikincisi gerekmez.

| Sekme / alan | `ZCHE_NETGSM` | `ZCHE_NETGSM_EXT` (şablonlar) |
|---|---|---|
| Teknik ayarlar → Host | `api.netgsm.com.tr` | `ext-api.netgsm.com.tr` |
| Port | `443` | `443` |
| Yol öneki (Path prefix) | **boş**; program `/sms/rest/v2/...` yolunu kendisi gönderir | **boş** |
| Oturum açma ve güvenlik → Temel kimlik doğrulama → Kullanıcı | Netgsm **kullanıcı kodu** (1. adım) | aynısı |
| Şifre | **API alt kullanıcısının şifresi** (1. adım) | aynısı |
| Oturum açma ve güvenlik → SSL | **Aktif**, sertifika listesi **ANONYM** (ya da 3. adımdaki PSE) | aynısı |
| Oturum açma ve güvenlik → Hedef için yetki (Authorization for Destination) | `ZCHE_NETGSM` (önerilir, aşağıya bakın) | `ZCHE_NETGSM_EXT` |

Başka adlar da olur; ekrandaki *SM59 hedefi* alanlarına yazarsınız.

SAP şifreyi kendi güvenli deposunda saklar. Program şifreyi hiç okumaz; SM59 onu her isteğe HTTP Basic kimlik doğrulaması olarak ekler.

**Kim gönderebilir?** *Hedef için yetki* alanı doluysa SAP hedefi yalnızca **`S_ICF`** yetki nesnesinde `ICF_FIELD = DEST`, `ICF_VALUE = <hedef>` olan kullanıcılara açar. Program aynı kontrolü önizlemeden ve her çağrıdan önce kendisi de yapar; yetki eksikse açık bir mesaj (`NO_AUTH`) verir. `S_ICF`'i SMS gönderebilecek kişilerin ve batch kullanıcısının rolüne ekleyin. Programı kimin başlatabileceğini sınırlamak için `S_PROGRAM` ya da bir işlem kodu kullanın.

### 5. İlk çalıştırma: bağlantı testi

1. `ZCHE_SMS_NETGSM`'i başlatın (SA38), **Test: gönderici adlarını listele** işlemini seçip **Çalıştır**'a basın.
2. Beklenen: `00: Netgsm cevabı: tamam.`, ardından *Netgsm bağlantısı ve girişi çalışıyor.* ve onaylı gönderici adlarınızın listesi. Ücret yoktur.

| Cevap | Anlamı |
|---|---|
| `NO_DEST` | SM59 hedefi yok ya da G tipi değil. |
| `NO_AUTH` | Kullanıcınızda hedef için `S_ICF` yetkisi yok. |
| `NO_TRUST` | STRUST adımı eksik. Hiçbir şey gitmedi. |
| `NO_CONN` | Bağlantı yok: ağ, proxy ya da güvenlik duvarı. |
| `30` | Kullanıcı kodu ya da şifre yanlış, alt kullanıcının API erişimi yok ya da SAP'nin IP adresine izin verilmemiş. |

### 6. Önce önizleme, sonra gönderim

1. **SMS gönder**'i (ya da **OTP SMS gönder**'i) seçin. Bir ya da daha fazla **cep numarası**, **gönderici adı** ve en fazla dört **metin satırı** girin; her dolu satır SMS'te bir satır olur.
2. **Yalnızca önizleme** işaretli kalsın ve çalıştırın. Ekranda şunlar görünür:
   - karakter seti, karakter sayısı ve parça sayısı;
   - maskeli numaralar, reddedilen numaralar ve sebebi;
   - Netgsm'e gidecek isteğin kendisi (numaralar maskeli).

   *Netgsm'e de saydır* işaretlenirse Netgsm'in kendi hesabıyla karşılaştırırsınız (ücretsiz).
3. **Yalnızca önizleme** işaretini kaldırıp tekrar çalıştırın. Bir onay penceresi tahmini SMS kredisini gösterir. **Bu adım ücretlidir.**
4. **İş numarasını** (jobid) not edin. Sonra **Teslim raporu**'nu seçin, iş numarasını girip çalıştırın. Netgsm'e göre raporun görünmesi birkaç dakika sürebilir.

**İleri tarihli gönderim:** *Gönderim günü* ve *Gönderim saati* alanlarını doldurun (Türkiye saati, UTC+3). *Son deneme günü/saati* isteğe bağlıdır; boşsa Netgsm 21 saat boyunca dener. Vazgeçerseniz iş numarasıyla **İleri tarihli SMS'i iptal et**.

**Şablonlu SMS:** şablon numarasını **Şablonları listele** ile bulun. Sonra **Şablonlu SMS gönder**'i seçin, numarayı ve şablondaki her `${ad}` için bir `ad=değer` satırı girin. *Otomatik* karakter seti şablonları Türkçe olarak gönderir, çünkü program şablonun metnini göremez.

### 7. Uygulama günlüğü (isteğe bağlı)

SLG1'de kayıt tutmak için **SLG0**'da bir kez **`ZCHE_SMS`** günlük nesnesini oluşturun; alt nesne gerekmez. Nesne olmadan da program çalışır: sonuç yalnızca listede ve job günlüğünde olur, liste de bunu söyler. Günlükte işlem, kod, iş numarası, gönderici adı, karakter seti, parça sayısı ve **maskeli** numaralar bulunur. Metin yalnızca **Mesaj metnini de günlüğe yaz** işaretliyse yazılır. `PERFORM send_otp` ile gönderilen metinler kod oldukları için hiç yazılmaz.

## Kendi programlarınızdan kullanım

```abap
DATA lt_numbers TYPE string_table.
DATA lv_code    TYPE string.
DATA lv_jobid   TYPE string.
DATA lv_message TYPE string.

APPEND `0500 000 00 00` TO lt_numbers.          " uydurma numara
PERFORM send_sms IN PROGRAM zche_sms_netgsm IF FOUND
  USING    lt_numbers `ZFI_CLOSE hata verdi, SM37'ye bakın` `FIRMA`
           abap_false
  CHANGING lv_code lv_jobid lv_message.

IF lv_code <> '00'.
  " gönderilmedi ya da emin değiliz: lv_message hangisi olduğunu söyler
ENDIF.
```

| FORM | Ne için |
|---|---|
| `send_sms` | numaralar, metin, gönderici adı, önizleme |
| `send_sms_opt` | ayrıca karakter seti (`AUTO`, `TR`, `UNICODE`, `ASCII`), İYS tipi (`0`, `11`, `12`), metni günlüğe yazma |
| `send_sms_at` | ayrıca ileri tarih (`lif_sms=>ty_schedule`, Türkiye saati) ve referansınız |
| `send_otp` | tek numara, metin, gönderici adı, Türkçe harfleri sadeleştirme, önizleme |
| `send_template` | numaralar, şablon numarası, `ad=değer` satırları, gönderici adı, önizleme |
| `cancel_sms` | ileri tarihli gönderimin iş numarası |

- `00`: Netgsm isteği kabul etti, iş numarası dolu. Başka her kod "gönderilmedi" ya da "emin değiliz" demektir; mesaj açıklar.
- Önizleme işaretliyse her şey kontrol edilir, hiçbir şey gönderilmez (`DRY_RUN`).
- Onay penceresi ve liste yok. Hedefler `ZCHE_NETGSM` ve `ZCHE_NETGSM_EXT`; çağıran kullanıcının bunlar için `S_ICF` yetkisi olmalı.
- Günlük kaydı çağıranın LUW'unda yazılır. Çağıran ROLLBACK yaparsa kayıt da gider.

**Job adımı:** ekranı işlem ve değerleriyle varyant olarak kaydedin, *Yalnızca önizleme* işaretini kaldırın ve `ZCHE_SMS_NETGSM`'i bu varyantla job'a adım olarak ekleyin. Arka planda onay penceresi çıkmaz. Hata olursa job "İptal edildi" olur, böylece job izleme bunu görür.

## Karakterler, uzunluk ve maliyet

Netgsm dokümanına göre:

| Karakter seti | Tek parça | bölünürse parça başına | 6 parçada en fazla |
|---|---|---|---|
| GSM (Türkçe harf yok) | 160 | 153 | 912 |
| Türkçe (`TR`) | 155 | 148 | 883 |
| Unicode (ör. emoji) | 70 | 66 | 391 |
| OTP SMS | 160, yalnızca tek parça | | |

- `ç ğ ı ş Ğ İ Ş` ve `€ [ ] { } ^ ~ \ |` **iki** karakter sayılır.
- Harf içeren gönderici adında Netgsm metnin sonuna " B021" ekler (2016'dan beri BTK kuralı). Bu 5 karakter tutar ve program bunu hesaba katar; bu yüzden OTP'de 155 karakter kalır.
- **ASCII** seçeneği Türkçe harfleri göndermeden önce Latin harflerine çevirir (ç → c). Daha ucuzdur, ama metin değişir. Metin Türkçe harf içeriyorsa OTP SMS için bu seçenek gerekir.
- Netgsm **alıcı sayısı × parça sayısı** kadar ücret alır. Program bu tahmini gösterir; geçerli olan Netgsm faturasıdır. Şablonlu SMS'te parça sayısı gönderimden önce bilinmez.

## Sonuç kodları

Netgsm aynı kodu farklı servislerde farklı anlamda kullanıyor; program her birini bağlamına göre açıklar.

| Kod | Anlamı |
|---|---|
| `00` | Kabul edildi (gönderim) / tamam (diğerleri). |
| `20` | Metinde sorun var ya da metin çok uzun. |
| `30` | Kullanıcı kodu ya da şifre yanlış, API erişimi yok ya da IP adresine izin verilmemiş. |
| `40` | Gönderici adı tanımlı değil (gönderim, OTP). Gelen SMS'te: yeni mesaj yok. |
| `50`, `51` | Hesap İYS kontrollü gönderim yapamıyor / İYS marka kodu yok. OTP'de: numarayı kontrol edin. |
| `60` | Rapor: kayıt yok. İptal: böyle bir iş yok. OTP: OTP paketi yok. Gelen SMS: aralık 30 günden uzun. |
| `70` | Hatalı ya da eksik parametre. |
| `80` | Sınır aşıldı. |
| `85` | Aynı numaraya bir dakikada 20'den fazla iş. |
| `100`–`110` | Netgsm sistem hatası. |
| `NOT_FOUND`, `UNAUTHORIZED`, `BAD_REQUEST` | Şablon: böyle bir numara yok / izin yok / eksik değer. |
| `DRY_RUN` | Önizleme: her şey kontrol edildi, hiçbir şey gönderilmedi. |
| `BAD_NUMBER`, `BAD_TEXT`, `BAD_INPUT` | Program Netgsm'i çağırmadan reddetti. |
| `NO_DEST`, `NO_AUTH` | SM59 hedefi yok ya da tipi yanlış / `S_ICF` yetkisi yok. |
| `NO_TRUST` | Sertifikaya güvenilmiyor (STRUST). Hiçbir şey gitmedi. |
| `NO_CONN` | Cevap gelmedi. **SMS gitmiş de olabilir, gitmemiş de**: tekrar göndermeden önce teslim raporuna ya da Netgsm paneline bakın. |
| `HTTP_ERROR`, `BAD_REPLY` | Netgsm HTTP hatasıyla ya da programın okuyamadığı bir şeyle cevap verdi. |

## Neler doğrulandı

7 Kasım 2026'da SAP ABAP Platform deneme sistemi A4H'de (SAP_BASIS 816):

- abaplint 7.00 modunda bulgu vermedi. Program uyarısız aktifleşiyor ve birim testlerinin **50'si de** geçiyor.
- Birim testleri programın kurduğu her isteği ve Netgsm dokümanındaki her cevabı kapsıyor: gönderim, ileri tarihli gönderim, OTP, şablon, iptal, rapor, istatistik, gelen SMS, gönderici adları, şablon listesi, uzunluk. Yollar, gövdeler, kodlar, maskeleme ve yerel kontroller test ediliyor.
- Programın seçim ekranı üzerinden (`SUBMIT` ile değer vererek) çalıştırılanlar:
  - Önizlemeler: referanslı ileri tarihli gönderim, OTP SMS ve şablonlu SMS.
  - Türkçe harf içeren OTP metni beklendiği gibi reddedildi.
  - Tek tarihli rapor sorgusu beklendiği gibi reddedildi.
- Başka bir programdan `PERFORM send_sms`: hedef yokken `NO_DEST`, numara yokken `BAD_NUMBER`.
- SM59 üzerinden `api.netgsm.com.tr` ve `ext-api.netgsm.com.tr` adreslerine gerçek HTTPS çağrıları TLS el sıkışmasına kadar ulaştı. Deneme sisteminde USERTrust kökü olmadığı için `NO_TRUST` ile düştüler. 3. adımdaki bilgi buradan geliyor.

**Henüz doğrulanmadı:**

- Gerçek bir Netgsm hesabından gelen herhangi bir cevap: gönderim, OTP, rapor, istatistik, gelen SMS, şablonlar, uzunluk, iptal.
- Ekranın SAP GUI'de alanları işleme göre gizleyip göstermesi. Yalnızca `SUBMIT` ile değer verilerek çalıştırıldı.
- 7.00 sürümünün kendisi. Yalnızca söz dizimi 7.00'a göre kontrol edildi.
- Netgsm dokümanından alınan, denenmemiş bilgiler:
  - v2'nin gönderici adında büyük/küçük harf ayırıp ayırmadığı;
  - tek istekte en fazla kaç alıcı olabileceği (program 100'e izin veriyor);
  - teslim raporunun OTP iş numaralarını da kapsayıp kapsamadığı;
  - istatistik sorgusunda saatsiz gönderim tarihinin çalışıp çalışmadığı;
  - rapor sorgu sınırı (doküman hem dakikada 10 hem 60 diyor).

## Neden Netgsm REST v2, neden v3 değil

Netgsm'in iki SMS API'si var. Yeni olan v3, token almak için şifrenin bir JSON gövdesine yazılmasını istiyor. Bunu SM59 yapamaz, yani kodun şifreyi okuması gerekirdi. v2 ise HTTP Basic kimlik doğrulamasını kabul ediyor ve bunu SM59 kendisi gönderiyor. Böylece şifre koddan uzak kalıyor. Netgsm'in JavaScript SDK'sı v2 için "legacy" diyor, ama dokümanda bir bitiş tarihi yok.

## Kaynaklar

- Netgsm dokümanı (REST v2): <https://www.netgsm.com.tr/dokuman/>
- Netgsm SMS API v3 dokümanı: <https://api-docs.netgsm.com.tr/>
- [DESIGN.md](DESIGN.md): tasarım kararları

---

[MIT lisansı](LICENSE) · Netgsm ile bağlantılı değildir · [Sorunlar ve geri bildirim](https://github.com/Cheditte/abap-sms-netgsm/issues)
