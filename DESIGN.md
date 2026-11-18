# Tasarım: SAP'den Netgsm ile SMS (çalışma adı `ZCHE_SMS_NETGSM`)

Bu belge v0.2 için alınan tasarım kararlarını ve ilk A4H denemelerini kaydeder. Daha sonra gerçek Netgsm hesabında bağlantı, şablon listesi ve karakter sayımı doğrulandı. [Güncel test sonuçları](VALIDATION.tr.md)

Onaylanan kararlar: REST v2, tek program + dış `PERFORM`/`SUBMIT`, standart `S_ICF` DEST yetkisi, günlükte metin varsayılan olarak yok, v0.1'de yalnızca Türkiye cep numaraları.

## 1. Amaç

SAP'den Netgsm üzerinden SMS göndermek. Middleware gerekmez, SAP doğrudan Netgsm'in HTTPS API'sini çağırır.

| Kullanım | Nasıl |
|---|---|
| Bir iş (job) bittiğinde ya da hata verdiğinde nöbetçiye SMS | Programı job adımı olarak ekleyin (varyantta numara ve metin), ya da kendi programınızdan `SUBMIT` ile çağırın |
| Bir Z programın içinden SMS (sonucu da görmek isteyen) | Dış `PERFORM ... IN PROGRAM zche_sms_netgsm` ile çağrılabilen bir giriş noktası (bkz. 4. bölüm) |
| Deneme | Seçim ekranı: numara, metin, **önizleme (dry-run, varsayılan açık)**, gerçek gönderim, teslim raporu sorgusu |

**Kapsam dışı (v0.1):** toplu kampanya gönderimi, ileri tarihli gönderim (`startdate`), yurt dışı numaralar, gelen SMS, OTP. Ticari ileti (İYS) desteklenir ama izin (onay) yönetimi kullanıcının sorumluluğundadır.

## 2. Kısıtlar (önceki projelerle aynı çizgi)

- **Tek program**, kopyala-yapıştır kurulum, özel DDIC yok. abapGit isteğe bağlı.
- **ABAP 7.00 klasik söz dizimi**, abaplint `v700` ile kontrol, satırlar en fazla 72 sütun.
- **Kimlik bilgisi kodda, tabloda, varyantta yok.** Yalnızca SM59'da (3. bölüm).
- **Ekran dili.** Bu depodaki `lcl_text`, Türkçe SAP oturumunda Türkçe, diğer oturumlarda İngilizce metin gösterir. Rehberdeki Türkçe önizleme, A4H’de denenen yerel Türkçe sürümden alınmıştır.
- **Birim testleri gerçek SMS göndermez:** HTTP katmanı bir arayüzün arkasında, testler sahte (test double) kullanır.

## 3. Netgsm API'si: hangisi ve neden

Netgsm'in bugün iki resmi SMS API'si var (kaynaklar 9. bölümde):

| | REST v2 | SMS API v3 |
|---|---|---|
| Adres | `https://api.netgsm.com.tr/sms/rest/v2/send` | `https://ext-api.netgsm.com.tr/sms/v3/send` |
| Kimlik doğrulama | **HTTP Basic** (kullanıcı kodu + alt kullanıcı şifresi) | Önce `/auth/v3/token`'a JSON gövdede kullanıcı adı ve şifre, sonra Bearer token |
| Hatalar | HTTP 200 + gövdede `code` (`00`, `30`, `40`...) | Gerçek HTTP durum kodları |
| Durum | Resmi JS SDK'sı v2'yi "legacy" diye anıyor; dokümanda kullanımdan kaldırma tarihi yok | Yeni |

**Öneri: REST v2.** Tek sebep güvenlik kuralımız: v2'de şifreyi SM59 hedefi **Basic Authentication** olarak kendisi gönderir, ABAP kodu şifreyi hiç görmez (abap-graph'taki client secret ile aynı yöntem). v3'te şifre JSON gövdeye yazılmak zorunda; bunu SM59 yapamaz, yani kodun şifreyi bir yerden okuması gerekir. v3'e geçiş, Netgsm v2 için tarih verirse ayrı bir sürümde ele alınır; HTTP katmanı arayüz arkasında olduğu için gönderim mantığı değişmez.

### SM59 hedefi `ZCHE_NETGSM` (tip G)

| Alan | Değer | Nereden |
|---|---|---|
| Host / Port | `api.netgsm.com.tr` / `443` | Netgsm dokümanı |
| Path prefix | boş | Program `/sms/rest/v2/send`, `/report`, `/msgheader` yollarını kendisi gönderir (abap-graph'taki gibi) |
| SSL | Aktif, `ANONYM` SSL istemci PSE'si; STRUST'ta kök sertifika **USERTrust RSA Certification Authority** (A4H'de denendi, bkz. 11. bölüm) | Basis |
| Logon & Security → Basic | Kullanıcı = Netgsm kullanıcı kodu (ör. `312XXXXXXX`), şifre = **API tipi alt kullanıcının** şifresi | Netgsm paneli: Abonelik İşlemleri → Alt Kullanıcı Hesapları |
| Authorization for Destination | `ZCHE_NETGSM` (önerilir, bkz. 7. bölüm) | Basis |

Netgsm tarafında ayrıca: **gönderici adı (başlık)** panelde tanımlı ve onaylı olmalı; **API IP erişim kısıtı** açıksa SAP sunucusunun internete çıktığı IP eklenmeli (yoksa kod `30`).

## 4. Program yapısı

Tek dosya `ZCHE_SMS_NETGSM` (yürütülebilir program), içinde yerel sınıflar:

| Parça | Görev |
|---|---|
| `lif_sms` | Tipler, sabitler, sonuç kodları |
| `lcl_sms_phone` | Numara normalleştirme ve maskeleme |
| `lcl_sms_text` | Karakter seti seçimi, uzunluk ve parça (segment) hesabı |
| `lcl_sms_json` | JSON yazma/okuma (7.00'da `/ui2/cl_json` yok; abap-graph'taki okuyucunun sadeleştirilmişi) |
| `lif_sms_http` / `lcl_sms_http` | SM59 üzerinden HTTP; testte sahtesi kullanılır |
| `lcl_sms_netgsm` | `send( )`, `report( )`, `headers( )`: istek kurma, cevabı yorumlama, hata metinleri |
| `lcl_sms_log` | Uygulama günlüğü (SLG1) ve ekran/job günlüğü |
| Seçim ekranı + `FORM send_sms` | Deneme ekranı, job adımı ve dış `PERFORM` giriş noktası |

**Başka programdan çağırma (dış PERFORM):**

```abap
DATA lt_numbers TYPE string_table.
DATA lv_code TYPE string.     " Netgsm kodu ya da yerel hata kodu
DATA lv_jobid TYPE string.
DATA lv_message TYPE string.
APPEND `0500 000 00 00` TO lt_numbers.
PERFORM send_sms IN PROGRAM zche_sms_netgsm IF FOUND
  USING lt_numbers `Gece job'u hata verdi` `BASLIGIM` abap_false
  CHANGING lv_code lv_jobid lv_message.
```

Alternatif (daha sade, sonuç dönmez): `SUBMIT zche_sms_netgsm WITH ... AND RETURN`. İkisi de README'de örnekli. Fonksiyon modülü (RFC'den çağırmak isteyenler için) README'de isteğe bağlı küçük bir sarmalayıcı olarak verilir; kurulumun parçası değildir.

## 5. Kurallar

**Numara normalleştirme.** Boşluk, tire, nokta ve parantez atılır. Kabul edilenler: `+90 5xx…`, `0090 5xx…`, `90 5xx…`, `0 5xx…`, `5xx…`. Sonuç Netgsm'in istediği biçimde **10 hane, `5` ile başlar**. Diğer her şey (sabit hat, eksik hane, harf, yurt dışı) gönderimden önce satır bazında reddedilir, sebebiyle. Aynı numara iki kez verilirse bir kez gönderilir. Ekranda ve günlükte numara maskeli görünür: `5** *** ** 34`.

**Türkçe karakter ve uzunluk.** Kodlama seçeneği: `AUTO` (varsayılan), `TR`, `UNICODE`, `ASCII`.
- `AUTO`: metinde herhangi bir Türkçe harf (`ç ğ ı ö ş ü`, büyükleri dahil) varsa `TR`, çünkü Netgsm'in varsayılan modu Türkçe harfleri Latin harflerine çevirebiliyor (v3 dokümanı); GSM alfabesi + Türkçe tabloda olmayan karakter (ör. emoji) varsa `UNICODE`; yoksa varsayılan (Netgsm'in `UTF-8` dediği düz GSM).
- `ASCII`: Türkçe harfleri Latin karşılığına çevirir (ç→c), daha ucuz; metni bilerek değiştirir.
- Parça başına sınır (Netgsm `/length` dokümanı): GSM 160 / çok parçada 153; Türkçe 155 / 148; Unicode 70 / 66. `ç ğ ı ş Ğ İ Ş` ve GSM genişletme karakterleri (`€ [ ] { } ^ ~ \ |`) 2 sayılır. Alfanümerik başlıkta Netgsm metne " B021" (5 karakter) ekler, hesaba katılır.
- **En fazla 6 parça.** Aşan metin gönderilmez (Netgsm de `20` döner). Önizleme parça sayısını ve kalan karakteri gösterir. Bizim hesabımız tahmindir; kesin sayı Netgsm'in faturasıdır.

**Ticari ileti (İYS).** `iysfilter`: `0` bilgilendirme (varsayılan), `11` ticari/bireysel, `12` ticari/tacir. Ekranda açıklamasıyla seçilir.

**Tekrar deneme yok.** SMS para tutar ve Netgsm aynı isteği iki kez alırsa iki kez gönderebilir. Zaman aşımında program "gönderilmiş olabilir, teslim raporuna bakın" der, yeniden göndermez.

**Teslim raporu.** `POST /report` ile `jobid` listesi (istek başına en fazla 50). Her numara için durum (bekliyor, iletildi, zaman aşımı, hatalı numara, kara liste, İYS reddi...) ve operatör hata kodu metne çevrilir. Rapor birkaç dakika gecikebilir; gönderimden hemen sonra beklemez, ekrandaki "Rapor sorgula" ya da ayrı bir job adımıyla sorgulanır.

## 6. Önizleme (dry-run)

Seçim ekranında **varsayılan açık**; API'de `iv_dry_run`. Normalleştirme, uzunluk/parça hesabı, yetki kontrolü ve SM59 hedefinin varlığı kontrol edilir, gönderilecek JSON gösterilir (numaralar maskeli, şifre zaten kodda yok). **Netgsm'e hiçbir istek gitmez.** Gerçek gönderim ekranda ayrıca bir onay penceresi açar (arka planda pencere yok).

## 7. Yetki: kim gönderebilir?

Özel yetki nesnesi yaratmamak için SAP'nin standart yolu: SM59'da hedefin **Authorization for Destination** alanına `ZCHE_NETGSM` yazılır; SAP bağlantı açarken `S_ICF` (`ICF_FIELD = DEST`, `ICF_VALUE = ZCHE_NETGSM`) kontrol eder. Program aynı kontrolü gönderimden (ve önizlemeden) önce kendisi de yapar ki hata erken ve anlaşılır gelsin. Yetkisi olmayan kullanıcı ne ekrandan ne `PERFORM` ile gönderebilir. Programı çalıştırma yetkisi ayrıca `S_PROGRAM` / işlem kodu ile kısıtlanabilir (README).

## 8. Günlük (log)

- **Varsayılan:** her gönderim için zaman, SAP kullanıcısı, çağıran program, maskeli numara, başlık, kodlama, parça sayısı, Netgsm kodu ve `jobid`. **Mesaj metni yazılmaz.**
- **İsteğe bağlı:** "metni de günlüğe yaz" seçeneği (varsayılan kapalı).
- **Nereye:** uygulama günlüğü (SLG1), nesne `ZCHE_SMS`. Bu nesne SLG0'da bir kez tanımlanırsa kullanılır (DDIC değil, bir özelleştirme kaydı); tanımlı değilse günlük yalnızca ekrana / job günlüğüne gider ve program bunu söyler. Ayrıca job'da her sonuç job günlüğüne mesaj olarak düşer; hata job'u "İptal edildi" yapar (TCMB aracıyla aynı davranış).

## 9. Kaynaklar ve doğrulanamayanlar

Kaynaklar (7 Kasım 2026'da okundu): v2 dokümanı `https://www.netgsm.com.tr/dokuman/`; v3 dokümanı `https://api-docs.netgsm.com.tr/` (token sayfasında şifrenin JSON gövdede gittiği doğrudan okundu); resmi JS SDK `github.com/netgsm/netgsm-sms-js`.

**Doğrulanamadı (gerçek hesapla denenene kadar varsayım):**
- v2'nin `90…` ya da `0…` ile başlayan numarayı kabul edip etmediği (biz zaten 10 haneye çeviriyoruz).
- v2'de tek istekte en fazla kaç alıcı olabileceği. v0.1 istek başına 100 alıcıyla sınırlar.
- v2'nin başlıkta büyük/küçük harf ayrımı yapıp yapmadığı (v3 yapıyor). Program başlığı olduğu gibi gönderir.
- " B021" ekinin her alfanümerik başlıkta mı yoksa yalnızca ticari iletide mi eklendiği.
- Rapor sorgu limiti: dokümanda hem "dakikada 60" hem "dakikada 10" geçiyor.
- v2 için resmi bir kullanımdan kaldırma tarihi.
- Netgsm'in sunucu sertifikasının hangi kök sertifikaya bağlandığı (STRUST için); A4H'de denenip README'ye yazılacak.

## 10. Test planı

1. abaplint `v700` temiz; A4H'de derleme ve aktivasyon.
2. Birim testleri (sahte HTTP ile): numara normalleştirme, kodlama seçimi, uzunluk/parça sınırları (159/160/161, 6 parça sınırı), JSON gövdesi, cevap kodları `00/20/30/40/70/80/85`, rapor ayrıştırma, önizlemede HTTP çağrısı olmaması, yetki yoksa gönderim olmaması.
3. A4H'de SM59 hedefiyle bağlantı ve `/msgheader` (ücretsiz) çağrısı, Netgsm hesabı girildikten sonra.
4. **Tek gerçek gönderim** yalnızca sizin verdiğiniz numaraya ve sizin açık onayınızla (ücretli). Numara hiçbir dokümana ya da ekran görüntüsüne girmez.

## Onayınızı beklediğim kararlar

1. **REST v2** (Basic auth, şifre SM59'da) — v3 yerine.
2. **Tek program** + dış `PERFORM` / `SUBMIT` ile çağırma — abap-graph gibi ayrı bir core INCLUDE yerine.
3. Yetki için **standart `S_ICF` DEST** kontrolü — özel yetki nesnesi yerine.
4. Günlükte **metin varsayılan olarak yok**; SLG1 nesnesi `ZCHE_SMS` isteğe bağlı.
5. v0.1'de **yalnızca Türkiye cep numaraları**.

## 11. Uygulamada netleşenler (v0.1)

- **Tek program:** `src/zche_sms_netgsm.prog.abap`, 72 sütun, abaplint `v700` temiz. İsteğe bağlı abapGit dosyaları da var.
- **Giriş noktaları:** `FORM send_sms` (numaralar, metin, başlık, önizleme) ve tüm seçenekleriyle `FORM send_sms_opt` (karakter seti, İYS, metni günlüğe yazma).
- **Seçim ekranı metni:** 4 satır × 132 karakter; her dolu satır SMS'te bir satır olur. Daha uzun metinler koddan (`PERFORM`) gönderilir.
- **Sertifika:** A4H'de ilk HTTPS çağrısı `SSSLERR_PEER_CERT_UNTRUSTED` ile düştü. Zincir: `*.netgsm.com.tr` → Sectigo Public Server Authentication CA DV R36 → Sectigo Public Server Authentication Root R46 → **USERTrust RSA Certification Authority**. Program bu durumu ayrı bir kodla (`NO_TRUST`) bildirir ve "gitmiş olabilir" demez, çünkü el sıkışma bitmeden hiçbir istek gitmez. Diğer bağlantı hatalarında (`NO_CONN`) "gitmiş de olabilir, gitmemiş de" der.
- **JSON:** 7.00'da hazır ayrıştırıcı olmadığı için küçük bir okuyucu yazıldı (düz `yol = değer` listesi). HTML gibi JSON olmayan cevaplar `BAD_REPLY` olur.
- **A4H'de denenen:** 35/35 birim testi; seçim ekranından önizleme (Türkçe metin → `TR`, 54/883 karakter, 1 parça, maskeli numaralar, reddedilen sabit hat); dış `PERFORM` (`NO_DEST`, `BAD_NUMBER`); SM59 hedefi `ZCHE_NETGSM` (kullanıcı/şifre boş) ile gerçek bir TLS denemesi (`NO_TRUST`).
- **Bekleyen:** STRUST'a kök sertifika, SM59'a Netgsm hesabı, ardından onayınızla tek bir gerçek gönderim.

## 12. v0.2: Netgsm'in SMS servislerinin tamamı (7 Kasım 2026)

Kullanıcının isteği: "Netgsm üstünde yapılabilir her şeyi yapabilelim, ama test için yalnızca OTP SMS kullanalım."

**Eklenenler (hepsi REST v2, HTTP Basic, şifre SM59'da):**

| İşlem | Netgsm servisi | Not |
|---|---|---|
| İleri tarihli gönderim + referans | `/send` içinde `startdate`, `stopdate` (ddMMyyyyHHmm), `referansID` | Saatler Türkiye saati olarak girilir; program dönüştürmez |
| İptal | `POST /cancel` | |
| OTP SMS | `POST /otp` | Tek numara, tek parça, Türkçe harf yok (ö ü hariç); en fazla 160, harfli başlıkla 155 |
| Şablonlu SMS | `POST https://ext-api.netgsm.com.tr/sms/rest/v2/template/send` | **İkinci SM59 hedefi** `ZCHE_NETGSM_EXT`; tarih biçimi yyyy-MM-dd HH:mm; şablon metni görülemediği için AUTO = TR |
| Şablon listesi | `GET ext-api …/template/list` | |
| Netgsm'in uzunluk hesabı | `POST /length` | Kimlik doğrulama istemiyor; yine de aynı hedeften gider |
| Tarih aralıklı rapor | `/report` içinde `startdate`/`stopdate` (dd.MM.yyyy HH:mm:ss), sayfa | En fazla 3 ay (program 92 gün kontrol eder) |
| İstatistik | `POST /stats` | Başarılı cevapta `code` yok; `description = success` kabul edilir |
| Gelen SMS | `GET /inbox` | Tarihsiz sorgu yalnızca yeni mesajları döner ve onları "görüldü" yapar; ekranda uyarı var. Zaman (`kayittar`, ms) Türkiye saatine (UTC+3) çevrilir; numaralar varsayılan maskeli |

**Bilerek eklenmeyenler:** kara liste ve İYS adres yükleme/sorgulama (Netgsm şifreyi istek gövdesinde istiyor, SM59 yapamaz), gelen SMS'in URL'ye yönlendirilmesi ve İYS webhook (SAP'nin dışarıdan çağrı alması gerekir; ICF servisi ve sınıf ister), WhatsApp OTP ve sesli servisler (başka ürünler), eski XML servisleri.

**Ekran:** radyo düğmeleri yerine bir "İşlem" listesi; seçilen işleme göre alanlar `MODIF ID` ile gizlenir. Gizleme yalnızca `SUBMIT` ile denendi, SAP GUI'de görsel olarak henüz denenmedi.

**Kodlar artık servise göre okunuyor:** aynı Netgsm kodu farklı servislerde farklı anlama geliyor (ör. `60`: rapor "kayıt yok", iptal "böyle iş yok", OTP "paket yok", gelen SMS "aralık 30 günden uzun"). Program önce `<SERVİS>_<kod>` metnine, sonra genel `C<kod>` metnine bakar.

**Yeni FORM'lar:** `send_sms_at`, `send_otp`, `send_template`, `cancel_sms`. `send_sms` ve `send_sms_opt` aynı kaldı.

**A4H'de ayrıca denenen:** `ZCHE_NETGSM_EXT` (şifresiz) ile `ext-api.netgsm.com.tr` aynı `*.netgsm.com.tr` sertifikasını kullanıyor; tek kök sertifika (USERTrust) iki hedefe de yetiyor.
