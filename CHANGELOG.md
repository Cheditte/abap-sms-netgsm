# Değişiklikler

## Henüz yayımlanmayanlar

- OTP metni, eski varyantlarda günlük seçeneği açıkken de SAP uygulama günlüğünden ve önizleme çıktısından çıkarıldı. Netgsm hata ayrıntıları OTP içeriğini geri yansıtamaz. Standart SMS için isteğe bağlı metin kaydı sürüyor.

- Türkçe ve İngilizce kurulum rehberlerine A4H ekranları, temsili telefon görünümü ve gerçek Netgsm hesabıyla yapılan kontroller eklendi.

- Netgsm HTTP 406 döndürdüğünde, yanıt gövdesinde `00` veya `30` gibi okunabilir bir sonuç kodu varsa program bu kodu gösterir. Kod okunamıyorsa `HTTP_ERROR` döner. Bu düzeltme ilk kez 50 birim testini içeren pakette kontrol edildi (`83f5c20`).

## 0.2.0

- `ZCHE_SMS_NETGSM` ile standart, ileri tarihli, OTP ve şablonlu SMS hazırlama ve önizleme eklendi. Gönderimden önce parça sayısı ve maskeli alıcılar görülebilir (`b5b7e02`).
- Gönderici adları, şablonlar, karakter sayıları, teslim raporları, iş istatistikleri ve gelen SMS’ler sorgulanabilir. İleri tarihli gönderim iş numarasıyla iptal edilebilir.
- REST v2 bağlantısında SM59 kimlik bilgileri kullanılır. Diğer ABAP programları alt yordamları doğrudan çağırabilir.
