# Değişiklikler

## Henüz yayımlanmayanlar

- OTP metni, eski varyantlarda metin kaydı açıkken bile SAP uygulama günlüğüne, sonuç listesine ve bu listenin makara (spool) çıktısına yazılmaz. Standart SMS için isteğe bağlı metin kaydı sürüyor.
- SAP_BASIS 7.00 için iç içe metot çağrısı bir ara değişken kullanacak şekilde düzeltildi. [`086925f`](https://github.com/Cheditte/abap-sms-netgsm/commit/086925f50fe9a4e86f0c916721c6df2b2fbb7c03)

- Türkçe ve İngilizce kurulum rehberlerine A4H ekranları, temsili telefon görünümü ve gerçek Netgsm hesabıyla yapılan kontroller eklendi.

- Netgsm HTTP 406 döndürdüğünde, yanıt gövdesinde `00` veya `30` gibi okunabilir bir sonuç kodu varsa program bu kodu gösterir. Kod okunamıyorsa `HTTP_ERROR` döner. Bu düzeltme ilk kez 50 birim testini içeren pakette kontrol edildi (`83f5c20`).

## 0.2.0

- `ZCHE_SMS_NETGSM` ile standart, ileri tarihli, OTP ve şablonlu SMS hazırlama ve önizleme eklendi. Gönderimden önce parça sayısı ve maskeli alıcılar görülebilir (`b5b7e02`).
- Gönderici adları, şablonlar, karakter sayıları, teslim raporları, iş istatistikleri ve gelen SMS’ler sorgulanabilir. İleri tarihli gönderim iş numarasıyla iptal edilebilir.
- REST v2 bağlantısında SM59 kimlik bilgileri kullanılır. Diğer ABAP programları alt yordamları doğrudan çağırabilir.
