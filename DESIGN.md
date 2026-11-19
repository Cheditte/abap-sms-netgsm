# Tasarım kararları

`ZCHE_SMS_NETGSM`, SAP uygulama sunucusundan Netgsm’e HTTPS üzerinden bağlanan tek bir ABAP raporudur. Türkiye cep numaralarına standart, ileri tarihli, OTP ve şablonlu SMS göndermek için kullanılır. [Kurulum ve kullanım](WALKTHROUGH.tr.md) · [Doğrulananlar ve açık testler](VALIDATION.tr.md)

## Bağlantı ve yetki

REST v2, SM59’un HTTP Basic kimlik doğrulamasını destekler. SAP parolayı hedefte tutar ve HTTP isteğine ekler. Standart işlemler `ZCHE_NETGSM`, şablon işlemleri `ZCHE_NETGSM_EXT` hedefini kullanır. Program bağlantı açmadan ve önizleme yapmadan önce hedefin G tipinde olduğunu ve çalıştıran kullanıcının hedef adına karşılık gelen `S_ICF` yetkisini denetler. Şablon kullanmayanların yalnız ilk hedefe ihtiyacı vardır. [SM59 ayarları](WALKTHROUGH.tr.md#sm59)

## Gönderim ve kayıt

- Program dışarıdan gelen telefon numaralarını Türkiye cep numarası biçimine dönüştürür, yinelenen alıcıları ayıklar ve sonuçta numaraları maskeler.
- Seçim ekranı önizlemeyle açılır. Standart SMS için isteğe bağlı **Netgsm’e de saydır** seçeneği ayrıca karakter sayımı sorgusu yapar. Ekrandan ücretli gönderimde kullanıcı tahmini krediyi görüp onay verir.
- Arka plan işleri ve diğer programlar `PERFORM send_sms`, `send_otp` veya `send_template` çağırır. Çağıran program sonuç kodunu, iş numarasını ve açıklamayı alır. Bağlantı kesilirse otomatik yeniden gönderim yapılmaz. [Arka plan örneği](WALKTHROUGH.tr.md#arka-plan)
- İsteğe bağlı `ZCHE_SMS` uygulama günlüğü, sonucu ve maskeli alıcıları kaydeder. Standart SMS metni için ayrıca seçim gerekir. OTP metni yalnızca gönderilecek isteğin hazırlanmasında kullanılır. Sonuç listesi, makara ve uygulama günlüğü OTP metnini içermez.

## Kurulum ve uyumluluk

Özel DDIC nesnesi gerekmez. Kaynak SE38’e kopyalanabilir veya abapGit ile kurulabilir. Kod klasik ABAP 7.00 sözdizimini hedefler. HTTP ve SM59 erişimi bir arayüz arkasındadır. Birim testleri sahte bir bağlantı kullanarak gönderim, rapor ve hata yanıtlarını denetler. Gerçek A4H ve Netgsm hesabıyla yapılan kontrollerin kapsamı [test sonuçlarında](VALIDATION.tr.md) yer alır.
