# Netgsm test sonuçları

[English](VALIDATION.md) · [Ana sayfa](README.md) · [Kurulum ve kullanım](WALKTHROUGH.tr.md)

A4H/001’de (SAP_BASIS 816) SMS önizlemesi ve Netgsm hesabına bağlantı doğrulandı. Hesabın onaylı gönderici adı yoktu. Gerçek OTP denemesinde Netgsm `40` döndürdü. Telefona SMS ulaşmadı ve bu deneme için ücret alınmadı.

## OTP günlük testi

20 Kasım 2026’da 51 birim testi Open ABAP çalıştırıcısı ve sahte Netgsm bağlantısıyla yerelde geçti. Yeni test önceki kodda başarısız oldu. Üç ek kontrolde uygulama günlüğüne iletilen satırlar incelendi. Metin kaydı açıkken OTP metni gizli kaldı ve standart SMS metni kaydedildi. Kayıt kapalıyken standart SMS metni de yazılmadı. Bu çalıştırmada Netgsm’e istek gönderilmedi. Aşağıdaki SAP sonuçları önceki sürüme aittir.

## SAP’de görülen sonuçlar

| Kontrol | Gözlenen sonuç |
|---|---|
| ABAP Unit | Beş sınıftaki 50 test geçti. Testler HTTP yanıtlarını taklit eder. [Test özeti](docs/img/S02-abap-unit.png) |
| SMS önizlemesi | `FIRMA` için `DRY_RUN`, bir geçerli alıcı ve bir SMS parçası. Sonuç ekranında numara maskeli. [Önizleme](docs/img/S11-preview.png) |
| Tek tarihli teslim raporu | Program ikinci tarihi istedi ve `BAD_INPUT` döndürdü. [Rapor ekranı](docs/img/S25-report-one-date.png) |
| Var olmayan işi iptal | Netgsm, örnek `123` iş numarası için `60` döndürdü. [İptal sonucu](docs/img/S23-cancel-unknown-job.png) |

## Gerçek Netgsm hesabıyla yapılan kontroller

| İşlem | Gözlenen sonuç |
|---|---|
| Bağlantı ve giriş | STRUST’ta kök sertifika eklendikten sonra iki HTTPS hedefine de bağlanıldı. İlk girişteki `30`, SAP sunucusunun çıkış IP adresi Netgsm’in izin listesine eklendikten sonra düzeldi. |
| Gönderici adları | `00` döndü. Onaylı ad listesi boştu. [Netgsm yanıtı](docs/img/S20-sender-names.png) |
| Şablonlar | Şablon servisinden `00` ve 51 şablon geldi. |
| Karakter sayımı | `ığüşöç` için metin 10 birim tuttu. Netgsm’in sayımı, harfli gönderici adına eklenen beş karakterle (` B021`) 15 oldu. |
| Teslim raporu ve gelen kutusu | Denenen tarih aralığında rapor `60` (kayıt yok), gelen SMS sorgusu `40` (mesaj yok) döndürdü. |

## Açık kalan doğrulamalar

- Standart, ileri tarihli, şablonlu ve OTP SMS’in telefona teslimi. [Telefon örneği](WALKTHROUGH.tr.md#alıcı-telefonunda-ne-görür) temsili olarak üretildi.
- Gerçek bir zamanlanmış işi iptal etme, iş istatistikleri ve OTP iş numarasının teslim raporunda görünmesi.
- Gönderici adının büyük/küçük harfe duyarlılığı, istekteki alıcı sayısı sınırı ve rapor sorgu sınırı.
- SAP_BASIS 7.00 üzerinde çalıştırma ve arka plan işinden gerçek gönderim.
