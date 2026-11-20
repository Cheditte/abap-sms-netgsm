*&---------------------------------------------------------------------*
*& ZCHE_SMS_NETGSM: send SMS from SAP through Netgsm
*& abap-sms-netgsm, https://github.com/Cheditte/abap-sms-netgsm
*& MIT License, Copyright (c) 2026 Ali Emre Altuntas
*&---------------------------------------------------------------------*
*& One program, nothing else to create: copy it into SE38 and activate.
*&
*& What it does, through Netgsm's SMS API v2
*& (https://www.netgsm.com.tr/dokuman/):
*&   SMS          send now or at a later time, n numbers
*&   OTP SMS      one number, one part, fast (needs an OTP package)
*&   Template SMS a template approved at Netgsm, with values
*&   Cancel       a scheduled SMS
*&   Report       delivery report by job ID or date range
*&   Statistics   parts, credits and status totals of a job
*&   Inbox        SMS sent to your Netgsm number
*&   Sender names, templates, length: lists and Netgsm's own count
*& Every send can be previewed first (default); nothing goes out.
*&
*& From your own program, with the result (FORMs at the end):
*&   PERFORM send_sms IN PROGRAM zche_sms_netgsm IF FOUND
*&     USING lt_numbers lv_text lv_header abap_false
*&     CHANGING lv_code lv_jobid lv_message.
*&
*& SM59 destinations of type G, SSL active, no path prefix, basic
*& authentication: user = Netgsm user code (subscriber number),
*& password = password of the API sub-user:
*&   ZCHE_NETGSM      host api.netgsm.com.tr, port 443
*&   ZCHE_NETGSM_EXT  host ext-api.netgsm.com.tr, port 443
*&                    (templates only)
*& The password stays in SM59; this program never sees it.
*& Who may use them: authorization object S_ICF, ICF_FIELD = DEST,
*& ICF_VALUE = the destination name.
*&
*& Written in classic ABAP (SAP_BASIS 7.00, ECC 6.0): no inline
*& declarations, no constructor expressions, no string templates.
*& Lines stay within 72 columns for the classic editor.
*&---------------------------------------------------------------------*
REPORT ZCHE_SMS_NETGSM LINE-SIZE 255.

TYPE-POOLS: ABAP, VRM.

*----------------------------------------------------------------------*
* Types and constants
*----------------------------------------------------------------------*
INTERFACE LIF_SMS.

  CONSTANTS VERSION TYPE STRING VALUE `0.2.0`.
  CONSTANTS DEFAULT_DESTINATION TYPE RFCDEST VALUE 'ZCHE_NETGSM'.
  " Netgsm serves templates from another host
  CONSTANTS DEFAULT_EXT_DESTINATION TYPE RFCDEST
            VALUE 'ZCHE_NETGSM_EXT'.
  CONSTANTS API_PATH TYPE STRING VALUE `/sms/rest/v2`.

  " Recipients per call; Netgsm documents no limit for v2, so we
  " stay small
  CONSTANTS MAX_RECIPIENTS TYPE I VALUE 100.
  " Netgsm: at most 6 parts (segments) per SMS
  CONSTANTS MAX_PARTS TYPE I VALUE 6.
  " Netgsm: at most 50 job IDs per report query
  CONSTANTS MAX_JOBIDS TYPE I VALUE 50.
  " Netgsm: report range at most 3 months, inbox range 30 days
  CONSTANTS MAX_REPORT_DAYS TYPE I VALUE 92.
  CONSTANTS MAX_INBOX_DAYS TYPE I VALUE 30.
  " Netgsm sends its times in Turkish time, UTC+3 all year
  CONSTANTS TURKEY_OFFSET_SECONDS TYPE I VALUE 10800.

  TYPES TY_ENCODING TYPE C LENGTH 7.
  " Character set: AUTO, TR and UNICODE are what you ask for, ASCII
  " turns Turkish letters into Latin ones first. GSM is the plain
  " GSM alphabet, chosen by AUTO when the text needs nothing else.
  CONSTANTS:
    BEGIN OF ENCODING,
      AUTO    TYPE TY_ENCODING VALUE 'AUTO',
      GSM     TYPE TY_ENCODING VALUE 'GSM',
      TURKISH TYPE TY_ENCODING VALUE 'TR',
      UNICODE TYPE TY_ENCODING VALUE 'UNICODE',
      ASCII   TYPE TY_ENCODING VALUE 'ASCII',
    END OF ENCODING.

  TYPES TY_IYS TYPE C LENGTH 2.
  " Netgsm iysfilter: 0 informational, 11 commercial to individuals,
  " 12 commercial to merchants
  CONSTANTS:
    BEGIN OF IYS,
      INFO       TYPE TY_IYS VALUE '0',
      INDIVIDUAL TYPE TY_IYS VALUE '11',
      MERCHANT   TYPE TY_IYS VALUE '12',
    END OF IYS.

  " What is done; Netgsm's codes mean different things per service
  TYPES TY_ACTION TYPE C LENGTH 8.
  CONSTANTS:
    BEGIN OF ACTION,
      SEND      TYPE TY_ACTION VALUE 'SEND',
      OTP       TYPE TY_ACTION VALUE 'OTP',
      TEMPLATE  TYPE TY_ACTION VALUE 'TEMPLATE',
      CANCEL    TYPE TY_ACTION VALUE 'CANCEL',
      REPORT    TYPE TY_ACTION VALUE 'REPORT',
      STATS     TYPE TY_ACTION VALUE 'STATS',
      INBOX     TYPE TY_ACTION VALUE 'INBOX',
      HEADERS   TYPE TY_ACTION VALUE 'HEADERS',
      TEMPLATES TYPE TY_ACTION VALUE 'TPLLIST',
      LENGTH    TYPE TY_ACTION VALUE 'LENGTH',
    END OF ACTION.

  " Result codes. Netgsm's own codes are two or three digits
  " ('00' = accepted); these are the program's own.
  CONSTANTS:
    BEGIN OF CODE,
      OK         TYPE STRING VALUE `00`,
      DRY_RUN    TYPE STRING VALUE `DRY_RUN`,
      BAD_INPUT  TYPE STRING VALUE `BAD_INPUT`,
      BAD_NUMBER TYPE STRING VALUE `BAD_NUMBER`,
      BAD_TEXT   TYPE STRING VALUE `BAD_TEXT`,
      NO_DEST    TYPE STRING VALUE `NO_DEST`,
      NO_AUTH    TYPE STRING VALUE `NO_AUTH`,
      NO_CONN    TYPE STRING VALUE `NO_CONN`,
      NO_TRUST   TYPE STRING VALUE `NO_TRUST`,
      HTTP       TYPE STRING VALUE `HTTP_ERROR`,
      BAD_REPLY  TYPE STRING VALUE `BAD_REPLY`,
    END OF CODE.

  " When to send, in Turkish time; an initial date means now
  TYPES:
    BEGIN OF TY_SCHEDULE,
      START_DATE TYPE D,
      START_TIME TYPE T,
      STOP_DATE  TYPE D,
      STOP_TIME  TYPE T,
    END OF TY_SCHEDULE.

  " A template value: name as in ${name}, and the value
  TYPES:
    BEGIN OF TY_PARAM,
      NAME  TYPE STRING,
      VALUE TYPE STRING,
    END OF TY_PARAM,
    TY_PARAMS TYPE STANDARD TABLE OF TY_PARAM WITH DEFAULT KEY.

  " One number as given and what became of it
  TYPES:
    BEGIN OF TY_RECIPIENT,
      INPUT  TYPE STRING,
      NUMBER TYPE STRING,
      MASKED TYPE STRING,
      OK     TYPE ABAP_BOOL,
      REASON TYPE STRING,
    END OF TY_RECIPIENT,
    TY_RECIPIENTS TYPE STANDARD TABLE OF TY_RECIPIENT
                  WITH DEFAULT KEY.

  " The text as it will be sent, and its size
  TYPES:
    BEGIN OF TY_TEXT_INFO,
      TEXT      TYPE STRING,
      ENCODING  TYPE TY_ENCODING,
      UNITS     TYPE I,
      MAX_UNITS TYPE I,
      SUFFIX    TYPE I,
      PARTS     TYPE I,
      OK        TYPE ABAP_BOOL,
      MESSAGE   TYPE STRING,
    END OF TY_TEXT_INFO.

  TYPES:
    BEGIN OF TY_RESULT,
      ACTION      TYPE TY_ACTION,
      CODE        TYPE STRING,
      MESSAGE     TYPE STRING,
      SENT        TYPE ABAP_BOOL,
      JOBID       TYPE STRING,
      DESCRIPTION TYPE STRING,
      HEADER      TYPE STRING,
      IYS         TYPE TY_IYS,
      RECIPIENTS  TYPE TY_RECIPIENTS,
      VALID       TYPE I,
      TEXT_INFO   TYPE TY_TEXT_INFO,
      TEMPLATE_ID TYPE I,
      SCHEDULE    TYPE TY_SCHEDULE,
      REFERENCE   TYPE STRING,
      " Request body with masked numbers, for the preview
      REQUEST     TYPE STRING,
      HTTP_STATUS TYPE I,
    END OF TY_RESULT.

  " Code and text of a call that returns nothing else (cancel)
  TYPES:
    BEGIN OF TY_ANSWER,
      CODE    TYPE STRING,
      MESSAGE TYPE STRING,
      JOBID   TYPE STRING,
    END OF TY_ANSWER.

  TYPES:
    BEGIN OF TY_REPORT_LINE,
      JOBID       TYPE STRING,
      NUMBER      TYPE STRING,
      STATUS      TYPE STRING,
      STATUS_TEXT TYPE STRING,
      OPERATOR    TYPE STRING,
      ERROR_CODE  TYPE STRING,
      ERROR_TEXT  TYPE STRING,
      DELIVERED   TYPE STRING,
      MSGLEN      TYPE STRING,
      REFERENCE   TYPE STRING,
    END OF TY_REPORT_LINE,
    TY_REPORT_LINES TYPE STANDARD TABLE OF TY_REPORT_LINE
                    WITH DEFAULT KEY,
    BEGIN OF TY_REPORT,
      CODE    TYPE STRING,
      MESSAGE TYPE STRING,
      LINES   TYPE TY_REPORT_LINES,
    END OF TY_REPORT.

  TYPES:
    BEGIN OF TY_STATS_LINE,
      STATUS      TYPE STRING,
      STATUS_TEXT TYPE STRING,
      TOTAL_SMS   TYPE STRING,
      TOTAL_PARTS TYPE STRING,
      CHARGE      TYPE STRING,
      STATEMENT   TYPE STRING,
      DOMESTIC    TYPE STRING,
    END OF TY_STATS_LINE,
    TY_STATS_LINES TYPE STANDARD TABLE OF TY_STATS_LINE
                   WITH DEFAULT KEY,
    BEGIN OF TY_STATS,
      CODE    TYPE STRING,
      MESSAGE TYPE STRING,
      LINES   TYPE TY_STATS_LINES,
    END OF TY_STATS.

  TYPES:
    BEGIN OF TY_INBOX_LINE,
      ID       TYPE STRING,
      JOBID    TYPE STRING,
      RECEIVED TYPE STRING,
      SENDER   TYPE STRING,
      OPERATOR TYPE STRING,
      TEXT     TYPE STRING,
    END OF TY_INBOX_LINE,
    TY_INBOX_LINES TYPE STANDARD TABLE OF TY_INBOX_LINE
                   WITH DEFAULT KEY,
    BEGIN OF TY_INBOX,
      CODE    TYPE STRING,
      MESSAGE TYPE STRING,
      LINES   TYPE TY_INBOX_LINES,
    END OF TY_INBOX.

  TYPES:
    BEGIN OF TY_HEADERS,
      CODE    TYPE STRING,
      MESSAGE TYPE STRING,
      NAMES   TYPE STRING_TABLE,
    END OF TY_HEADERS.

  TYPES:
    BEGIN OF TY_TEMPLATE,
      ID          TYPE STRING,
      TYPE        TYPE STRING,
      DESCRIPTION TYPE STRING,
      CONTENT     TYPE STRING,
      " name (TYPE, max. length), ...
      PARAMETERS  TYPE STRING,
      PUBLIC      TYPE STRING,
      REGISTERED  TYPE STRING,
    END OF TY_TEMPLATE,
    TY_TEMPLATE_LINES TYPE STANDARD TABLE OF TY_TEMPLATE
                      WITH DEFAULT KEY,
    BEGIN OF TY_TEMPLATES,
      CODE     TYPE STRING,
      MESSAGE  TYPE STRING,
      LINES    TYPE TY_TEMPLATE_LINES,
      PAGE     TYPE STRING,
      PAGES    TYPE STRING,
      TOTAL    TYPE STRING,
    END OF TY_TEMPLATES.

  " Netgsm's own count of a text
  TYPES:
    BEGIN OF TY_LENGTH,
      CODE       TYPE STRING,
      MESSAGE    TYPE STRING,
      PARTS      TYPE STRING,
      USED       TYPE STRING,
      LEFT       TYPE STRING,
      LEFT_PART  TYPE STRING,
      ENCODING   TYPE TY_ENCODING,
    END OF TY_LENGTH.

  TYPES:
    BEGIN OF TY_HTTP,
      STATUS TYPE I,
      REASON TYPE STRING,
      BODY   TYPE STRING,
    END OF TY_HTTP.

ENDINTERFACE.

*----------------------------------------------------------------------*
* Error inside the program; callers get a result code instead
*----------------------------------------------------------------------*
CLASS LCX_SMS DEFINITION INHERITING FROM CX_STATIC_CHECK FINAL.
  PUBLIC SECTION.
    DATA CODE TYPE STRING READ-ONLY.
    DATA TEXT TYPE STRING READ-ONLY.

    METHODS CONSTRUCTOR
      IMPORTING
        CODE     TYPE STRING OPTIONAL
        TEXT     TYPE STRING OPTIONAL
        PREVIOUS TYPE REF TO CX_ROOT OPTIONAL.

    METHODS IF_MESSAGE~GET_TEXT REDEFINITION.
ENDCLASS.

CLASS LCX_SMS IMPLEMENTATION.

  METHOD CONSTRUCTOR.

    SUPER->CONSTRUCTOR( PREVIOUS = PREVIOUS ).
    ME->CODE = CODE.
    ME->TEXT = TEXT.

  ENDMETHOD.

  METHOD IF_MESSAGE~GET_TEXT.

    RESULT = TEXT.
    IF RESULT IS INITIAL.

      RESULT = SUPER->IF_MESSAGE~GET_TEXT( ).

    ENDIF.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Texts in English and Turkish (logon language TR = Turkish). Set in
* code because a copy/paste installation carries no text elements.
*----------------------------------------------------------------------*
CLASS LCL_TEXT DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS GET
      IMPORTING
        IV_KEY         TYPE CSEQUENCE
        IV_1           TYPE CSEQUENCE OPTIONAL
        IV_2           TYPE CSEQUENCE OPTIONAL
        IV_3           TYPE CSEQUENCE OPTIONAL
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    CLASS-METHODS PICK
      IMPORTING
        IV_EN          TYPE CSEQUENCE
        IV_TR          TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

  PRIVATE SECTION.
    CLASS-METHODS LOOKUP
      IMPORTING
        IV_KEY         TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.
ENDCLASS.

CLASS LCL_TEXT IMPLEMENTATION.

  METHOD GET.

    DATA LV_VALUE TYPE STRING.

    RV_TEXT = LOOKUP( IV_KEY ).
    LV_VALUE = IV_1.
    REPLACE ALL OCCURRENCES OF '&1' IN RV_TEXT WITH LV_VALUE.
    LV_VALUE = IV_2.
    REPLACE ALL OCCURRENCES OF '&2' IN RV_TEXT WITH LV_VALUE.
    LV_VALUE = IV_3.
    REPLACE ALL OCCURRENCES OF '&3' IN RV_TEXT WITH LV_VALUE.

  ENDMETHOD.

  METHOD PICK.

    IF SY-LANGU EQ 'T'.

      RV_TEXT = IV_TR.

    ELSE.

      RV_TEXT = IV_EN.

    ENDIF.

  ENDMETHOD.

  METHOD LOOKUP.

    DATA: LV_EN TYPE STRING,
          LV_TR TYPE STRING.

    CASE IV_KEY.

*     Numbers

      WHEN 'NUM_CHARS'.

        LV_EN = `contains characters other than digits`.
        LV_TR = `rakam dışında karakter var`.

      WHEN 'NUM_FOREIGN'.

        LV_EN = `not a Turkish number (only +90 is supported)`.
        LV_TR = `Türkiye numarası değil (yalnızca +90)`.

      WHEN 'NUM_LENGTH'.

        LV_EN = `wrong number of digits`.
        LV_TR = `hane sayısı yanlış`.

      WHEN 'NUM_MOBILE'.

        LV_EN = `not a mobile number (must start with 5)`.
        LV_TR = `cep numarası değil (5 ile başlamalı)`.

      WHEN 'NUM_DUP'.

        LV_EN = `given twice; sent once`.
        LV_TR = `iki kez verilmiş; bir kez gönderilir`.

      WHEN 'NO_NUMBERS'.

        LV_EN = `No valid mobile number.`.
        LV_TR = `Geçerli cep numarası yok.`.

      WHEN 'TOO_MANY'.

        LV_EN = `At most &1 numbers per call.`.
        LV_TR = `Bir çağrıda en fazla &1 numara olabilir.`.
*     Header and text

      WHEN 'NO_HEADER'.

        CONCATENATE `Enter the sender name (header) exactly as it`
                    ` is approved in the Netgsm panel.`
          INTO LV_EN.
        CONCATENATE `Gönderici adını (başlık) Netgsm panelinde`
                    ` onaylandığı gibi girin.`
          INTO LV_TR.

      WHEN 'HEADER_LEN'.

        LV_EN = `The sender name must have 3 to 11 characters.`.
        LV_TR = `Gönderici adı 3 ile 11 karakter olmalı.`.

      WHEN 'NO_TEXT'.

        LV_EN = `The message text is empty.`.
        LV_TR = `Mesaj metni boş.`.

      WHEN 'TOO_LONG'.

        CONCATENATE `The text counts &1 characters; with this`
                    ` character set at most &2 fit into 6 parts.`
          INTO LV_EN.
        CONCATENATE `Metin &1 karakter sayılıyor; bu karakter`
                    ` setiyle 6 parçaya en fazla &2 sığar.`
          INTO LV_TR.

      WHEN 'TR_UNICODE'.

        CONCATENATE `The text has characters that the Turkish`
                    ` character set cannot send (for example`
                    ` emoji). Choose Unicode.`
          INTO LV_EN.
        CONCATENATE `Metinde Türkçe karakter setinin gönderemediği`
                    ` karakterler var (ör. emoji). Unicode seçin.`
          INTO LV_TR.

      WHEN 'BAD_ENC'.

        LV_EN = `Unknown character set &1.`.
        LV_TR = `Bilinmeyen karakter seti &1.`.

      WHEN 'BAD_IYS'.

        LV_EN = `Unknown IYS value &1; use 0, 11 or 12.`.
        LV_TR = `Bilinmeyen İYS değeri &1; 0, 11 ya da 12 olmalı.`.
*     Destination and authorization

      WHEN 'NO_DEST'.

        CONCATENATE `SM59 destination &1 does not exist. Create it`
                    ` as type G (HTTP connection to external`
                    ` server), host api.netgsm.com.tr, port 443,`
                    ` SSL active.`
          INTO LV_EN.
        CONCATENATE `SM59 hedefi &1 yok. G tipinde (dış sunucuya`
                    ` HTTP bağlantısı) oluşturun: host`
                    ` api.netgsm.com.tr, port 443, SSL aktif.`
          INTO LV_TR.

      WHEN 'DEST_TYPE'.

        LV_EN = `SM59 destination &1 has type &2; it must be G.`.
        LV_TR = `SM59 hedefi &1 &2 tipinde; G olmalı.`.

      WHEN 'NO_AUTH'.

        CONCATENATE `You may not use SM59 destination &1`
                    ` (authorization object S_ICF, ICF_FIELD DEST,`
                    ` ICF_VALUE &1).`
          INTO LV_EN.
        CONCATENATE `SM59 hedefi &1 için yetkiniz yok (yetki`
                    ` nesnesi S_ICF, ICF_FIELD DEST, ICF_VALUE &1).`
          INTO LV_TR.
*     Sending

      WHEN 'DRY_RUN'.

        LV_EN = `Preview only: nothing was sent to Netgsm.`.
        LV_TR = `Yalnızca önizleme: Netgsm'e hiçbir şey gitmedi.`.

      WHEN 'NO_CONN'.

        LV_EN = `No answer from Netgsm: &1`.
        LV_TR = `Netgsm'den cevap gelmedi: &1`.

      WHEN 'UNSURE'.

        CONCATENATE `The SMS may or may not have been sent: check`
                    ` the delivery report or the Netgsm panel`
                    ` before you send again.`
          INTO LV_EN.
        CONCATENATE `SMS gitmiş de olabilir, gitmemiş de: tekrar`
                    ` göndermeden önce teslim raporuna ya da Netgsm`
                    ` paneline bakın.`
          INTO LV_TR.

      WHEN 'NO_TRUST'.

        CONCATENATE `SAP does not trust the certificate of`
                    ` *.netgsm.com.tr, so nothing was sent. In`
                    ` STRUST, add the root certificate "USERTrust`
                    ` RSA Certification Authority" to the SSL client`
                    ` PSE of the destination (usually SSL client`
                    ` Anonymous).`
          INTO LV_EN.
        CONCATENATE `SAP *.netgsm.com.tr sertifikasına güvenmiyor,`
                    ` bu yüzden hiçbir şey gitmedi. STRUST'ta`
                    ` "USERTrust RSA Certification Authority" kök`
                    ` sertifikasını hedefin SSL istemci PSE'sine`
                    ` (genellikle SSL client Anonymous) ekleyin.`
          INTO LV_TR.

      WHEN 'HTTP'.

        LV_EN = `Netgsm answered with HTTP &1 &2.`.
        LV_TR = `Netgsm HTTP &1 &2 ile cevap verdi.`.

      WHEN 'BAD_REPLY'.

        LV_EN = `Netgsm's answer cannot be read: &1`.
        LV_TR = `Netgsm'in cevabı okunamadı: &1`.

      WHEN 'OTP_REPLY'.

        LV_EN = `Netgsm returned an unreadable OTP response.`.
        LV_TR = `Netgsm OTP yanıtı okunamadı.`.

      WHEN 'OTP_CONN'.

        LV_EN = `No response to the OTP request.`.
        LV_TR = `OTP isteğine yanıt alınamadı.`.
*     Netgsm codes. The same code can mean different things in
*     different services: <SERVICE>_<code> first, then C<code>.

      WHEN 'C00'.

        LV_EN = `Netgsm accepted the message.`.
        LV_TR = `Netgsm mesajı kabul etti.`.

      WHEN 'C00_OK'.

        LV_EN = `Netgsm answered: OK.`.
        LV_TR = `Netgsm cevabı: tamam.`.

      WHEN 'C01' OR 'C02'.

        LV_EN = `Accepted; Netgsm corrected the send date.`.
        LV_TR = `Kabul edildi; Netgsm gönderim tarihini düzeltti.`.

      WHEN 'C20'.

        CONCATENATE `Problem in the message text, or the text is`
                    ` longer than allowed.`
          INTO LV_EN.
        CONCATENATE `Mesaj metninde sorun var ya da metin izin`
                    ` verilenden uzun.`
          INTO LV_TR.

      WHEN 'C30'.

        CONCATENATE `Wrong user code or password, no API access`
                    ` for the sub-user, or the IP address of SAP is`
                    ` not allowed (Netgsm panel: API IP access).`
          INTO LV_EN.
        CONCATENATE `Kullanıcı kodu ya da şifre yanlış, alt`
                    ` kullanıcının API erişimi yok ya da SAP'nin IP`
                    ` adresine izin verilmemiş (Netgsm paneli: API`
                    ` IP erişim yönetimi).`
          INTO LV_TR.

      WHEN 'C40'.

        CONCATENATE `This sender name (header) is not defined on`
                    ` your Netgsm account.`
          INTO LV_EN.
        CONCATENATE `Bu gönderici adı (başlık) Netgsm hesabınızda`
                    ` tanımlı değil.`
          INTO LV_TR.

      WHEN 'C50'.

        LV_EN = `Your account cannot send IYS-checked messages.`.
        LV_TR = `Hesabınız İYS kontrollü gönderim yapamıyor.`.

      WHEN 'C51'.

        LV_EN = `No IYS brand code is defined for your account.`.
        LV_TR = `Hesabınızda İYS marka kodu tanımlı değil.`.

      WHEN 'C70'.

        LV_EN = `Invalid or missing parameter.`.
        LV_TR = `Hatalı ya da eksik parametre.`.

      WHEN 'C80'.

        LV_EN = `Sending limit exceeded.`.
        LV_TR = `Gönderim sınırı aşıldı.`.

      WHEN 'C85'.

        CONCATENATE `More than 20 jobs to the same number within`
                    ` one minute.`
          INTO LV_EN.
        CONCATENATE `Aynı numaraya bir dakikada 20'den fazla iş`
                    ` oluşturulamaz.`
          INTO LV_TR.

      WHEN 'C100'.

        LV_EN = `Netgsm system error (&1).`.
        LV_TR = `Netgsm sistem hatası (&1).`.

      WHEN 'OTP_20'.

        CONCATENATE `Problem in the text, or it is too long: an OTP`
                    ` SMS is one part without Turkish letters, at`
                    ` most 155 characters with a sender name that`
                    ` has letters.`
          INTO LV_EN.
        CONCATENATE `Metinde sorun var ya da metin uzun: OTP SMS`
                    ` Türkçe harf içermeyen tek parçadır, harfli`
                    ` gönderici adıyla en fazla 155 karakter.`
          INTO LV_TR.

      WHEN 'OTP_50'.

        CONCATENATE `Check the number: OTP SMS go only to Turkish`
                    ` mobile numbers.`
          INTO LV_EN.
        CONCATENATE `Numarayı kontrol edin: OTP SMS yalnızca`
                    ` Türkiye cep numaralarına gider.`
          INTO LV_TR.

      WHEN 'OTP_60'.

        LV_EN = `No OTP SMS package on your Netgsm account.`.
        LV_TR = `Netgsm hesabınızda OTP SMS paketi tanımlı değil.`.

      WHEN 'TPL_UNAUTHORIZED'.

        LV_EN = `Your account may not use this template.`.
        LV_TR = `Hesabınız bu şablonu kullanamıyor.`.

      WHEN 'TPL_NOT_FOUND'.

        LV_EN = `There is no template with this ID.`.
        LV_TR = `Bu numarada bir şablon yok.`.

      WHEN 'TPL_BAD_REQUEST'.

        LV_EN = `Values are missing for this template.`.
        LV_TR = `Bu şablon için eksik değer var.`.

      WHEN 'CANCEL_00'.

        LV_EN = `The scheduled SMS was cancelled.`.
        LV_TR = `İleri tarihli SMS iptal edildi.`.

      WHEN 'CANCEL_60'.

        LV_EN = `There is no job with this ID.`.
        LV_TR = `Bu numarada bir iş yok.`.

      WHEN 'REPORT_60'.

        LV_EN = `No records for these criteria (yet).`.
        LV_TR = `Bu kriterlere uyan kayıt (henüz) yok.`.

      WHEN 'REPORT_70'.

        CONCATENATE `Invalid or missing parameter, or the date`
                    ` range is longer than 3 months.`
          INTO LV_EN.
        CONCATENATE `Hatalı ya da eksik parametre ya da tarih`
                    ` aralığı 3 aydan uzun.`
          INTO LV_TR.

      WHEN 'REPORT_80'.

        CONCATENATE `Query limit: each job ID once a minute, 60`
                    ` queries a minute.`
          INTO LV_EN.
        CONCATENATE `Sorgu sınırı: her iş numarası dakikada bir`
                    ` kez, dakikada en fazla 60 sorgu.`
          INTO LV_TR.

      WHEN 'INBOX_40'.

        CONCATENATE `No messages. Without a date range each`
                    ` message is listed only once.`
          INTO LV_EN.
        CONCATENATE `Mesaj yok. Tarih aralığı verilmezse her mesaj`
                    ` yalnızca bir kez listelenir.`
          INTO LV_TR.

      WHEN 'INBOX_50'.

        LV_EN = `Wrong date format.`.
        LV_TR = `Tarih biçimi hatalı.`.

      WHEN 'INBOX_60'.

        LV_EN = `The date range is longer than 30 days.`.
        LV_TR = `Tarih aralığı 30 günden uzun.`.

      WHEN 'C_OTHER'.

        LV_EN = `Netgsm code &1 &2`.
        LV_TR = `Netgsm kodu &1 &2`.
*     Delivery status per number (report)

      WHEN 'S0'.

        LV_EN = `waiting`.
        LV_TR = `iletilmeyi bekliyor`.

      WHEN 'S1'.

        LV_EN = `delivered`.
        LV_TR = `iletildi`.

      WHEN 'S2'.

        LV_EN = `timed out`.
        LV_TR = `zaman aşımı`.

      WHEN 'S3'.

        LV_EN = `wrong or restricted number`.
        LV_TR = `hatalı ya da kısıtlı numara`.

      WHEN 'S4'.

        LV_EN = `not sent to the operator`.
        LV_TR = `operatöre gönderilemedi`.

      WHEN 'S11'.

        LV_EN = `rejected by the operator`.
        LV_TR = `operatör kabul etmedi`.

      WHEN 'S12'.

        LV_EN = `send error`.
        LV_TR = `gönderim hatası`.

      WHEN 'S13'.

        LV_EN = `duplicate`.
        LV_TR = `mükerrer gönderim`.

      WHEN 'S14'.

        LV_EN = `not enough credit`.
        LV_TR = `yetersiz kredi`.

      WHEN 'S15'.

        LV_EN = `number is blacklisted`.
        LV_TR = `numara kara listede`.

      WHEN 'S16'.

        LV_EN = `rejected by IYS`.
        LV_TR = `İYS reddetti`.

      WHEN 'S17'.

        LV_EN = `IYS error`.
        LV_TR = `İYS hatası`.

      WHEN 'S22'.

        LV_EN = `no permission for international SMS`.
        LV_TR = `yurt dışı gönderim izni yok`.
*     Operator error codes (report)

      WHEN 'E101'.

        LV_EN = `mailbox full`.
        LV_TR = `mesaj kutusu dolu`.

      WHEN 'E102'.

        LV_EN = `phone off or out of coverage`.
        LV_TR = `telefon kapalı ya da kapsama dışında`.

      WHEN 'E103'.

        LV_EN = `line busy`.
        LV_TR = `hat meşgul`.

      WHEN 'E104'.

        LV_EN = `line not active`.
        LV_TR = `hat aktif değil`.

      WHEN 'E105'.

        LV_EN = `wrong number`.
        LV_TR = `hatalı numara`.

      WHEN 'E106'.

        LV_EN = `blacklisted`.
        LV_TR = `kara listede`.

      WHEN 'E111'.

        LV_EN = `timed out`.
        LV_TR = `zaman aşımı`.

      WHEN 'E112'.

        LV_EN = `phone does not accept SMS`.
        LV_TR = `cihaz SMS almaya kapalı`.

      WHEN 'E113'.

        LV_EN = `phone does not support it`.
        LV_TR = `cihaz desteklemiyor`.

      WHEN 'E114'.

        LV_EN = `forwarding failed`.
        LV_TR = `yönlendirme başarısız`.

      WHEN 'E115'.

        LV_EN = `timeout at the operator of the number`.
        LV_TR = `hedef operatörde zaman aşımı`.

      WHEN 'E116'.

        LV_EN = `unknown subscriber`.
        LV_TR = `tanımlanamayan abone`.

      WHEN 'E117'.

        LV_EN = `illegal subscriber`.
        LV_TR = `yasa dışı abone`.

      WHEN 'E119'.

        LV_EN = `system error`.
        LV_TR = `sistemsel hata`.

      WHEN 'E_OTHER'.

        LV_EN = `operator or system error &1`.
        LV_TR = `operatör ya da sistem hatası &1`.

      WHEN 'NO_JOBS'.

        LV_EN = `Enter at least one Netgsm job ID.`.
        LV_TR = `En az bir Netgsm iş numarası (jobid) girin.`.

      WHEN 'TOO_MANY_JOBS'.

        LV_EN = `At most &1 job IDs per query.`.
        LV_TR = `Bir sorguda en fazla &1 iş numarası olabilir.`.
*     Application log

      WHEN 'LOG_SAVED'.

        LV_EN = `Saved in the application log (SLG1, object &1).`.
        LV_TR = `Uygulama günlüğüne yazıldı (SLG1, nesne &1).`.

      WHEN 'LOG_NONE'.

        CONCATENATE `Application log object &1 is not defined`
                    ` (SLG0); the result is only in this list and`
                    ` in the job log.`
          INTO LV_EN.
        CONCATENATE `Uygulama günlüğü nesnesi &1 tanımlı değil`
                    ` (SLG0); sonuç yalnızca bu listede ve job`
                    ` günlüğünde.`
          INTO LV_TR.

      WHEN 'LOG_SUMMARY'.

        LV_EN = `Header &1, character set &2, &3 part(s)`.
        LV_TR = `Başlık &1, karakter seti &2, &3 parça`.

      WHEN 'LOG_TEXT'.

        LV_EN = `Text: &1`.
        LV_TR = `Metin: &1`.
*     Screen

      WHEN 'T_MSG'.

        LV_EN = `Message`.
        LV_TR = `Mesaj`.

      WHEN 'T_RUN'.

        LV_EN = `What to do`.
        LV_TR = `Ne yapılacak`.

      WHEN 'C_TXT'.

        LV_EN = `Each filled line becomes one line of the SMS`.
        LV_TR = `Her dolu satır SMS'te bir satır olur`.

      WHEN 'S_NO'.

        LV_EN = `Mobile numbers`.
        LV_TR = `Cep numaraları`.

      WHEN 'P_HEAD'.

        LV_EN = `Sender name (header)`.
        LV_TR = `Gönderici adı (başlık)`.

      WHEN 'P_TXT1'.

        LV_EN = `Text, line 1`.
        LV_TR = `Metin, 1. satır`.

      WHEN 'P_TXT2'.

        LV_EN = `Text, line 2`.
        LV_TR = `Metin, 2. satır`.

      WHEN 'P_TXT3'.

        LV_EN = `Text, line 3`.
        LV_TR = `Metin, 3. satır`.

      WHEN 'P_TXT4'.

        LV_EN = `Text, line 4`.
        LV_TR = `Metin, 4. satır`.

      WHEN 'P_ENC'.

        LV_EN = `Character set`.
        LV_TR = `Karakter seti`.

      WHEN 'P_IYS'.

        LV_EN = `Message type (IYS)`.
        LV_TR = `İleti tipi (İYS)`.

      WHEN 'P_DRY'.

        LV_EN = `Preview only, send nothing`.
        LV_TR = `Yalnızca önizleme, gönderme`.

      WHEN 'P_LOGTX'.

        LV_EN = `Also log the message text`.
        LV_TR = `Mesaj metnini de günlüğe yaz`.

      WHEN 'S_JOB'.

        LV_EN = `Netgsm job IDs`.
        LV_TR = `Netgsm iş numaraları`.

      WHEN 'P_DEST'.

        LV_EN = `SM59 destination`.
        LV_TR = `SM59 hedefi`.

      WHEN 'ENC_AUTO'.

        LV_EN = `Automatic (Turkish only when needed)`.
        LV_TR = `Otomatik (gerekirse Türkçe)`.

      WHEN 'ENC_TR'.

        LV_EN = `Turkish characters (TR)`.
        LV_TR = `Türkçe karakterli (TR)`.

      WHEN 'ENC_UNICODE'.

        LV_EN = `Unicode (for example emoji)`.
        LV_TR = `Unicode (ör. emoji)`.

      WHEN 'ENC_ASCII'.

        LV_EN = `Turkish letters to Latin (c, g, s...)`.
        LV_TR = `Türkçe harfleri sadeleştir (c, g, s...)`.

      WHEN 'IYS_0'.

        LV_EN = `Informational (no IYS check)`.
        LV_TR = `Bilgilendirme (İYS kontrolü yok)`.

      WHEN 'IYS_11'.

        LV_EN = `Commercial, to individuals`.
        LV_TR = `Ticari, bireysel alıcı`.

      WHEN 'IYS_12'.

        LV_EN = `Commercial, to merchants`.
        LV_TR = `Ticari, tacir alıcı`.
*     List and popup

      WHEN 'L_PREVIEW'.

        LV_EN = `PREVIEW - nothing sent`.
        LV_TR = `ÖNİZLEME - hiçbir şey gönderilmedi`.

      WHEN 'L_SENT'.

        LV_EN = `SENT to Netgsm`.
        LV_TR = `Netgsm'e GÖNDERİLDİ`.

      WHEN 'L_NOT_SENT'.

        LV_EN = `NOT SENT`.
        LV_TR = `GÖNDERİLMEDİ`.

      WHEN 'L_RESULT'.

        LV_EN = `Result`.
        LV_TR = `Sonuç`.

      WHEN 'L_JOBID'.

        LV_EN = `Job ID`.
        LV_TR = `İş numarası`.

      WHEN 'L_HEADER'.

        LV_EN = `Sender name`.
        LV_TR = `Gönderici adı`.

      WHEN 'L_ENC'.

        LV_EN = `Character set`.
        LV_TR = `Karakter seti`.

      WHEN 'L_SIZE'.

        LV_EN = `&1 of &2 characters, &3 part(s)`.
        LV_TR = `&1 / &2 karakter, &3 parça`.

      WHEN 'L_SUFFIX'.

        CONCATENATE `(includes the 5 characters Netgsm adds to`
                    ` an alphanumeric sender name)`
          INTO LV_EN.
        CONCATENATE `(Netgsm'in harfli gönderici adına eklediği`
                    ` 5 karakter dahil)`
          INTO LV_TR.

      WHEN 'L_RCPT'.

        LV_EN = `Recipients: &1 valid, &2 rejected`.
        LV_TR = `Alıcılar: &1 geçerli, &2 reddedildi`.

      WHEN 'L_CREDITS'.

        LV_EN = `About &1 SMS credit(s)`.
        LV_TR = `Yaklaşık &1 SMS kredisi`.

      WHEN 'L_TEXT'.

        LV_EN = `Text as it will be sent`.
        LV_TR = `Gönderilecek metin`.

      WHEN 'L_REQUEST'.

        LV_EN = `Request to Netgsm (numbers masked)`.
        LV_TR = `Netgsm'e gidecek istek (numaralar maskeli)`.

      WHEN 'L_REPORT'.

        LV_EN = `Delivery report`.
        LV_TR = `Teslim raporu`.

      WHEN 'L_REPORT_COLS'.

        CONCATENATE `Job ID                      Number`
                    `          Status / error`
          INTO LV_EN.
        CONCATENATE `İş numarası                 Numara`
                    `          Durum / hata`
          INTO LV_TR.

      WHEN 'L_HEADERS'.

        LV_EN = `Sender names on the Netgsm account`.
        LV_TR = `Netgsm hesabındaki gönderici adları`.

      WHEN 'L_CONN_OK'.

        LV_EN = `Connection and logon to Netgsm work.`.
        LV_TR = `Netgsm bağlantısı ve girişi çalışıyor.`.

      WHEN 'POP_TITLE'.

        LV_EN = `Send SMS for real`.
        LV_TR = `Gerçek SMS gönderimi`.

      WHEN 'POP_QUESTION'.

        CONCATENATE `Send the SMS to &1 number(s) through Netgsm,`
                    ` about &2 SMS credit(s)? This costs money.`
          INTO LV_EN.
        CONCATENATE `SMS Netgsm üzerinden &1 numaraya gönderilsin`
                    ` mi (yaklaşık &2 SMS kredisi)? Ücretlidir.`
          INTO LV_TR.

      WHEN 'CANCELLED'.

        LV_EN = `Cancelled; nothing was sent.`.
        LV_TR = `İptal edildi; hiçbir şey gönderilmedi.`.

      WHEN 'IGNORED'.

        LV_EN = `Only single numbers are used; &1 entries ignored.`.
        LV_TR = `Yalnızca tek numaralar alınır; &1 giriş atlandı.`.
*     Version 0.2: actions, schedule, templates, OTP, lists

      WHEN 'OTP_ONE'.

        LV_EN = `An OTP SMS goes to exactly one number.`.
        LV_TR = `OTP SMS tam olarak bir numaraya gider.`.

      WHEN 'OTP_CHARS'.

        CONCATENATE `An OTP SMS cannot contain "&1": no Turkish`
                    ` letters, no emoji. Choose the character set`
                    ` "Turkish letters to Latin".`
          INTO LV_EN.
        CONCATENATE `OTP SMS "&1" içeremez: Türkçe harf ve emoji`
                    ` olmaz. "Türkçe harfleri sadeleştir" karakter`
                    ` setini seçin.`
          INTO LV_TR.

      WHEN 'OTP_LONG'.

        CONCATENATE `An OTP SMS is one part: at most &2`
                    ` characters, this text counts &1.`
          INTO LV_EN.
        CONCATENATE `OTP SMS tek parçadır: en fazla &2 karakter,`
                    ` bu metin &1 karakter.`
          INTO LV_TR.

      WHEN 'NO_TEMPLATE'.

        LV_EN = `Enter the template ID (see "List templates").`.
        LV_TR = `Şablon numarasını girin ("Şablonları listele").`.

      WHEN 'BAD_PARAM'.

        LV_EN = `Template value "&1" must look like name=value.`.
        LV_TR = `Şablon değeri "&1" ad=değer biçiminde olmalı.`.

      WHEN 'SCHED_NO_START'.

        LV_EN = `An end time needs a send date.`.
        LV_TR = `Son deneme zamanı için gönderim günü gerekir.`.

      WHEN 'SCHED_STOP'.

        LV_EN = `The end time must be after the send time.`.
        CONCATENATE `Son deneme zamanı gönderim zamanından sonra`
                    ` olmalı.`
          INTO LV_TR.

      WHEN 'NO_JOB'.

        LV_EN = `Enter a Netgsm job ID.`.
        LV_TR = `Bir Netgsm iş numarası (jobid) girin.`.

      WHEN 'NO_CRITERIA'.

        LV_EN = `Enter job IDs or a date range.`.
        LV_TR = `İş numarası ya da tarih aralığı girin.`.

      WHEN 'RANGE_BOTH'.

        LV_EN = `Enter both dates of the range, or neither.`.
        LV_TR = `Aralığın iki tarihini de girin ya da hiçbirini.`.

      WHEN 'RANGE_ORDER'.

        LV_EN = `The end date is before the start date.`.
        LV_TR = `Bitiş tarihi başlangıç tarihinden önce.`.

      WHEN 'RANGE_LONG'.

        LV_EN = `The date range may have at most &1 days.`.
        LV_TR = `Tarih aralığı en fazla &1 gün olabilir.`.

      WHEN 'NOTHING_DONE'.

        LV_EN = `Cancelled; nothing was changed.`.
        LV_TR = `Vazgeçildi; hiçbir şey değişmedi.`.

      WHEN 'OP_60'.

        LV_EN = `Türk Telekom fixed line`.
        LV_TR = `Türk Telekom sabit`.

      WHEN 'OP_70'.

        LV_EN = `unknown operator`.
        LV_TR = `tanımsız operatör`.

      WHEN 'OP_ABROAD'.

        LV_EN = `abroad`.
        LV_TR = `yurt dışı`.

      WHEN 'ST_successful'.

        LV_EN = `delivered`.
        LV_TR = `iletildi`.

      WHEN 'ST_notEnoughCredit'.

        LV_EN = `not enough credit`.
        LV_TR = `yetersiz kredi / paket`.

      WHEN 'ST_iysNotValid'.

        LV_EN = `rejected by IYS`.
        LV_TR = `İYS reddetti`.

      WHEN 'ST_blacklist'.

        LV_EN = `blacklisted`.
        LV_TR = `kara listede`.

      WHEN 'ST_numberError'.

        LV_EN = `wrong number`.
        LV_TR = `hatalı numara`.

      WHEN 'ST_sendingError'.

        LV_EN = `send error`.
        LV_TR = `gönderim hatası`.

      WHEN 'ST_operatorError'.

        LV_EN = `operator error`.
        LV_TR = `operatör hatası`.

      WHEN 'ST_operatorRefused'.

        LV_EN = `refused by the operator`.
        LV_TR = `operatör kabul etmedi`.

      WHEN 'ST_cannotSendToOperator'.

        LV_EN = `not sent to the operator`.
        LV_TR = `operatöre gönderilemedi`.

      WHEN 'ST_messageTextError'.

        LV_EN = `message length error`.
        LV_TR = `mesaj boyu hatası`.

      WHEN 'ST_notAccceptedByNts' OR 'ST_notAcceptedByNts'.

        LV_EN = `NTS error`.
        LV_TR = `NTS hatası`.

      WHEN 'ST_waiting'.

        LV_EN = `waiting`.
        LV_TR = `bekliyor`.

      WHEN 'ST_repeated'.

        LV_EN = `duplicate`.
        LV_TR = `mükerrer`.

      WHEN 'ST_refunded'.

        LV_EN = `charge refunded`.
        LV_TR = `ücret iade edildi`.

      WHEN 'ST_expired'.

        LV_EN = `timed out`.
        LV_TR = `zaman aşımı`.

      WHEN 'T_TPL'.

        LV_EN = `Template`.
        LV_TR = `Şablon`.

      WHEN 'T_SCH'.

        LV_EN = `Later send (Turkish time) and reference`.
        LV_TR = `İleri tarihli gönderim (Türkiye saati), referans`.

      WHEN 'T_JOB'.

        LV_EN = `Job IDs and dates`.
        LV_TR = `İş numaraları ve tarihler`.

      WHEN 'T_TLS'.

        LV_EN = `Filter`.
        LV_TR = `Filtre`.

      WHEN 'T_CON'.

        LV_EN = `Connection`.
        LV_TR = `Bağlantı`.

      WHEN 'C_TPAR'.

        LV_EN = `Template values, one per line: name=value`.
        LV_TR = `Şablon değerleri, her satıra bir tane: ad=değer`.

      WHEN 'C_JOB'.

        LV_EN = `Cancel and statistics use the first job ID`.
        LV_TR = `İptal ve istatistik ilk iş numarasını kullanır`.

      WHEN 'C_INB'.

        LV_EN = `No dates: only new SMS, each one listed once`.
        LV_TR = `Tarihsiz: yalnızca yeni SMS, her biri bir kez`.

      WHEN 'P_ACT'.

        LV_EN = `Action`.
        LV_TR = `İşlem`.

      WHEN 'P_NLEN'.

        LV_EN = `Also count at Netgsm (free)`.
        LV_TR = `Netgsm'e de saydır (ücretsiz)`.

      WHEN 'P_TID'.

        LV_EN = `Template ID`.
        LV_TR = `Şablon numarası`.

      WHEN 'S_TPAR'.

        LV_EN = `Values name=value`.
        LV_TR = `Değerler ad=değer`.

      WHEN 'P_SDATE'.

        LV_EN = `Send on`.
        LV_TR = `Gönderim günü`.

      WHEN 'P_STIME'.

        LV_EN = `Send at`.
        LV_TR = `Gönderim saati`.

      WHEN 'P_EDATE'.

        LV_EN = `Stop trying on`.
        LV_TR = `Son deneme günü`.

      WHEN 'P_ETIME'.

        LV_EN = `Stop trying at`.
        LV_TR = `Son deneme saati`.

      WHEN 'P_REF'.

        LV_EN = `Your reference (referansID)`.
        LV_TR = `Referansınız (referansID)`.

      WHEN 'P_RFROM'.

        LV_EN = `From date`.
        LV_TR = `Başlangıç tarihi`.

      WHEN 'P_RTO'.

        LV_EN = `To date`.
        LV_TR = `Bitiş tarihi`.

      WHEN 'P_SENDD'.

        LV_EN = `Send date (older months)`.
        LV_TR = `Gönderim tarihi (eski aylar)`.

      WHEN 'P_FULL'.

        LV_EN = `Show full numbers`.
        LV_TR = `Numaraları tam göster`.

      WHEN 'P_TSRCH'.

        LV_EN = `Description contains`.
        LV_TR = `Açıklamada geçen`.

      WHEN 'P_TCONT'.

        LV_EN = `Text contains`.
        LV_TR = `Metinde geçen`.

      WHEN 'P_TTYPE'.

        LV_EN = `Template type`.
        LV_TR = `Şablon tipi`.

      WHEN 'P_TPUB'.

        LV_EN = `Also Netgsm's own templates`.
        LV_TR = `Netgsm'in şablonları da`.

      WHEN 'P_TPAGE'.

        LV_EN = `Page (from 0)`.
        LV_TR = `Sayfa (0'dan)`.

      WHEN 'P_DEXT'.

        LV_EN = `SM59 destination (templates)`.
        LV_TR = `SM59 hedefi (şablonlar)`.

      WHEN 'ACT_SEND'.

        LV_EN = `Send SMS`.
        LV_TR = `SMS gönder`.

      WHEN 'ACT_OTP'.

        LV_EN = `Send OTP SMS (one number)`.
        LV_TR = `OTP SMS gönder (tek numara)`.

      WHEN 'ACT_TEMPLATE'.

        LV_EN = `Send template SMS`.
        LV_TR = `Şablonlu SMS gönder`.

      WHEN 'ACT_CANCEL'.

        LV_EN = `Cancel a scheduled SMS`.
        LV_TR = `İleri tarihli SMS'i iptal et`.

      WHEN 'ACT_REPORT'.

        LV_EN = `Delivery report`.
        LV_TR = `Teslim raporu`.

      WHEN 'ACT_STATS'.

        LV_EN = `Statistics of a job`.
        LV_TR = `Bir işin istatistiği`.

      WHEN 'ACT_INBOX'.

        LV_EN = `Incoming SMS`.
        LV_TR = `Gelen SMS`.

      WHEN 'ACT_HEADERS'.

        LV_EN = `Test: list sender names`.
        LV_TR = `Test: gönderici adlarını listele`.

      WHEN 'ACT_TPLLIST'.

        LV_EN = `List templates`.
        LV_TR = `Şablonları listele`.

      WHEN 'ACT_LENGTH'.

        LV_EN = `Count characters at Netgsm`.
        LV_TR = `Karakterleri Netgsm'e saydır`.

      WHEN 'L_STATS'.

        LV_EN = `Statistics`.
        LV_TR = `İstatistik`.

      WHEN 'L_STATS_LINE'.

        LV_EN = `&1 SMS, &2 part(s), charged &3`.
        LV_TR = `&1 SMS, &2 parça, ücret &3`.

      WHEN 'L_INBOX'.

        LV_EN = `Incoming SMS`.
        LV_TR = `Gelen SMS`.

      WHEN 'L_TEMPLATES'.

        LV_EN = `Templates`.
        LV_TR = `Şablonlar`.

      WHEN 'L_PAGE'.

        LV_EN = `Page &1 of &2 (from 0), &3 template(s)`.
        LV_TR = `Sayfa &1 / &2 (0'dan), &3 şablon`.

      WHEN 'L_PARAMS'.

        LV_EN = `Values: &1`.
        LV_TR = `Değerler: &1`.

      WHEN 'L_LENGTH'.

        LV_EN = `Netgsm's count`.
        LV_TR = `Netgsm'in hesabı`.

      WHEN 'L_LEN_LINE'.

        CONCATENATE `&1 part(s), &2 characters in the last part,`
                    ` &3 left until the next part`
          INTO LV_EN.
        CONCATENATE `&1 parça, son parçada &2 karakter, sonraki`
                    ` parçaya &3 karakter`
          INTO LV_TR.

      WHEN 'L_LEN_LEFT'.

        LV_EN = `&1 characters left in 6 parts`.
        LV_TR = `6 parçada &1 karakter yer kaldı`.

      WHEN 'L_LOCAL'.

        CONCATENATE `This program's count: &1, &2 characters,`
                    ` &3 part(s)`
          INTO LV_EN.
        LV_TR = `Programın hesabı: &1, &2 karakter, &3 parça`.

      WHEN 'L_SCHEDULE'.

        LV_EN = `Send on &1, stop trying &2 (Turkish time)`.
        LV_TR = `Gönderim &1, son deneme &2 (Türkiye saati)`.

      WHEN 'L_REFERENCE'.

        LV_EN = `Reference`.
        LV_TR = `Referans`.

      WHEN 'POP_CANCEL_T'.

        LV_EN = `Cancel scheduled SMS`.
        LV_TR = `İleri tarihli SMS iptali`.

      WHEN 'POP_CANCEL_Q'.

        LV_EN = `Cancel the scheduled SMS with job ID &1?`.
        LV_TR = `&1 numaralı ileri tarihli SMS iptal edilsin mi?`.

      WHEN OTHERS.

        LV_EN = IV_KEY.
        LV_TR = IV_KEY.

    ENDCASE.
    RV_TEXT = PICK( IV_EN = LV_EN IV_TR = LV_TR ).

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Phone numbers: +90 500 000 00 00, 0500..., 500..., 0090 500...
* all become 5000000000, the 10-digit form Netgsm v2 asks for
*----------------------------------------------------------------------*
CLASS LCL_SMS_PHONE DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS NORMALIZE
      IMPORTING
        IV_INPUT            TYPE CSEQUENCE
      RETURNING
        VALUE(RS_RECIPIENT) TYPE LIF_SMS=>TY_RECIPIENT.

    "! Normalizes all, skips empty entries, marks numbers given twice
    CLASS-METHODS NORMALIZE_ALL
      IMPORTING
        IT_INPUTS            TYPE STRING_TABLE
      RETURNING
        VALUE(RT_RECIPIENTS) TYPE LIF_SMS=>TY_RECIPIENTS.

    "! 5000000034 -> 5** *** ** 34
    CLASS-METHODS MASK
      IMPORTING
        IV_NUMBER        TYPE CSEQUENCE
      RETURNING
        VALUE(RV_MASKED) TYPE STRING.

    "! Every digit but the last two becomes *
    CLASS-METHODS MASK_ANY
      IMPORTING
        IV_INPUT         TYPE CSEQUENCE
      RETURNING
        VALUE(RV_MASKED) TYPE STRING.
ENDCLASS.

CLASS LCL_SMS_PHONE IMPLEMENTATION.

  METHOD NORMALIZE.

    DATA: LV_WORK   TYPE C LENGTH 40,
          LV_NUMBER TYPE STRING,
          LV_LEN    TYPE I.

    RS_RECIPIENT-INPUT = IV_INPUT.
    LV_WORK = IV_INPUT.
    TRANSLATE LV_WORK USING '- . ( ) / '.
    CONDENSE LV_WORK NO-GAPS.
    IF LV_WORK(1) EQ '+'.

      CONCATENATE '00' LV_WORK+1 INTO LV_WORK.

    ENDIF.
    LV_NUMBER = LV_WORK.
    LV_LEN = STRLEN( LV_NUMBER ).

    IF LV_LEN EQ 0 OR NOT LV_NUMBER CO '0123456789'.

      RS_RECIPIENT-REASON = LCL_TEXT=>GET( 'NUM_CHARS' ).

    ELSEIF LV_LEN GE 2 AND LV_NUMBER(2) EQ '00'
       AND NOT ( LV_LEN GE 4 AND LV_NUMBER(4) EQ '0090' ).

      RS_RECIPIENT-REASON = LCL_TEXT=>GET( 'NUM_FOREIGN' ).

    ELSE.

      IF LV_LEN EQ 14 AND LV_NUMBER(4) EQ '0090'.

        SHIFT LV_NUMBER LEFT BY 4 PLACES.

      ELSEIF LV_LEN EQ 12 AND LV_NUMBER(2) EQ '90'.

        SHIFT LV_NUMBER LEFT BY 2 PLACES.

      ELSEIF LV_LEN EQ 11 AND LV_NUMBER(1) EQ '0'.

        SHIFT LV_NUMBER LEFT BY 1 PLACES.

      ENDIF.
      LV_LEN = STRLEN( LV_NUMBER ).
      IF LV_LEN NE 10.

        RS_RECIPIENT-REASON = LCL_TEXT=>GET( 'NUM_LENGTH' ).

      ELSEIF LV_NUMBER(1) NE '5'.

        RS_RECIPIENT-REASON = LCL_TEXT=>GET( 'NUM_MOBILE' ).

      ELSE.

        RS_RECIPIENT-NUMBER = LV_NUMBER.
        RS_RECIPIENT-OK = ABAP_TRUE.

      ENDIF.

    ENDIF.

    IF RS_RECIPIENT-OK EQ ABAP_TRUE.

      RS_RECIPIENT-MASKED = MASK( RS_RECIPIENT-NUMBER ).

    ELSE.

      RS_RECIPIENT-MASKED = MASK_ANY( IV_INPUT ).

    ENDIF.

  ENDMETHOD.

  METHOD NORMALIZE_ALL.

    DATA LT_SEEN TYPE SORTED TABLE OF STRING
                 WITH UNIQUE KEY TABLE_LINE.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    DATA LV_INPUT TYPE STRING.

    LOOP AT IT_INPUTS INTO LV_INPUT.

      CONDENSE LV_INPUT.
      IF LV_INPUT IS INITIAL.

        CONTINUE.

      ENDIF.
      LS_RECIPIENT = NORMALIZE( LV_INPUT ).
      IF LS_RECIPIENT-OK EQ ABAP_TRUE.

        READ TABLE LT_SEEN
             TRANSPORTING NO FIELDS
             WITH TABLE KEY TABLE_LINE = LS_RECIPIENT-NUMBER.
        IF SY-SUBRC EQ 0.

          LS_RECIPIENT-OK = ABAP_FALSE.
          LS_RECIPIENT-REASON = LCL_TEXT=>GET( 'NUM_DUP' ).

        ELSE.

          INSERT LS_RECIPIENT-NUMBER INTO TABLE LT_SEEN.

        ENDIF.

      ENDIF.
      APPEND LS_RECIPIENT TO RT_RECIPIENTS.

      CLEAR LV_INPUT.

    ENDLOOP.

    CLEAR LV_INPUT.

  ENDMETHOD.

  METHOD MASK.

    DATA: LV_NUMBER TYPE STRING,
          LV_LEN    TYPE I,
          LV_OFF    TYPE I.

    LV_NUMBER = IV_NUMBER.
    LV_LEN = STRLEN( LV_NUMBER ).
    IF LV_LEN NE 10.

      RV_MASKED = MASK_ANY( LV_NUMBER ).
      RETURN.

    ENDIF.
    LV_OFF = LV_LEN - 2.
    CONCATENATE LV_NUMBER(1) '** *** **' INTO RV_MASKED.
    CONCATENATE RV_MASKED ` ` LV_NUMBER+LV_OFF(2) INTO RV_MASKED.

  ENDMETHOD.

  METHOD MASK_ANY.

    DATA: LV_WORK TYPE C LENGTH 40,
          LV_LEN  TYPE I,
          LV_KEEP TYPE I,
          LV_POS  TYPE I.

    LV_WORK = IV_INPUT.
    LV_LEN = STRLEN( LV_WORK ).
    LV_KEEP = LV_LEN - 2.
    DO LV_LEN TIMES.

      LV_POS = SY-INDEX - 1.
      IF LV_POS GE LV_KEEP.

        EXIT.

      ENDIF.
      IF LV_WORK+LV_POS(1) CO '0123456789'.

        LV_WORK+LV_POS(1) = '*'.

      ENDIF.

    ENDDO.
    RV_MASKED = LV_WORK.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Character set, length and parts. Netgsm, /length documentation:
*   GSM alphabet      160 characters, 153 per part when split
*   Turkish (TR)      155, 148 per part; c g i s G I S with
*                     cedilla/breve/dot count twice
*   Unicode            70,  66 per part
* At most 6 parts. GSM extension characters (EUR [ ] { } ^ ~ \ |)
* count twice. Netgsm adds " B021" (5 characters) after the text
* when the sender name has letters. All counted from Unicode code
* points, so this source needs no special characters.
*----------------------------------------------------------------------*
CLASS LCL_SMS_TEXT DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES TY_KIND TYPE C LENGTH 1.
    CONSTANTS:
      BEGIN OF KIND,
        BASIC     TYPE TY_KIND VALUE 'B',
        EXTENSION TYPE TY_KIND VALUE 'E',
        TURKISH   TYPE TY_KIND VALUE 'T',
        OTHER     TYPE TY_KIND VALUE 'U',
      END OF KIND.

    CLASS-METHODS ANALYZE
      IMPORTING
        IV_TEXT        TYPE CSEQUENCE
        IV_ENCODING    TYPE LIF_SMS=>TY_ENCODING
        IV_HEADER      TYPE CSEQUENCE
      RETURNING
        VALUE(RS_INFO) TYPE LIF_SMS=>TY_TEXT_INFO.

    "! What a character costs: basic, extension, Turkish, other
    CLASS-METHODS KIND_OF
      IMPORTING
        IV_CODE_POINT  TYPE I
      RETURNING
        VALUE(RV_KIND) TYPE TY_KIND.

    "! One of the twelve Turkish letters (c g i o s u, both cases)
    CLASS-METHODS IS_TURKISH_LETTER
      IMPORTING
        IV_CODE_POINT TYPE I
      RETURNING
        VALUE(RV_YES) TYPE ABAP_BOOL.

    "! OTP SMS rules (Netgsm): one part, plain GSM letters, no
    "! Turkish letters except o and u with umlaut
    CLASS-METHODS CHECK_OTP
      IMPORTING
        IV_TEXT        TYPE CSEQUENCE
        IV_HEADER      TYPE CSEQUENCE
        IV_ASCII       TYPE ABAP_BOOL
      RETURNING
        VALUE(RS_INFO) TYPE LIF_SMS=>TY_TEXT_INFO.

    "! Turkish letters to Latin ones; the rest stays
    CLASS-METHODS TO_ASCII
      IMPORTING
        IV_TEXT        TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

  PRIVATE SECTION.
    CLASS-METHODS REPLACE_CODE_POINT
      IMPORTING
        IV_CODE_POINT TYPE I
        IV_WITH       TYPE C
      CHANGING
        CV_TEXT       TYPE STRING.
ENDCLASS.

CLASS LCL_SMS_TEXT IMPLEMENTATION.

  METHOD ANALYZE.

    DATA: LV_TEXT       TYPE STRING,
          LV_LEN        TYPE I,
          LV_POS        TYPE I,
          LV_CHAR       TYPE C LENGTH 1,
          LV_CODE_POINT TYPE I,
          LV_KIND       TYPE TY_KIND,
          LV_BASIC      TYPE I,
          LV_EXT        TYPE I,
          LV_TR         TYPE I,
          LV_OTHER      TYPE I,
          LV_LETTERS    TYPE I,
          LV_HEADER     TYPE STRING,
          LV_SINGLE     TYPE I,
          LV_MULTI      TYPE I,
          LV_TOTAL      TYPE I,
          LV_1          TYPE C LENGTH 12,
          LV_2          TYPE C LENGTH 12.

    LV_TEXT = IV_TEXT.
    REPLACE ALL OCCURRENCES OF CL_ABAP_CHAR_UTILITIES=>CR_LF
            IN LV_TEXT WITH CL_ABAP_CHAR_UTILITIES=>NEWLINE.

    CASE IV_ENCODING.

      WHEN LIF_SMS=>ENCODING-AUTO OR LIF_SMS=>ENCODING-TURKISH
        OR LIF_SMS=>ENCODING-UNICODE.

      WHEN LIF_SMS=>ENCODING-ASCII.

        LV_TEXT = TO_ASCII( LV_TEXT ).

      WHEN OTHERS.

        RS_INFO-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'BAD_ENC'
                                         IV_1   = IV_ENCODING ).
        RETURN.

    ENDCASE.
    RS_INFO-TEXT = LV_TEXT.

    LV_LEN = STRLEN( LV_TEXT ).
    IF LV_LEN EQ 0.

      RS_INFO-MESSAGE = LCL_TEXT=>GET( 'NO_TEXT' ).
      RETURN.

    ENDIF.

    DO LV_LEN TIMES.

      LV_POS = SY-INDEX - 1.
      LV_CHAR = LV_TEXT+LV_POS(1).
      TRY.

          LV_CODE_POINT = CL_ABAP_CONV_OUT_CE=>UCCPI( LV_CHAR ).

        CATCH CX_ROOT.

          " Half of a surrogate pair (emoji): not GSM, not Turkish
          LV_CODE_POINT = 65535.

      ENDTRY.
      LV_KIND = KIND_OF( LV_CODE_POINT ).
      CASE LV_KIND.

        WHEN KIND-BASIC.

          LV_BASIC = LV_BASIC + 1.

        WHEN KIND-EXTENSION.

          LV_EXT = LV_EXT + 1.

        WHEN KIND-TURKISH.

          LV_TR = LV_TR + 1.

        WHEN OTHERS.

          LV_OTHER = LV_OTHER + 1.

      ENDCASE.
      IF IS_TURKISH_LETTER( LV_CODE_POINT ) EQ ABAP_TRUE.

        LV_LETTERS = LV_LETTERS + 1.

      ENDIF.

    ENDDO.

    CASE IV_ENCODING.

      WHEN LIF_SMS=>ENCODING-UNICODE.

        RS_INFO-ENCODING = LIF_SMS=>ENCODING-UNICODE.

      WHEN LIF_SMS=>ENCODING-TURKISH.

        IF LV_OTHER GT 0.

          RS_INFO-MESSAGE = LCL_TEXT=>GET( 'TR_UNICODE' ).
          RETURN.

        ENDIF.
        RS_INFO-ENCODING = LIF_SMS=>ENCODING-TURKISH.

      WHEN OTHERS.

        " AUTO, and ASCII after the conversion
        IF LV_OTHER GT 0.

          RS_INFO-ENCODING = LIF_SMS=>ENCODING-UNICODE.

        ELSEIF LV_LETTERS GT 0.

          RS_INFO-ENCODING = LIF_SMS=>ENCODING-TURKISH.

        ELSE.

          RS_INFO-ENCODING = LIF_SMS=>ENCODING-GSM.

        ENDIF.

    ENDCASE.

    CASE RS_INFO-ENCODING.

      WHEN LIF_SMS=>ENCODING-GSM.

        RS_INFO-UNITS = LV_BASIC + 2 * LV_EXT.
        LV_SINGLE = 160.
        LV_MULTI = 153.
        RS_INFO-MAX_UNITS = 912.

      WHEN LIF_SMS=>ENCODING-TURKISH.

        RS_INFO-UNITS = LV_BASIC + 2 * LV_EXT + 2 * LV_TR.
        LV_SINGLE = 155.
        LV_MULTI = 148.
        RS_INFO-MAX_UNITS = 883.

      WHEN OTHERS.

        " UTF-16 code units, an emoji counts as two
        RS_INFO-UNITS = LV_LEN.
        LV_SINGLE = 70.
        LV_MULTI = 66.
        RS_INFO-MAX_UNITS = 391.

    ENDCASE.

    LV_HEADER = IV_HEADER.
    TRANSLATE LV_HEADER TO UPPER CASE.
    IF LV_HEADER CA SY-ABCDE.

      RS_INFO-SUFFIX = 5.

    ENDIF.

    LV_TOTAL = RS_INFO-UNITS + RS_INFO-SUFFIX.
    IF LV_TOTAL LE LV_SINGLE.

      RS_INFO-PARTS = 1.

    ELSE.

      RS_INFO-PARTS = LV_TOTAL DIV LV_MULTI.
      IF LV_TOTAL MOD LV_MULTI GT 0.

        RS_INFO-PARTS = RS_INFO-PARTS + 1.

      ENDIF.

    ENDIF.

    IF RS_INFO-UNITS GT RS_INFO-MAX_UNITS
       OR RS_INFO-PARTS GT LIF_SMS=>MAX_PARTS.

      LV_1 = RS_INFO-UNITS.
      LV_2 = RS_INFO-MAX_UNITS.
      CONDENSE: LV_1, LV_2.
      RS_INFO-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'TOO_LONG'
                                       IV_1   = LV_1
                                       IV_2   = LV_2 ).
      RETURN.

    ENDIF.
    RS_INFO-OK = ABAP_TRUE.

  ENDMETHOD.

  METHOD KIND_OF.

    CASE IV_CODE_POINT.

      WHEN 10 OR 13 OR 95.

        RV_KIND = KIND-BASIC.

      WHEN 12 OR 91 OR 92 OR 93 OR 94 OR 123 OR 124 OR 125 OR 126
        OR 8364.

        RV_KIND = KIND-EXTENSION.

      WHEN 231 OR 286 OR 287 OR 304 OR 305 OR 350 OR 351.

        RV_KIND = KIND-TURKISH.

      WHEN 161 OR 163 OR 164 OR 165 OR 167 OR 191 OR 196 OR 197
        OR 198 OR 199 OR 201 OR 209 OR 214 OR 216 OR 220 OR 223
        OR 224 OR 228 OR 229 OR 230 OR 232 OR 233 OR 236 OR 241
        OR 242 OR 246 OR 248 OR 249 OR 252
        OR 915 OR 916 OR 920 OR 923 OR 926 OR 928 OR 931 OR 934
        OR 936 OR 937.

        RV_KIND = KIND-BASIC.

      WHEN OTHERS.

        IF ( IV_CODE_POINT GE 32 AND IV_CODE_POINT LE 90 )
           OR ( IV_CODE_POINT GE 97 AND IV_CODE_POINT LE 122 ).

          RV_KIND = KIND-BASIC.

        ELSE.

          RV_KIND = KIND-OTHER.

        ENDIF.

    ENDCASE.

  ENDMETHOD.

  METHOD IS_TURKISH_LETTER.

    CASE IV_CODE_POINT.

      WHEN 199 OR 231 OR 286 OR 287 OR 304 OR 305 OR 214 OR 246
        OR 350 OR 351 OR 220 OR 252.

        RV_YES = ABAP_TRUE.

      WHEN OTHERS.

        RV_YES = ABAP_FALSE.

    ENDCASE.

  ENDMETHOD.

  METHOD TO_ASCII.

    RV_TEXT = IV_TEXT.
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 231 IV_WITH = 'c'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 199 IV_WITH = 'C'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 287 IV_WITH = 'g'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 286 IV_WITH = 'G'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 305 IV_WITH = 'i'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 304 IV_WITH = 'I'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 246 IV_WITH = 'o'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 214 IV_WITH = 'O'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 351 IV_WITH = 's'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 350 IV_WITH = 'S'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 252 IV_WITH = 'u'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 220 IV_WITH = 'U'
                        CHANGING  CV_TEXT = RV_TEXT ).
    " Circumflex letters in loan words
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 226 IV_WITH = 'a'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 194 IV_WITH = 'A'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 238 IV_WITH = 'i'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 206 IV_WITH = 'I'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 251 IV_WITH = 'u'
                        CHANGING  CV_TEXT = RV_TEXT ).
    REPLACE_CODE_POINT( EXPORTING IV_CODE_POINT = 219 IV_WITH = 'U'
                        CHANGING  CV_TEXT = RV_TEXT ).

  ENDMETHOD.

  METHOD CHECK_OTP.

    DATA: LV_TEXT       TYPE STRING,
          LV_LEN        TYPE I,
          LV_POS        TYPE I,
          LV_CHAR       TYPE C LENGTH 1,
          LV_CODE_POINT TYPE I,
          LV_KIND       TYPE TY_KIND,
          LV_HEADER     TYPE STRING,
          LV_MAX        TYPE I,
          LV_1          TYPE C LENGTH 12,
          LV_2          TYPE C LENGTH 12.

    LV_TEXT = IV_TEXT.
    REPLACE ALL OCCURRENCES OF CL_ABAP_CHAR_UTILITIES=>CR_LF
            IN LV_TEXT WITH CL_ABAP_CHAR_UTILITIES=>NEWLINE.
    IF IV_ASCII EQ ABAP_TRUE.

      LV_TEXT = TO_ASCII( LV_TEXT ).

    ENDIF.
    RS_INFO-TEXT = LV_TEXT.
    RS_INFO-ENCODING = LIF_SMS=>ENCODING-GSM.
    RS_INFO-MAX_UNITS = 160.
    LV_HEADER = IV_HEADER.
    TRANSLATE LV_HEADER TO UPPER CASE.
    IF LV_HEADER CA SY-ABCDE.

      RS_INFO-SUFFIX = 5.

    ENDIF.
    LV_MAX = RS_INFO-MAX_UNITS - RS_INFO-SUFFIX.

    LV_LEN = STRLEN( LV_TEXT ).
    IF LV_LEN EQ 0.

      RS_INFO-MESSAGE = LCL_TEXT=>GET( 'NO_TEXT' ).
      RETURN.

    ENDIF.
    DO LV_LEN TIMES.

      LV_POS = SY-INDEX - 1.
      LV_CHAR = LV_TEXT+LV_POS(1).
      TRY.

          LV_CODE_POINT = CL_ABAP_CONV_OUT_CE=>UCCPI( LV_CHAR ).

        CATCH CX_ROOT.

          LV_CODE_POINT = 65535.

      ENDTRY.
      LV_KIND = KIND_OF( LV_CODE_POINT ).
      IF LV_KIND EQ KIND-OTHER OR LV_KIND EQ KIND-TURKISH
         OR LV_CODE_POINT EQ 199.

        RS_INFO-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'OTP_CHARS'
                                         IV_1   = LV_CHAR ).
        RETURN.

      ENDIF.
      IF LV_KIND EQ KIND-EXTENSION.

        RS_INFO-UNITS = RS_INFO-UNITS + 2.

      ELSE.

        RS_INFO-UNITS = RS_INFO-UNITS + 1.

      ENDIF.

    ENDDO.
    RS_INFO-PARTS = 1.
    IF RS_INFO-UNITS GT LV_MAX.

      LV_1 = RS_INFO-UNITS.
      LV_2 = LV_MAX.
      CONDENSE: LV_1, LV_2.
      RS_INFO-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'OTP_LONG'
                                       IV_1   = LV_1
                                       IV_2   = LV_2 ).
      RETURN.

    ENDIF.
    RS_INFO-MAX_UNITS = LV_MAX.
    RS_INFO-OK = ABAP_TRUE.

  ENDMETHOD.

  METHOD REPLACE_CODE_POINT.

    DATA LV_CHAR TYPE C LENGTH 1.

    LV_CHAR = CL_ABAP_CONV_IN_CE=>UCCPI( IV_CODE_POINT ).
    REPLACE ALL OCCURRENCES OF LV_CHAR IN CV_TEXT WITH IV_WITH.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Minimal JSON. Writing: escape string values. Reading: the answer
* becomes a flat list of path = value, for example
*   code = 00, jobs/1/jobid = 123, jobs/1/status = 1
* Release 7.00 has no JSON parser of its own (/UI2/CL_JSON is later).
*----------------------------------------------------------------------*
CLASS LCL_SMS_JSON DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES:
      BEGIN OF TY_VALUE,
        PATH  TYPE STRING,
        VALUE TYPE STRING,
      END OF TY_VALUE,
      TY_VALUES TYPE STANDARD TABLE OF TY_VALUE WITH DEFAULT KEY.

    CLASS-METHODS ESCAPE
      IMPORTING
        IV_TEXT        TYPE CSEQUENCE
      RETURNING
        VALUE(RV_JSON) TYPE STRING.

    CLASS-METHODS PARSE
      IMPORTING
        IV_JSON          TYPE STRING
      RETURNING
        VALUE(RT_VALUES) TYPE TY_VALUES
      RAISING
        LCX_SMS.

    CLASS-METHODS VALUE_OF
      IMPORTING
        IT_VALUES       TYPE TY_VALUES
        IV_PATH         TYPE CSEQUENCE
      RETURNING
        VALUE(RV_VALUE) TYPE STRING.

    CLASS-METHODS HAS
      IMPORTING
        IT_VALUES     TYPE TY_VALUES
        IV_PATH       TYPE CSEQUENCE
      RETURNING
        VALUE(RV_YES) TYPE ABAP_BOOL.

  PRIVATE SECTION.
    DATA MV_JSON TYPE STRING.
    DATA MV_LEN TYPE I.
    DATA MV_POS TYPE I.
    DATA MT_VALUES TYPE TY_VALUES.

    METHODS READ_VALUE
      IMPORTING
        IV_PATH TYPE STRING
      RAISING
        LCX_SMS.

    METHODS READ_OBJECT
      IMPORTING
        IV_PATH TYPE STRING
      RAISING
        LCX_SMS.

    METHODS READ_ARRAY
      IMPORTING
        IV_PATH TYPE STRING
      RAISING
        LCX_SMS.

    METHODS READ_STRING
      RETURNING
        VALUE(RV_VALUE) TYPE STRING
      RAISING
        LCX_SMS.

    METHODS READ_LITERAL
      RETURNING
        VALUE(RV_VALUE) TYPE STRING.

    METHODS SKIP_BLANKS.

    METHODS CURRENT
      RETURNING
        VALUE(RV_CHAR) TYPE STRING.

    METHODS ADD
      IMPORTING
        IV_PATH  TYPE STRING
        IV_VALUE TYPE STRING.

    METHODS FAIL
      IMPORTING
        IV_WHAT TYPE STRING
      RAISING
        LCX_SMS.

    CLASS-METHODS UNESCAPE
      IMPORTING
        IV_RAW          TYPE STRING
      RETURNING
        VALUE(RV_VALUE) TYPE STRING.

    CLASS-METHODS CHILD_PATH
      IMPORTING
        IV_PATH        TYPE STRING
        IV_NAME        TYPE CSEQUENCE
      RETURNING
        VALUE(RV_PATH) TYPE STRING.
ENDCLASS.

CLASS LCL_SMS_JSON IMPLEMENTATION.

  METHOD ESCAPE.

    DATA LV_CHAR TYPE C LENGTH 1.

    RV_JSON = IV_TEXT.
    REPLACE ALL OCCURRENCES OF `\` IN RV_JSON WITH `\\`.
    REPLACE ALL OCCURRENCES OF `"` IN RV_JSON WITH `\"`.
    LV_CHAR = CL_ABAP_CHAR_UTILITIES=>NEWLINE.
    REPLACE ALL OCCURRENCES OF LV_CHAR IN RV_JSON WITH `\n`.
    LV_CHAR = CL_ABAP_CHAR_UTILITIES=>CR_LF(1).
    REPLACE ALL OCCURRENCES OF LV_CHAR IN RV_JSON WITH `\r`.
    LV_CHAR = CL_ABAP_CHAR_UTILITIES=>HORIZONTAL_TAB.
    REPLACE ALL OCCURRENCES OF LV_CHAR IN RV_JSON WITH `\t`.

  ENDMETHOD.

  METHOD PARSE.

    DATA LO_PARSER TYPE REF TO LCL_SMS_JSON.

    CREATE OBJECT LO_PARSER.
    LO_PARSER->MV_JSON = IV_JSON.
    LO_PARSER->MV_LEN = STRLEN( IV_JSON ).
    LO_PARSER->READ_VALUE( `` ).
    LO_PARSER->SKIP_BLANKS( ).
    IF LO_PARSER->MV_POS LT LO_PARSER->MV_LEN.

      LO_PARSER->FAIL( `text after the end` ).

    ENDIF.
    RT_VALUES = LO_PARSER->MT_VALUES.

  ENDMETHOD.

  METHOD VALUE_OF.

    DATA LS_VALUE TYPE TY_VALUE.

    CLEAR LS_VALUE.
    READ TABLE IT_VALUES
         INTO LS_VALUE
         WITH KEY PATH = IV_PATH.
    IF SY-SUBRC EQ 0.

      RV_VALUE = LS_VALUE-VALUE.

    ENDIF.

  ENDMETHOD.

  METHOD HAS.

    READ TABLE IT_VALUES
         TRANSPORTING NO FIELDS
         WITH KEY PATH = IV_PATH.
    IF SY-SUBRC EQ 0.

      RV_YES = ABAP_TRUE.

    ENDIF.

  ENDMETHOD.

  METHOD READ_VALUE.

    DATA: LV_CHAR  TYPE STRING,
          LV_VALUE TYPE STRING.

    SKIP_BLANKS( ).
    LV_CHAR = CURRENT( ).
    CASE LV_CHAR.

      WHEN `{`.

        READ_OBJECT( IV_PATH ).

      WHEN `[`.

        READ_ARRAY( IV_PATH ).

      WHEN `"`.

        LV_VALUE = READ_STRING( ).
        ADD( IV_PATH = IV_PATH IV_VALUE = LV_VALUE ).

      WHEN ``.

        FAIL( `unexpected end` ).

      WHEN OTHERS.

        LV_VALUE = READ_LITERAL( ).
        IF LV_VALUE IS INITIAL.

          FAIL( `unexpected character` ).

        ENDIF.
        IF LV_VALUE EQ `null`.

          CLEAR LV_VALUE.

        ENDIF.
        ADD( IV_PATH = IV_PATH IV_VALUE = LV_VALUE ).

    ENDCASE.

  ENDMETHOD.

  METHOD READ_OBJECT.

    DATA: LV_NAME TYPE STRING,
          LV_CHAR TYPE STRING,
          LV_PATH TYPE STRING.

    MV_POS = MV_POS + 1.
    SKIP_BLANKS( ).
    IF CURRENT( ) EQ `}`.

      MV_POS = MV_POS + 1.
      RETURN.

    ENDIF.
    DO.

      SKIP_BLANKS( ).
      IF CURRENT( ) NE `"`.

        FAIL( `name expected` ).

      ENDIF.
      LV_NAME = READ_STRING( ).
      SKIP_BLANKS( ).
      IF CURRENT( ) NE `:`.

        FAIL( `colon expected` ).

      ENDIF.
      MV_POS = MV_POS + 1.
      LV_PATH = CHILD_PATH( IV_PATH = IV_PATH IV_NAME = LV_NAME ).
      READ_VALUE( LV_PATH ).
      SKIP_BLANKS( ).
      LV_CHAR = CURRENT( ).
      MV_POS = MV_POS + 1.
      IF LV_CHAR EQ `}`.

        EXIT.

      ELSEIF LV_CHAR NE `,`.

        FAIL( `comma or } expected` ).

      ENDIF.

    ENDDO.

  ENDMETHOD.

  METHOD READ_ARRAY.

    DATA: LV_INDEX TYPE I,
          LV_NAME  TYPE C LENGTH 11,
          LV_CHAR  TYPE STRING,
          LV_PATH  TYPE STRING.

    MV_POS = MV_POS + 1.
    SKIP_BLANKS( ).
    IF CURRENT( ) EQ `]`.

      MV_POS = MV_POS + 1.
      RETURN.

    ENDIF.
    DO.

      LV_INDEX = LV_INDEX + 1.
      LV_NAME = LV_INDEX.
      CONDENSE LV_NAME.
      LV_PATH = CHILD_PATH( IV_PATH = IV_PATH IV_NAME = LV_NAME ).
      READ_VALUE( LV_PATH ).
      SKIP_BLANKS( ).
      LV_CHAR = CURRENT( ).
      MV_POS = MV_POS + 1.
      IF LV_CHAR EQ `]`.

        EXIT.

      ELSEIF LV_CHAR NE `,`.

        FAIL( `comma or ] expected` ).

      ENDIF.

    ENDDO.

  ENDMETHOD.

  METHOD READ_STRING.

    DATA: LV_START TYPE I,
          LV_FROM  TYPE I,
          LV_QUOTE TYPE I,
          LV_BACK  TYPE I,
          LV_COUNT TYPE I,
          LV_LEN   TYPE I,
          LV_RAW   TYPE STRING.

    LV_START = MV_POS + 1.
    LV_FROM = LV_START.
    DO.

      IF LV_FROM GE MV_LEN.

        FAIL( `string not closed` ).

      ENDIF.
      FIND `"` IN SECTION OFFSET LV_FROM OF MV_JSON
           MATCH OFFSET LV_QUOTE.
      IF SY-SUBRC NE 0.

        FAIL( `string not closed` ).

      ENDIF.
      " An odd number of backslashes before it escapes the quote
      LV_COUNT = 0.
      LV_BACK = LV_QUOTE - 1.
      WHILE LV_BACK GE LV_START AND MV_JSON+LV_BACK(1) EQ `\`.

        LV_COUNT = LV_COUNT + 1.
        LV_BACK = LV_BACK - 1.

      ENDWHILE.
      IF LV_COUNT MOD 2 EQ 0.

        EXIT.

      ENDIF.
      LV_FROM = LV_QUOTE + 1.

    ENDDO.
    LV_LEN = LV_QUOTE - LV_START.
    IF LV_LEN GT 0.

      LV_RAW = MV_JSON+LV_START(LV_LEN).

    ENDIF.
    RV_VALUE = UNESCAPE( LV_RAW ).
    MV_POS = LV_QUOTE + 1.

  ENDMETHOD.

  METHOD READ_LITERAL.

    " A number, true, false or null; anything else is an error
    DATA: LV_END  TYPE I,
          LV_LEN  TYPE I,
          LV_CHAR TYPE C LENGTH 1.

    LV_END = MV_POS.
    WHILE LV_END LT MV_LEN.

      LV_CHAR = MV_JSON+LV_END(1).
      IF LV_CHAR CA ',}]'
         OR LV_CHAR EQ ' '
         OR LV_CHAR EQ CL_ABAP_CHAR_UTILITIES=>NEWLINE
         OR LV_CHAR EQ CL_ABAP_CHAR_UTILITIES=>CR_LF(1)
         OR LV_CHAR EQ CL_ABAP_CHAR_UTILITIES=>HORIZONTAL_TAB.

        EXIT.

      ENDIF.
      LV_END = LV_END + 1.

    ENDWHILE.
    LV_LEN = LV_END - MV_POS.
    IF LV_LEN GT 0.

      RV_VALUE = MV_JSON+MV_POS(LV_LEN).

    ENDIF.
    IF RV_VALUE NE `true` AND RV_VALUE NE `false`
       AND RV_VALUE NE `null` AND NOT RV_VALUE CO '0123456789+-.eE'.

      CLEAR RV_VALUE.
      RETURN.

    ENDIF.
    MV_POS = LV_END.

  ENDMETHOD.

  METHOD SKIP_BLANKS.

    DATA LV_CHAR TYPE C LENGTH 1.

    WHILE MV_POS LT MV_LEN.

      LV_CHAR = MV_JSON+MV_POS(1).
      IF LV_CHAR EQ ' '
         OR LV_CHAR EQ CL_ABAP_CHAR_UTILITIES=>NEWLINE
         OR LV_CHAR EQ CL_ABAP_CHAR_UTILITIES=>CR_LF(1)
         OR LV_CHAR EQ CL_ABAP_CHAR_UTILITIES=>HORIZONTAL_TAB.

        MV_POS = MV_POS + 1.

      ELSE.

        EXIT.

      ENDIF.

    ENDWHILE.

  ENDMETHOD.

  METHOD CURRENT.

    IF MV_POS LT MV_LEN.

      RV_CHAR = MV_JSON+MV_POS(1).

    ENDIF.

  ENDMETHOD.

  METHOD ADD.

    DATA LS_VALUE TYPE TY_VALUE.

    LS_VALUE-PATH = IV_PATH.
    LS_VALUE-VALUE = IV_VALUE.
    APPEND LS_VALUE TO MT_VALUES.

  ENDMETHOD.

  METHOD FAIL.

    DATA: LV_TEXT TYPE STRING,
          LV_POS  TYPE C LENGTH 11.

    LV_POS = MV_POS.
    CONDENSE LV_POS.
    CONCATENATE IV_WHAT ` at position ` LV_POS INTO LV_TEXT.
    RAISE EXCEPTION TYPE LCX_SMS
      EXPORTING
        CODE = LIF_SMS=>CODE-BAD_REPLY
        TEXT = LV_TEXT.

  ENDMETHOD.

  METHOD UNESCAPE.

    DATA: LV_MARK       TYPE C LENGTH 1,
          LV_CHAR       TYPE C LENGTH 1,
          LV_OFF        TYPE I,
          LV_HEX_OFF    TYPE I,
          LV_REST       TYPE I,
          LV_HEX        TYPE C LENGTH 4,
          LV_X          TYPE X LENGTH 2,
          LV_CODE_POINT TYPE I.

    RV_VALUE = IV_RAW.
    FIND `\` IN RV_VALUE.
    IF SY-SUBRC NE 0.

      RETURN.

    ENDIF.
    " Keep escaped backslashes out of the way first
    LV_MARK = CL_ABAP_CONV_IN_CE=>UCCPI( 1 ).
    REPLACE ALL OCCURRENCES OF `\\` IN RV_VALUE WITH LV_MARK.
    REPLACE ALL OCCURRENCES OF `\"` IN RV_VALUE WITH `"`.
    REPLACE ALL OCCURRENCES OF `\/` IN RV_VALUE WITH `/`.
    LV_CHAR = CL_ABAP_CHAR_UTILITIES=>NEWLINE.
    REPLACE ALL OCCURRENCES OF `\n` IN RV_VALUE WITH LV_CHAR.
    LV_CHAR = CL_ABAP_CHAR_UTILITIES=>CR_LF(1).
    REPLACE ALL OCCURRENCES OF `\r` IN RV_VALUE WITH LV_CHAR.
    LV_CHAR = CL_ABAP_CHAR_UTILITIES=>HORIZONTAL_TAB.
    REPLACE ALL OCCURRENCES OF `\t` IN RV_VALUE WITH LV_CHAR.
    REPLACE ALL OCCURRENCES OF `\b` IN RV_VALUE WITH ``.
    REPLACE ALL OCCURRENCES OF `\f` IN RV_VALUE WITH ``.
    DO.

      FIND `\u` IN RV_VALUE MATCH OFFSET LV_OFF.
      IF SY-SUBRC NE 0.

        EXIT.

      ENDIF.
      LV_HEX_OFF = LV_OFF + 2.
      LV_REST = STRLEN( RV_VALUE ) - LV_HEX_OFF.
      IF LV_REST LT 4.

        REPLACE SECTION OFFSET LV_OFF LENGTH 2 OF RV_VALUE WITH `?`.
        CONTINUE.

      ENDIF.
      LV_HEX = RV_VALUE+LV_HEX_OFF(4).
      TRANSLATE LV_HEX TO UPPER CASE.
      LV_CHAR = '?'.
      IF LV_HEX CO '0123456789ABCDEF'.

        LV_X = LV_HEX.
        LV_CODE_POINT = LV_X.
        TRY.

            LV_CHAR = CL_ABAP_CONV_IN_CE=>UCCPI( LV_CODE_POINT ).

          CATCH CX_ROOT.

            LV_CHAR = '?'.

        ENDTRY.

      ENDIF.
      IF LV_CHAR EQ ' '.

        REPLACE SECTION OFFSET LV_OFF LENGTH 6 OF RV_VALUE WITH ` `.

      ELSE.

        REPLACE SECTION OFFSET LV_OFF LENGTH 6 OF RV_VALUE
                WITH LV_CHAR.

      ENDIF.

    ENDDO.
    REPLACE ALL OCCURRENCES OF LV_MARK IN RV_VALUE WITH `\`.

  ENDMETHOD.

  METHOD CHILD_PATH.

    IF IV_PATH IS INITIAL.

      RV_PATH = IV_NAME.

    ELSE.

      CONCATENATE IV_PATH `/` IV_NAME INTO RV_PATH.

    ENDIF.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* What the program needs from the system: authorization, the SM59
* destination and HTTP. The unit tests replace it with a double, so
* they never reach Netgsm.
*----------------------------------------------------------------------*
INTERFACE LIF_SMS_BACKEND.
  METHODS HAS_AUTHORITY
    IMPORTING
      IV_DESTINATION TYPE RFCDEST
    RETURNING
      VALUE(RV_YES)  TYPE ABAP_BOOL.

  "! Type of the SM59 destination, initial when it does not exist
  METHODS DESTINATION_TYPE
    IMPORTING
      IV_DESTINATION TYPE RFCDEST
    RETURNING
      VALUE(RV_TYPE) TYPE RFCDES-RFCTYPE.

  "! Raises lcx_sms only when no answer came back
  METHODS CALL
    IMPORTING
      IV_DESTINATION TYPE RFCDEST
      IV_METHOD      TYPE STRING
      IV_PATH        TYPE STRING
      IV_BODY        TYPE STRING OPTIONAL
    RETURNING
      VALUE(RS_HTTP) TYPE LIF_SMS=>TY_HTTP
    RAISING
      LCX_SMS.
ENDINTERFACE.

CLASS LCL_SMS_BACKEND DEFINITION FINAL.
  PUBLIC SECTION.
    INTERFACES LIF_SMS_BACKEND.
ENDCLASS.

CLASS LCL_SMS_BACKEND IMPLEMENTATION.

  METHOD LIF_SMS_BACKEND~HAS_AUTHORITY.

    AUTHORITY-CHECK OBJECT 'S_ICF'
      ID 'ICF_FIELD' FIELD 'DEST'
      ID 'ICF_VALUE' FIELD IV_DESTINATION.
    IF SY-SUBRC EQ 0.

      RV_YES = ABAP_TRUE.

    ENDIF.

  ENDMETHOD.

  METHOD LIF_SMS_BACKEND~DESTINATION_TYPE.

    SELECT SINGLE RFCTYPE
      FROM RFCDES
      INTO RV_TYPE
      WHERE RFCDEST EQ IV_DESTINATION.
    IF SY-SUBRC NE 0.

      CLEAR RV_TYPE.

    ENDIF.

  ENDMETHOD.

  METHOD LIF_SMS_BACKEND~CALL.

    DATA: LO_CLIENT TYPE REF TO IF_HTTP_CLIENT,
          LO_OUT    TYPE REF TO CL_ABAP_CONV_OUT_CE,
          LO_IN     TYPE REF TO CL_ABAP_CONV_IN_CE.

    DATA: LV_DATA    TYPE XSTRING,
          LV_CODE    TYPE I,
          LV_MESSAGE TYPE STRING,
          LV_REST    TYPE STRING,
          LV_TEXT    TYPE STRING.

    CL_HTTP_CLIENT=>CREATE_BY_DESTINATION(
      EXPORTING
        DESTINATION              = IV_DESTINATION
      IMPORTING
        CLIENT                   = LO_CLIENT
      EXCEPTIONS
        ARGUMENT_NOT_FOUND       = 1
        DESTINATION_NOT_FOUND    = 2
        DESTINATION_NO_AUTHORITY = 3
        PLUGIN_NOT_ACTIVE        = 4
        INTERNAL_ERROR           = 5
        OTHERS                   = 6 ).
    IF SY-SUBRC EQ 3.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'NO_AUTH'
                               IV_1   = IV_DESTINATION ).
      RAISE EXCEPTION TYPE LCX_SMS
        EXPORTING
          CODE = LIF_SMS=>CODE-NO_AUTH
          TEXT = LV_TEXT.

    ELSEIF SY-SUBRC NE 0.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'NO_DEST'
                               IV_1   = IV_DESTINATION ).
      RAISE EXCEPTION TYPE LCX_SMS
        EXPORTING
          CODE = LIF_SMS=>CODE-NO_DEST
          TEXT = LV_TEXT.

    ENDIF.

    " A job has no one to answer a logon popup
    LO_CLIENT->PROPERTYTYPE_LOGON_POPUP = IF_HTTP_CLIENT=>CO_DISABLED.
    LO_CLIENT->PROPERTYTYPE_ACCEPT_COOKIE =
      IF_HTTP_CLIENT=>CO_DISABLED.
    LO_CLIENT->REQUEST->SET_METHOD( IV_METHOD ).
    CL_HTTP_UTILITY=>SET_REQUEST_URI( REQUEST = LO_CLIENT->REQUEST
                                      URI     = IV_PATH ).
    LO_CLIENT->REQUEST->SET_HEADER_FIELD( NAME  = 'Accept'
                                          VALUE = 'application/json' ).
    IF IV_BODY IS NOT INITIAL.

      LO_OUT = CL_ABAP_CONV_OUT_CE=>CREATE( ENCODING = 'UTF-8' ).
      LO_OUT->CONVERT( EXPORTING DATA   = IV_BODY
                       IMPORTING BUFFER = LV_DATA ).
      LO_CLIENT->REQUEST->SET_HEADER_FIELD(
        NAME  = 'Content-Type'
        VALUE = 'application/json; charset=utf-8' ).
      LO_CLIENT->REQUEST->SET_DATA( LV_DATA ).

    ENDIF.

    LO_CLIENT->SEND(
      EXCEPTIONS
        HTTP_COMMUNICATION_FAILURE = 1
        HTTP_INVALID_STATE         = 2
        HTTP_PROCESSING_FAILED     = 3
        HTTP_INVALID_TIMEOUT       = 4
        OTHERS                     = 5 ).
    IF SY-SUBRC EQ 0.

      LO_CLIENT->RECEIVE(
        EXCEPTIONS
          HTTP_COMMUNICATION_FAILURE = 1
          HTTP_INVALID_STATE         = 2
          HTTP_PROCESSING_FAILED     = 3
          OTHERS                     = 4 ).

    ENDIF.
    IF SY-SUBRC NE 0.

      LO_CLIENT->GET_LAST_ERROR( IMPORTING MESSAGE = LV_MESSAGE ).
      LO_CLIENT->CLOSE( ).
      IF LV_MESSAGE CS 'PEER_CERT_UNTRUSTED'.

        " The handshake failed, so no request went out
        LV_TEXT = LCL_TEXT=>GET( 'NO_TRUST' ).
        RAISE EXCEPTION TYPE LCX_SMS
          EXPORTING
            CODE = LIF_SMS=>CODE-NO_TRUST
            TEXT = LV_TEXT.

      ENDIF.
      " First line only; the details are in the ICM trace (SMICM)
      SPLIT LV_MESSAGE AT CL_ABAP_CHAR_UTILITIES=>NEWLINE
            INTO LV_MESSAGE LV_REST.
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'NO_CONN'
                               IV_1   = LV_MESSAGE ).
      RAISE EXCEPTION TYPE LCX_SMS
        EXPORTING
          CODE = LIF_SMS=>CODE-NO_CONN
          TEXT = LV_TEXT.

    ENDIF.

    LO_CLIENT->RESPONSE->GET_STATUS(
      IMPORTING
        CODE   = LV_CODE
        REASON = RS_HTTP-REASON ).
    RS_HTTP-STATUS = LV_CODE.
    LV_DATA = LO_CLIENT->RESPONSE->GET_DATA( ).
    LO_CLIENT->CLOSE( ).
    IF LV_DATA IS NOT INITIAL.

      TRY.

          LO_IN = CL_ABAP_CONV_IN_CE=>CREATE( ENCODING = 'UTF-8'
                                              INPUT    = LV_DATA ).
          LO_IN->READ( IMPORTING DATA = RS_HTTP-BODY ).

        CATCH CX_ROOT.

          RS_HTTP-BODY = `(not UTF-8)`.

      ENDTRY.

    ENDIF.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Netgsm SMS API v2: every service that works with basic
* authentication. Checks everything it can before it calls Netgsm;
* never retries a send, because a repeated request can mean a
* second, paid SMS.
* Not here, because Netgsm wants the password inside the request
* body, which SM59 cannot do: blacklist, IYS address upload and
* search. Not here, because SAP would have to receive calls:
* forwarding of incoming SMS to a URL, IYS webhook.
*----------------------------------------------------------------------*
CLASS LCL_SMS_NETGSM DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS CONSTRUCTOR
      IMPORTING
        IV_DESTINATION     TYPE RFCDEST
                           DEFAULT LIF_SMS=>DEFAULT_DESTINATION
        IV_EXT_DESTINATION TYPE RFCDEST
                           DEFAULT LIF_SMS=>DEFAULT_EXT_DESTINATION
        IO_BACKEND         TYPE REF TO LIF_SMS_BACKEND OPTIONAL.

    "! SMS to one or more numbers, now or at a later time
    METHODS SEND
      IMPORTING
        IT_NUMBERS       TYPE STRING_TABLE
        IV_TEXT          TYPE CSEQUENCE
        IV_HEADER        TYPE CSEQUENCE
        IV_ENCODING      TYPE LIF_SMS=>TY_ENCODING
                         DEFAULT LIF_SMS=>ENCODING-AUTO
        IV_IYS           TYPE LIF_SMS=>TY_IYS DEFAULT LIF_SMS=>IYS-INFO
        IS_SCHEDULE      TYPE LIF_SMS=>TY_SCHEDULE OPTIONAL
        IV_REFERENCE     TYPE CSEQUENCE OPTIONAL
        IV_DRY_RUN       TYPE ABAP_BOOL DEFAULT ABAP_TRUE
      RETURNING
        VALUE(RS_RESULT) TYPE LIF_SMS=>TY_RESULT.

    "! OTP SMS: one number, one part, no Turkish letters
    METHODS SEND_OTP
      IMPORTING
        IT_NUMBERS       TYPE STRING_TABLE
        IV_TEXT          TYPE CSEQUENCE
        IV_HEADER        TYPE CSEQUENCE
        IV_ASCII         TYPE ABAP_BOOL DEFAULT ABAP_FALSE
        IV_DRY_RUN       TYPE ABAP_BOOL DEFAULT ABAP_TRUE
      RETURNING
        VALUE(RS_RESULT) TYPE LIF_SMS=>TY_RESULT.

    "! Template SMS: a template approved at Netgsm, with values
    METHODS SEND_TEMPLATE
      IMPORTING
        IT_NUMBERS       TYPE STRING_TABLE
        IV_TEMPLATE_ID   TYPE I
        IT_PARAMS        TYPE LIF_SMS=>TY_PARAMS
        IV_HEADER        TYPE CSEQUENCE
        IV_ENCODING      TYPE LIF_SMS=>TY_ENCODING
                         DEFAULT LIF_SMS=>ENCODING-AUTO
        IV_IYS           TYPE LIF_SMS=>TY_IYS DEFAULT LIF_SMS=>IYS-INFO
        IS_SCHEDULE      TYPE LIF_SMS=>TY_SCHEDULE OPTIONAL
        IV_REFERENCE     TYPE CSEQUENCE OPTIONAL
        IV_DRY_RUN       TYPE ABAP_BOOL DEFAULT ABAP_TRUE
      RETURNING
        VALUE(RS_RESULT) TYPE LIF_SMS=>TY_RESULT.

    "! Cancels a scheduled SMS
    METHODS CANCEL
      IMPORTING
        IV_JOBID         TYPE CSEQUENCE
      RETURNING
        VALUE(RS_ANSWER) TYPE LIF_SMS=>TY_ANSWER.

    "! Delivery report by job IDs, a date range, or both
    METHODS REPORT
      IMPORTING
        IT_JOBIDS        TYPE STRING_TABLE OPTIONAL
        IV_FROM          TYPE D OPTIONAL
        IV_TO            TYPE D OPTIONAL
        IV_PAGE          TYPE I OPTIONAL
        IV_PAGE_SIZE     TYPE I OPTIONAL
      RETURNING
        VALUE(RS_REPORT) TYPE LIF_SMS=>TY_REPORT.

    "! Totals of one job: status, parts, credits
    METHODS STATS
      IMPORTING
        IV_JOBID        TYPE CSEQUENCE
        IV_SEND_DATE    TYPE D OPTIONAL
      RETURNING
        VALUE(RS_STATS) TYPE LIF_SMS=>TY_STATS.

    "! SMS sent to your Netgsm number. Without dates Netgsm returns
    "! only the ones not listed before, and marks them as listed.
    METHODS INBOX
      IMPORTING
        IV_FROM         TYPE D OPTIONAL
        IV_TO           TYPE D OPTIONAL
        IV_FULL_NUMBERS TYPE ABAP_BOOL DEFAULT ABAP_FALSE
      RETURNING
        VALUE(RS_INBOX) TYPE LIF_SMS=>TY_INBOX.

    METHODS HEADERS
      RETURNING
        VALUE(RS_HEADERS) TYPE LIF_SMS=>TY_HEADERS.

    METHODS TEMPLATES
      IMPORTING
        IV_PAGE             TYPE I DEFAULT 0
        IV_SIZE             TYPE I DEFAULT 50
        IV_PUBLIC           TYPE ABAP_BOOL DEFAULT ABAP_TRUE
        IV_SEARCH           TYPE CSEQUENCE OPTIONAL
        IV_TYPE             TYPE CSEQUENCE OPTIONAL
        IV_CONTENT          TYPE CSEQUENCE OPTIONAL
      RETURNING
        VALUE(RS_TEMPLATES) TYPE LIF_SMS=>TY_TEMPLATES.

    "! Netgsm's own count of parts and characters (free)
    METHODS LENGTH
      IMPORTING
        IV_TEXT          TYPE CSEQUENCE
        IV_ENCODING      TYPE LIF_SMS=>TY_ENCODING
                         DEFAULT LIF_SMS=>ENCODING-AUTO
        IV_HEADER        TYPE CSEQUENCE OPTIONAL
      RETURNING
        VALUE(RS_LENGTH) TYPE LIF_SMS=>TY_LENGTH.

    "! Text for a Netgsm code; the same code means different
    "! things in different services
    CLASS-METHODS CODE_TEXT
      IMPORTING
        IV_ACTION      TYPE LIF_SMS=>TY_ACTION
        IV_CODE        TYPE CSEQUENCE
        IV_DESCRIPTION TYPE CSEQUENCE OPTIONAL
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    "! Date and time in one of Netgsm's formats:
    "! DMYHM ddMMyyyyHHmm, ISO_M yyyy-MM-dd HH:mm,
    "! DOT_S dd.MM.yyyy HH:mm:ss, ISO_S yyyy-MM-dd HH:mm:ss
    CLASS-METHODS FORMAT_TIME
      IMPORTING
        IV_DATE        TYPE D
        IV_TIME        TYPE T
        IV_STYLE       TYPE C
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    "! Milliseconds since 1970 (UTC) as Turkish time dd.MM.yyyy ...
    CLASS-METHODS TURKISH_TIME
      IMPORTING
        IV_MILLIS      TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    "! Percent-encoding for a URL query value (UTF-8)
    CLASS-METHODS URL_ENCODE
      IMPORTING
        IV_TEXT        TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

  PRIVATE SECTION.
    DATA MV_DESTINATION TYPE RFCDEST.
    DATA MV_EXT_DESTINATION TYPE RFCDEST.
    DATA MO_BACKEND TYPE REF TO LIF_SMS_BACKEND.

    "! Checks access, calls Netgsm, reads the answer. Never raises.
    METHODS CALL_NETGSM
      IMPORTING
        IV_ACTION      TYPE LIF_SMS=>TY_ACTION
        IV_DESTINATION TYPE RFCDEST
        IV_METHOD      TYPE STRING
        IV_PATH        TYPE STRING
        IV_BODY        TYPE STRING OPTIONAL
      EXPORTING
        EV_CODE        TYPE STRING
        EV_MESSAGE     TYPE STRING
        ET_VALUES      TYPE LCL_SMS_JSON=>TY_VALUES
        EV_STATUS      TYPE I.

    "! Destination exists, has type G, and the user may use it
    METHODS CHECK_ACCESS
      IMPORTING
        IV_DESTINATION TYPE RFCDEST
      EXPORTING
        EV_CODE        TYPE STRING
        EV_MESSAGE     TYPE STRING.

    "! Reads code, description and values; plain codes too
    METHODS READ_ANSWER
      IMPORTING
        IS_HTTP        TYPE LIF_SMS=>TY_HTTP
      EXPORTING
        EV_CODE        TYPE STRING
        EV_DESCRIPTION TYPE STRING
        ET_VALUES      TYPE LCL_SMS_JSON=>TY_VALUES
      RAISING
        LCX_SMS.

    "! The checks shared by all sends; they set cs_result-code
    "! when something is wrong
    METHODS CHECK_NUMBERS
      IMPORTING
        IT_NUMBERS TYPE STRING_TABLE
        IV_MAX     TYPE I
      CHANGING
        CS_RESULT  TYPE LIF_SMS=>TY_RESULT.

    METHODS CHECK_HEADER
      CHANGING
        CS_RESULT TYPE LIF_SMS=>TY_RESULT.

    METHODS CHECK_IYS
      CHANGING
        CS_RESULT TYPE LIF_SMS=>TY_RESULT.

    METHODS CHECK_SCHEDULE
      CHANGING
        CS_RESULT TYPE LIF_SMS=>TY_RESULT.

    METHODS CHECK_RANGE
      IMPORTING
        IV_FROM    TYPE D
        IV_TO      TYPE D
        IV_DAYS    TYPE I
      EXPORTING
        EV_CODE    TYPE STRING
        EV_MESSAGE TYPE STRING.

    "! Sends a prepared body, or stops at the preview
    METHODS FINISH_SEND
      IMPORTING
        IV_DESTINATION TYPE RFCDEST
        IV_PATH        TYPE STRING
        IV_BODY        TYPE STRING
        IV_DRY_RUN     TYPE ABAP_BOOL
      CHANGING
        CS_RESULT      TYPE LIF_SMS=>TY_RESULT.

    METHODS SEND_BODY
      IMPORTING
        IS_RESULT      TYPE LIF_SMS=>TY_RESULT
        IV_MASKED      TYPE ABAP_BOOL
      RETURNING
        VALUE(RV_JSON) TYPE STRING.

    METHODS OTP_BODY
      IMPORTING
        IS_RESULT      TYPE LIF_SMS=>TY_RESULT
      RETURNING
        VALUE(RV_JSON) TYPE STRING.

    METHODS TEMPLATE_BODY
      IMPORTING
        IS_RESULT      TYPE LIF_SMS=>TY_RESULT
        IT_PARAMS      TYPE LIF_SMS=>TY_PARAMS
        IV_ASCII       TYPE ABAP_BOOL
        IV_MASKED      TYPE ABAP_BOOL
      RETURNING
        VALUE(RV_JSON) TYPE STRING.

    "! ,"startdate":"...","stopdate":"..." or nothing
    CLASS-METHODS SCHEDULE_JSON
      IMPORTING
        IS_SCHEDULE    TYPE LIF_SMS=>TY_SCHEDULE
        IV_STYLE       TYPE C
      RETURNING
        VALUE(RV_JSON) TYPE STRING.

    CLASS-METHODS REFERENCE_JSON
      IMPORTING
        IV_REFERENCE   TYPE STRING
      RETURNING
        VALUE(RV_JSON) TYPE STRING.

    CLASS-METHODS ROW_PATH
      IMPORTING
        IV_LIST        TYPE CSEQUENCE
        IV_ROW         TYPE I
        IV_FIELD       TYPE CSEQUENCE
      RETURNING
        VALUE(RV_PATH) TYPE STRING.

    CLASS-METHODS INT_TEXT
      IMPORTING
        IV_VALUE       TYPE I
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    CLASS-METHODS STATUS_TEXT
      IMPORTING
        IV_STATUS      TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    CLASS-METHODS STATS_TEXT
      IMPORTING
        IV_STATUS      TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    CLASS-METHODS ERROR_TEXT
      IMPORTING
        IV_ERROR       TYPE CSEQUENCE
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    CLASS-METHODS OPERATOR_NAME
      IMPORTING
        IV_OPERATOR    TYPE CSEQUENCE
      RETURNING
        VALUE(RV_NAME) TYPE STRING.
ENDCLASS.

CLASS LCL_SMS_NETGSM IMPLEMENTATION.

  METHOD CONSTRUCTOR.

    MV_DESTINATION = IV_DESTINATION.
    MV_EXT_DESTINATION = IV_EXT_DESTINATION.
    IF IO_BACKEND IS BOUND.

      MO_BACKEND = IO_BACKEND.

    ELSE.

      CREATE OBJECT MO_BACKEND TYPE LCL_SMS_BACKEND.

    ENDIF.

  ENDMETHOD.

  METHOD SEND.

    DATA: LV_BODY TYPE STRING,
          LV_PATH TYPE STRING.

    RS_RESULT-ACTION = LIF_SMS=>ACTION-SEND.
    RS_RESULT-HEADER = IV_HEADER.
    RS_RESULT-IYS = IV_IYS.
    RS_RESULT-SCHEDULE = IS_SCHEDULE.
    RS_RESULT-REFERENCE = IV_REFERENCE.

    CHECK_NUMBERS( EXPORTING IT_NUMBERS = IT_NUMBERS
                             IV_MAX     = LIF_SMS=>MAX_RECIPIENTS
                   CHANGING  CS_RESULT  = RS_RESULT ).
    IF RS_RESULT-CODE IS INITIAL.

      CHECK_HEADER( CHANGING CS_RESULT = RS_RESULT ).

    ENDIF.
    IF RS_RESULT-CODE IS INITIAL.

      CHECK_IYS( CHANGING CS_RESULT = RS_RESULT ).

    ENDIF.
    IF RS_RESULT-CODE IS INITIAL.

      CHECK_SCHEDULE( CHANGING CS_RESULT = RS_RESULT ).

    ENDIF.
    IF RS_RESULT-CODE IS NOT INITIAL.

      RETURN.

    ENDIF.

    RS_RESULT-TEXT_INFO = LCL_SMS_TEXT=>ANALYZE(
                            IV_TEXT     = IV_TEXT
                            IV_ENCODING = IV_ENCODING
                            IV_HEADER   = RS_RESULT-HEADER ).
    IF RS_RESULT-TEXT_INFO-OK EQ ABAP_FALSE.

      RS_RESULT-CODE = LIF_SMS=>CODE-BAD_TEXT.
      RS_RESULT-MESSAGE = RS_RESULT-TEXT_INFO-MESSAGE.
      RETURN.

    ENDIF.

    RS_RESULT-REQUEST = SEND_BODY( IS_RESULT = RS_RESULT
                                   IV_MASKED = ABAP_TRUE ).
    LV_BODY = SEND_BODY( IS_RESULT = RS_RESULT
                         IV_MASKED = ABAP_FALSE ).
    CONCATENATE LIF_SMS=>API_PATH `/send` INTO LV_PATH.
    FINISH_SEND( EXPORTING IV_DESTINATION = MV_DESTINATION
                           IV_PATH        = LV_PATH
                           IV_BODY        = LV_BODY
                           IV_DRY_RUN     = IV_DRY_RUN
                 CHANGING  CS_RESULT      = RS_RESULT ).

  ENDMETHOD.

  METHOD SEND_OTP.

    DATA: LV_BODY TYPE STRING,
          LV_PATH TYPE STRING.

    RS_RESULT-ACTION = LIF_SMS=>ACTION-OTP.
    RS_RESULT-HEADER = IV_HEADER.
    RS_RESULT-IYS = LIF_SMS=>IYS-INFO.

    CHECK_NUMBERS( EXPORTING IT_NUMBERS = IT_NUMBERS
                             IV_MAX     = 1
                   CHANGING  CS_RESULT  = RS_RESULT ).
    IF RS_RESULT-CODE IS INITIAL.

      CHECK_HEADER( CHANGING CS_RESULT = RS_RESULT ).

    ENDIF.
    IF RS_RESULT-CODE IS NOT INITIAL.

      RETURN.

    ENDIF.

    RS_RESULT-TEXT_INFO = LCL_SMS_TEXT=>CHECK_OTP(
                            IV_TEXT   = IV_TEXT
                            IV_HEADER = RS_RESULT-HEADER
                            IV_ASCII  = IV_ASCII ).
    IF RS_RESULT-TEXT_INFO-OK EQ ABAP_FALSE.

      RS_RESULT-CODE = LIF_SMS=>CODE-BAD_TEXT.
      RS_RESULT-MESSAGE = RS_RESULT-TEXT_INFO-MESSAGE.
      CLEAR RS_RESULT-TEXT_INFO-TEXT.
      RETURN.

    ENDIF.

    LV_BODY = OTP_BODY( RS_RESULT ).
    CLEAR RS_RESULT-TEXT_INFO-TEXT.
    CONCATENATE LIF_SMS=>API_PATH `/otp` INTO LV_PATH.
    FINISH_SEND( EXPORTING IV_DESTINATION = MV_DESTINATION
                           IV_PATH        = LV_PATH
                           IV_BODY        = LV_BODY
                           IV_DRY_RUN     = IV_DRY_RUN
                 CHANGING  CS_RESULT      = RS_RESULT ).

  ENDMETHOD.

  METHOD SEND_TEMPLATE.

    DATA LS_PARAM TYPE LIF_SMS=>TY_PARAM.

    DATA: LV_BODY  TYPE STRING,
          LV_PATH  TYPE STRING,
          LV_ASCII TYPE ABAP_BOOL.

    RS_RESULT-ACTION = LIF_SMS=>ACTION-TEMPLATE.
    RS_RESULT-HEADER = IV_HEADER.
    RS_RESULT-IYS = IV_IYS.
    RS_RESULT-SCHEDULE = IS_SCHEDULE.
    RS_RESULT-REFERENCE = IV_REFERENCE.
    RS_RESULT-TEMPLATE_ID = IV_TEMPLATE_ID.

    CHECK_NUMBERS( EXPORTING IT_NUMBERS = IT_NUMBERS
                             IV_MAX     = LIF_SMS=>MAX_RECIPIENTS
                   CHANGING  CS_RESULT  = RS_RESULT ).
    IF RS_RESULT-CODE IS INITIAL.

      CHECK_HEADER( CHANGING CS_RESULT = RS_RESULT ).

    ENDIF.
    IF RS_RESULT-CODE IS INITIAL.

      CHECK_IYS( CHANGING CS_RESULT = RS_RESULT ).

    ENDIF.
    IF RS_RESULT-CODE IS INITIAL.

      CHECK_SCHEDULE( CHANGING CS_RESULT = RS_RESULT ).

    ENDIF.
    IF RS_RESULT-CODE IS NOT INITIAL.

      RETURN.

    ENDIF.
    IF IV_TEMPLATE_ID LE 0.

      RS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      RS_RESULT-MESSAGE = LCL_TEXT=>GET( 'NO_TEMPLATE' ).
      RETURN.

    ENDIF.
    LOOP AT IT_PARAMS INTO LS_PARAM
         WHERE NAME IS INITIAL.

      RS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      RS_RESULT-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'BAD_PARAM'
                                         IV_1   = LS_PARAM-VALUE ).
      RETURN.

    ENDLOOP.

    " The template text is at Netgsm, so the program cannot see
    " which characters it has: AUTO means Turkish, to be safe
    CASE IV_ENCODING.

      WHEN LIF_SMS=>ENCODING-AUTO OR LIF_SMS=>ENCODING-TURKISH.

        RS_RESULT-TEXT_INFO-ENCODING = LIF_SMS=>ENCODING-TURKISH.

      WHEN LIF_SMS=>ENCODING-UNICODE.

        RS_RESULT-TEXT_INFO-ENCODING = LIF_SMS=>ENCODING-UNICODE.

      WHEN LIF_SMS=>ENCODING-ASCII.

        RS_RESULT-TEXT_INFO-ENCODING = LIF_SMS=>ENCODING-GSM.
        LV_ASCII = ABAP_TRUE.

      WHEN OTHERS.

        RS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
        RS_RESULT-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'BAD_ENC'
                                           IV_1   = IV_ENCODING ).
        RETURN.

    ENDCASE.

    RS_RESULT-REQUEST = TEMPLATE_BODY( IS_RESULT = RS_RESULT
                                       IT_PARAMS = IT_PARAMS
                                       IV_ASCII  = LV_ASCII
                                       IV_MASKED = ABAP_TRUE ).
    LV_BODY = TEMPLATE_BODY( IS_RESULT = RS_RESULT
                             IT_PARAMS = IT_PARAMS
                             IV_ASCII  = LV_ASCII
                             IV_MASKED = ABAP_FALSE ).
    CONCATENATE LIF_SMS=>API_PATH `/template/send` INTO LV_PATH.
    FINISH_SEND( EXPORTING IV_DESTINATION = MV_EXT_DESTINATION
                           IV_PATH        = LV_PATH
                           IV_BODY        = LV_BODY
                           IV_DRY_RUN     = IV_DRY_RUN
                 CHANGING  CS_RESULT      = RS_RESULT ).

  ENDMETHOD.

  METHOD CANCEL.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA: LV_BODY   TYPE STRING,
          LV_PATH   TYPE STRING,
          LV_STATUS TYPE I.

    RS_ANSWER-JOBID = IV_JOBID.
    CONDENSE RS_ANSWER-JOBID NO-GAPS.
    IF RS_ANSWER-JOBID IS INITIAL.

      RS_ANSWER-CODE = LIF_SMS=>CODE-BAD_INPUT.
      RS_ANSWER-MESSAGE = LCL_TEXT=>GET( 'NO_JOB' ).
      RETURN.

    ENDIF.
    LV_BODY = LCL_SMS_JSON=>ESCAPE( RS_ANSWER-JOBID ).
    CONCATENATE `{"jobid":"` LV_BODY `"}` INTO LV_BODY.
    CONCATENATE LIF_SMS=>API_PATH `/cancel` INTO LV_PATH.
    CALL_NETGSM( EXPORTING IV_ACTION      = LIF_SMS=>ACTION-CANCEL
                           IV_DESTINATION = MV_DESTINATION
                           IV_METHOD      = `POST`
                           IV_PATH        = LV_PATH
                           IV_BODY        = LV_BODY
                 IMPORTING EV_CODE        = RS_ANSWER-CODE
                           EV_MESSAGE     = RS_ANSWER-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = LV_STATUS ).

  ENDMETHOD.

  METHOD REPORT.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LS_LINE TYPE LIF_SMS=>TY_REPORT_LINE.

    DATA: LV_JOBID  TYPE STRING,
          LV_JOBS   TYPE STRING,
          LV_BODY   TYPE STRING,
          LV_PATH   TYPE STRING,
          LV_TEXT   TYPE STRING,
          LV_COUNT  TYPE I,
          LV_ROW    TYPE I,
          LV_STATUS TYPE I,
          LV_VALUE  TYPE STRING.

    LOOP AT IT_JOBIDS INTO LV_JOBID.

      CONDENSE LV_JOBID NO-GAPS.
      IF LV_JOBID IS INITIAL.

        CONTINUE.

      ENDIF.
      LV_COUNT = LV_COUNT + 1.
      LV_JOBID = LCL_SMS_JSON=>ESCAPE( LV_JOBID ).
      IF LV_COUNT EQ 1.

        CONCATENATE `"jobids":["` LV_JOBID `"` INTO LV_JOBS.

      ELSE.

        CONCATENATE LV_JOBS `,"` LV_JOBID `"` INTO LV_JOBS.

      ENDIF.

      CLEAR LV_JOBID.

    ENDLOOP.

    CLEAR LV_JOBID.
    IF LV_COUNT GT LIF_SMS=>MAX_JOBIDS.

      LV_TEXT = INT_TEXT( LIF_SMS=>MAX_JOBIDS ).
      RS_REPORT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      RS_REPORT-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'TOO_MANY_JOBS'
                                         IV_1   = LV_TEXT ).
      RETURN.

    ENDIF.
    CHECK_RANGE( EXPORTING IV_FROM    = IV_FROM
                           IV_TO      = IV_TO
                           IV_DAYS    = LIF_SMS=>MAX_REPORT_DAYS
                 IMPORTING EV_CODE    = RS_REPORT-CODE
                           EV_MESSAGE = RS_REPORT-MESSAGE ).
    IF RS_REPORT-CODE IS NOT INITIAL.

      RETURN.

    ENDIF.
    IF LV_COUNT EQ 0 AND IV_FROM IS INITIAL.

      RS_REPORT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      RS_REPORT-MESSAGE = LCL_TEXT=>GET( 'NO_CRITERIA' ).
      RETURN.

    ENDIF.

    IF LV_COUNT GT 0.

      CONCATENATE LV_JOBS `]` INTO LV_BODY.

    ENDIF.
    IF IV_FROM IS NOT INITIAL.

      LV_TEXT = FORMAT_TIME( IV_DATE  = IV_FROM
                             IV_TIME  = '000000'
                             IV_STYLE = 'DOT_S' ).
      IF LV_BODY IS NOT INITIAL.

        CONCATENATE LV_BODY `,` INTO LV_BODY.

      ENDIF.
      CONCATENATE LV_BODY `"startdate":"` LV_TEXT `"` INTO LV_BODY.
      LV_TEXT = FORMAT_TIME( IV_DATE  = IV_TO
                             IV_TIME  = '235959'
                             IV_STYLE = 'DOT_S' ).
      CONCATENATE LV_BODY `,"stopdate":"` LV_TEXT `"` INTO LV_BODY.

    ENDIF.
    IF IV_PAGE GT 0.

      LV_TEXT = INT_TEXT( IV_PAGE ).
      CONCATENATE LV_BODY `,"pagenumber":` LV_TEXT INTO LV_BODY.

    ENDIF.
    IF IV_PAGE_SIZE GT 0.

      LV_TEXT = INT_TEXT( IV_PAGE_SIZE ).
      CONCATENATE LV_BODY `,"pagesize":` LV_TEXT INTO LV_BODY.

    ENDIF.
    CONCATENATE `{` LV_BODY `}` INTO LV_BODY.

    CONCATENATE LIF_SMS=>API_PATH `/report` INTO LV_PATH.
    CALL_NETGSM( EXPORTING IV_ACTION      = LIF_SMS=>ACTION-REPORT
                           IV_DESTINATION = MV_DESTINATION
                           IV_METHOD      = `POST`
                           IV_PATH        = LV_PATH
                           IV_BODY        = LV_BODY
                 IMPORTING EV_CODE        = RS_REPORT-CODE
                           EV_MESSAGE     = RS_REPORT-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = LV_STATUS ).

    DO.

      LV_ROW = SY-INDEX.
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `status` ).
      LV_TEXT = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `jobid` ).
      IF LCL_SMS_JSON=>HAS( IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ) EQ ABAP_FALSE
         AND LCL_SMS_JSON=>HAS( IT_VALUES = LT_VALUES
                                IV_PATH   = LV_TEXT ) EQ ABAP_FALSE.

        EXIT.

      ENDIF.
      CLEAR LS_LINE.
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `jobid` ).
      LS_LINE-JOBID = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                              IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `number` ).
      LV_VALUE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                         IV_PATH   = LV_PATH ).
      LS_LINE-NUMBER = LCL_SMS_PHONE=>MASK_ANY( LV_VALUE ).
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `status` ).
      LS_LINE-STATUS = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                               IV_PATH   = LV_PATH ).
      LS_LINE-STATUS_TEXT = STATUS_TEXT( LS_LINE-STATUS ).
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `operator` ).
      LV_VALUE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                         IV_PATH   = LV_PATH ).
      LS_LINE-OPERATOR = OPERATOR_NAME( LV_VALUE ).
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `errorCode` ).
      LS_LINE-ERROR_CODE = LCL_SMS_JSON=>VALUE_OF(
                             IT_VALUES = LT_VALUES
                             IV_PATH   = LV_PATH ).
      LS_LINE-ERROR_TEXT = ERROR_TEXT( LS_LINE-ERROR_CODE ).
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `deliveredDate` ).
      LS_LINE-DELIVERED = LCL_SMS_JSON=>VALUE_OF(
                            IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `msglen` ).
      LS_LINE-MSGLEN = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                               IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `jobs` IV_ROW = LV_ROW
                          IV_FIELD = `referansID` ).
      LS_LINE-REFERENCE = LCL_SMS_JSON=>VALUE_OF(
                            IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ).
      APPEND LS_LINE TO RS_REPORT-LINES.

    ENDDO.

  ENDMETHOD.

  METHOD STATS.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LS_LINE TYPE LIF_SMS=>TY_STATS_LINE.

    DATA: LV_JOBID  TYPE STRING,
          LV_BODY   TYPE STRING,
          LV_PATH   TYPE STRING,
          LV_TEXT   TYPE STRING,
          LV_ROW    TYPE I,
          LV_STATUS TYPE I.

    LV_JOBID = IV_JOBID.
    CONDENSE LV_JOBID NO-GAPS.
    IF LV_JOBID IS INITIAL.

      RS_STATS-CODE = LIF_SMS=>CODE-BAD_INPUT.
      RS_STATS-MESSAGE = LCL_TEXT=>GET( 'NO_JOB' ).
      RETURN.

    ENDIF.
    LV_JOBID = LCL_SMS_JSON=>ESCAPE( LV_JOBID ).
    CONCATENATE `{"jobid":"` LV_JOBID `"` INTO LV_BODY.
    IF IV_SEND_DATE IS NOT INITIAL.

      LV_TEXT = FORMAT_TIME( IV_DATE  = IV_SEND_DATE
                             IV_TIME  = '000000'
                             IV_STYLE = 'ISO_S' ).
      CONCATENATE LV_BODY `,"senddate":"` LV_TEXT `"` INTO LV_BODY.

    ENDIF.
    CONCATENATE LV_BODY `}` INTO LV_BODY.

    CONCATENATE LIF_SMS=>API_PATH `/stats` INTO LV_PATH.
    CALL_NETGSM( EXPORTING IV_ACTION      = LIF_SMS=>ACTION-STATS
                           IV_DESTINATION = MV_DESTINATION
                           IV_METHOD      = `POST`
                           IV_PATH        = LV_PATH
                           IV_BODY        = LV_BODY
                 IMPORTING EV_CODE        = RS_STATS-CODE
                           EV_MESSAGE     = RS_STATS-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = LV_STATUS ).

    DO.

      LV_ROW = SY-INDEX.
      LV_PATH = ROW_PATH( IV_LIST = `stats` IV_ROW = LV_ROW
                          IV_FIELD = `status` ).
      IF LCL_SMS_JSON=>HAS( IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ) EQ ABAP_FALSE.

        EXIT.

      ENDIF.
      CLEAR LS_LINE.
      LS_LINE-STATUS = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                               IV_PATH   = LV_PATH ).
      LS_LINE-STATUS_TEXT = STATS_TEXT( LS_LINE-STATUS ).
      LV_PATH = ROW_PATH( IV_LIST = `stats` IV_ROW = LV_ROW
                          IV_FIELD = `totalSms` ).
      LS_LINE-TOTAL_SMS = LCL_SMS_JSON=>VALUE_OF(
                            IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `stats` IV_ROW = LV_ROW
                          IV_FIELD = `totalMessageLength` ).
      LS_LINE-TOTAL_PARTS = LCL_SMS_JSON=>VALUE_OF(
                              IT_VALUES = LT_VALUES
                              IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `stats` IV_ROW = LV_ROW
                          IV_FIELD = `chargeStatement` ).
      LS_LINE-CHARGE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                               IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `stats` IV_ROW = LV_ROW
                          IV_FIELD = `statement` ).
      LS_LINE-STATEMENT = LCL_SMS_JSON=>VALUE_OF(
                            IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `stats` IV_ROW = LV_ROW
                          IV_FIELD = `domestic` ).
      LS_LINE-DOMESTIC = LCL_SMS_JSON=>VALUE_OF(
                           IT_VALUES = LT_VALUES
                           IV_PATH   = LV_PATH ).
      APPEND LS_LINE TO RS_STATS-LINES.

    ENDDO.

  ENDMETHOD.

  METHOD INBOX.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LS_LINE TYPE LIF_SMS=>TY_INBOX_LINE.

    DATA: LV_PATH   TYPE STRING,
          LV_TEXT   TYPE STRING,
          LV_ROW    TYPE I,
          LV_STATUS TYPE I,
          LV_VALUE  TYPE STRING.

    CHECK_RANGE( EXPORTING IV_FROM    = IV_FROM
                           IV_TO      = IV_TO
                           IV_DAYS    = LIF_SMS=>MAX_INBOX_DAYS
                 IMPORTING EV_CODE    = RS_INBOX-CODE
                           EV_MESSAGE = RS_INBOX-MESSAGE ).
    IF RS_INBOX-CODE IS NOT INITIAL.

      RETURN.

    ENDIF.

    CONCATENATE LIF_SMS=>API_PATH `/inbox` INTO LV_PATH.
    IF IV_FROM IS NOT INITIAL.

      LV_TEXT = FORMAT_TIME( IV_DATE  = IV_FROM
                             IV_TIME  = '000000'
                             IV_STYLE = 'DMYHM' ).
      CONCATENATE LV_PATH `?startdate=` LV_TEXT INTO LV_PATH.
      LV_TEXT = FORMAT_TIME( IV_DATE  = IV_TO
                             IV_TIME  = '235900'
                             IV_STYLE = 'DMYHM' ).
      CONCATENATE LV_PATH `&stopdate=` LV_TEXT INTO LV_PATH.

    ENDIF.
    CALL_NETGSM( EXPORTING IV_ACTION      = LIF_SMS=>ACTION-INBOX
                           IV_DESTINATION = MV_DESTINATION
                           IV_METHOD      = `GET`
                           IV_PATH        = LV_PATH
                 IMPORTING EV_CODE        = RS_INBOX-CODE
                           EV_MESSAGE     = RS_INBOX-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = LV_STATUS ).

    DO.

      LV_ROW = SY-INDEX.
      LV_PATH = ROW_PATH( IV_LIST = `messages` IV_ROW = LV_ROW
                          IV_FIELD = `id` ).
      IF LCL_SMS_JSON=>HAS( IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ) EQ ABAP_FALSE.

        EXIT.

      ENDIF.
      CLEAR LS_LINE.
      LS_LINE-ID = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                           IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `messages` IV_ROW = LV_ROW
                          IV_FIELD = `gorevId` ).
      LS_LINE-JOBID = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                              IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `messages` IV_ROW = LV_ROW
                          IV_FIELD = `kayittar` ).
      LV_VALUE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                         IV_PATH   = LV_PATH ).
      LS_LINE-RECEIVED = TURKISH_TIME( LV_VALUE ).
      LV_PATH = ROW_PATH( IV_LIST = `messages` IV_ROW = LV_ROW
                          IV_FIELD = `gonderen` ).
      LV_VALUE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                         IV_PATH   = LV_PATH ).
      IF IV_FULL_NUMBERS EQ ABAP_TRUE.

        LS_LINE-SENDER = LV_VALUE.

      ELSE.

        LS_LINE-SENDER = LCL_SMS_PHONE=>MASK_ANY( LV_VALUE ).

      ENDIF.
      LV_PATH = ROW_PATH( IV_LIST = `messages` IV_ROW = LV_ROW
                          IV_FIELD = `operator` ).
      LS_LINE-OPERATOR = LCL_SMS_JSON=>VALUE_OF(
                           IT_VALUES = LT_VALUES
                           IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `messages` IV_ROW = LV_ROW
                          IV_FIELD = `mesaj` ).
      LS_LINE-TEXT = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                             IV_PATH   = LV_PATH ).
      APPEND LS_LINE TO RS_INBOX-LINES.

    ENDDO.

  ENDMETHOD.

  METHOD HEADERS.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LS_VALUE TYPE LCL_SMS_JSON=>TY_VALUE.

    DATA: LV_PATH   TYPE STRING,
          LV_STATUS TYPE I.

    CONCATENATE LIF_SMS=>API_PATH `/msgheader` INTO LV_PATH.
    CALL_NETGSM( EXPORTING IV_ACTION      = LIF_SMS=>ACTION-HEADERS
                           IV_DESTINATION = MV_DESTINATION
                           IV_METHOD      = `GET`
                           IV_PATH        = LV_PATH
                 IMPORTING EV_CODE        = RS_HEADERS-CODE
                           EV_MESSAGE     = RS_HEADERS-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = LV_STATUS ).
    LOOP AT LT_VALUES INTO LS_VALUE.

      IF LS_VALUE-PATH CP 'msgheaders/*'.

        APPEND LS_VALUE-VALUE TO RS_HEADERS-NAMES.

      ENDIF.

      CLEAR LS_VALUE.

    ENDLOOP.

    CLEAR LS_VALUE.

  ENDMETHOD.

  METHOD TEMPLATES.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LS_LINE TYPE LIF_SMS=>TY_TEMPLATE.

    DATA: LV_PATH   TYPE STRING,
          LV_TEXT   TYPE STRING,
          LV_ROW    TYPE I,
          LV_PARAM  TYPE I,
          LV_STATUS TYPE I,
          LV_NAME   TYPE STRING,
          LV_TYPE   TYPE STRING,
          LV_MAX    TYPE STRING,
          LV_PREFIX TYPE STRING.

    LV_TEXT = INT_TEXT( IV_PAGE ).
    CONCATENATE LIF_SMS=>API_PATH `/template/list?page=` LV_TEXT
      INTO LV_PATH.
    LV_TEXT = INT_TEXT( IV_SIZE ).
    CONCATENATE LV_PATH `&size=` LV_TEXT INTO LV_PATH.
    IF IV_PUBLIC EQ ABAP_TRUE.

      CONCATENATE LV_PATH `&includePublic=true` INTO LV_PATH.

    ELSE.

      CONCATENATE LV_PATH `&includePublic=false` INTO LV_PATH.

    ENDIF.
    IF IV_SEARCH IS NOT INITIAL.

      LV_TEXT = URL_ENCODE( IV_SEARCH ).
      CONCATENATE LV_PATH `&search=` LV_TEXT INTO LV_PATH.

    ENDIF.
    IF IV_TYPE IS NOT INITIAL.

      LV_TEXT = URL_ENCODE( IV_TYPE ).
      CONCATENATE LV_PATH `&type=` LV_TEXT INTO LV_PATH.

    ENDIF.
    IF IV_CONTENT IS NOT INITIAL.

      LV_TEXT = URL_ENCODE( IV_CONTENT ).
      CONCATENATE LV_PATH `&context=` LV_TEXT INTO LV_PATH.

    ENDIF.

    CALL_NETGSM( EXPORTING IV_ACTION      = LIF_SMS=>ACTION-TEMPLATES
                           IV_DESTINATION = MV_EXT_DESTINATION
                           IV_METHOD      = `GET`
                           IV_PATH        = LV_PATH
                 IMPORTING EV_CODE        = RS_TEMPLATES-CODE
                           EV_MESSAGE     = RS_TEMPLATES-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = LV_STATUS ).
    RS_TEMPLATES-PAGE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                                IV_PATH   = `page` ).
    RS_TEMPLATES-PAGES = LCL_SMS_JSON=>VALUE_OF(
                           IT_VALUES = LT_VALUES
                           IV_PATH   = `totalPages` ).
    RS_TEMPLATES-TOTAL = LCL_SMS_JSON=>VALUE_OF(
                           IT_VALUES = LT_VALUES
                           IV_PATH   = `totalElements` ).

    DO.

      LV_ROW = SY-INDEX.
      LV_PATH = ROW_PATH( IV_LIST = `templates` IV_ROW = LV_ROW
                          IV_FIELD = `templateId` ).
      IF LCL_SMS_JSON=>HAS( IT_VALUES = LT_VALUES
                            IV_PATH   = LV_PATH ) EQ ABAP_FALSE.

        EXIT.

      ENDIF.
      CLEAR LS_LINE.
      LS_LINE-ID = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                           IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `templates` IV_ROW = LV_ROW
                          IV_FIELD = `type` ).
      LS_LINE-TYPE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                             IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `templates` IV_ROW = LV_ROW
                          IV_FIELD = `description` ).
      LS_LINE-DESCRIPTION = LCL_SMS_JSON=>VALUE_OF(
                              IT_VALUES = LT_VALUES
                              IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `templates` IV_ROW = LV_ROW
                          IV_FIELD = `templateContent` ).
      LS_LINE-CONTENT = LCL_SMS_JSON=>VALUE_OF(
                          IT_VALUES = LT_VALUES
                          IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `templates` IV_ROW = LV_ROW
                          IV_FIELD = `public` ).
      LS_LINE-PUBLIC = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                               IV_PATH   = LV_PATH ).
      LV_PATH = ROW_PATH( IV_LIST = `templates` IV_ROW = LV_ROW
                          IV_FIELD = `registryDate` ).
      LS_LINE-REGISTERED = LCL_SMS_JSON=>VALUE_OF(
                             IT_VALUES = LT_VALUES
                             IV_PATH   = LV_PATH ).
      " parameters/n/name, type, maxLength
      LV_PREFIX = ROW_PATH( IV_LIST = `templates` IV_ROW = LV_ROW
                            IV_FIELD = `parameters` ).
      DO.

        LV_PARAM = SY-INDEX.
        LV_PATH = ROW_PATH( IV_LIST = LV_PREFIX IV_ROW = LV_PARAM
                            IV_FIELD = `name` ).
        IF LCL_SMS_JSON=>HAS( IT_VALUES = LT_VALUES
                              IV_PATH   = LV_PATH ) EQ ABAP_FALSE.

          EXIT.

        ENDIF.
        LV_NAME = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                          IV_PATH   = LV_PATH ).
        LV_PATH = ROW_PATH( IV_LIST = LV_PREFIX IV_ROW = LV_PARAM
                            IV_FIELD = `type` ).
        LV_TYPE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                          IV_PATH   = LV_PATH ).
        LV_PATH = ROW_PATH( IV_LIST = LV_PREFIX IV_ROW = LV_PARAM
                            IV_FIELD = `maxLength` ).
        LV_MAX = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                         IV_PATH   = LV_PATH ).
        IF LV_MAX IS NOT INITIAL.

          CONCATENATE LV_TYPE `, ` LV_MAX INTO LV_TYPE.

        ENDIF.
        CONCATENATE LV_NAME ` (` LV_TYPE `)` INTO LV_NAME.
        IF LS_LINE-PARAMETERS IS INITIAL.

          LS_LINE-PARAMETERS = LV_NAME.

        ELSE.

          CONCATENATE LS_LINE-PARAMETERS `; ` LV_NAME
            INTO LS_LINE-PARAMETERS.

        ENDIF.

      ENDDO.
      APPEND LS_LINE TO RS_TEMPLATES-LINES.

    ENDDO.

  ENDMETHOD.

  METHOD LENGTH.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    DATA: LV_TEXT   TYPE STRING,
          LV_BODY   TYPE STRING,
          LV_PATH   TYPE STRING,
          LV_CODE   TYPE STRING,
          LV_STATUS TYPE I.

    LS_INFO = LCL_SMS_TEXT=>ANALYZE( IV_TEXT     = IV_TEXT
                                     IV_ENCODING = IV_ENCODING
                                     IV_HEADER   = IV_HEADER ).
    IF LS_INFO-ENCODING IS INITIAL.

      RS_LENGTH-CODE = LIF_SMS=>CODE-BAD_TEXT.
      RS_LENGTH-MESSAGE = LS_INFO-MESSAGE.
      RETURN.

    ENDIF.
    RS_LENGTH-ENCODING = LS_INFO-ENCODING.
    CASE LS_INFO-ENCODING.

      WHEN LIF_SMS=>ENCODING-TURKISH.

        LV_CODE = `11`.

      WHEN LIF_SMS=>ENCODING-UNICODE.

        LV_CODE = `8`.

      WHEN OTHERS.

        LV_CODE = `0`.

    ENDCASE.
    LV_TEXT = LCL_SMS_JSON=>ESCAPE( LS_INFO-TEXT ).
    CONCATENATE `{"context":"` LV_TEXT `","encoding":` LV_CODE
      INTO LV_BODY.
    IF LS_INFO-SUFFIX GT 0.

      CONCATENATE LV_BODY `,"customHeader":true}` INTO LV_BODY.

    ELSE.

      CONCATENATE LV_BODY `,"customHeader":false}` INTO LV_BODY.

    ENDIF.

    CONCATENATE LIF_SMS=>API_PATH `/length` INTO LV_PATH.
    CALL_NETGSM( EXPORTING IV_ACTION      = LIF_SMS=>ACTION-LENGTH
                           IV_DESTINATION = MV_DESTINATION
                           IV_METHOD      = `POST`
                           IV_PATH        = LV_PATH
                           IV_BODY        = LV_BODY
                 IMPORTING EV_CODE        = RS_LENGTH-CODE
                           EV_MESSAGE     = RS_LENGTH-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = LV_STATUS ).
    RS_LENGTH-PARTS = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                              IV_PATH   = `parts` ).
    RS_LENGTH-USED = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                             IV_PATH   = `charsUsed` ).
    RS_LENGTH-LEFT = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                             IV_PATH   = `charsLeft` ).
    RS_LENGTH-LEFT_PART = LCL_SMS_JSON=>VALUE_OF(
                            IT_VALUES = LT_VALUES
                            IV_PATH   = `charsLeftUntilNextPart` ).

  ENDMETHOD.

  METHOD CODE_TEXT.

    DATA: LV_CODE   TYPE STRING,
          LV_KEY    TYPE STRING,
          LV_PREFIX TYPE STRING,
          LV_VALUE  TYPE STRING,
          LV_LEN    TYPE I.

    LV_CODE = IV_CODE.
    LV_LEN = STRLEN( LV_CODE ).
    " 100-110: system errors, all the same text
    IF LV_LEN EQ 3 AND LV_CODE(1) EQ '1' AND LV_CODE CO '0123456789'.

      LV_CODE = `100`.

    ENDIF.
    IF IV_ACTION EQ LIF_SMS=>ACTION-OTP.

      CASE LV_CODE.

        WHEN `41`.

          LV_CODE = `40`.

        WHEN `51` OR `52`.

          LV_CODE = `50`.

      ENDCASE.

    ENDIF.

    CASE IV_ACTION.

      WHEN LIF_SMS=>ACTION-SEND.

        LV_PREFIX = `SEND`.

      WHEN LIF_SMS=>ACTION-OTP.

        LV_PREFIX = `OTP`.

      WHEN LIF_SMS=>ACTION-TEMPLATE.

        LV_PREFIX = `TPL`.

      WHEN LIF_SMS=>ACTION-CANCEL.

        LV_PREFIX = `CANCEL`.

      WHEN LIF_SMS=>ACTION-REPORT.

        LV_PREFIX = `REPORT`.

      WHEN LIF_SMS=>ACTION-INBOX.

        LV_PREFIX = `INBOX`.

      WHEN LIF_SMS=>ACTION-LENGTH.

        LV_PREFIX = `LENGTH`.

      WHEN OTHERS.

        LV_PREFIX = `OTHER`.

    ENDCASE.
    CONCATENATE LV_PREFIX `_` LV_CODE INTO LV_KEY.
    RV_TEXT = LCL_TEXT=>GET( LV_KEY ).
    IF RV_TEXT NE LV_KEY.

      RETURN.

    ENDIF.

    IF LV_CODE EQ `00`.

      IF IV_ACTION EQ LIF_SMS=>ACTION-SEND
         OR IV_ACTION EQ LIF_SMS=>ACTION-OTP
         OR IV_ACTION EQ LIF_SMS=>ACTION-TEMPLATE.

        RV_TEXT = LCL_TEXT=>GET( 'C00' ).

      ELSE.

        RV_TEXT = LCL_TEXT=>GET( 'C00_OK' ).

      ENDIF.
      RETURN.

    ENDIF.

    " C100 shows the original code (100 to 110) in its text
    CONCATENATE `C` LV_CODE INTO LV_KEY.
    RV_TEXT = LCL_TEXT=>GET( IV_KEY = LV_KEY
                             IV_1   = IV_CODE ).
    IF RV_TEXT NE LV_KEY.

      RETURN.

    ENDIF.

    LV_VALUE = IV_DESCRIPTION.
    IF LV_VALUE IS NOT INITIAL.

      CONCATENATE `(` LV_VALUE `)` INTO LV_VALUE.

    ENDIF.
    RV_TEXT = LCL_TEXT=>GET( IV_KEY = 'C_OTHER'
                             IV_1   = IV_CODE
                             IV_2   = LV_VALUE ).

  ENDMETHOD.

  METHOD FORMAT_TIME.

    CASE IV_STYLE.

      WHEN 'DMYHM'.

        CONCATENATE IV_DATE+6(2) IV_DATE+4(2) IV_DATE(4)
                    IV_TIME(2) IV_TIME+2(2)
          INTO RV_TEXT.

      WHEN 'ISO_M'.

        CONCATENATE IV_DATE(4) '-' IV_DATE+4(2) '-' IV_DATE+6(2) ` `
                    IV_TIME(2) ':' IV_TIME+2(2)
          INTO RV_TEXT.

      WHEN 'DOT_S'.

        CONCATENATE IV_DATE+6(2) '.' IV_DATE+4(2) '.' IV_DATE(4) ` `
                    IV_TIME(2) ':' IV_TIME+2(2) ':' IV_TIME+4(2)
          INTO RV_TEXT.

      WHEN OTHERS.

        CONCATENATE IV_DATE(4) '-' IV_DATE+4(2) '-' IV_DATE+6(2) ` `
                    IV_TIME(2) ':' IV_TIME+2(2) ':' IV_TIME+4(2)
          INTO RV_TEXT.

    ENDCASE.

  ENDMETHOD.

  METHOD TURKISH_TIME.

    DATA: LV_MILLIS  TYPE STRING,
          LV_SECONDS TYPE P LENGTH 16 DECIMALS 0,
          LV_DAYS    TYPE I,
          LV_REST    TYPE I,
          LV_DATE    TYPE D,
          LV_TIME    TYPE T.

    LV_MILLIS = IV_MILLIS.
    CONDENSE LV_MILLIS NO-GAPS.
    IF LV_MILLIS IS INITIAL OR NOT LV_MILLIS CO '0123456789'
       OR STRLEN( LV_MILLIS ) GT 15.

      RV_TEXT = LV_MILLIS.
      RETURN.

    ENDIF.
    LV_SECONDS = LV_MILLIS.
    LV_SECONDS = LV_SECONDS DIV 1000
                 + LIF_SMS=>TURKEY_OFFSET_SECONDS.
    LV_DAYS = LV_SECONDS DIV 86400.
    LV_REST = LV_SECONDS MOD 86400.
    LV_DATE = '19700101'.
    LV_DATE = LV_DATE + LV_DAYS.
    LV_TIME = LV_REST.
    RV_TEXT = FORMAT_TIME( IV_DATE  = LV_DATE
                           IV_TIME  = LV_TIME
                           IV_STYLE = 'DOT_S' ).

  ENDMETHOD.

  METHOD URL_ENCODE.

    DATA LO_OUT TYPE REF TO CL_ABAP_CONV_OUT_CE.

    DATA: LV_TEXT  TYPE STRING,
          LV_BYTES TYPE XSTRING,
          LV_BYTE  TYPE X LENGTH 1,
          LV_LEN   TYPE I,
          LV_POS   TYPE I,
          LV_VALUE TYPE I,
          LV_CHAR  TYPE C LENGTH 1,
          LV_HEX   TYPE C LENGTH 2.

    LV_TEXT = IV_TEXT.
    IF LV_TEXT IS INITIAL.

      RETURN.

    ENDIF.
    LO_OUT = CL_ABAP_CONV_OUT_CE=>CREATE( ENCODING = 'UTF-8' ).
    LO_OUT->CONVERT( EXPORTING DATA   = LV_TEXT
                     IMPORTING BUFFER = LV_BYTES ).
    LV_LEN = XSTRLEN( LV_BYTES ).
    DO LV_LEN TIMES.

      LV_POS = SY-INDEX - 1.
      LV_BYTE = LV_BYTES+LV_POS(1).
      LV_VALUE = LV_BYTE.
      " Letters, digits and - . _ ~ stay; the rest becomes %XX
      IF ( LV_VALUE GE 48 AND LV_VALUE LE 57 )
         OR ( LV_VALUE GE 65 AND LV_VALUE LE 90 )
         OR ( LV_VALUE GE 97 AND LV_VALUE LE 122 )
         OR LV_VALUE EQ 45 OR LV_VALUE EQ 46 OR LV_VALUE EQ 95
         OR LV_VALUE EQ 126.

        LV_CHAR = CL_ABAP_CONV_IN_CE=>UCCPI( LV_VALUE ).
        CONCATENATE RV_TEXT LV_CHAR INTO RV_TEXT.

      ELSE.

        LV_HEX = LV_BYTE.
        CONCATENATE RV_TEXT '%' LV_HEX INTO RV_TEXT.

      ENDIF.

    ENDDO.

  ENDMETHOD.

  METHOD CALL_NETGSM.

    DATA LX_ERROR TYPE REF TO LCX_SMS.

    DATA LS_HTTP TYPE LIF_SMS=>TY_HTTP.

    DATA: LV_DESCRIPTION TYPE STRING,
          LV_STATUS      TYPE STRING.

    CLEAR: EV_CODE, EV_MESSAGE, ET_VALUES, EV_STATUS.
    CHECK_ACCESS( EXPORTING IV_DESTINATION = IV_DESTINATION
                  IMPORTING EV_CODE        = EV_CODE
                            EV_MESSAGE     = EV_MESSAGE ).
    IF EV_CODE IS NOT INITIAL.

      RETURN.

    ENDIF.
    TRY.

        LS_HTTP = MO_BACKEND->CALL( IV_DESTINATION = IV_DESTINATION
                                    IV_METHOD      = IV_METHOD
                                    IV_PATH        = IV_PATH
                                    IV_BODY        = IV_BODY ).
        EV_STATUS = LS_HTTP-STATUS.
        READ_ANSWER( EXPORTING IS_HTTP        = LS_HTTP
                     IMPORTING EV_CODE        = EV_CODE
                               EV_DESCRIPTION = LV_DESCRIPTION
                               ET_VALUES      = ET_VALUES ).

      CATCH LCX_SMS INTO LX_ERROR.

        EV_CODE = LX_ERROR->CODE.
        EV_MESSAGE = LX_ERROR->TEXT.
        IF IV_ACTION EQ LIF_SMS=>ACTION-OTP.

          CASE EV_CODE.

            WHEN LIF_SMS=>CODE-HTTP.

              " 7.00: no method call as an actual parameter
              LV_STATUS = INT_TEXT( EV_STATUS ).
              EV_MESSAGE = LCL_TEXT=>GET( IV_KEY = 'HTTP'
                                          IV_1   = LV_STATUS ).

            WHEN LIF_SMS=>CODE-NO_CONN.

              EV_MESSAGE = LCL_TEXT=>GET( 'OTP_CONN' ).

            WHEN LIF_SMS=>CODE-NO_TRUST OR LIF_SMS=>CODE-NO_DEST
              OR LIF_SMS=>CODE-NO_AUTH.

              EV_MESSAGE = LCL_TEXT=>GET( IV_KEY = EV_CODE
                                          IV_1 = IV_DESTINATION ).

            WHEN OTHERS.

              EV_MESSAGE = LCL_TEXT=>GET( 'OTP_REPLY' ).

          ENDCASE.

        ENDIF.
        RETURN.

    ENDTRY.
    IF IV_ACTION EQ LIF_SMS=>ACTION-OTP.

      CLEAR LV_DESCRIPTION.
      IF EV_CODE CN '0123456789' OR STRLEN( EV_CODE ) GT 3.

        EV_CODE = LIF_SMS=>CODE-BAD_REPLY.
        EV_MESSAGE = LCL_TEXT=>GET( 'OTP_REPLY' ).
        CLEAR ET_VALUES.
        RETURN.

      ENDIF.

    ENDIF.
    EV_MESSAGE = CODE_TEXT( IV_ACTION      = IV_ACTION
                            IV_CODE        = EV_CODE
                            IV_DESCRIPTION = LV_DESCRIPTION ).

  ENDMETHOD.

  METHOD CHECK_ACCESS.

    DATA LV_TYPE TYPE RFCDES-RFCTYPE.

    CLEAR: EV_CODE, EV_MESSAGE.
    LV_TYPE = MO_BACKEND->DESTINATION_TYPE( IV_DESTINATION ).
    IF LV_TYPE IS INITIAL.

      EV_CODE = LIF_SMS=>CODE-NO_DEST.
      EV_MESSAGE = LCL_TEXT=>GET( IV_KEY = 'NO_DEST'
                                  IV_1   = IV_DESTINATION ).

    ELSEIF LV_TYPE NE 'G'.

      EV_CODE = LIF_SMS=>CODE-NO_DEST.
      EV_MESSAGE = LCL_TEXT=>GET( IV_KEY = 'DEST_TYPE'
                                  IV_1   = IV_DESTINATION
                                  IV_2   = LV_TYPE ).

    ELSEIF MO_BACKEND->HAS_AUTHORITY( IV_DESTINATION ) EQ ABAP_FALSE.

      EV_CODE = LIF_SMS=>CODE-NO_AUTH.
      EV_MESSAGE = LCL_TEXT=>GET( IV_KEY = 'NO_AUTH'
                                  IV_1   = IV_DESTINATION ).

    ENDIF.

  ENDMETHOD.

  METHOD READ_ANSWER.

    DATA: LV_BODY   TYPE STRING,
          LV_STATUS TYPE C LENGTH 11,
          LV_TEXT   TYPE STRING.

    CLEAR: EV_CODE, EV_DESCRIPTION, ET_VALUES.
    LV_BODY = IS_HTTP-BODY.
    CONDENSE LV_BODY.

    IF LV_BODY IS NOT INITIAL AND LV_BODY(1) EQ `{`.

      ET_VALUES = LCL_SMS_JSON=>PARSE( LV_BODY ).
      EV_CODE = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = ET_VALUES
                                        IV_PATH   = `code` ).
      EV_DESCRIPTION = LCL_SMS_JSON=>VALUE_OF(
                         IT_VALUES = ET_VALUES
                         IV_PATH   = `description` ).
      " Statistics and length answer without a code when all is well
      IF EV_CODE IS INITIAL
         AND ( EV_DESCRIPTION EQ `success`
               OR LCL_SMS_JSON=>HAS( IT_VALUES = ET_VALUES
                                     IV_PATH   = `parts` )
                  EQ ABAP_TRUE ).

        EV_CODE = LIF_SMS=>CODE-OK.

      ENDIF.

    ELSEIF LV_BODY CO '0123456789 '.

      " Older answers are plain text: the code, maybe a job ID
      SPLIT LV_BODY AT ` ` INTO EV_CODE EV_DESCRIPTION.

    ENDIF.

    " Netgsm also answers with HTTP 406 and a normal code in the
    " body (seen live: 406 with code 00 and 406 with code 30), so
    " the code in the body wins over the HTTP status
    IF EV_CODE IS INITIAL AND IS_HTTP-STATUS NE 200.

      LV_STATUS = IS_HTTP-STATUS.
      CONDENSE LV_STATUS.
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'HTTP'
                               IV_1   = LV_STATUS
                               IV_2   = IS_HTTP-REASON ).
      IF LV_BODY IS NOT INITIAL.

        CONCATENATE LV_TEXT ` ` LV_BODY INTO LV_TEXT.

      ENDIF.
      RAISE EXCEPTION TYPE LCX_SMS
        EXPORTING
          CODE = LIF_SMS=>CODE-HTTP
          TEXT = LV_TEXT.

    ENDIF.

    IF EV_CODE IS INITIAL.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'BAD_REPLY'
                               IV_1   = LV_BODY ).
      RAISE EXCEPTION TYPE LCX_SMS
        EXPORTING
          CODE = LIF_SMS=>CODE-BAD_REPLY
          TEXT = LV_TEXT.

    ENDIF.

  ENDMETHOD.

  METHOD CHECK_NUMBERS.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    DATA LV_MAX TYPE STRING.

    CS_RESULT-RECIPIENTS = LCL_SMS_PHONE=>NORMALIZE_ALL( IT_NUMBERS ).
    CS_RESULT-VALID = 0.
    LOOP AT CS_RESULT-RECIPIENTS INTO LS_RECIPIENT
         WHERE OK EQ ABAP_TRUE.

      CS_RESULT-VALID = CS_RESULT-VALID + 1.

      CLEAR LS_RECIPIENT.

    ENDLOOP.

    CLEAR LS_RECIPIENT.
    IF CS_RESULT-VALID EQ 0.

      CS_RESULT-CODE = LIF_SMS=>CODE-BAD_NUMBER.
      CS_RESULT-MESSAGE = LCL_TEXT=>GET( 'NO_NUMBERS' ).

    ELSEIF CS_RESULT-VALID GT IV_MAX.

      CS_RESULT-CODE = LIF_SMS=>CODE-BAD_NUMBER.
      IF IV_MAX EQ 1.

        CS_RESULT-MESSAGE = LCL_TEXT=>GET( 'OTP_ONE' ).

      ELSE.

        LV_MAX = INT_TEXT( IV_MAX ).
        CS_RESULT-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'TOO_MANY'
                                           IV_1   = LV_MAX ).

      ENDIF.

    ENDIF.

  ENDMETHOD.

  METHOD CHECK_HEADER.

    DATA LV_LEN TYPE I.

    LV_LEN = STRLEN( CS_RESULT-HEADER ).
    IF LV_LEN EQ 0.

      CS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      CS_RESULT-MESSAGE = LCL_TEXT=>GET( 'NO_HEADER' ).

    ELSEIF LV_LEN LT 3 OR LV_LEN GT 11.

      CS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      CS_RESULT-MESSAGE = LCL_TEXT=>GET( 'HEADER_LEN' ).

    ENDIF.

  ENDMETHOD.

  METHOD CHECK_IYS.

    IF CS_RESULT-IYS NE LIF_SMS=>IYS-INFO
       AND CS_RESULT-IYS NE LIF_SMS=>IYS-INDIVIDUAL
       AND CS_RESULT-IYS NE LIF_SMS=>IYS-MERCHANT.

      CS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      CS_RESULT-MESSAGE = LCL_TEXT=>GET( IV_KEY = 'BAD_IYS'
                                         IV_1   = CS_RESULT-IYS ).

    ENDIF.

  ENDMETHOD.

  METHOD CHECK_SCHEDULE.

    DATA: LV_START TYPE C LENGTH 14,
          LV_STOP  TYPE C LENGTH 14.

    IF CS_RESULT-SCHEDULE-START_DATE IS INITIAL
       OR CS_RESULT-SCHEDULE-START_DATE EQ '00000000'.

      IF CS_RESULT-SCHEDULE-STOP_DATE IS NOT INITIAL
         AND CS_RESULT-SCHEDULE-STOP_DATE NE '00000000'.

        CS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
        CS_RESULT-MESSAGE = LCL_TEXT=>GET( 'SCHED_NO_START' ).

      ENDIF.
      CLEAR CS_RESULT-SCHEDULE.
      RETURN.

    ENDIF.
    IF CS_RESULT-SCHEDULE-STOP_DATE IS INITIAL
       OR CS_RESULT-SCHEDULE-STOP_DATE EQ '00000000'.

      CLEAR: CS_RESULT-SCHEDULE-STOP_DATE,
             CS_RESULT-SCHEDULE-STOP_TIME.
      RETURN.

    ENDIF.
    CONCATENATE CS_RESULT-SCHEDULE-START_DATE
                CS_RESULT-SCHEDULE-START_TIME
      INTO LV_START.
    CONCATENATE CS_RESULT-SCHEDULE-STOP_DATE
                CS_RESULT-SCHEDULE-STOP_TIME
      INTO LV_STOP.
    IF LV_STOP LE LV_START.

      CS_RESULT-CODE = LIF_SMS=>CODE-BAD_INPUT.
      CS_RESULT-MESSAGE = LCL_TEXT=>GET( 'SCHED_STOP' ).

    ENDIF.

  ENDMETHOD.

  METHOD CHECK_RANGE.

    DATA: LV_DAYS TYPE I,
          LV_MAX  TYPE STRING.

    CLEAR: EV_CODE, EV_MESSAGE.
    IF IV_FROM IS INITIAL AND IV_TO IS INITIAL.

      RETURN.

    ENDIF.
    IF IV_FROM IS INITIAL OR IV_TO IS INITIAL.

      EV_CODE = LIF_SMS=>CODE-BAD_INPUT.
      EV_MESSAGE = LCL_TEXT=>GET( 'RANGE_BOTH' ).

    ELSEIF IV_TO LT IV_FROM.

      EV_CODE = LIF_SMS=>CODE-BAD_INPUT.
      EV_MESSAGE = LCL_TEXT=>GET( 'RANGE_ORDER' ).

    ELSE.

      LV_DAYS = IV_TO - IV_FROM.
      IF LV_DAYS GT IV_DAYS.

        LV_MAX = INT_TEXT( IV_DAYS ).
        EV_CODE = LIF_SMS=>CODE-BAD_INPUT.
        EV_MESSAGE = LCL_TEXT=>GET( IV_KEY = 'RANGE_LONG'
                                    IV_1   = LV_MAX ).

      ENDIF.

    ENDIF.

  ENDMETHOD.

  METHOD FINISH_SEND.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LV_UNSURE TYPE STRING.

    " Destination and authorization, also for the preview
    CHECK_ACCESS( EXPORTING IV_DESTINATION = IV_DESTINATION
                  IMPORTING EV_CODE        = CS_RESULT-CODE
                            EV_MESSAGE     = CS_RESULT-MESSAGE ).
    IF CS_RESULT-CODE IS NOT INITIAL.

      RETURN.

    ENDIF.
    IF IV_DRY_RUN EQ ABAP_TRUE.

      CS_RESULT-CODE = LIF_SMS=>CODE-DRY_RUN.
      CS_RESULT-MESSAGE = LCL_TEXT=>GET( 'DRY_RUN' ).
      RETURN.

    ENDIF.

    " From here on, any answer means Netgsm may have it
    CALL_NETGSM( EXPORTING IV_ACTION      = CS_RESULT-ACTION
                           IV_DESTINATION = IV_DESTINATION
                           IV_METHOD      = `POST`
                           IV_PATH        = IV_PATH
                           IV_BODY        = IV_BODY
                 IMPORTING EV_CODE        = CS_RESULT-CODE
                           EV_MESSAGE     = CS_RESULT-MESSAGE
                           ET_VALUES      = LT_VALUES
                           EV_STATUS      = CS_RESULT-HTTP_STATUS ).
    IF CS_RESULT-CODE EQ LIF_SMS=>CODE-NO_CONN.

      LV_UNSURE = LCL_TEXT=>GET( 'UNSURE' ).
      CONCATENATE CS_RESULT-MESSAGE LV_UNSURE
        INTO CS_RESULT-MESSAGE
        SEPARATED BY ` `.
      RETURN.

    ENDIF.
    IF CS_RESULT-ACTION NE LIF_SMS=>ACTION-OTP.

      CS_RESULT-DESCRIPTION = LCL_SMS_JSON=>VALUE_OF(
                              IT_VALUES = LT_VALUES
                              IV_PATH   = `description` ).

    ENDIF.
    IF CS_RESULT-CODE EQ `00` OR CS_RESULT-CODE EQ `01`
       OR CS_RESULT-CODE EQ `02`.

      CS_RESULT-SENT = ABAP_TRUE.

    ENDIF.
    IF CS_RESULT-ACTION NE LIF_SMS=>ACTION-OTP OR
       CS_RESULT-SENT EQ ABAP_TRUE.

      CS_RESULT-JOBID = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = LT_VALUES
                                               IV_PATH = `jobid` ).

    ENDIF.

  ENDMETHOD.

  METHOD SEND_BODY.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    DATA: LV_TEXT   TYPE STRING,
          LV_NUMBER TYPE STRING,
          LV_HEADER TYPE STRING,
          LV_EXTRA  TYPE STRING,
          LV_FIRST  TYPE ABAP_BOOL VALUE ABAP_TRUE.

    LV_TEXT = LCL_SMS_JSON=>ESCAPE( IS_RESULT-TEXT_INFO-TEXT ).
    LV_HEADER = LCL_SMS_JSON=>ESCAPE( IS_RESULT-HEADER ).
    CONCATENATE `{"msgheader":"` LV_HEADER `"` INTO RV_JSON.
    CASE IS_RESULT-TEXT_INFO-ENCODING.

      WHEN LIF_SMS=>ENCODING-TURKISH.

        CONCATENATE RV_JSON `,"encoding":"TR"` INTO RV_JSON.

      WHEN LIF_SMS=>ENCODING-UNICODE.

        CONCATENATE RV_JSON `,"encoding":"UNICODE"` INTO RV_JSON.

    ENDCASE.
    CONCATENATE RV_JSON `,"iysfilter":"` IS_RESULT-IYS `"`
      INTO RV_JSON.
    LV_EXTRA = SCHEDULE_JSON( IS_SCHEDULE = IS_RESULT-SCHEDULE
                              IV_STYLE    = 'DMYHM' ).
    CONCATENATE RV_JSON LV_EXTRA INTO RV_JSON.
    LV_EXTRA = REFERENCE_JSON( IS_RESULT-REFERENCE ).
    CONCATENATE RV_JSON LV_EXTRA `,"messages":[` INTO RV_JSON.
    LOOP AT IS_RESULT-RECIPIENTS INTO LS_RECIPIENT
         WHERE OK EQ ABAP_TRUE.

      IF IV_MASKED EQ ABAP_TRUE.

        LV_NUMBER = LS_RECIPIENT-MASKED.

      ELSE.

        LV_NUMBER = LS_RECIPIENT-NUMBER.

      ENDIF.
      IF LV_FIRST EQ ABAP_FALSE.

        CONCATENATE RV_JSON `,` INTO RV_JSON.

      ENDIF.
      LV_FIRST = ABAP_FALSE.
      CONCATENATE RV_JSON `{"msg":"` LV_TEXT `","no":"` LV_NUMBER `"}`
        INTO RV_JSON.

      CLEAR LS_RECIPIENT.

    ENDLOOP.

    CLEAR LS_RECIPIENT.
    CONCATENATE RV_JSON `]}` INTO RV_JSON.

  ENDMETHOD.

  METHOD OTP_BODY.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    DATA: LV_TEXT   TYPE STRING,
          LV_NUMBER TYPE STRING,
          LV_HEADER TYPE STRING.

    CLEAR LS_RECIPIENT.
    READ TABLE IS_RESULT-RECIPIENTS
         INTO LS_RECIPIENT
         WITH KEY OK = ABAP_TRUE.
    LV_NUMBER = LS_RECIPIENT-NUMBER.
    LV_TEXT = LCL_SMS_JSON=>ESCAPE( IS_RESULT-TEXT_INFO-TEXT ).
    LV_HEADER = LCL_SMS_JSON=>ESCAPE( IS_RESULT-HEADER ).
    CONCATENATE `{"msgheader":"` LV_HEADER `","msg":"` LV_TEXT
                `","no":"` LV_NUMBER `"}`
      INTO RV_JSON.

  ENDMETHOD.

  METHOD TEMPLATE_BODY.

    DATA: LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT,
          LS_PARAM     TYPE LIF_SMS=>TY_PARAM.

    DATA: LV_PARAMS TYPE STRING,
          LV_NAME   TYPE STRING,
          LV_VALUE  TYPE STRING,
          LV_NUMBER TYPE STRING,
          LV_HEADER TYPE STRING,
          LV_EXTRA  TYPE STRING,
          LV_ID     TYPE STRING,
          LV_FIRST  TYPE ABAP_BOOL VALUE ABAP_TRUE.

    " The same values for every number
    LOOP AT IT_PARAMS INTO LS_PARAM.

      LV_NAME = LCL_SMS_JSON=>ESCAPE( LS_PARAM-NAME ).
      LV_VALUE = LS_PARAM-VALUE.
      IF IV_ASCII EQ ABAP_TRUE.

        LV_VALUE = LCL_SMS_TEXT=>TO_ASCII( LV_VALUE ).

      ENDIF.
      LV_VALUE = LCL_SMS_JSON=>ESCAPE( LV_VALUE ).
      IF LV_PARAMS IS NOT INITIAL.

        CONCATENATE LV_PARAMS `,` INTO LV_PARAMS.

      ENDIF.
      CONCATENATE LV_PARAMS `"` LV_NAME `":"` LV_VALUE `"`
        INTO LV_PARAMS.

      CLEAR LS_PARAM.

    ENDLOOP.

    CLEAR LS_PARAM.

    LV_HEADER = LCL_SMS_JSON=>ESCAPE( IS_RESULT-HEADER ).
    CONCATENATE `{"msgheader":"` LV_HEADER `"` INTO RV_JSON.
    CASE IS_RESULT-TEXT_INFO-ENCODING.

      WHEN LIF_SMS=>ENCODING-TURKISH.

        CONCATENATE RV_JSON `,"encoding":"TR"` INTO RV_JSON.

      WHEN LIF_SMS=>ENCODING-UNICODE.

        CONCATENATE RV_JSON `,"encoding":"UNICODE"` INTO RV_JSON.

    ENDCASE.
    CONCATENATE RV_JSON `,"iysfilter":"` IS_RESULT-IYS `"`
      INTO RV_JSON.
    LV_EXTRA = SCHEDULE_JSON( IS_SCHEDULE = IS_RESULT-SCHEDULE
                              IV_STYLE    = 'ISO_M' ).
    CONCATENATE RV_JSON LV_EXTRA INTO RV_JSON.
    LV_EXTRA = REFERENCE_JSON( IS_RESULT-REFERENCE ).
    CONCATENATE RV_JSON LV_EXTRA `,"templates":[` INTO RV_JSON.
    LV_ID = INT_TEXT( IS_RESULT-TEMPLATE_ID ).
    LOOP AT IS_RESULT-RECIPIENTS INTO LS_RECIPIENT
         WHERE OK EQ ABAP_TRUE.

      IF IV_MASKED EQ ABAP_TRUE.

        LV_NUMBER = LS_RECIPIENT-MASKED.

      ELSE.

        LV_NUMBER = LS_RECIPIENT-NUMBER.

      ENDIF.
      IF LV_FIRST EQ ABAP_FALSE.

        CONCATENATE RV_JSON `,` INTO RV_JSON.

      ENDIF.
      LV_FIRST = ABAP_FALSE.
      CONCATENATE RV_JSON `{"templateId":` LV_ID `,"number":"`
                  LV_NUMBER `","params":{` LV_PARAMS `}}`
        INTO RV_JSON.

      CLEAR LS_RECIPIENT.

    ENDLOOP.

    CLEAR LS_RECIPIENT.
    CONCATENATE RV_JSON `]}` INTO RV_JSON.

  ENDMETHOD.

  METHOD SCHEDULE_JSON.

    DATA LV_TEXT TYPE STRING.

    IF IS_SCHEDULE-START_DATE IS INITIAL.

      RETURN.

    ENDIF.
    LV_TEXT = FORMAT_TIME( IV_DATE  = IS_SCHEDULE-START_DATE
                           IV_TIME  = IS_SCHEDULE-START_TIME
                           IV_STYLE = IV_STYLE ).
    CONCATENATE `,"startdate":"` LV_TEXT `"` INTO RV_JSON.
    IF IS_SCHEDULE-STOP_DATE IS NOT INITIAL.

      LV_TEXT = FORMAT_TIME( IV_DATE  = IS_SCHEDULE-STOP_DATE
                             IV_TIME  = IS_SCHEDULE-STOP_TIME
                             IV_STYLE = IV_STYLE ).
      CONCATENATE RV_JSON `,"stopdate":"` LV_TEXT `"` INTO RV_JSON.

    ENDIF.

  ENDMETHOD.

  METHOD REFERENCE_JSON.

    DATA LV_TEXT TYPE STRING.

    IF IV_REFERENCE IS INITIAL.

      RETURN.

    ENDIF.
    LV_TEXT = LCL_SMS_JSON=>ESCAPE( IV_REFERENCE ).
    CONCATENATE `,"referansID":"` LV_TEXT `"` INTO RV_JSON.

  ENDMETHOD.

  METHOD ROW_PATH.

    DATA LV_ROW TYPE STRING.

    LV_ROW = INT_TEXT( IV_ROW ).
    CONCATENATE IV_LIST `/` LV_ROW `/` IV_FIELD INTO RV_PATH.

  ENDMETHOD.

  METHOD INT_TEXT.

    DATA LV_CHAR TYPE C LENGTH 11.

    LV_CHAR = IV_VALUE.
    CONDENSE LV_CHAR.
    RV_TEXT = LV_CHAR.

  ENDMETHOD.

  METHOD STATUS_TEXT.

    DATA LV_KEY TYPE STRING.

    CASE IV_STATUS.

      WHEN '0' OR '1' OR '2' OR '3' OR '4' OR '11' OR '12' OR '13'
        OR '14' OR '15' OR '16' OR '17' OR '22'.

        CONCATENATE `S` IV_STATUS INTO LV_KEY.
        RV_TEXT = LCL_TEXT=>GET( LV_KEY ).

      WHEN OTHERS.

        RV_TEXT = IV_STATUS.

    ENDCASE.

  ENDMETHOD.

  METHOD STATS_TEXT.

    DATA LV_KEY TYPE STRING.

    CONCATENATE `ST_` IV_STATUS INTO LV_KEY.
    RV_TEXT = LCL_TEXT=>GET( LV_KEY ).
    IF RV_TEXT EQ LV_KEY.

      RV_TEXT = IV_STATUS.

    ENDIF.

  ENDMETHOD.

  METHOD ERROR_TEXT.

    DATA LV_KEY TYPE STRING.

    CASE IV_ERROR.

      WHEN '' OR '0'.

        CLEAR RV_TEXT.

      WHEN '101' OR '102' OR '103' OR '104' OR '105' OR '106'
        OR '111' OR '112' OR '113' OR '114' OR '115' OR '116'
        OR '117' OR '119'.

        CONCATENATE `E` IV_ERROR INTO LV_KEY.
        RV_TEXT = LCL_TEXT=>GET( LV_KEY ).

      WHEN OTHERS.

        RV_TEXT = LCL_TEXT=>GET( IV_KEY = 'E_OTHER'
                                 IV_1   = IV_ERROR ).

    ENDCASE.

  ENDMETHOD.

  METHOD OPERATOR_NAME.

    CASE IV_OPERATOR.

      WHEN '10'.

        RV_NAME = `Vodafone`.

      WHEN '20'.

        RV_NAME = `Türk Telekom`.

      WHEN '30'.

        RV_NAME = `Turkcell`.

      WHEN '40'.

        RV_NAME = `Netgsm STH`.

      WHEN '41'.

        RV_NAME = `Netgsm Mobil`.

      WHEN '60'.

        RV_NAME = LCL_TEXT=>GET( 'OP_60' ).

      WHEN '70'.

        RV_NAME = LCL_TEXT=>GET( 'OP_70' ).

      WHEN '160'.

        RV_NAME = `KKTC Vodafone`.

      WHEN '880'.

        RV_NAME = `KKTC Turkcell`.

      WHEN '212' OR '213' OR '214' OR '215'.

        RV_NAME = LCL_TEXT=>GET( 'OP_ABROAD' ).

      WHEN OTHERS.

        RV_NAME = IV_OPERATOR.

    ENDCASE.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Application log (SLG1). Object ZCHE_SMS has to be created once in
* SLG0; without it nothing is saved and the program says so. The
* message text is only logged when asked for.
*----------------------------------------------------------------------*
CLASS LCL_SMS_LOG DEFINITION FINAL.
  PUBLIC SECTION.
    CONSTANTS OBJECT TYPE BALOBJ_D VALUE 'ZCHE_SMS'.

    CLASS-METHODS WRITE
      IMPORTING
        IS_RESULT      TYPE LIF_SMS=>TY_RESULT
        IV_WITH_TEXT   TYPE ABAP_BOOL
      RETURNING
        VALUE(RV_SAVED) TYPE ABAP_BOOL.

    "! One line, for a cancel
    CLASS-METHODS WRITE_SIMPLE
      IMPORTING
        IV_ACTION       TYPE LIF_SMS=>TY_ACTION
        IV_CODE         TYPE STRING
        IV_MESSAGE      TYPE STRING
        IV_JOBID        TYPE STRING
      RETURNING
        VALUE(RV_SAVED) TYPE ABAP_BOOL.

  PRIVATE SECTION.
    CLASS-METHODS CREATE
      IMPORTING
        IV_EXTNUMBER     TYPE CSEQUENCE
      RETURNING
        VALUE(RV_HANDLE) TYPE BALLOGHNDL.

    CLASS-METHODS SAVE
      IMPORTING
        IV_HANDLE       TYPE BALLOGHNDL
      RETURNING
        VALUE(RV_SAVED) TYPE ABAP_BOOL.

    CLASS-METHODS ADD
      IMPORTING
        IV_HANDLE TYPE BALLOGHNDL
        IV_TYPE   TYPE SYMSGTY
        IV_TEXT   TYPE STRING.
ENDCLASS.

CLASS LCL_SMS_LOG IMPLEMENTATION.

  METHOD WRITE.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    DATA: LV_HANDLE TYPE BALLOGHNDL,
          LV_TYPE   TYPE SYMSGTY,
          LV_TEXT   TYPE STRING,
          LV_PARTS  TYPE C LENGTH 11,
          LV_ACTION TYPE STRING.

    IF IS_RESULT-JOBID IS NOT INITIAL.

      LV_HANDLE = CREATE( IS_RESULT-JOBID ).

    ELSE.

      LV_HANDLE = CREATE( IS_RESULT-CODE ).

    ENDIF.
    IF LV_HANDLE IS INITIAL.

      RETURN.

    ENDIF.

    IF IS_RESULT-SENT EQ ABAP_TRUE.

      LV_TYPE = 'S'.

    ELSE.

      LV_TYPE = 'E'.

    ENDIF.
    LV_ACTION = IS_RESULT-ACTION.
    CONCATENATE LV_ACTION ` ` IS_RESULT-CODE `: ` IS_RESULT-MESSAGE
      INTO LV_TEXT.
    IF IS_RESULT-JOBID IS NOT INITIAL.

      CONCATENATE LV_TEXT ` (jobid ` IS_RESULT-JOBID `)` INTO LV_TEXT.

    ENDIF.
    ADD( IV_HANDLE = LV_HANDLE IV_TYPE = LV_TYPE IV_TEXT = LV_TEXT ).

    LV_PARTS = IS_RESULT-TEXT_INFO-PARTS.
    CONDENSE LV_PARTS.
    LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'LOG_SUMMARY'
                             IV_1   = IS_RESULT-HEADER
                             IV_2   = IS_RESULT-TEXT_INFO-ENCODING
                             IV_3   = LV_PARTS ).
    ADD( IV_HANDLE = LV_HANDLE IV_TYPE = 'I' IV_TEXT = LV_TEXT ).

    LOOP AT IS_RESULT-RECIPIENTS INTO LS_RECIPIENT.

      IF LS_RECIPIENT-OK EQ ABAP_TRUE.

        LV_TEXT = LS_RECIPIENT-MASKED.
        ADD( IV_HANDLE = LV_HANDLE IV_TYPE = 'I' IV_TEXT = LV_TEXT ).

      ELSE.

        CONCATENATE LS_RECIPIENT-MASKED `: ` LS_RECIPIENT-REASON
          INTO LV_TEXT.
        ADD( IV_HANDLE = LV_HANDLE IV_TYPE = 'W' IV_TEXT = LV_TEXT ).

      ENDIF.

      CLEAR LS_RECIPIENT.

    ENDLOOP.

    CLEAR LS_RECIPIENT.

    IF IV_WITH_TEXT EQ ABAP_TRUE
       AND IS_RESULT-ACTION NE LIF_SMS=>ACTION-OTP
       AND IS_RESULT-TEXT_INFO-TEXT IS NOT INITIAL.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'LOG_TEXT'
                               IV_1   = IS_RESULT-TEXT_INFO-TEXT ).
      ADD( IV_HANDLE = LV_HANDLE IV_TYPE = 'I' IV_TEXT = LV_TEXT ).

    ENDIF.

    RV_SAVED = SAVE( LV_HANDLE ).

  ENDMETHOD.

  METHOD WRITE_SIMPLE.

    DATA: LV_HANDLE TYPE BALLOGHNDL,
          LV_TYPE   TYPE SYMSGTY,
          LV_TEXT   TYPE STRING,
          LV_ACTION TYPE STRING.

    LV_HANDLE = CREATE( IV_JOBID ).
    IF LV_HANDLE IS INITIAL.

      RETURN.

    ENDIF.
    IF IV_CODE EQ LIF_SMS=>CODE-OK.

      LV_TYPE = 'S'.

    ELSE.

      LV_TYPE = 'E'.

    ENDIF.
    LV_ACTION = IV_ACTION.
    CONCATENATE LV_ACTION ` ` IV_CODE `: ` IV_MESSAGE INTO LV_TEXT.
    ADD( IV_HANDLE = LV_HANDLE IV_TYPE = LV_TYPE IV_TEXT = LV_TEXT ).
    RV_SAVED = SAVE( LV_HANDLE ).

  ENDMETHOD.

  METHOD CREATE.

    DATA LS_LOG TYPE BAL_S_LOG.

    LS_LOG-OBJECT = OBJECT.
    LS_LOG-EXTNUMBER = IV_EXTNUMBER.
    LS_LOG-ALUSER = SY-UNAME.
    LS_LOG-ALPROG = SY-CPROG.
    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        I_S_LOG      = LS_LOG
      IMPORTING
        E_LOG_HANDLE = RV_HANDLE
      EXCEPTIONS
        OTHERS       = 1.
    IF SY-SUBRC NE 0.

      CLEAR RV_HANDLE.

    ENDIF.

  ENDMETHOD.

  METHOD SAVE.

    DATA LT_HANDLES TYPE BAL_T_LOGH.

    APPEND IV_HANDLE TO LT_HANDLES.
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        I_T_LOG_HANDLE = LT_HANDLES
      EXCEPTIONS
        OTHERS         = 1.
    IF SY-SUBRC EQ 0.

      RV_SAVED = ABAP_TRUE.

    ENDIF.

  ENDMETHOD.

  METHOD ADD.

    " Free text is limited to 200 characters per message
    DATA: LV_CHUNK TYPE C LENGTH 200,
          LV_LEN   TYPE I,
          LV_OFF   TYPE I,
          LV_TAKE  TYPE I.

    LV_LEN = STRLEN( IV_TEXT ).
    WHILE LV_OFF LT LV_LEN.

      LV_TAKE = LV_LEN - LV_OFF.
      IF LV_TAKE GT 200.

        LV_TAKE = 200.

      ENDIF.
      LV_CHUNK = IV_TEXT+LV_OFF(LV_TAKE).
      CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
        EXPORTING
          I_LOG_HANDLE = IV_HANDLE
          I_MSGTY      = IV_TYPE
          I_TEXT       = LV_CHUNK
        EXCEPTIONS
          OTHERS       = 1.
      IF SY-SUBRC NE 0.

        EXIT.

      ENDIF.
      LV_OFF = LV_OFF + LV_TAKE.

    ENDWHILE.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Selection screen. Choose the action; the screen shows only its
* fields. Save it as a variant for a job.
*----------------------------------------------------------------------*
DATA GV_NUMBER TYPE C LENGTH 40.
DATA GV_JOBID TYPE C LENGTH 40.
DATA GV_PARAM TYPE C LENGTH 132.
DATA GV_ACTION TYPE LIF_SMS=>TY_ACTION.

SELECTION-SCREEN BEGIN OF BLOCK B_ACT WITH FRAME TITLE T_ACT.
PARAMETERS P_ACT LIKE GV_ACTION AS LISTBOX VISIBLE LENGTH 40
                 USER-COMMAND ACT DEFAULT 'SEND' OBLIGATORY.
PARAMETERS P_DRY AS CHECKBOX DEFAULT 'X' MODIF ID SND.
PARAMETERS P_LOGTX AS CHECKBOX MODIF ID LOG.
PARAMETERS P_NLEN AS CHECKBOX MODIF ID NLN.
SELECTION-SCREEN END OF BLOCK B_ACT.

SELECTION-SCREEN BEGIN OF BLOCK B_MSG WITH FRAME TITLE T_MSG.
SELECT-OPTIONS S_NO FOR GV_NUMBER NO INTERVALS MODIF ID NUM.
PARAMETERS P_HEAD TYPE C LENGTH 11 LOWER CASE MODIF ID HDR.
SELECTION-SCREEN COMMENT /1(70) C_TXT MODIF ID TXT.
PARAMETERS P_TXT1 TYPE C LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID TXT.
PARAMETERS P_TXT2 TYPE C LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID TXT.
PARAMETERS P_TXT3 TYPE C LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID TXT.
PARAMETERS P_TXT4 TYPE C LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID TXT.
PARAMETERS P_ENC TYPE C LENGTH 7 AS LISTBOX VISIBLE LENGTH 40
                 DEFAULT 'AUTO' MODIF ID ENC.
PARAMETERS P_IYS TYPE C LENGTH 2 AS LISTBOX VISIBLE LENGTH 40
                 DEFAULT '0' MODIF ID IYS.
SELECTION-SCREEN END OF BLOCK B_MSG.

SELECTION-SCREEN BEGIN OF BLOCK B_TPL WITH FRAME TITLE T_TPL.
PARAMETERS P_TID TYPE N LENGTH 9 MODIF ID TPL.
SELECTION-SCREEN COMMENT /1(70) C_TPAR MODIF ID TPL.
SELECT-OPTIONS S_TPAR FOR GV_PARAM NO INTERVALS LOWER CASE
                      MODIF ID TPL.
SELECTION-SCREEN END OF BLOCK B_TPL.

SELECTION-SCREEN BEGIN OF BLOCK B_SCH WITH FRAME TITLE T_SCH.
PARAMETERS P_SDATE TYPE D MODIF ID SCH.
PARAMETERS P_STIME TYPE T MODIF ID SCH.
PARAMETERS P_EDATE TYPE D MODIF ID SCH.
PARAMETERS P_ETIME TYPE T MODIF ID SCH.
PARAMETERS P_REF TYPE C LENGTH 50 LOWER CASE MODIF ID SCH.
SELECTION-SCREEN END OF BLOCK B_SCH.

SELECTION-SCREEN BEGIN OF BLOCK B_JOB WITH FRAME TITLE T_JOB.
SELECTION-SCREEN COMMENT /1(70) C_JOB MODIF ID JOB.
SELECT-OPTIONS S_JOB FOR GV_JOBID NO INTERVALS MODIF ID JOB.
PARAMETERS P_RFROM TYPE D MODIF ID RDT.
PARAMETERS P_RTO TYPE D MODIF ID RDT.
PARAMETERS P_SENDD TYPE D MODIF ID SDT.
SELECTION-SCREEN COMMENT /1(70) C_INB MODIF ID INB.
PARAMETERS P_FULL AS CHECKBOX MODIF ID INB.
SELECTION-SCREEN END OF BLOCK B_JOB.

SELECTION-SCREEN BEGIN OF BLOCK B_TLS WITH FRAME TITLE T_TLS.
PARAMETERS P_TSRCH TYPE C LENGTH 50 LOWER CASE MODIF ID TLS.
PARAMETERS P_TCONT TYPE C LENGTH 50 LOWER CASE MODIF ID TLS.
PARAMETERS P_TTYPE TYPE C LENGTH 40 MODIF ID TLS.
PARAMETERS P_TPUB AS CHECKBOX DEFAULT 'X' MODIF ID TLS.
PARAMETERS P_TPAGE TYPE N LENGTH 4 MODIF ID TLS.
SELECTION-SCREEN END OF BLOCK B_TLS.

SELECTION-SCREEN BEGIN OF BLOCK B_CON WITH FRAME TITLE T_CON.
PARAMETERS P_DEST TYPE RFCDEST DEFAULT 'ZCHE_NETGSM' OBLIGATORY.
PARAMETERS P_DEXT TYPE RFCDEST DEFAULT 'ZCHE_NETGSM_EXT'
                  MODIF ID EXT.
SELECTION-SCREEN END OF BLOCK B_CON.

*----------------------------------------------------------------------*
* The program around the classes: screen, list, job log, popup
*----------------------------------------------------------------------*
CLASS LCL_APP DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS SET_TEXTS.
    CLASS-METHODS SET_SCREEN.
    CLASS-METHODS RUN.

    "! Is a screen group (MODIF ID) used by this action?
    CLASS-METHODS SHOWS
      IMPORTING
        IV_GROUP      TYPE CSEQUENCE
        IV_ACTION     TYPE LIF_SMS=>TY_ACTION
      RETURNING
        VALUE(RV_YES) TYPE ABAP_BOOL.

    "! name=value lines to template values
    CLASS-METHODS PARAMS_OF
      IMPORTING
        IT_LINES         TYPE STRING_TABLE
      RETURNING
        VALUE(RT_PARAMS) TYPE LIF_SMS=>TY_PARAMS.

  PRIVATE SECTION.
    TYPES TY_TEXTS TYPE STANDARD TABLE OF RSSELTEXTS
                   WITH DEFAULT KEY.

    CLASS-DATA GO_SMS TYPE REF TO LCL_SMS_NETGSM.

    CLASS-METHODS SET_LISTBOXES.

    CLASS-METHODS RUN_SEND.
    CLASS-METHODS RUN_CANCEL.
    CLASS-METHODS RUN_REPORT.
    CLASS-METHODS RUN_STATS.
    CLASS-METHODS RUN_INBOX.
    CLASS-METHODS RUN_HEADERS.
    CLASS-METHODS RUN_TEMPLATES.
    CLASS-METHODS RUN_LENGTH.

    "! The send of the chosen action with the screen's values
    CLASS-METHODS SEND_FROM_SCREEN
      IMPORTING
        IV_DRY_RUN       TYPE ABAP_BOOL
      RETURNING
        VALUE(RS_RESULT) TYPE LIF_SMS=>TY_RESULT.

    CLASS-METHODS SCREEN_TEXT
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    CLASS-METHODS SCREEN_NUMBERS
      RETURNING
        VALUE(RT_NUMBERS) TYPE STRING_TABLE.

    CLASS-METHODS SCREEN_JOBIDS
      RETURNING
        VALUE(RT_JOBIDS) TYPE STRING_TABLE.

    CLASS-METHODS CONFIRM
      IMPORTING
        IV_TITLE      TYPE STRING
        IV_QUESTION   TYPE STRING
      RETURNING
        VALUE(RV_YES) TYPE ABAP_BOOL.

    CLASS-METHODS SHOW_RESULT
      IMPORTING
        IS_RESULT TYPE LIF_SMS=>TY_RESULT.

    CLASS-METHODS SHOW_LENGTH
      IMPORTING
        IS_LENGTH TYPE LIF_SMS=>TY_LENGTH.

    CLASS-METHODS SHOW_LOG_STATE
      IMPORTING
        IV_SAVED TYPE ABAP_BOOL.

    CLASS-METHODS HEADING
      IMPORTING
        IV_KEY TYPE CSEQUENCE.

    CLASS-METHODS WRITE_CODE
      IMPORTING
        IV_CODE    TYPE STRING
        IV_MESSAGE TYPE STRING.

    CLASS-METHODS WRITE_LONG
      IMPORTING
        IV_TEXT   TYPE STRING
        IV_INDENT TYPE I DEFAULT 3.

    CLASS-METHODS CREDITS
      IMPORTING
        IS_RESULT       TYPE LIF_SMS=>TY_RESULT
      RETURNING
        VALUE(RV_COUNT) TYPE STRING.

    "! Success to the job log; an error cancels a background job
    CLASS-METHODS FINISH
      IMPORTING
        IV_OK   TYPE ABAP_BOOL
        IV_TEXT TYPE STRING.

    CLASS-METHODS ADD_TEXT
      IMPORTING
        IV_NAME  TYPE CSEQUENCE
        IV_KIND  TYPE C
      CHANGING
        CT_TEXTS TYPE TY_TEXTS.

    CLASS-METHODS ADD_VALUE
      IMPORTING
        IV_KEY    TYPE CSEQUENCE
        IV_TEXT   TYPE CSEQUENCE
      CHANGING
        CT_VALUES TYPE VRM_VALUES.
ENDCLASS.

CLASS LCL_APP IMPLEMENTATION.

  METHOD SET_TEXTS.

    DATA LT_TEXTS TYPE TY_TEXTS.

    T_ACT = LCL_TEXT=>GET( 'T_RUN' ).
    T_MSG = LCL_TEXT=>GET( 'T_MSG' ).
    T_TPL = LCL_TEXT=>GET( 'T_TPL' ).
    T_SCH = LCL_TEXT=>GET( 'T_SCH' ).
    T_JOB = LCL_TEXT=>GET( 'T_JOB' ).
    T_TLS = LCL_TEXT=>GET( 'T_TLS' ).
    T_CON = LCL_TEXT=>GET( 'T_CON' ).
    C_TXT = LCL_TEXT=>GET( 'C_TXT' ).
    C_TPAR = LCL_TEXT=>GET( 'C_TPAR' ).
    C_JOB = LCL_TEXT=>GET( 'C_JOB' ).
    C_INB = LCL_TEXT=>GET( 'C_INB' ).

    ADD_TEXT( EXPORTING IV_NAME = 'P_ACT' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_DRY' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_LOGTX' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_NLEN' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'S_NO' IV_KIND = 'S'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_HEAD' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TXT1' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TXT2' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TXT3' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TXT4' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_ENC' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_IYS' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TID' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'S_TPAR' IV_KIND = 'S'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_SDATE' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_STIME' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_EDATE' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_ETIME' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_REF' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'S_JOB' IV_KIND = 'S'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_RFROM' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_RTO' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_SENDD' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_FULL' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TSRCH' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TCONT' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TTYPE' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TPUB' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_TPAGE' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_DEST' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).
    ADD_TEXT( EXPORTING IV_NAME = 'P_DEXT' IV_KIND = 'P'
              CHANGING  CT_TEXTS = LT_TEXTS ).

    " If this fails, the screen shows the field names; nothing else
    " changes
    CALL FUNCTION 'SELECTION_TEXTS_MODIFY'
      EXPORTING
        PROGRAM  = SY-REPID
      TABLES
        SELTEXTS = LT_TEXTS
      EXCEPTIONS
        OTHERS   = 1.
    IF SY-SUBRC NE 0.

      RETURN.

    ENDIF.

  ENDMETHOD.

  METHOD ADD_TEXT.

    DATA LS_TEXT TYPE RSSELTEXTS.

    LS_TEXT-NAME = IV_NAME.
    LS_TEXT-KIND = IV_KIND.
    LS_TEXT-TEXT = LCL_TEXT=>GET( IV_NAME ).
    APPEND LS_TEXT TO CT_TEXTS.

  ENDMETHOD.

  METHOD SET_SCREEN.

    DATA LV_SHOW TYPE ABAP_BOOL.

    SET_LISTBOXES( ).
    LOOP AT SCREEN.

      IF SCREEN-GROUP1 IS INITIAL.

        CONTINUE.

      ENDIF.
      LV_SHOW = SHOWS( IV_GROUP  = SCREEN-GROUP1
                       IV_ACTION = P_ACT ).
      IF LV_SHOW EQ ABAP_FALSE.

        SCREEN-ACTIVE = '0'.
        MODIFY SCREEN.

      ENDIF.

    ENDLOOP.

  ENDMETHOD.

  METHOD SHOWS.

    DATA: LV_ACTIONS TYPE STRING,
          LV_ACTION  TYPE STRING.

    CASE IV_GROUP.

      WHEN 'SND' OR 'NUM'.

        LV_ACTIONS = `SEND OTP TEMPLATE`.

      WHEN 'LOG'.

        LV_ACTIONS = `SEND TEMPLATE`.

      WHEN 'HDR' OR 'ENC'.

        LV_ACTIONS = `SEND OTP TEMPLATE LENGTH`.

      WHEN 'TXT'.

        LV_ACTIONS = `SEND OTP LENGTH`.

      WHEN 'IYS' OR 'SCH'.

        LV_ACTIONS = `SEND TEMPLATE`.

      WHEN 'NLN'.

        LV_ACTIONS = `SEND`.

      WHEN 'TPL'.

        LV_ACTIONS = `TEMPLATE`.

      WHEN 'JOB'.

        LV_ACTIONS = `CANCEL REPORT STATS`.

      WHEN 'RDT'.

        LV_ACTIONS = `REPORT INBOX`.

      WHEN 'SDT'.

        LV_ACTIONS = `STATS`.

      WHEN 'INB'.

        LV_ACTIONS = `INBOX`.

      WHEN 'TLS'.

        LV_ACTIONS = `TPLLIST`.

      WHEN 'EXT'.

        LV_ACTIONS = `TEMPLATE TPLLIST`.

      WHEN OTHERS.

        RV_YES = ABAP_TRUE.
        RETURN.

    ENDCASE.
    LV_ACTION = IV_ACTION.
    CONCATENATE ` ` LV_ACTIONS ` ` INTO LV_ACTIONS.
    CONCATENATE ` ` LV_ACTION ` ` INTO LV_ACTION.
    IF LV_ACTIONS CS LV_ACTION.

      RV_YES = ABAP_TRUE.

    ENDIF.

  ENDMETHOD.

  METHOD SET_LISTBOXES.

    DATA LT_VALUES TYPE VRM_VALUES.

    DATA LV_TEXT TYPE STRING.

    LV_TEXT = LCL_TEXT=>GET( 'ACT_SEND' ).
    ADD_VALUE( EXPORTING IV_KEY = LIF_SMS=>ACTION-SEND IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_OTP' ).
    ADD_VALUE( EXPORTING IV_KEY = LIF_SMS=>ACTION-OTP IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_TEMPLATE' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-TEMPLATE
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_CANCEL' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-CANCEL
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_REPORT' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-REPORT
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_STATS' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-STATS
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_INBOX' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-INBOX
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_HEADERS' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-HEADERS
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_TPLLIST' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-TEMPLATES
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ACT_LENGTH' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ACTION-LENGTH
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    CALL FUNCTION 'VRM_SET_VALUES'
      EXPORTING
        ID     = 'P_ACT'
        VALUES = LT_VALUES
      EXCEPTIONS
        OTHERS = 1.
    IF SY-SUBRC NE 0.

      CLEAR LT_VALUES.

    ENDIF.

    CLEAR LT_VALUES.
    LV_TEXT = LCL_TEXT=>GET( 'ENC_AUTO' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ENCODING-AUTO
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ENC_TR' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ENCODING-TURKISH
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ENC_UNICODE' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ENCODING-UNICODE
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'ENC_ASCII' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>ENCODING-ASCII
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    CALL FUNCTION 'VRM_SET_VALUES'
      EXPORTING
        ID     = 'P_ENC'
        VALUES = LT_VALUES
      EXCEPTIONS
        OTHERS = 1.
    IF SY-SUBRC NE 0.

      CLEAR LT_VALUES.

    ENDIF.

    CLEAR LT_VALUES.
    LV_TEXT = LCL_TEXT=>GET( 'IYS_0' ).
    ADD_VALUE( EXPORTING IV_KEY = LIF_SMS=>IYS-INFO IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'IYS_11' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>IYS-INDIVIDUAL
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    LV_TEXT = LCL_TEXT=>GET( 'IYS_12' ).
    ADD_VALUE( EXPORTING IV_KEY  = LIF_SMS=>IYS-MERCHANT
                         IV_TEXT = LV_TEXT
               CHANGING  CT_VALUES = LT_VALUES ).
    CALL FUNCTION 'VRM_SET_VALUES'
      EXPORTING
        ID     = 'P_IYS'
        VALUES = LT_VALUES
      EXCEPTIONS
        OTHERS = 1.
    IF SY-SUBRC NE 0.

      CLEAR LT_VALUES.

    ENDIF.

  ENDMETHOD.

  METHOD ADD_VALUE.

    DATA LS_VALUE TYPE VRM_VALUE.

    LS_VALUE-KEY = IV_KEY.
    LS_VALUE-TEXT = IV_TEXT.
    APPEND LS_VALUE TO CT_VALUES.

  ENDMETHOD.

  METHOD RUN.

    CREATE OBJECT GO_SMS
      EXPORTING
        IV_DESTINATION     = P_DEST
        IV_EXT_DESTINATION = P_DEXT.
    CASE P_ACT.

      WHEN LIF_SMS=>ACTION-SEND OR LIF_SMS=>ACTION-OTP
        OR LIF_SMS=>ACTION-TEMPLATE.

        RUN_SEND( ).

      WHEN LIF_SMS=>ACTION-CANCEL.

        RUN_CANCEL( ).

      WHEN LIF_SMS=>ACTION-REPORT.

        RUN_REPORT( ).

      WHEN LIF_SMS=>ACTION-STATS.

        RUN_STATS( ).

      WHEN LIF_SMS=>ACTION-INBOX.

        RUN_INBOX( ).

      WHEN LIF_SMS=>ACTION-HEADERS.

        RUN_HEADERS( ).

      WHEN LIF_SMS=>ACTION-TEMPLATES.

        RUN_TEMPLATES( ).

      WHEN LIF_SMS=>ACTION-LENGTH.

        RUN_LENGTH( ).

    ENDCASE.

  ENDMETHOD.

  METHOD PARAMS_OF.

    DATA LS_PARAM TYPE LIF_SMS=>TY_PARAM.

    DATA: LV_LINE TYPE STRING,
          LV_OFF  TYPE I,
          LV_REST TYPE I.

    LOOP AT IT_LINES INTO LV_LINE.

      IF LV_LINE IS INITIAL.

        CONTINUE.

      ENDIF.
      CLEAR LS_PARAM.
      FIND '=' IN LV_LINE MATCH OFFSET LV_OFF.
      IF SY-SUBRC NE 0 OR LV_OFF EQ 0.

        " No name: send_template rejects it with the line
        LS_PARAM-VALUE = LV_LINE.

      ELSE.

        LS_PARAM-NAME = LV_LINE(LV_OFF).
        CONDENSE LS_PARAM-NAME.
        LV_OFF = LV_OFF + 1.
        LV_REST = STRLEN( LV_LINE ) - LV_OFF.
        IF LV_REST GT 0.

          LS_PARAM-VALUE = LV_LINE+LV_OFF(LV_REST).

        ENDIF.

      ENDIF.
      APPEND LS_PARAM TO RT_PARAMS.

      CLEAR LV_LINE.

    ENDLOOP.

    CLEAR LV_LINE.

  ENDMETHOD.

  METHOD SEND_FROM_SCREEN.

    DATA: LT_LINES   TYPE STRING_TABLE,
          LT_PARAMS  TYPE LIF_SMS=>TY_PARAMS,
          LT_NUMBERS TYPE STRING_TABLE.

    DATA: LS_SCHEDULE TYPE LIF_SMS=>TY_SCHEDULE,
          LS_PARAM    LIKE LINE OF S_TPAR.

    DATA: LV_LINE     TYPE STRING,
          LV_ASCII    TYPE ABAP_BOOL,
          LV_TEMPLATE TYPE I,
          LV_TEXT     TYPE STRING.

    LT_NUMBERS = SCREEN_NUMBERS( ).
    LV_TEXT = SCREEN_TEXT( ).
    LS_SCHEDULE-START_DATE = P_SDATE.
    LS_SCHEDULE-START_TIME = P_STIME.
    LS_SCHEDULE-STOP_DATE = P_EDATE.
    LS_SCHEDULE-STOP_TIME = P_ETIME.

    CASE P_ACT.

      WHEN LIF_SMS=>ACTION-OTP.

        IF P_ENC EQ LIF_SMS=>ENCODING-ASCII.

          LV_ASCII = ABAP_TRUE.

        ENDIF.
        RS_RESULT = GO_SMS->SEND_OTP( IT_NUMBERS = LT_NUMBERS
                                      IV_TEXT    = LV_TEXT
                                      IV_HEADER  = P_HEAD
                                      IV_ASCII   = LV_ASCII
                                      IV_DRY_RUN = IV_DRY_RUN ).

      WHEN LIF_SMS=>ACTION-TEMPLATE.

        LOOP AT S_TPAR[] INTO LS_PARAM
             WHERE SIGN EQ 'I'.

          LV_LINE = LS_PARAM-LOW.
          APPEND LV_LINE TO LT_LINES.

          CLEAR LS_PARAM.

        ENDLOOP.

        CLEAR LS_PARAM.
        LT_PARAMS = PARAMS_OF( LT_LINES ).
        LV_TEMPLATE = P_TID.
        RS_RESULT = GO_SMS->SEND_TEMPLATE(
                      IT_NUMBERS     = LT_NUMBERS
                      IV_TEMPLATE_ID = LV_TEMPLATE
                      IT_PARAMS      = LT_PARAMS
                      IV_HEADER      = P_HEAD
                      IV_ENCODING    = P_ENC
                      IV_IYS         = P_IYS
                      IS_SCHEDULE    = LS_SCHEDULE
                      IV_REFERENCE   = P_REF
                      IV_DRY_RUN     = IV_DRY_RUN ).

      WHEN OTHERS.

        RS_RESULT = GO_SMS->SEND( IT_NUMBERS   = LT_NUMBERS
                                  IV_TEXT      = LV_TEXT
                                  IV_HEADER    = P_HEAD
                                  IV_ENCODING  = P_ENC
                                  IV_IYS       = P_IYS
                                  IS_SCHEDULE  = LS_SCHEDULE
                                  IV_REFERENCE = P_REF
                                  IV_DRY_RUN   = IV_DRY_RUN ).

    ENDCASE.

  ENDMETHOD.

  METHOD RUN_SEND.

    DATA: LS_RESULT TYPE LIF_SMS=>TY_RESULT,
          LS_LENGTH TYPE LIF_SMS=>TY_LENGTH.

    DATA: LV_TEXT     TYPE STRING,
          LV_TITLE    TYPE STRING,
          LV_VALID    TYPE STRING,
          LV_CREDITS  TYPE STRING,
          LV_SAVED    TYPE ABAP_BOOL,
          LV_SMS_TEXT TYPE STRING.

    " Always check first; a real send only follows a clean preview
    LS_RESULT = SEND_FROM_SCREEN( ABAP_TRUE ).
    IF LS_RESULT-CODE NE LIF_SMS=>CODE-DRY_RUN OR P_DRY EQ ABAP_TRUE.

      SHOW_RESULT( LS_RESULT ).
      IF P_NLEN EQ ABAP_TRUE AND P_ACT EQ LIF_SMS=>ACTION-SEND
         AND LS_RESULT-CODE EQ LIF_SMS=>CODE-DRY_RUN.

        LV_SMS_TEXT = SCREEN_TEXT( ).
        LS_LENGTH = GO_SMS->LENGTH( IV_TEXT     = LV_SMS_TEXT
                                    IV_ENCODING = P_ENC
                                    IV_HEADER   = P_HEAD ).
        SHOW_LENGTH( LS_LENGTH ).

      ENDIF.
      IF LS_RESULT-CODE EQ LIF_SMS=>CODE-DRY_RUN.

        FINISH( IV_OK = ABAP_TRUE IV_TEXT = LS_RESULT-MESSAGE ).

      ELSE.

        FINISH( IV_OK = ABAP_FALSE IV_TEXT = LS_RESULT-MESSAGE ).

      ENDIF.
      RETURN.

    ENDIF.

    IF SY-BATCH EQ ABAP_FALSE.

      LV_VALID = LS_RESULT-VALID.
      CONDENSE LV_VALID.
      LV_CREDITS = CREDITS( LS_RESULT ).
      LV_TITLE = LCL_TEXT=>GET( 'POP_TITLE' ).
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'POP_QUESTION'
                               IV_1   = LV_VALID
                               IV_2   = LV_CREDITS ).
      IF CONFIRM( IV_TITLE = LV_TITLE IV_QUESTION = LV_TEXT )
         EQ ABAP_FALSE.

        SHOW_RESULT( LS_RESULT ).
        LV_TEXT = LCL_TEXT=>GET( 'CANCELLED' ).
        FINISH( IV_OK = ABAP_TRUE IV_TEXT = LV_TEXT ).
        RETURN.

      ENDIF.

    ENDIF.

    LS_RESULT = SEND_FROM_SCREEN( ABAP_FALSE ).
    LV_SAVED = LCL_SMS_LOG=>WRITE( IS_RESULT    = LS_RESULT
                                   IV_WITH_TEXT = P_LOGTX ).
    SHOW_RESULT( LS_RESULT ).
    SHOW_LOG_STATE( LV_SAVED ).
    CONCATENATE LS_RESULT-CODE `: ` LS_RESULT-MESSAGE INTO LV_TEXT.
    IF LS_RESULT-JOBID IS NOT INITIAL.

      CONCATENATE LV_TEXT ` (jobid ` LS_RESULT-JOBID `)` INTO LV_TEXT.

    ENDIF.
    FINISH( IV_OK = LS_RESULT-SENT IV_TEXT = LV_TEXT ).

  ENDMETHOD.

  METHOD RUN_CANCEL.

    DATA LT_JOBIDS TYPE STRING_TABLE.

    DATA LS_ANSWER TYPE LIF_SMS=>TY_ANSWER.

    DATA: LV_JOBID TYPE STRING,
          LV_TITLE TYPE STRING,
          LV_TEXT  TYPE STRING,
          LV_OK    TYPE ABAP_BOOL,
          LV_SAVED TYPE ABAP_BOOL.

    LT_JOBIDS = SCREEN_JOBIDS( ).
    CLEAR LV_JOBID.
    READ TABLE LT_JOBIDS
         INTO LV_JOBID
         INDEX 1.
    IF SY-BATCH EQ ABAP_FALSE AND LV_JOBID IS NOT INITIAL.

      LV_TITLE = LCL_TEXT=>GET( 'POP_CANCEL_T' ).
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'POP_CANCEL_Q'
                               IV_1   = LV_JOBID ).
      IF CONFIRM( IV_TITLE = LV_TITLE IV_QUESTION = LV_TEXT )
         EQ ABAP_FALSE.

        LV_TEXT = LCL_TEXT=>GET( 'NOTHING_DONE' ).
        FINISH( IV_OK = ABAP_TRUE IV_TEXT = LV_TEXT ).
        RETURN.

      ENDIF.

    ENDIF.

    LS_ANSWER = GO_SMS->CANCEL( LV_JOBID ).
    LV_SAVED = LCL_SMS_LOG=>WRITE_SIMPLE(
                 IV_ACTION  = LIF_SMS=>ACTION-CANCEL
                 IV_CODE    = LS_ANSWER-CODE
                 IV_MESSAGE = LS_ANSWER-MESSAGE
                 IV_JOBID   = LS_ANSWER-JOBID ).
    HEADING( 'ACT_CANCEL' ).
    WRITE_CODE( IV_CODE    = LS_ANSWER-CODE
                IV_MESSAGE = LS_ANSWER-MESSAGE ).
    IF LS_ANSWER-JOBID IS NOT INITIAL.

      LV_TEXT = LCL_TEXT=>GET( 'L_JOBID' ).
      CONCATENATE LV_TEXT `: ` LS_ANSWER-JOBID INTO LV_TEXT.
      WRITE_LONG( LV_TEXT ).

    ENDIF.
    SHOW_LOG_STATE( LV_SAVED ).
    IF LS_ANSWER-CODE EQ LIF_SMS=>CODE-OK.

      LV_OK = ABAP_TRUE.

    ENDIF.
    FINISH( IV_OK = LV_OK IV_TEXT = LS_ANSWER-MESSAGE ).

  ENDMETHOD.

  METHOD RUN_REPORT.

    DATA LT_JOBIDS TYPE STRING_TABLE.

    DATA: LS_REPORT TYPE LIF_SMS=>TY_REPORT,
          LS_LINE   TYPE LIF_SMS=>TY_REPORT_LINE.

    DATA: LV_OK   TYPE ABAP_BOOL,
          LV_TEXT TYPE STRING,
          LV_JOB  TYPE C LENGTH 27,
          LV_NUM  TYPE C LENGTH 15.

    LT_JOBIDS = SCREEN_JOBIDS( ).
    LS_REPORT = GO_SMS->REPORT( IT_JOBIDS = LT_JOBIDS
                                IV_FROM   = P_RFROM
                                IV_TO     = P_RTO ).
    HEADING( 'L_REPORT' ).
    WRITE_CODE( IV_CODE    = LS_REPORT-CODE
                IV_MESSAGE = LS_REPORT-MESSAGE ).
    IF LS_REPORT-LINES IS NOT INITIAL.

      SKIP.
      LV_TEXT = LCL_TEXT=>GET( 'L_REPORT_COLS' ).
      WRITE: / LV_TEXT COLOR COL_HEADING.

    ENDIF.
    LOOP AT LS_REPORT-LINES INTO LS_LINE.

      LV_TEXT = LS_LINE-STATUS_TEXT.
      IF LS_LINE-ERROR_TEXT IS NOT INITIAL.

        CONCATENATE LV_TEXT ` / ` LS_LINE-ERROR_TEXT INTO LV_TEXT.

      ENDIF.
      LV_JOB = LS_LINE-JOBID.
      LV_NUM = LS_LINE-NUMBER.
      WRITE: / LV_JOB, LV_NUM, LV_TEXT, LS_LINE-OPERATOR,
               LS_LINE-DELIVERED, LS_LINE-REFERENCE.

      CLEAR LS_LINE.

    ENDLOOP.

    CLEAR LS_LINE.

    IF LS_REPORT-CODE EQ `00` OR LS_REPORT-CODE EQ `60`.

      LV_OK = ABAP_TRUE.

    ENDIF.
    FINISH( IV_OK = LV_OK IV_TEXT = LS_REPORT-MESSAGE ).

  ENDMETHOD.

  METHOD RUN_STATS.

    DATA LT_JOBIDS TYPE STRING_TABLE.

    DATA: LS_STATS TYPE LIF_SMS=>TY_STATS,
          LS_LINE  TYPE LIF_SMS=>TY_STATS_LINE.

    DATA: LV_JOBID  TYPE STRING,
          LV_TEXT   TYPE STRING,
          LV_ABROAD TYPE STRING,
          LV_OK     TYPE ABAP_BOOL.

    LT_JOBIDS = SCREEN_JOBIDS( ).
    CLEAR LV_JOBID.
    READ TABLE LT_JOBIDS
         INTO LV_JOBID
         INDEX 1.
    LS_STATS = GO_SMS->STATS( IV_JOBID     = LV_JOBID
                              IV_SEND_DATE = P_SENDD ).
    HEADING( 'L_STATS' ).
    WRITE_CODE( IV_CODE    = LS_STATS-CODE
                IV_MESSAGE = LS_STATS-MESSAGE ).
    LOOP AT LS_STATS-LINES INTO LS_LINE.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_STATS_LINE'
                               IV_1   = LS_LINE-TOTAL_SMS
                               IV_2   = LS_LINE-TOTAL_PARTS
                               IV_3   = LS_LINE-CHARGE ).
      CONCATENATE LS_LINE-STATUS_TEXT `: ` LV_TEXT ` (`
                  LS_LINE-STATEMENT `)`
        INTO LV_TEXT.
      IF LS_LINE-DOMESTIC EQ `false`.

        LV_ABROAD = LCL_TEXT=>GET( 'OP_ABROAD' ).
        CONCATENATE LV_TEXT ` ` LV_ABROAD INTO LV_TEXT.

      ENDIF.
      WRITE_LONG( LV_TEXT ).

      CLEAR LS_LINE.

    ENDLOOP.

    CLEAR LS_LINE.
    IF LS_STATS-CODE EQ `00`.

      LV_OK = ABAP_TRUE.

    ENDIF.
    FINISH( IV_OK = LV_OK IV_TEXT = LS_STATS-MESSAGE ).

  ENDMETHOD.

  METHOD RUN_INBOX.

    DATA: LS_INBOX TYPE LIF_SMS=>TY_INBOX,
          LS_LINE  TYPE LIF_SMS=>TY_INBOX_LINE.

    DATA: LV_TEXT TYPE STRING,
          LV_OK   TYPE ABAP_BOOL.

    LS_INBOX = GO_SMS->INBOX( IV_FROM         = P_RFROM
                              IV_TO           = P_RTO
                              IV_FULL_NUMBERS = P_FULL ).
    HEADING( 'L_INBOX' ).
    WRITE_CODE( IV_CODE    = LS_INBOX-CODE
                IV_MESSAGE = LS_INBOX-MESSAGE ).
    LOOP AT LS_INBOX-LINES INTO LS_LINE.

      SKIP.
      CONCATENATE LS_LINE-RECEIVED LS_LINE-SENDER LS_LINE-OPERATOR
        INTO LV_TEXT
        SEPARATED BY `   `.
      WRITE: / LV_TEXT COLOR COL_KEY.
      WRITE_LONG( IV_TEXT = LS_LINE-TEXT IV_INDENT = 5 ).

      CLEAR LS_LINE.

    ENDLOOP.

    CLEAR LS_LINE.
    IF LS_INBOX-CODE EQ `00` OR LS_INBOX-CODE EQ `40`.

      LV_OK = ABAP_TRUE.

    ENDIF.
    FINISH( IV_OK = LV_OK IV_TEXT = LS_INBOX-MESSAGE ).

  ENDMETHOD.

  METHOD RUN_HEADERS.

    DATA LS_HEADERS TYPE LIF_SMS=>TY_HEADERS.

    DATA: LV_NAME TYPE STRING,
          LV_TEXT TYPE STRING,
          LV_OK   TYPE ABAP_BOOL.

    LS_HEADERS = GO_SMS->HEADERS( ).
    HEADING( 'L_HEADERS' ).
    WRITE_CODE( IV_CODE    = LS_HEADERS-CODE
                IV_MESSAGE = LS_HEADERS-MESSAGE ).
    IF LS_HEADERS-CODE EQ `00`.

      LV_OK = ABAP_TRUE.
      LV_TEXT = LCL_TEXT=>GET( 'L_CONN_OK' ).
      WRITE: / LV_TEXT COLOR COL_POSITIVE.

    ENDIF.
    SKIP.
    LOOP AT LS_HEADERS-NAMES INTO LV_NAME.

      WRITE: /3 LV_NAME.

      CLEAR LV_NAME.

    ENDLOOP.

    CLEAR LV_NAME.
    FINISH( IV_OK = LV_OK IV_TEXT = LS_HEADERS-MESSAGE ).

  ENDMETHOD.

  METHOD RUN_TEMPLATES.

    DATA: LS_TEMPLATES TYPE LIF_SMS=>TY_TEMPLATES,
          LS_LINE      TYPE LIF_SMS=>TY_TEMPLATE.

    DATA: LV_PAGE TYPE I,
          LV_TEXT TYPE STRING,
          LV_OK   TYPE ABAP_BOOL.

    LV_PAGE = P_TPAGE.
    LS_TEMPLATES = GO_SMS->TEMPLATES( IV_PAGE    = LV_PAGE
                                      IV_PUBLIC  = P_TPUB
                                      IV_SEARCH  = P_TSRCH
                                      IV_TYPE    = P_TTYPE
                                      IV_CONTENT = P_TCONT ).
    HEADING( 'L_TEMPLATES' ).
    WRITE_CODE( IV_CODE    = LS_TEMPLATES-CODE
                IV_MESSAGE = LS_TEMPLATES-MESSAGE ).
    IF LS_TEMPLATES-CODE EQ `00`.

      LV_OK = ABAP_TRUE.
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_PAGE'
                               IV_1   = LS_TEMPLATES-PAGE
                               IV_2   = LS_TEMPLATES-PAGES
                               IV_3   = LS_TEMPLATES-TOTAL ).
      WRITE_LONG( LV_TEXT ).

    ENDIF.
    LOOP AT LS_TEMPLATES-LINES INTO LS_LINE.

      SKIP.
      CONCATENATE LS_LINE-ID LS_LINE-TYPE LS_LINE-DESCRIPTION
        INTO LV_TEXT
        SEPARATED BY `   `.
      WRITE: / LV_TEXT COLOR COL_KEY.
      WRITE_LONG( IV_TEXT = LS_LINE-CONTENT IV_INDENT = 5 ).
      IF LS_LINE-PARAMETERS IS NOT INITIAL.

        LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_PARAMS'
                                 IV_1   = LS_LINE-PARAMETERS ).
        WRITE_LONG( IV_TEXT = LV_TEXT IV_INDENT = 5 ).

      ENDIF.

      CLEAR LS_LINE.

    ENDLOOP.

    CLEAR LS_LINE.
    FINISH( IV_OK = LV_OK IV_TEXT = LS_TEMPLATES-MESSAGE ).

  ENDMETHOD.

  METHOD RUN_LENGTH.

    DATA: LS_INFO   TYPE LIF_SMS=>TY_TEXT_INFO,
          LS_LENGTH TYPE LIF_SMS=>TY_LENGTH.

    DATA: LV_1        TYPE C LENGTH 11,
          LV_2        TYPE C LENGTH 11,
          LV_3        TYPE C LENGTH 11,
          LV_TEXT     TYPE STRING,
          LV_OK       TYPE ABAP_BOOL,
          LV_SMS_TEXT TYPE STRING.

    LV_SMS_TEXT = SCREEN_TEXT( ).
    LS_INFO = LCL_SMS_TEXT=>ANALYZE( IV_TEXT     = LV_SMS_TEXT
                                     IV_ENCODING = P_ENC
                                     IV_HEADER   = P_HEAD ).
    HEADING( 'ACT_LENGTH' ).
    IF LS_INFO-ENCODING IS NOT INITIAL.

      LV_1 = LS_INFO-UNITS.
      LV_2 = LS_INFO-MAX_UNITS.
      LV_3 = LS_INFO-PARTS.
      CONDENSE: LV_1, LV_2, LV_3.
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_LOCAL'
                               IV_1   = LS_INFO-ENCODING
                               IV_2   = LV_1
                               IV_3   = LV_3 ).
      WRITE_LONG( LV_TEXT ).

    ENDIF.
    LS_LENGTH = GO_SMS->LENGTH( IV_TEXT     = LV_SMS_TEXT
                                IV_ENCODING = P_ENC
                                IV_HEADER   = P_HEAD ).
    SHOW_LENGTH( LS_LENGTH ).
    IF LS_LENGTH-CODE EQ `00`.

      LV_OK = ABAP_TRUE.

    ENDIF.
    FINISH( IV_OK = LV_OK IV_TEXT = LS_LENGTH-MESSAGE ).

  ENDMETHOD.

  METHOD SCREEN_TEXT.

    DATA LT_LINES TYPE STRING_TABLE.

    DATA LV_LINE TYPE STRING.

    LV_LINE = P_TXT1.
    APPEND LV_LINE TO LT_LINES.
    LV_LINE = P_TXT2.
    APPEND LV_LINE TO LT_LINES.
    LV_LINE = P_TXT3.
    APPEND LV_LINE TO LT_LINES.
    LV_LINE = P_TXT4.
    APPEND LV_LINE TO LT_LINES.
    LOOP AT LT_LINES INTO LV_LINE.

      IF LV_LINE IS INITIAL.

        CONTINUE.

      ENDIF.
      IF RV_TEXT IS INITIAL.

        RV_TEXT = LV_LINE.

      ELSE.

        CONCATENATE RV_TEXT LV_LINE
          INTO RV_TEXT
          SEPARATED BY CL_ABAP_CHAR_UTILITIES=>NEWLINE.

      ENDIF.

      CLEAR LV_LINE.

    ENDLOOP.

    CLEAR LV_LINE.

  ENDMETHOD.

  METHOD SCREEN_NUMBERS.

    DATA LS_NO LIKE LINE OF S_NO.

    DATA: LV_NUMBER  TYPE STRING,
          LV_IGNORED TYPE I,
          LV_COUNT   TYPE C LENGTH 11,
          LV_TEXT    TYPE STRING.

    LOOP AT S_NO[] INTO LS_NO.

      IF LS_NO-SIGN EQ 'I' AND ( LS_NO-OPTION EQ 'EQ'
                                OR LS_NO-OPTION IS INITIAL ).

        LV_NUMBER = LS_NO-LOW.
        APPEND LV_NUMBER TO RT_NUMBERS.

      ELSE.

        LV_IGNORED = LV_IGNORED + 1.

      ENDIF.

      CLEAR LS_NO.

    ENDLOOP.

    CLEAR LS_NO.
    IF LV_IGNORED GT 0.

      LV_COUNT = LV_IGNORED.
      CONDENSE LV_COUNT.
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'IGNORED' IV_1 = LV_COUNT ).
      MESSAGE LV_TEXT TYPE 'S' DISPLAY LIKE 'W'.

    ENDIF.

  ENDMETHOD.

  METHOD SCREEN_JOBIDS.

    DATA LS_JOB LIKE LINE OF S_JOB.

    DATA LV_JOBID TYPE STRING.

    LOOP AT S_JOB[] INTO LS_JOB
         WHERE SIGN EQ 'I'.

      LV_JOBID = LS_JOB-LOW.
      APPEND LV_JOBID TO RT_JOBIDS.

      CLEAR LS_JOB.

    ENDLOOP.

    CLEAR LS_JOB.

  ENDMETHOD.

  METHOD CONFIRM.

    DATA LV_ANSWER TYPE C LENGTH 1.

    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        TITLEBAR              = IV_TITLE
        TEXT_QUESTION         = IV_QUESTION
        DEFAULT_BUTTON        = '2'
        DISPLAY_CANCEL_BUTTON = SPACE
      IMPORTING
        ANSWER                = LV_ANSWER
      EXCEPTIONS
        OTHERS                = 1.
    IF SY-SUBRC EQ 0 AND LV_ANSWER EQ '1'.

      RV_YES = ABAP_TRUE.

    ENDIF.

  ENDMETHOD.

  METHOD SHOW_RESULT.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    DATA: LV_TEXT     TYPE STRING,
          LV_VALUE    TYPE STRING,
          LV_1        TYPE C LENGTH 11,
          LV_2        TYPE C LENGTH 11,
          LV_3        TYPE C LENGTH 11,
          LV_REJECTED TYPE I,
          LV_LABEL    TYPE C LENGTH 20,
          LV_CREDITS  TYPE STRING.

    IF IS_RESULT-CODE EQ LIF_SMS=>CODE-DRY_RUN.

      LV_TEXT = LCL_TEXT=>GET( 'L_PREVIEW' ).
      WRITE: / LV_TEXT COLOR COL_TOTAL.

    ELSEIF IS_RESULT-SENT EQ ABAP_TRUE.

      LV_TEXT = LCL_TEXT=>GET( 'L_SENT' ).
      WRITE: / LV_TEXT COLOR COL_POSITIVE.

    ELSE.

      LV_TEXT = LCL_TEXT=>GET( 'L_NOT_SENT' ).
      WRITE: / LV_TEXT COLOR COL_NEGATIVE.

    ENDIF.
    LV_TEXT = LCL_TEXT=>GET( 'ACT_SEND' ).
    CASE IS_RESULT-ACTION.

      WHEN LIF_SMS=>ACTION-OTP.

        LV_TEXT = LCL_TEXT=>GET( 'ACT_OTP' ).

      WHEN LIF_SMS=>ACTION-TEMPLATE.

        LV_TEXT = LCL_TEXT=>GET( 'ACT_TEMPLATE' ).

    ENDCASE.
    WRITE: / LV_TEXT.
    SKIP.

    LV_LABEL = LCL_TEXT=>GET( 'L_RESULT' ).
    WRITE: / LV_LABEL.
    CONCATENATE IS_RESULT-CODE `: ` IS_RESULT-MESSAGE INTO LV_TEXT.
    WRITE_LONG( LV_TEXT ).
    IF IS_RESULT-JOBID IS NOT INITIAL.

      LV_LABEL = LCL_TEXT=>GET( 'L_JOBID' ).
      WRITE: / LV_LABEL, IS_RESULT-JOBID.

    ENDIF.
    LV_LABEL = LCL_TEXT=>GET( 'L_HEADER' ).
    WRITE: / LV_LABEL, IS_RESULT-HEADER.
    IF IS_RESULT-TEMPLATE_ID GT 0.

      LV_LABEL = LCL_TEXT=>GET( 'P_TID' ).
      LV_1 = IS_RESULT-TEMPLATE_ID.
      CONDENSE LV_1.
      WRITE: / LV_LABEL, LV_1.

    ENDIF.
    IF IS_RESULT-SCHEDULE-START_DATE IS NOT INITIAL.

      LV_TEXT = LCL_SMS_NETGSM=>FORMAT_TIME(
                  IV_DATE  = IS_RESULT-SCHEDULE-START_DATE
                  IV_TIME  = IS_RESULT-SCHEDULE-START_TIME
                  IV_STYLE = 'DOT_S' ).
      LV_VALUE = `-`.
      IF IS_RESULT-SCHEDULE-STOP_DATE IS NOT INITIAL.

        LV_VALUE = LCL_SMS_NETGSM=>FORMAT_TIME(
                     IV_DATE  = IS_RESULT-SCHEDULE-STOP_DATE
                     IV_TIME  = IS_RESULT-SCHEDULE-STOP_TIME
                     IV_STYLE = 'DOT_S' ).

      ENDIF.
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_SCHEDULE'
                               IV_1   = LV_TEXT
                               IV_2   = LV_VALUE ).
      WRITE_LONG( LV_TEXT ).

    ENDIF.
    IF IS_RESULT-REFERENCE IS NOT INITIAL.

      LV_LABEL = LCL_TEXT=>GET( 'L_REFERENCE' ).
      WRITE: / LV_LABEL, IS_RESULT-REFERENCE.

    ENDIF.

    IF IS_RESULT-TEXT_INFO-ENCODING IS NOT INITIAL.

      LV_LABEL = LCL_TEXT=>GET( 'L_ENC' ).
      WRITE: / LV_LABEL, IS_RESULT-TEXT_INFO-ENCODING.

    ENDIF.
    IF IS_RESULT-TEXT_INFO-PARTS GT 0.

      LV_1 = IS_RESULT-TEXT_INFO-UNITS.
      LV_2 = IS_RESULT-TEXT_INFO-MAX_UNITS.
      LV_3 = IS_RESULT-TEXT_INFO-PARTS.
      CONDENSE: LV_1, LV_2, LV_3.
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_SIZE'
                               IV_1   = LV_1
                               IV_2   = LV_2
                               IV_3   = LV_3 ).
      WRITE: / LV_TEXT.
      IF IS_RESULT-TEXT_INFO-SUFFIX GT 0.

        LV_TEXT = LCL_TEXT=>GET( 'L_SUFFIX' ).
        WRITE: / LV_TEXT.

      ENDIF.

    ENDIF.

    LOOP AT IS_RESULT-RECIPIENTS INTO LS_RECIPIENT
         WHERE OK EQ ABAP_FALSE.

      LV_REJECTED = LV_REJECTED + 1.

      CLEAR LS_RECIPIENT.

    ENDLOOP.

    CLEAR LS_RECIPIENT.
    LV_1 = IS_RESULT-VALID.
    LV_2 = LV_REJECTED.
    CONDENSE: LV_1, LV_2.
    SKIP.
    LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_RCPT'
                             IV_1   = LV_1
                             IV_2   = LV_2 ).
    WRITE: / LV_TEXT.
    IF IS_RESULT-VALID GT 0
       AND ( IS_RESULT-TEXT_INFO-PARTS GT 0
             OR IS_RESULT-ACTION EQ LIF_SMS=>ACTION-TEMPLATE ).

      LV_CREDITS = CREDITS( IS_RESULT ).
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_CREDITS'
                               IV_1   = LV_CREDITS ).
      WRITE: / LV_TEXT.

    ENDIF.
    LOOP AT IS_RESULT-RECIPIENTS INTO LS_RECIPIENT.

      IF LS_RECIPIENT-OK EQ ABAP_TRUE.

        WRITE: /3 LS_RECIPIENT-MASKED COLOR COL_POSITIVE.

      ELSE.

        WRITE: /3 LS_RECIPIENT-MASKED COLOR COL_NEGATIVE,
                  LS_RECIPIENT-REASON.

      ENDIF.

      CLEAR LS_RECIPIENT.

    ENDLOOP.

    CLEAR LS_RECIPIENT.

    IF IS_RESULT-CODE EQ LIF_SMS=>CODE-DRY_RUN.

      IF IS_RESULT-TEXT_INFO-TEXT IS NOT INITIAL.

        SKIP.
        HEADING( 'L_TEXT' ).
        WRITE_LONG( IS_RESULT-TEXT_INFO-TEXT ).

      ENDIF.
      IF IS_RESULT-REQUEST IS NOT INITIAL.

        SKIP.
        HEADING( 'L_REQUEST' ).
        WRITE_LONG( IS_RESULT-REQUEST ).

      ENDIF.

    ENDIF.

  ENDMETHOD.

  METHOD SHOW_LENGTH.

    DATA LV_TEXT TYPE STRING.

    SKIP.
    HEADING( 'L_LENGTH' ).
    IF IS_LENGTH-CODE EQ `00`.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_LEN_LINE'
                               IV_1   = IS_LENGTH-PARTS
                               IV_2   = IS_LENGTH-USED
                               IV_3   = IS_LENGTH-LEFT_PART ).
      CONCATENATE IS_LENGTH-ENCODING `: ` LV_TEXT INTO LV_TEXT.
      WRITE_LONG( LV_TEXT ).
      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'L_LEN_LEFT'
                               IV_1   = IS_LENGTH-LEFT ).
      WRITE_LONG( LV_TEXT ).

    ELSE.

      WRITE_CODE( IV_CODE    = IS_LENGTH-CODE
                  IV_MESSAGE = IS_LENGTH-MESSAGE ).

    ENDIF.

  ENDMETHOD.

  METHOD SHOW_LOG_STATE.

    DATA LV_TEXT TYPE STRING.

    SKIP.
    IF IV_SAVED EQ ABAP_TRUE.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'LOG_SAVED'
                               IV_1   = LCL_SMS_LOG=>OBJECT ).

    ELSE.

      LV_TEXT = LCL_TEXT=>GET( IV_KEY = 'LOG_NONE'
                               IV_1   = LCL_SMS_LOG=>OBJECT ).

    ENDIF.
    WRITE_LONG( LV_TEXT ).

  ENDMETHOD.

  METHOD HEADING.

    DATA LV_TEXT TYPE STRING.

    LV_TEXT = LCL_TEXT=>GET( IV_KEY ).
    WRITE: / LV_TEXT COLOR COL_HEADING.

  ENDMETHOD.

  METHOD WRITE_CODE.

    DATA LV_TEXT TYPE STRING.

    CONCATENATE IV_CODE `: ` IV_MESSAGE INTO LV_TEXT.
    WRITE_LONG( LV_TEXT ).

  ENDMETHOD.

  METHOD WRITE_LONG.

    " Line by line, at most 120 characters each
    DATA LT_LINES TYPE STRING_TABLE.

    DATA: LV_LINE  TYPE STRING,
          LV_LEN   TYPE I,
          LV_OFF   TYPE I,
          LV_TAKE  TYPE I,
          LV_BLANK TYPE I,
          LV_PIECE TYPE C LENGTH 120.

    SPLIT IV_TEXT AT CL_ABAP_CHAR_UTILITIES=>NEWLINE
          INTO TABLE LT_LINES.
    LOOP AT LT_LINES INTO LV_LINE.

      LV_LEN = STRLEN( LV_LINE ).
      IF LV_LEN EQ 0.

        SKIP.
        CONTINUE.

      ENDIF.
      LV_OFF = 0.
      WHILE LV_OFF LT LV_LEN.

        LV_TAKE = LV_LEN - LV_OFF.
        IF LV_TAKE GT 120.

          LV_TAKE = 120.
          " Break at the last blank, not inside a word
          FIND ALL OCCURRENCES OF ` ` IN SECTION OFFSET LV_OFF
               LENGTH LV_TAKE OF LV_LINE MATCH OFFSET LV_BLANK.
          IF SY-SUBRC EQ 0 AND LV_BLANK GT LV_OFF.

            LV_TAKE = LV_BLANK - LV_OFF + 1.

          ENDIF.

        ENDIF.
        LV_PIECE = LV_LINE+LV_OFF(LV_TAKE).
        WRITE AT /IV_INDENT LV_PIECE.
        LV_OFF = LV_OFF + LV_TAKE.

      ENDWHILE.

      CLEAR LV_LINE.

    ENDLOOP.

    CLEAR LV_LINE.

  ENDMETHOD.

  METHOD CREDITS.

    DATA: LV_COUNT TYPE I,
          LV_CHAR  TYPE C LENGTH 11.

    IF IS_RESULT-ACTION EQ LIF_SMS=>ACTION-TEMPLATE.

      " The template text is at Netgsm: parts unknown here
      LV_CHAR = IS_RESULT-VALID.
      CONDENSE LV_CHAR.
      CONCATENATE LV_CHAR ` x ?` INTO RV_COUNT.
      RETURN.

    ENDIF.
    LV_COUNT = IS_RESULT-VALID * IS_RESULT-TEXT_INFO-PARTS.
    LV_CHAR = LV_COUNT.
    CONDENSE LV_CHAR.
    RV_COUNT = LV_CHAR.

  ENDMETHOD.

  METHOD FINISH.

    IF IV_OK EQ ABAP_TRUE.

      MESSAGE IV_TEXT TYPE 'S'.

    ELSEIF SY-BATCH EQ ABAP_TRUE.

      " Ends the job as cancelled, so job monitoring sees it
      MESSAGE IV_TEXT TYPE 'E'.

    ELSE.

      MESSAGE IV_TEXT TYPE 'S' DISPLAY LIKE 'E'.

    ENDIF.

  ENDMETHOD.

ENDCLASS.

INITIALIZATION.
  LCL_APP=>SET_TEXTS( ).

AT SELECTION-SCREEN OUTPUT.
  LCL_APP=>SET_SCREEN( ).

START-OF-SELECTION.
  LCL_APP=>RUN( ).

*&---------------------------------------------------------------------*
*& Entries for other programs. Example:
*&
*&   DATA lt_numbers TYPE string_table.
*&   DATA lv_code TYPE string.
*&   DATA lv_jobid TYPE string.
*&   DATA lv_message TYPE string.
*&   APPEND `0500 000 00 00` TO lt_numbers.
*&   PERFORM send_sms IN PROGRAM zche_sms_netgsm IF FOUND
*&     USING lt_numbers `Night job failed` `MYHEADER` abap_false
*&     CHANGING lv_code lv_jobid lv_message.
*&
*& lv_code: '00' = Netgsm accepted the message (lv_jobid is set).
*& Anything else = not sent or not sure; lv_message says why.
*& With iv_dry_run = abap_true everything is checked, nothing sent
*& (lv_code = 'DRY_RUN'). Destinations ZCHE_NETGSM and
*& ZCHE_NETGSM_EXT, no popup, no list; the result goes to the
*& application log when ZCHE_SMS exists in SLG0. The caller needs
*& S_ICF for the destination.
*&---------------------------------------------------------------------*
FORM SEND_SMS USING IT_NUMBERS TYPE STRING_TABLE
                    IV_TEXT    TYPE CSEQUENCE
                    IV_HEADER  TYPE CSEQUENCE
                    IV_DRY_RUN TYPE ABAP_BOOL
              CHANGING CV_CODE    TYPE STRING
                       CV_JOBID   TYPE STRING
                       CV_MESSAGE TYPE STRING.

  PERFORM SEND_SMS_OPT USING IT_NUMBERS IV_TEXT IV_HEADER IV_DRY_RUN
                             LIF_SMS=>ENCODING-AUTO LIF_SMS=>IYS-INFO
                             ABAP_FALSE
                       CHANGING CV_CODE CV_JOBID CV_MESSAGE.

ENDFORM.

*&---------------------------------------------------------------------*
*& Same with the options: iv_encoding AUTO, TR, UNICODE or ASCII;
*& iv_iys '0', '11' or '12'; iv_log_text 'X' logs the message text.
*&---------------------------------------------------------------------*
FORM SEND_SMS_OPT USING IT_NUMBERS  TYPE STRING_TABLE
                        IV_TEXT     TYPE CSEQUENCE
                        IV_HEADER   TYPE CSEQUENCE
                        IV_DRY_RUN  TYPE ABAP_BOOL
                        IV_ENCODING TYPE CSEQUENCE
                        IV_IYS      TYPE CSEQUENCE
                        IV_LOG_TEXT TYPE ABAP_BOOL
                  CHANGING CV_CODE    TYPE STRING
                           CV_JOBID   TYPE STRING
                           CV_MESSAGE TYPE STRING.

  DATA LS_SCHEDULE TYPE LIF_SMS=>TY_SCHEDULE.

  PERFORM SEND_SMS_AT USING IT_NUMBERS IV_TEXT IV_HEADER IV_DRY_RUN
                            IV_ENCODING IV_IYS IV_LOG_TEXT
                            LS_SCHEDULE ``
                      CHANGING CV_CODE CV_JOBID CV_MESSAGE.

ENDFORM.

*&---------------------------------------------------------------------*
*& Send later: is_schedule holds date and time in Turkish time (an
*& initial start date means now); iv_reference is your own ID for
*& the delivery report (referansID). Cancel with FORM cancel_sms.
*&---------------------------------------------------------------------*
FORM SEND_SMS_AT USING IT_NUMBERS   TYPE STRING_TABLE
                       IV_TEXT      TYPE CSEQUENCE
                       IV_HEADER    TYPE CSEQUENCE
                       IV_DRY_RUN   TYPE ABAP_BOOL
                       IV_ENCODING  TYPE CSEQUENCE
                       IV_IYS       TYPE CSEQUENCE
                       IV_LOG_TEXT  TYPE ABAP_BOOL
                       IS_SCHEDULE  TYPE LIF_SMS=>TY_SCHEDULE
                       IV_REFERENCE TYPE CSEQUENCE
                 CHANGING CV_CODE    TYPE STRING
                          CV_JOBID   TYPE STRING
                          CV_MESSAGE TYPE STRING.

  DATA LO_SMS TYPE REF TO LCL_SMS_NETGSM.

  DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

  DATA: LV_ENCODING TYPE LIF_SMS=>TY_ENCODING,
        LV_IYS      TYPE LIF_SMS=>TY_IYS.

  LV_ENCODING = IV_ENCODING.
  LV_IYS = IV_IYS.
  CREATE OBJECT LO_SMS.
  LS_RESULT = LO_SMS->SEND( IT_NUMBERS   = IT_NUMBERS
                            IV_TEXT      = IV_TEXT
                            IV_HEADER    = IV_HEADER
                            IV_ENCODING  = LV_ENCODING
                            IV_IYS       = LV_IYS
                            IS_SCHEDULE  = IS_SCHEDULE
                            IV_REFERENCE = IV_REFERENCE
                            IV_DRY_RUN   = IV_DRY_RUN ).
  IF LS_RESULT-CODE NE LIF_SMS=>CODE-DRY_RUN.

    LCL_SMS_LOG=>WRITE( IS_RESULT    = LS_RESULT
                        IV_WITH_TEXT = IV_LOG_TEXT ).

  ENDIF.
  CV_CODE = LS_RESULT-CODE.
  CV_JOBID = LS_RESULT-JOBID.
  CV_MESSAGE = LS_RESULT-MESSAGE.

ENDFORM.

*&---------------------------------------------------------------------*
*& OTP SMS: one number, one part, no Turkish letters (iv_ascii 'X'
*& turns them into Latin ones). Needs an OTP package at Netgsm.
*&---------------------------------------------------------------------*
FORM SEND_OTP USING IV_NUMBER  TYPE CSEQUENCE
                    IV_TEXT    TYPE CSEQUENCE
                    IV_HEADER  TYPE CSEQUENCE
                    IV_ASCII   TYPE ABAP_BOOL
                    IV_DRY_RUN TYPE ABAP_BOOL
              CHANGING CV_CODE    TYPE STRING
                       CV_JOBID   TYPE STRING
                       CV_MESSAGE TYPE STRING.

  DATA LO_SMS TYPE REF TO LCL_SMS_NETGSM.

  DATA LT_NUMBERS TYPE STRING_TABLE.

  DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

  DATA LV_NUMBER TYPE STRING.

  LV_NUMBER = IV_NUMBER.
  APPEND LV_NUMBER TO LT_NUMBERS.
  CREATE OBJECT LO_SMS.
  LS_RESULT = LO_SMS->SEND_OTP( IT_NUMBERS = LT_NUMBERS
                                IV_TEXT    = IV_TEXT
                                IV_HEADER  = IV_HEADER
                                IV_ASCII   = IV_ASCII
                                IV_DRY_RUN = IV_DRY_RUN ).
  IF LS_RESULT-CODE NE LIF_SMS=>CODE-DRY_RUN.

    " An OTP text is a secret code: never logged
    LCL_SMS_LOG=>WRITE( IS_RESULT    = LS_RESULT
                        IV_WITH_TEXT = ABAP_FALSE ).

  ENDIF.
  CV_CODE = LS_RESULT-CODE.
  CV_JOBID = LS_RESULT-JOBID.
  CV_MESSAGE = LS_RESULT-MESSAGE.

ENDFORM.

*&---------------------------------------------------------------------*
*& Template SMS: it_params holds lines name=value, the same values
*& for every number. Template IDs: action "List templates".
*&---------------------------------------------------------------------*
FORM SEND_TEMPLATE USING IT_NUMBERS     TYPE STRING_TABLE
                         IV_TEMPLATE_ID TYPE I
                         IT_PARAMS      TYPE STRING_TABLE
                         IV_HEADER      TYPE CSEQUENCE
                         IV_DRY_RUN     TYPE ABAP_BOOL
                   CHANGING CV_CODE    TYPE STRING
                            CV_JOBID   TYPE STRING
                            CV_MESSAGE TYPE STRING.

  DATA LO_SMS TYPE REF TO LCL_SMS_NETGSM.

  DATA LT_PARAMS TYPE LIF_SMS=>TY_PARAMS.

  DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

  LT_PARAMS = LCL_APP=>PARAMS_OF( IT_PARAMS ).
  CREATE OBJECT LO_SMS.
  LS_RESULT = LO_SMS->SEND_TEMPLATE( IT_NUMBERS     = IT_NUMBERS
                                     IV_TEMPLATE_ID = IV_TEMPLATE_ID
                                     IT_PARAMS      = LT_PARAMS
                                     IV_HEADER      = IV_HEADER
                                     IV_DRY_RUN     = IV_DRY_RUN ).
  IF LS_RESULT-CODE NE LIF_SMS=>CODE-DRY_RUN.

    LCL_SMS_LOG=>WRITE( IS_RESULT    = LS_RESULT
                        IV_WITH_TEXT = ABAP_FALSE ).

  ENDIF.
  CV_CODE = LS_RESULT-CODE.
  CV_JOBID = LS_RESULT-JOBID.
  CV_MESSAGE = LS_RESULT-MESSAGE.

ENDFORM.

*&---------------------------------------------------------------------*
*& Cancels an SMS scheduled for later. cv_code '00' = cancelled.
*&---------------------------------------------------------------------*
FORM CANCEL_SMS USING IV_JOBID TYPE CSEQUENCE
                CHANGING CV_CODE    TYPE STRING
                         CV_MESSAGE TYPE STRING.

  DATA LO_SMS TYPE REF TO LCL_SMS_NETGSM.

  DATA LS_ANSWER TYPE LIF_SMS=>TY_ANSWER.

  CREATE OBJECT LO_SMS.
  LS_ANSWER = LO_SMS->CANCEL( IV_JOBID ).
  LCL_SMS_LOG=>WRITE_SIMPLE( IV_ACTION  = LIF_SMS=>ACTION-CANCEL
                             IV_CODE    = LS_ANSWER-CODE
                             IV_MESSAGE = LS_ANSWER-MESSAGE
                             IV_JOBID   = LS_ANSWER-JOBID ).
  CV_CODE = LS_ANSWER-CODE.
  CV_MESSAGE = LS_ANSWER-MESSAGE.

ENDFORM.

*&---------------------------------------------------------------------*
*& ABAP Unit tests: Program > Execute > Unit Tests (Ctrl+Shift+F10).
*& They use a test double instead of SM59 and HTTP, so they never
*& reach Netgsm and send nothing. Numbers in them are made up.
*& Written for release 7.00: CL_AUNIT_ASSERT, and risk level and
*& duration as "#AU pseudo comments.
*&---------------------------------------------------------------------*
CLASS LTD_BACKEND DEFINITION FINAL FOR TESTING.
  PUBLIC SECTION.
    INTERFACES LIF_SMS_BACKEND.

    DATA AUTHORIZED TYPE ABAP_BOOL VALUE ABAP_TRUE.
    DATA DEST_TYPE TYPE RFCDES-RFCTYPE VALUE 'G'.
    DATA STATUS TYPE I VALUE 200.
    DATA REPLY TYPE STRING.
    DATA NO_ANSWER TYPE ABAP_BOOL.
    DATA NO_ANSWER_CODE TYPE STRING VALUE `NO_CONN`.
    DATA CALLS TYPE I.
    DATA LAST_METHOD TYPE STRING.
    DATA LAST_PATH TYPE STRING.
    DATA LAST_BODY TYPE STRING.
    DATA LAST_DESTINATION TYPE RFCDEST.
ENDCLASS.

CLASS LTD_BACKEND IMPLEMENTATION.

  METHOD LIF_SMS_BACKEND~HAS_AUTHORITY.

    RV_YES = AUTHORIZED.

  ENDMETHOD.

  METHOD LIF_SMS_BACKEND~DESTINATION_TYPE.

    RV_TYPE = DEST_TYPE.

  ENDMETHOD.

  METHOD LIF_SMS_BACKEND~CALL.

    CALLS = CALLS + 1.
    LAST_DESTINATION = IV_DESTINATION.
    LAST_METHOD = IV_METHOD.
    LAST_PATH = IV_PATH.
    LAST_BODY = IV_BODY.
    IF NO_ANSWER EQ ABAP_TRUE.

      RAISE EXCEPTION TYPE LCX_SMS
        EXPORTING
          CODE = NO_ANSWER_CODE
          TEXT = `timeout`.

    ENDIF.
    RS_HTTP-STATUS = STATUS.
    RS_HTTP-BODY = REPLY.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Helpers for the tests: characters by code point, repeated text
*----------------------------------------------------------------------*
CLASS LTU_CHARS DEFINITION FINAL FOR TESTING.
  PUBLIC SECTION.
    CLASS-METHODS CHAR
      IMPORTING
        IV_CODE_POINT  TYPE I
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    "! Text from UTF-8 bytes, for an emoji
    CLASS-METHODS UTF8
      IMPORTING
        IV_BYTES       TYPE XSTRING
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.

    CLASS-METHODS REPEAT
      IMPORTING
        IV_TEXT        TYPE STRING
        IV_TIMES       TYPE I
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.
ENDCLASS.

CLASS LTU_CHARS IMPLEMENTATION.

  METHOD CHAR.

    DATA LV_CHAR TYPE C LENGTH 1.

    LV_CHAR = CL_ABAP_CONV_IN_CE=>UCCPI( IV_CODE_POINT ).
    RV_TEXT = LV_CHAR.

  ENDMETHOD.

  METHOD UTF8.

    DATA LO_IN TYPE REF TO CL_ABAP_CONV_IN_CE.

    LO_IN = CL_ABAP_CONV_IN_CE=>CREATE( ENCODING = 'UTF-8'
                                        INPUT    = IV_BYTES ).
    LO_IN->READ( IMPORTING DATA = RV_TEXT ).

  ENDMETHOD.

  METHOD REPEAT.

    DO IV_TIMES TIMES.

      CONCATENATE RV_TEXT IV_TEXT INTO RV_TEXT.

    ENDDO.

  ENDMETHOD.

ENDCLASS.

CLASS LTC_PHONE DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    METHODS ACCEPTS_TURKISH_FORMS FOR TESTING.
    METHODS REJECTS_OTHERS FOR TESTING.
    METHODS MARKS_DUPLICATES FOR TESTING.
    METHODS MASKS FOR TESTING.

    METHODS ASSERT_NUMBER
      IMPORTING
        IV_INPUT  TYPE STRING
        IV_NUMBER TYPE STRING.

    METHODS ASSERT_REJECTED
      IMPORTING
        IV_INPUT TYPE STRING.
ENDCLASS.

CLASS LTC_PHONE IMPLEMENTATION.

  METHOD ACCEPTS_TURKISH_FORMS.

    ASSERT_NUMBER( IV_INPUT  = `+90 500 111 22 33`
                   IV_NUMBER = `5001112233` ).
    ASSERT_NUMBER( IV_INPUT  = `0090 500 111 22 33`
                   IV_NUMBER = `5001112233` ).
    ASSERT_NUMBER( IV_INPUT  = `90 500 1112233`
                   IV_NUMBER = `5001112233` ).
    ASSERT_NUMBER( IV_INPUT  = `0500 111 22 33`
                   IV_NUMBER = `5001112233` ).
    ASSERT_NUMBER( IV_INPUT  = `(0500) 111-22-33`
                   IV_NUMBER = `5001112233` ).
    ASSERT_NUMBER( IV_INPUT  = `500.111.22.33`
                   IV_NUMBER = `5001112233` ).
    ASSERT_NUMBER( IV_INPUT  = `5001112233`
                   IV_NUMBER = `5001112233` ).

  ENDMETHOD.

  METHOD REJECTS_OTHERS.

    " Landline, too short, too long, letters, foreign, sign only
    ASSERT_REJECTED( `0212 000 00 00` ).
    ASSERT_REJECTED( `500 111 22` ).
    ASSERT_REJECTED( `0500 111 22 334` ).
    ASSERT_REJECTED( `0500 ABC 22 33` ).
    ASSERT_REJECTED( `+49 151 0000000` ).
    ASSERT_REJECTED( `+` ).

  ENDMETHOD.

  METHOD MARKS_DUPLICATES.

    DATA: LT_INPUTS     TYPE STRING_TABLE,
          LT_RECIPIENTS TYPE LIF_SMS=>TY_RECIPIENTS.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    DATA LV_COUNT TYPE I.

    APPEND `0500 111 22 33` TO LT_INPUTS.
    APPEND `` TO LT_INPUTS.
    APPEND `+905001112233` TO LT_INPUTS.
    APPEND `5001112244` TO LT_INPUTS.
    LT_RECIPIENTS = LCL_SMS_PHONE=>NORMALIZE_ALL( LT_INPUTS ).

    DESCRIBE TABLE LT_RECIPIENTS LINES LV_COUNT.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_COUNT
                                    EXP = 3
                                    MSG = 'empty entry skipped' ).
    CLEAR LS_RECIPIENT.
    READ TABLE LT_RECIPIENTS
         INTO LS_RECIPIENT
         INDEX 2.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RECIPIENT-OK
                                    EXP = ABAP_FALSE
                                    MSG = 'second one is a duplicate' ).
    CLEAR LS_RECIPIENT.
    READ TABLE LT_RECIPIENTS
         INTO LS_RECIPIENT
         INDEX 3.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RECIPIENT-OK
                                    EXP = ABAP_TRUE
                                    MSG = 'other number stays' ).

  ENDMETHOD.

  METHOD MASKS.

    DATA LV_MASKED TYPE STRING.

    LV_MASKED = LCL_SMS_PHONE=>MASK( '5001112233' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_MASKED
                                    EXP = `5** *** ** 33`
                                    MSG = 'mask' ).
    LV_MASKED = LCL_SMS_PHONE=>MASK_ANY( '0212 000 00 45' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_MASKED
                                    EXP = `**** *** ** 45`
                                    MSG = 'mask_any' ).

  ENDMETHOD.

  METHOD ASSERT_NUMBER.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    LS_RECIPIENT = LCL_SMS_PHONE=>NORMALIZE( IV_INPUT ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RECIPIENT-OK
                                    EXP = ABAP_TRUE
                                    MSG = IV_INPUT ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RECIPIENT-NUMBER
                                    EXP = IV_NUMBER
                                    MSG = IV_INPUT ).

  ENDMETHOD.

  METHOD ASSERT_REJECTED.

    DATA LS_RECIPIENT TYPE LIF_SMS=>TY_RECIPIENT.

    LS_RECIPIENT = LCL_SMS_PHONE=>NORMALIZE( IV_INPUT ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RECIPIENT-OK
                                    EXP = ABAP_FALSE
                                    MSG = IV_INPUT ).
    CL_AUNIT_ASSERT=>ASSERT_NOT_INITIAL( ACT = LS_RECIPIENT-REASON
                                         MSG = IV_INPUT ).

  ENDMETHOD.

ENDCLASS.

CLASS LTC_TEXT DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    METHODS GSM_PART_LIMITS FOR TESTING.
    METHODS HEADER_SUFFIX FOR TESTING.
    METHODS TURKISH_CHOOSES_TR FOR TESTING.
    METHODS SOFT_TURKISH_LETTERS FOR TESTING.
    METHODS EXTENSION_COUNTS_TWO FOR TESTING.
    METHODS EMOJI_CHOOSES_UNICODE FOR TESTING.
    METHODS TR_REFUSES_EMOJI FOR TESTING.
    METHODS ASCII_CONVERTS FOR TESTING.
    METHODS TOO_LONG FOR TESTING.
    METHODS EMPTY_TEXT FOR TESTING.

    "! Analyzes a text of iv_times letters a
    METHODS LETTERS
      IMPORTING
        IV_TIMES       TYPE I
        IV_HEADER      TYPE STRING
        IV_ENCODING    TYPE LIF_SMS=>TY_ENCODING
                       DEFAULT LIF_SMS=>ENCODING-AUTO
      RETURNING
        VALUE(RS_INFO) TYPE LIF_SMS=>TY_TEXT_INFO.

    METHODS EMOJI_TEXT
      RETURNING
        VALUE(RV_TEXT) TYPE STRING.
ENDCLASS.

CLASS LTC_TEXT IMPLEMENTATION.

  METHOD LETTERS.

    DATA LV_TEXT TYPE STRING.

    LV_TEXT = LTU_CHARS=>REPEAT( IV_TEXT = `a` IV_TIMES = IV_TIMES ).
    RS_INFO = LCL_SMS_TEXT=>ANALYZE( IV_TEXT     = LV_TEXT
                                     IV_ENCODING = IV_ENCODING
                                     IV_HEADER   = IV_HEADER ).

  ENDMETHOD.

  METHOD EMOJI_TEXT.

    DATA LV_EMOJI TYPE STRING.

    " ok + grinning face (U+1F600), two UTF-16 code units
    LV_EMOJI = LTU_CHARS=>UTF8( 'F09F9880' ).
    CONCATENATE `ok ` LV_EMOJI INTO RV_TEXT.

  ENDMETHOD.

  METHOD GSM_PART_LIMITS.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    " Numeric sender name: no suffix
    LS_INFO = LETTERS( IV_TIMES = 160 IV_HEADER = `8500000000` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-ENCODING
                                    EXP = LIF_SMS=>ENCODING-GSM
                                    MSG = 'plain text is GSM' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-PARTS
                                    EXP = 1
                                    MSG = '160 fit one part' ).
    LS_INFO = LETTERS( IV_TIMES = 161 IV_HEADER = `8500000000` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-PARTS
                                    EXP = 2
                                    MSG = '161 need two parts' ).
    LS_INFO = LETTERS( IV_TIMES = 307 IV_HEADER = `8500000000` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-PARTS
                                    EXP = 3
                                    MSG = '307 = 2 x 153 + 1' ).

  ENDMETHOD.

  METHOD HEADER_SUFFIX.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    LS_INFO = LETTERS( IV_TIMES = 155 IV_HEADER = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-SUFFIX
                                    EXP = 5
                                    MSG = 'suffix for letters' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-PARTS
                                    EXP = 1
                                    MSG = '155 + 5 = 160' ).
    LS_INFO = LETTERS( IV_TIMES = 156 IV_HEADER = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-PARTS
                                    EXP = 2
                                    MSG = '156 + 5 > 160' ).

  ENDMETHOD.

  METHOD TURKISH_CHOOSES_TR.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    DATA: LV_1    TYPE STRING,
          LV_2    TYPE STRING,
          LV_TEXT TYPE STRING.

    " Capital I with dot and s with cedilla: 2 + 2 characters
    LV_1 = LTU_CHARS=>CHAR( 304 ).
    LV_2 = LTU_CHARS=>CHAR( 351 ).
    CONCATENATE LV_1 LV_2 INTO LV_TEXT.
    LS_INFO = LCL_SMS_TEXT=>ANALYZE(
                IV_TEXT     = LV_TEXT
                IV_ENCODING = LIF_SMS=>ENCODING-AUTO
                IV_HEADER   = '8500000000' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-ENCODING
                                    EXP = LIF_SMS=>ENCODING-TURKISH
                                    MSG = 'Turkish letters, TR' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-UNITS
                                    EXP = 4
                                    MSG = 'shift letters count 2' ).

  ENDMETHOD.

  METHOD SOFT_TURKISH_LETTERS.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    DATA: LV_1    TYPE STRING,
          LV_2    TYPE STRING,
          LV_TEXT TYPE STRING.

    " o and u with umlaut are GSM letters: TR, but 1 each
    LV_1 = LTU_CHARS=>CHAR( 246 ).
    LV_2 = LTU_CHARS=>CHAR( 252 ).
    CONCATENATE LV_1 LV_2 INTO LV_TEXT.
    LS_INFO = LCL_SMS_TEXT=>ANALYZE(
                IV_TEXT     = LV_TEXT
                IV_ENCODING = LIF_SMS=>ENCODING-AUTO
                IV_HEADER   = '8500000000' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-ENCODING
                                    EXP = LIF_SMS=>ENCODING-TURKISH
                                    MSG = 'still Turkish' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-UNITS
                                    EXP = 2
                                    MSG = 'one each' ).

  ENDMETHOD.

  METHOD EXTENSION_COUNTS_TWO.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    DATA: LV_EURO TYPE STRING,
          LV_TEXT TYPE STRING.

    LV_EURO = LTU_CHARS=>CHAR( 8364 ).
    CONCATENATE `10 ` LV_EURO ` [x]` INTO LV_TEXT.
    LS_INFO = LCL_SMS_TEXT=>ANALYZE(
                IV_TEXT     = LV_TEXT
                IV_ENCODING = LIF_SMS=>ENCODING-AUTO
                IV_HEADER   = '8500000000' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-ENCODING
                                    EXP = LIF_SMS=>ENCODING-GSM
                                    MSG = 'GSM extension' ).
    " "10 " 3, euro 2, " " 1, "[" 2, "x" 1, "]" 2
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-UNITS
                                    EXP = 11
                                    MSG = 'extension counts 2' ).

  ENDMETHOD.

  METHOD EMOJI_CHOOSES_UNICODE.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    DATA LV_TEXT TYPE STRING.

    LV_TEXT = EMOJI_TEXT( ).
    LS_INFO = LCL_SMS_TEXT=>ANALYZE(
                IV_TEXT     = LV_TEXT
                IV_ENCODING = LIF_SMS=>ENCODING-AUTO
                IV_HEADER   = '8500000000' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-ENCODING
                                    EXP = LIF_SMS=>ENCODING-UNICODE
                                    MSG = 'emoji, Unicode' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-UNITS
                                    EXP = 5
                                    MSG = 'code units' ).
    LS_INFO = LETTERS( IV_TIMES    = 71
                       IV_HEADER   = `8500000000`
                       IV_ENCODING = LIF_SMS=>ENCODING-UNICODE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-PARTS
                                    EXP = 2
                                    MSG = '71 Unicode = 2 parts' ).

  ENDMETHOD.

  METHOD TR_REFUSES_EMOJI.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    DATA LV_TEXT TYPE STRING.

    LV_TEXT = EMOJI_TEXT( ).
    LS_INFO = LCL_SMS_TEXT=>ANALYZE(
                IV_TEXT     = LV_TEXT
                IV_ENCODING = LIF_SMS=>ENCODING-TURKISH
                IV_HEADER   = '8500000000' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-OK
                                    EXP = ABAP_FALSE
                                    MSG = 'TR cannot send emoji' ).

  ENDMETHOD.

  METHOD ASCII_CONVERTS.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    DATA: LV_U         TYPE STRING,
          LV_S         TYPE STRING,
          LV_CAPITAL_I TYPE STRING,
          LV_DOTLESS_I TYPE STRING,
          LV_G         TYPE STRING,
          LV_TEXT      TYPE STRING.

    " "Gunes Isigi" written with Turkish letters
    LV_U = LTU_CHARS=>CHAR( 252 ).
    LV_S = LTU_CHARS=>CHAR( 351 ).
    LV_CAPITAL_I = LTU_CHARS=>CHAR( 304 ).
    LV_DOTLESS_I = LTU_CHARS=>CHAR( 305 ).
    LV_G = LTU_CHARS=>CHAR( 287 ).
    CONCATENATE `G` LV_U `ne` LV_S ` ` LV_CAPITAL_I LV_S LV_DOTLESS_I
                LV_G LV_DOTLESS_I
      INTO LV_TEXT.
    LS_INFO = LCL_SMS_TEXT=>ANALYZE(
                IV_TEXT     = LV_TEXT
                IV_ENCODING = LIF_SMS=>ENCODING-ASCII
                IV_HEADER   = '8500000000' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-TEXT
                                    EXP = `Gunes Isigi`
                                    MSG = 'Latin letters' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-ENCODING
                                    EXP = LIF_SMS=>ENCODING-GSM
                                    MSG = 'plain GSM after it' ).

  ENDMETHOD.

  METHOD TOO_LONG.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    LS_INFO = LETTERS( IV_TIMES = 912 IV_HEADER = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-OK
                                    EXP = ABAP_TRUE
                                    MSG = '912 GSM characters fit' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-PARTS
                                    EXP = 6
                                    MSG = 'in 6 parts' ).
    LS_INFO = LETTERS( IV_TIMES = 913 IV_HEADER = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-OK
                                    EXP = ABAP_FALSE
                                    MSG = '913 do not' ).

  ENDMETHOD.

  METHOD EMPTY_TEXT.

    DATA LS_INFO TYPE LIF_SMS=>TY_TEXT_INFO.

    LS_INFO = LETTERS( IV_TIMES = 0 IV_HEADER = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_INFO-OK
                                    EXP = ABAP_FALSE
                                    MSG = 'empty' ).

  ENDMETHOD.

ENDCLASS.

CLASS LTC_JSON DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    METHODS READS_FLAT FOR TESTING RAISING LCX_SMS.
    METHODS READS_ARRAYS FOR TESTING RAISING LCX_SMS.
    METHODS KEEPS_BLANKS_AND_ESCAPES FOR TESTING RAISING LCX_SMS.
    METHODS REJECTS_BROKEN FOR TESTING.
    METHODS ESCAPES FOR TESTING.

    METHODS ASSERT_VALUE
      IMPORTING
        IT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES
        IV_PATH   TYPE STRING
        IV_EXP    TYPE STRING.

    METHODS ASSERT_BROKEN
      IMPORTING
        IV_JSON TYPE STRING.
ENDCLASS.

CLASS LTC_JSON IMPLEMENTATION.

  METHOD ASSERT_VALUE.

    DATA LV_ACT TYPE STRING.

    LV_ACT = LCL_SMS_JSON=>VALUE_OF( IT_VALUES = IT_VALUES
                                     IV_PATH   = IV_PATH ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_ACT
                                    EXP = IV_EXP
                                    MSG = IV_PATH ).

  ENDMETHOD.

  METHOD ASSERT_BROKEN.

    TRY.

        LCL_SMS_JSON=>PARSE( IV_JSON ).
        CL_AUNIT_ASSERT=>FAIL( IV_JSON ).

      CATCH LCX_SMS.

        RETURN.

    ENDTRY.

  ENDMETHOD.

  METHOD READS_FLAT.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA LV_JSON TYPE STRING.

    CONCATENATE `{"code":"00","jobid":"17377215342605050417149344",`
                `"description":"queued"}`
      INTO LV_JSON.
    LT_VALUES = LCL_SMS_JSON=>PARSE( LV_JSON ).
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `jobid`
                  IV_EXP    = `17377215342605050417149344` ).
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `description`
                  IV_EXP    = `queued` ).

  ENDMETHOD.

  METHOD READS_ARRAYS.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA: LV_JSON TYPE STRING,
          LV_HAS  TYPE ABAP_BOOL.

    CONCATENATE `{ "code" : "00", "jobs" : [ {"jobid":"1","status":1},`
                ` {"jobid":"2","status":"3","x":null,"y":true} ],`
                ` "empty":[], "obj":{} }`
      INTO LV_JSON.
    LT_VALUES = LCL_SMS_JSON=>PARSE( LV_JSON ).
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `jobs/1/status`
                  IV_EXP    = `1` ).
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `jobs/2/status`
                  IV_EXP    = `3` ).
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `jobs/2/y`
                  IV_EXP    = `true` ).
    LV_HAS = LCL_SMS_JSON=>HAS( IT_VALUES = LT_VALUES
                                IV_PATH   = `jobs/3/jobid` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_HAS
                                    EXP = ABAP_FALSE
                                    MSG = 'no third row' ).

  ENDMETHOD.

  METHOD KEEPS_BLANKS_AND_ESCAPES.

    DATA LT_VALUES TYPE LCL_SMS_JSON=>TY_VALUES.

    DATA: LV_JSON      TYPE STRING,
          LV_CAPITAL_I TYPE STRING,
          LV_EXP       TYPE STRING.

    CONCATENATE `{"a":" x y ","b":"q\"\\n\\\"",`
                `"c":"İ z"}`
      INTO LV_JSON.
    LT_VALUES = LCL_SMS_JSON=>PARSE( LV_JSON ).
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `a`
                  IV_EXP    = ` x y ` ).
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `b`
                  IV_EXP    = `q"\n\"` ).
    LV_CAPITAL_I = LTU_CHARS=>CHAR( 304 ).
    CONCATENATE LV_CAPITAL_I ` z` INTO LV_EXP.
    ASSERT_VALUE( IT_VALUES = LT_VALUES
                  IV_PATH   = `c`
                  IV_EXP    = LV_EXP ).

  ENDMETHOD.

  METHOD REJECTS_BROKEN.

    ASSERT_BROKEN( `{"code":"00"` ).
    ASSERT_BROKEN( `<html>` ).
    ASSERT_BROKEN( `{"code" "00"}` ).
    ASSERT_BROKEN( `{"a":"open}` ).

  ENDMETHOD.

  METHOD ESCAPES.

    DATA: LV_TEXT TYPE STRING,
          LV_ACT  TYPE STRING.

    CONCATENATE `a"b\c` CL_ABAP_CHAR_UTILITIES=>NEWLINE `d`
      INTO LV_TEXT.
    LV_ACT = LCL_SMS_JSON=>ESCAPE( LV_TEXT ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_ACT
                                    EXP = `a\"b\\c\nd`
                                    MSG = 'escape' ).

  ENDMETHOD.

ENDCLASS.

CLASS LTC_SEND DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    DATA MO_BACKEND TYPE REF TO LTD_BACKEND.
    DATA MO_CUT TYPE REF TO LCL_SMS_NETGSM.
    DATA MT_NUMBERS TYPE STRING_TABLE.

    METHODS SETUP.
    METHODS DRY_RUN_CALLS_NOTHING FOR TESTING.
    METHODS SENDS_AND_READS_JOBID FOR TESTING.
    METHODS BODY_HAS_NETGSM_FIELDS FOR TESTING.
    METHODS TURKISH_BODY FOR TESTING.
    METHODS NETGSM_ERROR_CODES FOR TESTING.
    METHODS NO_AUTHORITY FOR TESTING.
    METHODS NO_DESTINATION FOR TESTING.
    METHODS NO_VALID_NUMBER FOR TESTING.
    METHODS BAD_HEADER FOR TESTING.
    METHODS NO_ANSWER_IS_UNSURE FOR TESTING.
    METHODS UNTRUSTED_IS_NOT_SENT FOR TESTING.
    METHODS HTTP_ERROR FOR TESTING.
    METHODS PLAIN_TEXT_ANSWER FOR TESTING.
    METHODS REPORT_READS_JOBS FOR TESTING.
    METHODS REPORT_LIMITS FOR TESTING.
    METHODS LISTS_HEADERS FOR TESTING.

    METHODS SEND
      IMPORTING
        IV_DRY_RUN       TYPE ABAP_BOOL DEFAULT ABAP_FALSE
        IV_HEADER        TYPE STRING DEFAULT `FIRMA`
        IV_TEXT          TYPE STRING DEFAULT `Job ZFI_CLOSE failed`
      RETURNING
        VALUE(RS_RESULT) TYPE LIF_SMS=>TY_RESULT.

    METHODS ASSERT_CONTAINS
      IMPORTING
        IV_TEXT TYPE STRING
        IV_PART TYPE STRING.

    METHODS ASSERT_LACKS
      IMPORTING
        IV_TEXT TYPE STRING
        IV_PART TYPE STRING.
ENDCLASS.

CLASS LTC_SEND IMPLEMENTATION.

  METHOD SETUP.

    CREATE OBJECT MO_BACKEND.
    CREATE OBJECT MO_CUT
      EXPORTING
        IV_DESTINATION     = 'ZCHE_TEST'
        IV_EXT_DESTINATION = 'ZCHE_TEST_EXT'
        IO_BACKEND         = MO_BACKEND.
    CLEAR MT_NUMBERS.
    APPEND `0500 111 22 33` TO MT_NUMBERS.
    APPEND `0500 111 22 44` TO MT_NUMBERS.
    APPEND `0212 000 00 00` TO MT_NUMBERS.

  ENDMETHOD.

  METHOD SEND.

    RS_RESULT = MO_CUT->SEND( IT_NUMBERS = MT_NUMBERS
                              IV_TEXT    = IV_TEXT
                              IV_HEADER  = IV_HEADER
                              IV_DRY_RUN = IV_DRY_RUN ).

  ENDMETHOD.

  METHOD ASSERT_CONTAINS.

    IF IV_TEXT NS IV_PART.

      CL_AUNIT_ASSERT=>FAIL( IV_PART ).

    ENDIF.

  ENDMETHOD.

  METHOD ASSERT_LACKS.

    IF IV_TEXT CS IV_PART.

      CL_AUNIT_ASSERT=>FAIL( IV_PART ).

    ENDIF.

  ENDMETHOD.

  METHOD DRY_RUN_CALLS_NOTHING.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    LS_RESULT = SEND( IV_DRY_RUN = ABAP_TRUE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-DRY_RUN
                                    MSG = 'dry run' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-VALID
                                    EXP = 2
                                    MSG = 'two valid numbers' ).
    " The preview shows masked numbers only
    ASSERT_LACKS( IV_TEXT = LS_RESULT-REQUEST IV_PART = `5001112233` ).
    ASSERT_CONTAINS( IV_TEXT = LS_RESULT-REQUEST
                     IV_PART = `"no":"5** *** ** 33"` ).

  ENDMETHOD.

  METHOD SENDS_AND_READS_JOBID.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    MO_BACKEND->REPLY =
      `{"code":"00","jobid":"1737721534","description":"queued"}`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = `00`
                                    MSG = 'code' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-SENT
                                    EXP = ABAP_TRUE
                                    MSG = 'sent' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-JOBID
                                    EXP = `1737721534`
                                    MSG = 'jobid' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 1
                                    MSG = 'one call, no retry' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_METHOD
                                    EXP = `POST`
                                    MSG = 'method' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = `/sms/rest/v2/send`
                                    MSG = 'path' ).

  ENDMETHOD.

  METHOD BODY_HAS_NETGSM_FIELDS.

    DATA LV_BODY TYPE STRING.

    MO_BACKEND->REPLY = `{"code":"00","jobid":"1"}`.
    SEND( ).
    LV_BODY = MO_BACKEND->LAST_BODY.
    ASSERT_CONTAINS( IV_TEXT = LV_BODY
                     IV_PART = `{"msgheader":"FIRMA",` ).
    ASSERT_CONTAINS( IV_TEXT = LV_BODY
                     IV_PART = `"iysfilter":"0"` ).
    ASSERT_CONTAINS(
      IV_TEXT = LV_BODY
      IV_PART = `{"msg":"Job ZFI_CLOSE failed","no":"5001112233"}` ).
    ASSERT_CONTAINS( IV_TEXT = LV_BODY
                     IV_PART = `"no":"5001112244"` ).
    " Rejected number not sent; plain GSM needs no encoding field
    ASSERT_LACKS( IV_TEXT = LV_BODY IV_PART = `0212` ).
    ASSERT_LACKS( IV_TEXT = LV_BODY IV_PART = `"encoding"` ).

  ENDMETHOD.

  METHOD TURKISH_BODY.

    DATA: LV_S    TYPE STRING,
          LV_TEXT TYPE STRING.

    LV_S = LTU_CHARS=>CHAR( 351 ).
    CONCATENATE `Ba` LV_S `ar` CL_ABAP_CHAR_UTILITIES=>NEWLINE `"ok"`
      INTO LV_TEXT.
    MO_BACKEND->REPLY = `{"code":"00","jobid":"1"}`.
    SEND( IV_TEXT = LV_TEXT ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `"encoding":"TR"` ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `\n\"ok\"` ).

  ENDMETHOD.

  METHOD NETGSM_ERROR_CODES.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    DATA LV_EXP TYPE STRING.

    MO_BACKEND->REPLY = `{"code":"30","jobid":null,"description":""}`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-SENT
                                    EXP = ABAP_FALSE
                                    MSG = '30 is not sent' ).
    LV_EXP = LCL_TEXT=>GET( 'C30' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-MESSAGE
                                    EXP = LV_EXP
                                    MSG = '30 explained' ).
    MO_BACKEND->REPLY = `{"code":"40"}`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = `40`
                                    MSG = '40' ).
    MO_BACKEND->REPLY = `{"code":"85"}`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-SENT
                                    EXP = ABAP_FALSE
                                    MSG = '85 is not sent' ).

  ENDMETHOD.

  METHOD NO_AUTHORITY.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    MO_BACKEND->AUTHORIZED = ABAP_FALSE.
    LS_RESULT = SEND( IV_DRY_RUN = ABAP_TRUE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-NO_AUTH
                                    MSG = 'preview checks too' ).
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-NO_AUTH
                                    MSG = 'no authority' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).

  ENDMETHOD.

  METHOD NO_DESTINATION.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    CLEAR MO_BACKEND->DEST_TYPE.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-NO_DEST
                                    MSG = 'missing' ).
    MO_BACKEND->DEST_TYPE = '3'.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-NO_DEST
                                    MSG = 'wrong type' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).

  ENDMETHOD.

  METHOD NO_VALID_NUMBER.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    CLEAR MT_NUMBERS.
    APPEND `0212 000 00 00` TO MT_NUMBERS.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_NUMBER
                                    MSG = 'no valid number' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).

  ENDMETHOD.

  METHOD BAD_HEADER.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    LS_RESULT = SEND( IV_HEADER = `` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'no header' ).
    LS_RESULT = SEND( IV_HEADER = `AB` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'too short' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).

  ENDMETHOD.

  METHOD NO_ANSWER_IS_UNSURE.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    DATA LV_UNSURE TYPE STRING.

    MO_BACKEND->NO_ANSWER = ABAP_TRUE.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-NO_CONN
                                    MSG = 'no connection' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-SENT
                                    EXP = ABAP_FALSE
                                    MSG = 'not marked as sent' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 1
                                    MSG = 'no retry' ).
    LV_UNSURE = LCL_TEXT=>GET( 'UNSURE' ).
    ASSERT_CONTAINS( IV_TEXT = LS_RESULT-MESSAGE IV_PART = LV_UNSURE ).

  ENDMETHOD.

  METHOD UNTRUSTED_IS_NOT_SENT.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    DATA LV_UNSURE TYPE STRING.

    MO_BACKEND->NO_ANSWER = ABAP_TRUE.
    MO_BACKEND->NO_ANSWER_CODE = LIF_SMS=>CODE-NO_TRUST.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-NO_TRUST
                                    MSG = 'certificate' ).
    " The handshake failed, so the program is sure nothing went out
    LV_UNSURE = LCL_TEXT=>GET( 'UNSURE' ).
    ASSERT_LACKS( IV_TEXT = LS_RESULT-MESSAGE IV_PART = LV_UNSURE ).

  ENDMETHOD.

  METHOD HTTP_ERROR.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    MO_BACKEND->STATUS = 406.
    MO_BACKEND->REPLY = `Not Acceptable`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-HTTP
                                    MSG = 'HTTP status' ).
    ASSERT_CONTAINS( IV_TEXT = LS_RESULT-MESSAGE IV_PART = `406` ).
    " A code in the body wins over the HTTP status
    MO_BACKEND->REPLY = `{"code":"30","description":"x"}`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = `30`
                                    MSG = '406 with a code' ).

  ENDMETHOD.

  METHOD PLAIN_TEXT_ANSWER.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    MO_BACKEND->REPLY = `30`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = `30`
                                    MSG = 'plain code' ).
    MO_BACKEND->REPLY = `<html>error</html>`.
    LS_RESULT = SEND( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_REPLY
                                    MSG = 'unreadable' ).

  ENDMETHOD.

  METHOD REPORT_READS_JOBS.

    DATA LT_JOBIDS TYPE STRING_TABLE.

    DATA: LS_REPORT TYPE LIF_SMS=>TY_REPORT,
          LS_LINE   TYPE LIF_SMS=>TY_REPORT_LINE.

    DATA: LV_COUNT TYPE I,
          LV_EXP   TYPE STRING.

    APPEND `1737721534` TO LT_JOBIDS.
    CONCATENATE
      `{"code":"00","jobs":[`
      `{"jobid":"1737721534","number":"905001112233","status":"1",`
      `"operator":"30","msglen":1,"deliveredDate":"07.11.2026",`
      `"errorCode":"0"},`
      `{"jobid":"1737721534","number":"905001112244","status":"2",`
      `"operator":"10","errorCode":"102"}],"description":"success"}`
      INTO MO_BACKEND->REPLY.
    LS_REPORT = MO_CUT->REPORT( IT_JOBIDS = LT_JOBIDS ).

    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_BODY
                                    EXP = `{"jobids":["1737721534"]}`
                                    MSG = 'request' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = `/sms/rest/v2/report`
                                    MSG = 'path' ).
    DESCRIBE TABLE LS_REPORT-LINES LINES LV_COUNT.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_COUNT
                                    EXP = 2
                                    MSG = 'two lines' ).
    CLEAR LS_LINE.
    READ TABLE LS_REPORT-LINES
         INTO LS_LINE
         INDEX 1.
    LV_EXP = LCL_TEXT=>GET( 'S1' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-STATUS_TEXT
                                    EXP = LV_EXP
                                    MSG = 'delivered' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-OPERATOR
                                    EXP = `Turkcell`
                                    MSG = 'operator' ).
    ASSERT_LACKS( IV_TEXT = LS_LINE-NUMBER IV_PART = `5001112233` ).
    CLEAR LS_LINE.
    READ TABLE LS_REPORT-LINES
         INTO LS_LINE
         INDEX 2.
    LV_EXP = LCL_TEXT=>GET( 'E102' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-ERROR_TEXT
                                    EXP = LV_EXP
                                    MSG = 'operator error' ).

  ENDMETHOD.

  METHOD REPORT_LIMITS.

    DATA LT_JOBIDS TYPE STRING_TABLE.

    DATA LS_REPORT TYPE LIF_SMS=>TY_REPORT.

    LS_REPORT = MO_CUT->REPORT( IT_JOBIDS = LT_JOBIDS ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_REPORT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'none' ).
    DO 51 TIMES.

      APPEND `1` TO LT_JOBIDS.

    ENDDO.
    LS_REPORT = MO_CUT->REPORT( IT_JOBIDS = LT_JOBIDS ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_REPORT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'too many' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).

  ENDMETHOD.

  METHOD LISTS_HEADERS.

    DATA LS_HEADERS TYPE LIF_SMS=>TY_HEADERS.

    DATA LV_COUNT TYPE I.

    MO_BACKEND->REPLY = `{"code":"00","msgheaders":["FIRMA","FIRMA2"]}`.
    LS_HEADERS = MO_CUT->HEADERS( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_METHOD
                                    EXP = `GET`
                                    MSG = 'GET' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = `/sms/rest/v2/msgheader`
                                    MSG = 'path' ).
    DESCRIBE TABLE LS_HEADERS-NAMES LINES LV_COUNT.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_COUNT
                                    EXP = 2
                                    MSG = 'two names' ).

  ENDMETHOD.

ENDCLASS.

CLASS LTC_SERVICES DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    DATA MO_BACKEND TYPE REF TO LTD_BACKEND.
    DATA MO_CUT TYPE REF TO LCL_SMS_NETGSM.
    DATA MT_NUMBERS TYPE STRING_TABLE.

    METHODS SETUP.
    METHODS SCHEDULE_AND_REFERENCE FOR TESTING.
    METHODS SCHEDULE_ORDER FOR TESTING.
    METHODS OTP_REQUEST FOR TESTING.
    METHODS OTP_RULES FOR TESTING.
    METHODS OTP_CODES FOR TESTING.
    METHODS OTP_OUTPUT_IS_PRIVATE FOR TESTING.
    METHODS TEMPLATE_REQUEST FOR TESTING.
    METHODS TEMPLATE_CHECKS FOR TESTING.
    METHODS TEMPLATE_VALUES FOR TESTING.
    METHODS CANCEL_JOB FOR TESTING.
    METHODS REPORT_BY_DATES FOR TESTING.
    METHODS STATISTICS FOR TESTING.
    METHODS INBOX_MESSAGES FOR TESTING.
    METHODS TEMPLATE_LIST FOR TESTING.
    METHODS NETGSM_LENGTH FOR TESTING.
    METHODS HELPERS FOR TESTING.

    METHODS ASSERT_CONTAINS
      IMPORTING
        IV_TEXT TYPE STRING
        IV_PART TYPE STRING.

    METHODS ASSERT_TEXT
      IMPORTING
        IV_ACT TYPE STRING
        IV_KEY TYPE STRING
        IV_1   TYPE STRING OPTIONAL.
ENDCLASS.

CLASS LTC_SERVICES IMPLEMENTATION.

  METHOD SETUP.

    CREATE OBJECT MO_BACKEND.
    CREATE OBJECT MO_CUT
      EXPORTING
        IV_DESTINATION     = 'ZCHE_TEST'
        IV_EXT_DESTINATION = 'ZCHE_TEST_EXT'
        IO_BACKEND         = MO_BACKEND.
    CLEAR MT_NUMBERS.
    APPEND `0500 111 22 33` TO MT_NUMBERS.

  ENDMETHOD.

  METHOD ASSERT_CONTAINS.

    IF IV_TEXT NS IV_PART.

      CL_AUNIT_ASSERT=>FAIL( IV_PART ).

    ENDIF.

  ENDMETHOD.

  METHOD ASSERT_TEXT.

    DATA LV_EXP TYPE STRING.

    LV_EXP = LCL_TEXT=>GET( IV_KEY = IV_KEY IV_1 = IV_1 ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = IV_ACT
                                    EXP = LV_EXP
                                    MSG = IV_KEY ).

  ENDMETHOD.

  METHOD SCHEDULE_AND_REFERENCE.

    DATA: LS_SCHEDULE TYPE LIF_SMS=>TY_SCHEDULE,
          LS_RESULT   TYPE LIF_SMS=>TY_RESULT.

    LS_SCHEDULE-START_DATE = '20261108'.
    LS_SCHEDULE-START_TIME = '093000'.
    LS_SCHEDULE-STOP_DATE = '20261108'.
    LS_SCHEDULE-STOP_TIME = '180000'.
    MO_BACKEND->REPLY = `{"code":"00","jobid":"77"}`.
    LS_RESULT = MO_CUT->SEND( IT_NUMBERS   = MT_NUMBERS
                              IV_TEXT      = `Toplanti 10:00`
                              IV_HEADER    = `FIRMA`
                              IS_SCHEDULE  = LS_SCHEDULE
                              IV_REFERENCE = `SAP-4711`
                              IV_DRY_RUN   = ABAP_FALSE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-JOBID
                                    EXP = `77`
                                    MSG = 'job ID' ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `"startdate":"081120260930"` ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `,"stopdate":"081120261800"` ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `"referansID":"SAP-4711"` ).

  ENDMETHOD.

  METHOD SCHEDULE_ORDER.

    DATA: LS_SCHEDULE TYPE LIF_SMS=>TY_SCHEDULE,
          LS_RESULT   TYPE LIF_SMS=>TY_RESULT.

    LS_SCHEDULE-START_DATE = '20261108'.
    LS_SCHEDULE-START_TIME = '093000'.
    LS_SCHEDULE-STOP_DATE = '20261108'.
    LS_SCHEDULE-STOP_TIME = '080000'.
    LS_RESULT = MO_CUT->SEND( IT_NUMBERS  = MT_NUMBERS
                              IV_TEXT     = `x`
                              IV_HEADER   = `FIRMA`
                              IS_SCHEDULE = LS_SCHEDULE
                              IV_DRY_RUN  = ABAP_FALSE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'stop before start' ).
    CLEAR LS_SCHEDULE.
    LS_SCHEDULE-STOP_DATE = '20261108'.
    LS_RESULT = MO_CUT->SEND( IT_NUMBERS  = MT_NUMBERS
                              IV_TEXT     = `x`
                              IV_HEADER   = `FIRMA`
                              IS_SCHEDULE = LS_SCHEDULE
                              IV_DRY_RUN  = ABAP_FALSE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'stop without start' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).

  ENDMETHOD.

  METHOD OTP_REQUEST.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    DATA: LV_EXP  TYPE STRING,
          LV_TEXT TYPE STRING.

    LV_TEXT = LTU_CHARS=>CHAR( 351 ).
    CONCATENATE LV_TEXT `ifre: 123456` INTO LV_TEXT.
    MO_BACKEND->REPLY = `{"jobid":"88","code":"00","description":"x"}`.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = LV_TEXT
                                  IV_ASCII   = ABAP_TRUE
                                  IV_HEADER  = `FIRMA`
                                  IV_DRY_RUN = ABAP_FALSE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-SENT
                                    EXP = ABAP_TRUE
                                    MSG = 'sent' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = `/sms/rest/v2/otp`
                                    MSG = 'path' ).
    CONCATENATE `{"msgheader":"FIRMA","msg":"sifre: 123456",`
                `"no":"5001112233"}`
      INTO LV_EXP.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_BODY
                                    EXP = LV_EXP
                                    MSG = 'body' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-TEXT_INFO-PARTS
                                    EXP = 1
                                    MSG = 'one part' ).
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_RESULT-TEXT_INFO-TEXT ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-JOBID EXP = `88` ).

  ENDMETHOD.

  METHOD OTP_RULES.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    DATA: LV_TEXT TYPE STRING,
          LV_S    TYPE STRING.

    " Two numbers
    APPEND `0500 111 22 44` TO MT_NUMBERS.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = `Kod 1`
                                  IV_HEADER  = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_NUMBER
                                    MSG = 'one number only' ).
    DELETE MT_NUMBERS INDEX 2.

    " s with cedilla: refused, or turned into s
    LV_S = LTU_CHARS=>CHAR( 351 ).
    CONCATENATE `Kod ` LV_S `ifre` INTO LV_TEXT.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = LV_TEXT
                                  IV_HEADER  = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_TEXT
                                    MSG = 'Turkish letter' ).
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_RESULT-TEXT_INFO-TEXT ).
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = LV_TEXT
                                  IV_HEADER  = `FIRMA`
                                  IV_ASCII   = ABAP_TRUE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-DRY_RUN
                                    MSG = 'ASCII preview accepted' ).

    " 155 characters fit with a sender name with letters, 156 not
    LV_TEXT = LTU_CHARS=>REPEAT( IV_TEXT = `a` IV_TIMES = 155 ).
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = LV_TEXT
                                  IV_HEADER  = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-DRY_RUN
                                    MSG = '155 fit' ).
    CONCATENATE LV_TEXT `a` INTO LV_TEXT.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = LV_TEXT
                                  IV_HEADER  = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_TEXT
                                    MSG = '156 do not' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS
                                    EXP = 0
                                    MSG = 'no HTTP call' ).

  ENDMETHOD.

  METHOD OTP_OUTPUT_IS_PRIVATE.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = `Passcode 482951`
                                  IV_HEADER  = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-DRY_RUN ).
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_RESULT-TEXT_INFO-TEXT ).
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_RESULT-REQUEST ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->CALLS EXP = 0 ).

    MO_BACKEND->STATUS = 503.
    MO_BACKEND->REPLY = `Error processing Passcode 482951`.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = `Passcode 482951`
                                  IV_HEADER  = `FIRMA`
                                  IV_DRY_RUN = ABAP_FALSE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-HTTP ).
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_RESULT-TEXT_INFO-TEXT ).
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_RESULT-REQUEST ).
    IF LS_RESULT-MESSAGE CS '482951'.

      CL_AUNIT_ASSERT=>FAIL( MSG = 'OTP exposed in the HTTP error' ).

    ENDIF.

    MO_BACKEND->STATUS = 200.
    MO_BACKEND->REPLY = `{"code":"99","description":"482951"}`.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = `Passcode 482951`
                                  IV_HEADER  = `FIRMA`
                                  IV_DRY_RUN = ABAP_FALSE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE EXP = `99` ).
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_RESULT-DESCRIPTION ).
    IF LS_RESULT-MESSAGE CS '482951'.

      CL_AUNIT_ASSERT=>FAIL( MSG = 'OTP in the provider error' ).

    ENDIF.

  ENDMETHOD.

  METHOD OTP_CODES.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    MO_BACKEND->REPLY = `{"code":"60","description":"no package"}`.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = `Kod 1`
                                  IV_HEADER  = `FIRMA`
                                  IV_DRY_RUN = ABAP_FALSE ).
    ASSERT_TEXT( IV_ACT = LS_RESULT-MESSAGE IV_KEY = `OTP_60` ).
    MO_BACKEND->REPLY = `{"code":"41"}`.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = `Kod 1`
                                  IV_HEADER  = `FIRMA`
                                  IV_DRY_RUN = ABAP_FALSE ).
    ASSERT_TEXT( IV_ACT = LS_RESULT-MESSAGE IV_KEY = `C40` ).
    MO_BACKEND->REPLY = `{"code":"105"}`.
    LS_RESULT = MO_CUT->SEND_OTP( IT_NUMBERS = MT_NUMBERS
                                  IV_TEXT    = `Kod 1`
                                  IV_HEADER  = `FIRMA`
                                  IV_DRY_RUN = ABAP_FALSE ).
    ASSERT_TEXT( IV_ACT = LS_RESULT-MESSAGE
                 IV_KEY = `C100`
                 IV_1   = `105` ).

  ENDMETHOD.

  METHOD TEMPLATE_REQUEST.

    DATA LT_PARAMS TYPE LIF_SMS=>TY_PARAMS.

    DATA: LS_RESULT   TYPE LIF_SMS=>TY_RESULT,
          LS_SCHEDULE TYPE LIF_SMS=>TY_SCHEDULE,
          LS_PARAM    TYPE LIF_SMS=>TY_PARAM.

    LS_PARAM-NAME = `ad`.
    LS_PARAM-VALUE = `Ali`.
    APPEND LS_PARAM TO LT_PARAMS.
    LS_PARAM-NAME = `talepno`.
    LS_PARAM-VALUE = `123`.
    APPEND LS_PARAM TO LT_PARAMS.
    LS_SCHEDULE-START_DATE = '20261108'.
    LS_SCHEDULE-START_TIME = '093000'.
    MO_BACKEND->REPLY = `{"code":"00","jobid":"99"}`.
    LS_RESULT = MO_CUT->SEND_TEMPLATE( IT_NUMBERS     = MT_NUMBERS
                                       IV_TEMPLATE_ID = 97
                                       IT_PARAMS      = LT_PARAMS
                                       IV_HEADER      = `FIRMA`
                                       IS_SCHEDULE    = LS_SCHEDULE
                                       IV_DRY_RUN     = ABAP_FALSE ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-JOBID
                                    EXP = `99`
                                    MSG = 'job ID' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_DESTINATION
                                    EXP = 'ZCHE_TEST_EXT'
                                    MSG = 'second destination' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = `/sms/rest/v2/template/send`
                                    MSG = 'path' ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `"encoding":"TR"` ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `"startdate":"2026-11-08 09:30"` ).
    ASSERT_CONTAINS(
      IV_TEXT = MO_BACKEND->LAST_BODY
      IV_PART = `{"templateId":97,"number":"5001112233","params":` ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `{"ad":"Ali","talepno":"123"}}]}` ).

  ENDMETHOD.

  METHOD TEMPLATE_CHECKS.

    DATA LT_PARAMS TYPE LIF_SMS=>TY_PARAMS.

    DATA LS_RESULT TYPE LIF_SMS=>TY_RESULT.

    LS_RESULT = MO_CUT->SEND_TEMPLATE( IT_NUMBERS     = MT_NUMBERS
                                       IV_TEMPLATE_ID = 0
                                       IT_PARAMS      = LT_PARAMS
                                       IV_HEADER      = `FIRMA` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_RESULT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'no template ID' ).
    MO_BACKEND->REPLY = `{"code":"NOT_FOUND","description":"x"}`.
    LS_RESULT = MO_CUT->SEND_TEMPLATE( IT_NUMBERS     = MT_NUMBERS
                                       IV_TEMPLATE_ID = 5
                                       IT_PARAMS      = LT_PARAMS
                                       IV_HEADER      = `FIRMA`
                                       IV_DRY_RUN     = ABAP_FALSE ).
    ASSERT_TEXT( IV_ACT = LS_RESULT-MESSAGE
                 IV_KEY = `TPL_NOT_FOUND` ).

  ENDMETHOD.

  METHOD TEMPLATE_VALUES.

    DATA: LT_LINES  TYPE STRING_TABLE,
          LT_PARAMS TYPE LIF_SMS=>TY_PARAMS.

    DATA LS_PARAM TYPE LIF_SMS=>TY_PARAM.

    APPEND `ad=Ali` TO LT_LINES.
    APPEND `url=a=b` TO LT_LINES.
    APPEND `no equal sign` TO LT_LINES.
    LT_PARAMS = LCL_APP=>PARAMS_OF( LT_LINES ).
    CLEAR LS_PARAM.
    READ TABLE LT_PARAMS
         INTO LS_PARAM
         INDEX 2.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_PARAM-VALUE
                                    EXP = `a=b`
                                    MSG = 'first = splits' ).
    CLEAR LS_PARAM.
    READ TABLE LT_PARAMS
         INTO LS_PARAM
         INDEX 3.
    CL_AUNIT_ASSERT=>ASSERT_INITIAL( ACT = LS_PARAM-NAME
                                     MSG = 'no name' ).

  ENDMETHOD.

  METHOD CANCEL_JOB.

    DATA LS_ANSWER TYPE LIF_SMS=>TY_ANSWER.

    MO_BACKEND->REPLY =
      `{"code":"00","jobid":"123","description":"job canceled"}`.
    LS_ANSWER = MO_CUT->CANCEL( ` 123 ` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_BODY
                                    EXP = `{"jobid":"123"}`
                                    MSG = 'body' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = `/sms/rest/v2/cancel`
                                    MSG = 'path' ).
    ASSERT_TEXT( IV_ACT = LS_ANSWER-MESSAGE IV_KEY = `CANCEL_00` ).
    MO_BACKEND->REPLY = `{"code":"60","jobid":"123"}`.
    LS_ANSWER = MO_CUT->CANCEL( `123` ).
    ASSERT_TEXT( IV_ACT = LS_ANSWER-MESSAGE IV_KEY = `CANCEL_60` ).

  ENDMETHOD.

  METHOD REPORT_BY_DATES.

    DATA LS_REPORT TYPE LIF_SMS=>TY_REPORT.

    DATA LV_EXP TYPE STRING.

    MO_BACKEND->REPLY = `{"code":"60","jobs":null}`.
    LS_REPORT = MO_CUT->REPORT( IV_FROM = '20261101'
                                IV_TO   = '20261107' ).
    CONCATENATE `{"startdate":"01.11.2026 00:00:00",`
                `"stopdate":"07.11.2026 23:59:59"}`
      INTO LV_EXP.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_BODY
                                    EXP = LV_EXP
                                    MSG = 'body' ).
    ASSERT_TEXT( IV_ACT = LS_REPORT-MESSAGE IV_KEY = `REPORT_60` ).
    LS_REPORT = MO_CUT->REPORT( IV_FROM = '20260101'
                                IV_TO   = '20261107' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_REPORT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'more than 3 months' ).
    LS_REPORT = MO_CUT->REPORT( IV_FROM = '20261101' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_REPORT-CODE
                                    EXP = LIF_SMS=>CODE-BAD_INPUT
                                    MSG = 'one date only' ).

  ENDMETHOD.

  METHOD STATISTICS.

    DATA: LS_STATS TYPE LIF_SMS=>TY_STATS,
          LS_LINE  TYPE LIF_SMS=>TY_STATS_LINE.

    DATA LV_COUNT TYPE I.

    CONCATENATE
      `{"stats":[{"status":"repeated","totalMessageLength":0,`
      `"totalSms":1,"chargeStatement":"","statement":"uncharged",`
      `"domestic":true},{"status":"successful",`
      `"totalMessageLength":3,"totalSms":3,"chargeStatement":`
      `"3.0 unit(s) from: ","statement":"charged","domestic":true}],`
      `"description":"success"}`
      INTO MO_BACKEND->REPLY.
    LS_STATS = MO_CUT->STATS( IV_JOBID     = `123`
                              IV_SEND_DATE = '20261001' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_STATS-CODE
                                    EXP = `00`
                                    MSG = 'success without code' ).
    ASSERT_CONTAINS( IV_TEXT = MO_BACKEND->LAST_BODY
                     IV_PART = `"senddate":"2026-10-01 00:00:00"` ).
    DESCRIBE TABLE LS_STATS-LINES LINES LV_COUNT.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_COUNT
                                    EXP = 2
                                    MSG = 'two lines' ).
    CLEAR LS_LINE.
    READ TABLE LS_STATS-LINES
         INTO LS_LINE
         INDEX 2.
    ASSERT_TEXT( IV_ACT = LS_LINE-STATUS_TEXT
                 IV_KEY = `ST_successful` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-TOTAL_PARTS
                                    EXP = `3`
                                    MSG = 'parts' ).

  ENDMETHOD.

  METHOD INBOX_MESSAGES.

    DATA: LS_INBOX TYPE LIF_SMS=>TY_INBOX,
          LS_LINE  TYPE LIF_SMS=>TY_INBOX_LINE.

    DATA LV_EXP TYPE STRING.

    CONCATENATE
      `{"code":"00","messages":[{"id":121386491,"gorevId":"1202",`
      `"kayittar":"1770000000000","mesaj":"Tamam","operator":`
      `"Netgsm","gonderen":"5001112233"}],"description":"success"}`
      INTO MO_BACKEND->REPLY.
    LS_INBOX = MO_CUT->INBOX( IV_FROM = '20261101'
                              IV_TO   = '20261107' ).
    CONCATENATE `/sms/rest/v2/inbox?startdate=011120260000`
                `&stopdate=071120262359`
      INTO LV_EXP.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = LV_EXP
                                    MSG = 'path' ).
    CLEAR LS_LINE.
    READ TABLE LS_INBOX-LINES
         INTO LS_LINE
         INDEX 1.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-RECEIVED
                                    EXP = `02.02.2026 05:40:00`
                                    MSG = 'Turkish time' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-SENDER
                                    EXP = `********33`
                                    MSG = 'masked' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-TEXT
                                    EXP = `Tamam`
                                    MSG = 'text' ).
    LS_INBOX = MO_CUT->INBOX( ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = `/sms/rest/v2/inbox`
                                    MSG = 'only new ones' ).

  ENDMETHOD.

  METHOD TEMPLATE_LIST.

    DATA: LS_TEMPLATES TYPE LIF_SMS=>TY_TEMPLATES,
          LS_LINE      TYPE LIF_SMS=>TY_TEMPLATE.

    DATA LV_EXP TYPE STRING.

    CONCATENATE
      `{"code":"00","description":"success","templates":[{`
      `"templateId":97,"templateContent":"Merhaba ${ad}",`
      `"type":"SUPPORT_TICKET_UPDATE","description":"Destek",`
      `"registryDate":"11.09.2026 14:30:14","parameters":[`
      `{"id":82,"name":"ad","type":"TEXT","maxLength":50},`
      `{"id":83,"name":"talepno","type":"BIGINT","maxLength":null}`
      `],"public":false}],"page":0,"size":1,"totalElements":2,`
      `"totalPages":2}`
      INTO MO_BACKEND->REPLY.
    LS_TEMPLATES = MO_CUT->TEMPLATES( IV_SEARCH = `destek talebi` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_DESTINATION
                                    EXP = 'ZCHE_TEST_EXT'
                                    MSG = 'second destination' ).
    CONCATENATE `/sms/rest/v2/template/list?page=0&size=50`
                `&includePublic=true&search=destek%20talebi`
      INTO LV_EXP.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_PATH
                                    EXP = LV_EXP
                                    MSG = 'path' ).
    CLEAR LS_LINE.
    READ TABLE LS_TEMPLATES-LINES
         INTO LS_LINE
         INDEX 1.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LINE-ID
                                    EXP = `97`
                                    MSG = 'ID' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS(
      ACT = LS_LINE-PARAMETERS
      EXP = `ad (TEXT, 50); talepno (BIGINT)`
      MSG = 'parameters' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_TEMPLATES-TOTAL
                                    EXP = `2`
                                    MSG = 'total' ).

  ENDMETHOD.

  METHOD NETGSM_LENGTH.

    DATA LS_LENGTH TYPE LIF_SMS=>TY_LENGTH.

    DATA LV_EXP TYPE STRING.

    CONCATENATE `{"parts":1,"charsUsed":29,"charsLeft":888,`
                `"charsLeftUntilNextPart":131}`
      INTO MO_BACKEND->REPLY.
    LS_LENGTH = MO_CUT->LENGTH( IV_TEXT   = `Merhaba, sifreniz 123456`
                                IV_HEADER = `FIRMA` ).
    CONCATENATE `{"context":"Merhaba, sifreniz 123456","encoding":0,`
                `"customHeader":true}`
      INTO LV_EXP.
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = MO_BACKEND->LAST_BODY
                                    EXP = LV_EXP
                                    MSG = 'body' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LENGTH-CODE
                                    EXP = `00`
                                    MSG = 'no code means OK' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LS_LENGTH-USED
                                    EXP = `29`
                                    MSG = 'used' ).

  ENDMETHOD.

  METHOD HELPERS.

    DATA: LV_TEXT TYPE STRING,
          LV_C    TYPE STRING.

    LV_C = LTU_CHARS=>CHAR( 231 ).
    CONCATENATE `a b/` LV_C INTO LV_TEXT.
    LV_TEXT = LCL_SMS_NETGSM=>URL_ENCODE( LV_TEXT ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_TEXT
                                    EXP = `a%20b%2F%C3%A7`
                                    MSG = 'URL encoding' ).
    LV_TEXT = LCL_SMS_NETGSM=>TURKISH_TIME( `abc` ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_TEXT
                                    EXP = `abc`
                                    MSG = 'not a number' ).
    LV_TEXT = LCL_SMS_NETGSM=>FORMAT_TIME( IV_DATE  = '20260411'
                                           IV_TIME  = '010000'
                                           IV_STYLE = 'DMYHM' ).
    CL_AUNIT_ASSERT=>ASSERT_EQUALS( ACT = LV_TEXT
                                    EXP = `110420260100`
                                    MSG = 'Netgsm example' ).

  ENDMETHOD.

ENDCLASS.
