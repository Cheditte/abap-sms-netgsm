# abap-sms-netgsm

[Türkçe](README.md) · [English](README.en.md)

![SAP’den Netgsm üzerinden telefona SMS gönderen abap-sms-netgsm programı](docs/img/abap-sms-netgsm-cover.jpg)

SAP’de bir belge hazır olduğunda ilgili kişiye SMS ile haber verebilirsiniz. `ZCHE_SMS_NETGSM` programında alıcıları ve metni girersiniz. Önizleme kaç alıcının geçerli olduğunu ve mesajın kaç SMS parçası tutacağını gösterir.

[SAP’de örnek bir SMS hazırlayın](WALKTHROUGH.tr.md#6-önce-önizleme-sonra-gönderim) · [Alıcının telefonundaki örneği görün](WALKTHROUGH.tr.md#alıcı-telefonunda-ne-görür)

## Ne yapmak istiyorsunuz?

| Amaç | Nereden başlamalı? |
|---|---|
| Netgsm hesabını ve SAP bağlantısını hazırlamak | [Kurulum rehberi](WALKTHROUGH.tr.md) |
| Bir kişiye, bir listeye, ileri tarihli veya şablonlu SMS hazırlamak | [Önizleme ve gönderim](WALKTHROUGH.tr.md#6-önce-önizleme-sonra-gönderim) |
| Tek kullanımlık kod göndermek | OTP SMS paketini seçin ve tek alıcılı önizlemeyi kullanın. [Rehber](WALKTHROUGH.tr.md) |
| Teslim durumuna, gelen SMS’lere veya bir işin istatistiğine bakmak | İlgili işlemi seçin. Tarih aralığıyla sorgularken iki tarihi de girin. [Sonuç kodları](WALKTHROUGH.tr.md#sonuç-kodları) |
| Kendi ABAP programımdan çağırmak | [Önizleme ile PERFORM örneği](WALKTHROUGH.tr.md#kendi-programlarınızdan-kullanım) |
| Gerçek hesapta hangi kontrollerin geçtiğini görmek | [Test sonuçları ve sınırlar](VALIDATION.tr.md) |

## İlk deneme

1. **Netgsm.** Gönderici adı başvurusunu erken başlatın. Belgeler ve KEP ile iletim gerekir, onay günler sürebilir. API alt kullanıcısının şifresini ve SAP sunucusunun çıkış IP iznini hazırlayın.
2. **SAP.** Programı SE38’de aktifleştirin. STRUST’ta sertifika zincirini, SM59’da `ZCHE_NETGSM` bağlantısını hazırlayın. Şablon işlemleri ayrıca `ZCHE_NETGSM_EXT` hedefini kullanır. [Program kaynağı](src/zche_sms_netgsm.prog.abap)
3. **Ücretsiz kontrol.** SA38’de `ZCHE_SMS_NETGSM` → gönderici adlarını listeleme işlemini çalıştırın. `00` ve boş liste bağlantının çalıştığını gösterir. Gönderici adı onaylanana kadar gönderimler `40` ile reddedilir.

## Doğrulama

A4H/001’de (SAP_BASIS 816) 50 birim testi geçti. Gerçek hesapta iki HTTPS hedefine erişim, şablon listesi ve karakter sayımı doğrulandı. Test hesabında onaylı gönderici adı bulunmadığı için telefona SMS teslimi doğrulanamadı. [Test sonuçları](VALIDATION.tr.md) · [Değişiklikler](CHANGELOG.md) · [MIT lisansı](LICENSE)
