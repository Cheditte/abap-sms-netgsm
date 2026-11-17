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
REPORT zche_sms_netgsm LINE-SIZE 255.

TYPE-POOLS: abap, vrm.


*----------------------------------------------------------------------*
* Types and constants
*----------------------------------------------------------------------*
INTERFACE lif_sms.

  CONSTANTS version TYPE string VALUE `0.2.0`.
  CONSTANTS default_destination TYPE rfcdest VALUE 'ZCHE_NETGSM'.
  " Netgsm serves templates from another host
  CONSTANTS default_ext_destination TYPE rfcdest
            VALUE 'ZCHE_NETGSM_EXT'.
  CONSTANTS api_path TYPE string VALUE `/sms/rest/v2`.

  " Recipients per call; Netgsm documents no limit for v2, so we
  " stay small
  CONSTANTS max_recipients TYPE i VALUE 100.
  " Netgsm: at most 6 parts (segments) per SMS
  CONSTANTS max_parts TYPE i VALUE 6.
  " Netgsm: at most 50 job IDs per report query
  CONSTANTS max_jobids TYPE i VALUE 50.
  " Netgsm: report range at most 3 months, inbox range 30 days
  CONSTANTS max_report_days TYPE i VALUE 92.
  CONSTANTS max_inbox_days TYPE i VALUE 30.
  " Netgsm sends its times in Turkish time, UTC+3 all year
  CONSTANTS turkey_offset_seconds TYPE i VALUE 10800.

  TYPES ty_encoding TYPE c LENGTH 7.
  " Character set: AUTO, TR and UNICODE are what you ask for, ASCII
  " turns Turkish letters into Latin ones first. GSM is the plain
  " GSM alphabet, chosen by AUTO when the text needs nothing else.
  CONSTANTS:
    BEGIN OF encoding,
      auto    TYPE ty_encoding VALUE 'AUTO',
      gsm     TYPE ty_encoding VALUE 'GSM',
      turkish TYPE ty_encoding VALUE 'TR',
      unicode TYPE ty_encoding VALUE 'UNICODE',
      ascii   TYPE ty_encoding VALUE 'ASCII',
    END OF encoding.

  TYPES ty_iys TYPE c LENGTH 2.
  " Netgsm iysfilter: 0 informational, 11 commercial to individuals,
  " 12 commercial to merchants
  CONSTANTS:
    BEGIN OF iys,
      info       TYPE ty_iys VALUE '0',
      individual TYPE ty_iys VALUE '11',
      merchant   TYPE ty_iys VALUE '12',
    END OF iys.

  " What is done; Netgsm's codes mean different things per service
  TYPES ty_action TYPE c LENGTH 8.
  CONSTANTS:
    BEGIN OF action,
      send      TYPE ty_action VALUE 'SEND',
      otp       TYPE ty_action VALUE 'OTP',
      template  TYPE ty_action VALUE 'TEMPLATE',
      cancel    TYPE ty_action VALUE 'CANCEL',
      report    TYPE ty_action VALUE 'REPORT',
      stats     TYPE ty_action VALUE 'STATS',
      inbox     TYPE ty_action VALUE 'INBOX',
      headers   TYPE ty_action VALUE 'HEADERS',
      templates TYPE ty_action VALUE 'TPLLIST',
      length    TYPE ty_action VALUE 'LENGTH',
    END OF action.

  " Result codes. Netgsm's own codes are two or three digits
  " ('00' = accepted); these are the program's own.
  CONSTANTS:
    BEGIN OF code,
      ok         TYPE string VALUE `00`,
      dry_run    TYPE string VALUE `DRY_RUN`,
      bad_input  TYPE string VALUE `BAD_INPUT`,
      bad_number TYPE string VALUE `BAD_NUMBER`,
      bad_text   TYPE string VALUE `BAD_TEXT`,
      no_dest    TYPE string VALUE `NO_DEST`,
      no_auth    TYPE string VALUE `NO_AUTH`,
      no_conn    TYPE string VALUE `NO_CONN`,
      no_trust   TYPE string VALUE `NO_TRUST`,
      http       TYPE string VALUE `HTTP_ERROR`,
      bad_reply  TYPE string VALUE `BAD_REPLY`,
    END OF code.

  " When to send, in Turkish time; an initial date means now
  TYPES:
    BEGIN OF ty_schedule,
      start_date TYPE d,
      start_time TYPE t,
      stop_date  TYPE d,
      stop_time  TYPE t,
    END OF ty_schedule.

  " A template value: name as in ${name}, and the value
  TYPES:
    BEGIN OF ty_param,
      name  TYPE string,
      value TYPE string,
    END OF ty_param,
    ty_params TYPE STANDARD TABLE OF ty_param WITH DEFAULT KEY.

  " One number as given and what became of it
  TYPES:
    BEGIN OF ty_recipient,
      input  TYPE string,
      number TYPE string,
      masked TYPE string,
      ok     TYPE abap_bool,
      reason TYPE string,
    END OF ty_recipient,
    ty_recipients TYPE STANDARD TABLE OF ty_recipient
                  WITH DEFAULT KEY.

  " The text as it will be sent, and its size
  TYPES:
    BEGIN OF ty_text_info,
      text      TYPE string,
      encoding  TYPE ty_encoding,
      units     TYPE i,
      max_units TYPE i,
      suffix    TYPE i,
      parts     TYPE i,
      ok        TYPE abap_bool,
      message   TYPE string,
    END OF ty_text_info.

  TYPES:
    BEGIN OF ty_result,
      action      TYPE ty_action,
      code        TYPE string,
      message     TYPE string,
      sent        TYPE abap_bool,
      jobid       TYPE string,
      description TYPE string,
      header      TYPE string,
      iys         TYPE ty_iys,
      recipients  TYPE ty_recipients,
      valid       TYPE i,
      text_info   TYPE ty_text_info,
      template_id TYPE i,
      schedule    TYPE ty_schedule,
      reference   TYPE string,
      " Request body with masked numbers, for the preview
      request     TYPE string,
      http_status TYPE i,
    END OF ty_result.

  " Code and text of a call that returns nothing else (cancel)
  TYPES:
    BEGIN OF ty_answer,
      code    TYPE string,
      message TYPE string,
      jobid   TYPE string,
    END OF ty_answer.

  TYPES:
    BEGIN OF ty_report_line,
      jobid       TYPE string,
      number      TYPE string,
      status      TYPE string,
      status_text TYPE string,
      operator    TYPE string,
      error_code  TYPE string,
      error_text  TYPE string,
      delivered   TYPE string,
      msglen      TYPE string,
      reference   TYPE string,
    END OF ty_report_line,
    ty_report_lines TYPE STANDARD TABLE OF ty_report_line
                    WITH DEFAULT KEY,
    BEGIN OF ty_report,
      code    TYPE string,
      message TYPE string,
      lines   TYPE ty_report_lines,
    END OF ty_report.

  TYPES:
    BEGIN OF ty_stats_line,
      status      TYPE string,
      status_text TYPE string,
      total_sms   TYPE string,
      total_parts TYPE string,
      charge      TYPE string,
      statement   TYPE string,
      domestic    TYPE string,
    END OF ty_stats_line,
    ty_stats_lines TYPE STANDARD TABLE OF ty_stats_line
                   WITH DEFAULT KEY,
    BEGIN OF ty_stats,
      code    TYPE string,
      message TYPE string,
      lines   TYPE ty_stats_lines,
    END OF ty_stats.

  TYPES:
    BEGIN OF ty_inbox_line,
      id       TYPE string,
      jobid    TYPE string,
      received TYPE string,
      sender   TYPE string,
      operator TYPE string,
      text     TYPE string,
    END OF ty_inbox_line,
    ty_inbox_lines TYPE STANDARD TABLE OF ty_inbox_line
                   WITH DEFAULT KEY,
    BEGIN OF ty_inbox,
      code    TYPE string,
      message TYPE string,
      lines   TYPE ty_inbox_lines,
    END OF ty_inbox.

  TYPES:
    BEGIN OF ty_headers,
      code    TYPE string,
      message TYPE string,
      names   TYPE string_table,
    END OF ty_headers.

  TYPES:
    BEGIN OF ty_template,
      id          TYPE string,
      type        TYPE string,
      description TYPE string,
      content     TYPE string,
      " name (TYPE, max. length), ...
      parameters  TYPE string,
      public      TYPE string,
      registered  TYPE string,
    END OF ty_template,
    ty_template_lines TYPE STANDARD TABLE OF ty_template
                      WITH DEFAULT KEY,
    BEGIN OF ty_templates,
      code     TYPE string,
      message  TYPE string,
      lines    TYPE ty_template_lines,
      page     TYPE string,
      pages    TYPE string,
      total    TYPE string,
    END OF ty_templates.

  " Netgsm's own count of a text
  TYPES:
    BEGIN OF ty_length,
      code       TYPE string,
      message    TYPE string,
      parts      TYPE string,
      used       TYPE string,
      left       TYPE string,
      left_part  TYPE string,
      encoding   TYPE ty_encoding,
    END OF ty_length.

  TYPES:
    BEGIN OF ty_http,
      status TYPE i,
      reason TYPE string,
      body   TYPE string,
    END OF ty_http.

ENDINTERFACE.




*----------------------------------------------------------------------*
* Error inside the program; callers get a result code instead
*----------------------------------------------------------------------*
CLASS lcx_sms DEFINITION INHERITING FROM cx_static_check FINAL.
  PUBLIC SECTION.
    DATA code TYPE string READ-ONLY.
    DATA text TYPE string READ-ONLY.

    METHODS constructor
      IMPORTING
        code     TYPE string OPTIONAL
        text     TYPE string OPTIONAL
        previous TYPE REF TO cx_root OPTIONAL.

    METHODS if_message~get_text REDEFINITION.
ENDCLASS.


CLASS lcx_sms IMPLEMENTATION.

  METHOD constructor.
    super->constructor( previous = previous ).
    me->code = code.
    me->text = text.
  ENDMETHOD.


  METHOD if_message~get_text.
    result = text.
    IF result IS INITIAL.
      result = super->if_message~get_text( ).
    ENDIF.
  ENDMETHOD.

ENDCLASS.


*----------------------------------------------------------------------*
* Texts in English and Turkish (logon language TR = Turkish). Set in
* code because a copy/paste installation carries no text elements.
*----------------------------------------------------------------------*
CLASS lcl_text DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS get
      IMPORTING
        iv_key         TYPE csequence
        iv_1           TYPE csequence OPTIONAL
        iv_2           TYPE csequence OPTIONAL
        iv_3           TYPE csequence OPTIONAL
      RETURNING
        value(rv_text) TYPE string.

    CLASS-METHODS pick
      IMPORTING
        iv_en          TYPE csequence
        iv_tr          TYPE csequence
      RETURNING
        value(rv_text) TYPE string.

  PRIVATE SECTION.
    CLASS-METHODS lookup
      IMPORTING
        iv_key         TYPE csequence
      RETURNING
        value(rv_text) TYPE string.
ENDCLASS.


CLASS lcl_text IMPLEMENTATION.

  METHOD get.
    DATA lv_value TYPE string.

    rv_text = lookup( iv_key ).
    lv_value = iv_1.
    REPLACE ALL OCCURRENCES OF '&1' IN rv_text WITH lv_value.
    lv_value = iv_2.
    REPLACE ALL OCCURRENCES OF '&2' IN rv_text WITH lv_value.
    lv_value = iv_3.
    REPLACE ALL OCCURRENCES OF '&3' IN rv_text WITH lv_value.
  ENDMETHOD.


  METHOD pick.
    IF sy-langu = 'T'.
      rv_text = iv_tr.
    ELSE.
      rv_text = iv_en.
    ENDIF.
  ENDMETHOD.


  METHOD lookup.
    DATA lv_en TYPE string.
    DATA lv_tr TYPE string.

    CASE iv_key.
*     Numbers
      WHEN 'NUM_CHARS'.
        lv_en = `contains characters other than digits`.
        lv_tr = `rakam dışında karakter var`.
      WHEN 'NUM_FOREIGN'.
        lv_en = `not a Turkish number (only +90 is supported)`.
        lv_tr = `Türkiye numarası değil (yalnızca +90)`.
      WHEN 'NUM_LENGTH'.
        lv_en = `wrong number of digits`.
        lv_tr = `hane sayısı yanlış`.
      WHEN 'NUM_MOBILE'.
        lv_en = `not a mobile number (must start with 5)`.
        lv_tr = `cep numarası değil (5 ile başlamalı)`.
      WHEN 'NUM_DUP'.
        lv_en = `given twice; sent once`.
        lv_tr = `iki kez verilmiş; bir kez gönderilir`.
      WHEN 'NO_NUMBERS'.
        lv_en = `No valid mobile number.`.
        lv_tr = `Geçerli cep numarası yok.`.
      WHEN 'TOO_MANY'.
        lv_en = `At most &1 numbers per call.`.
        lv_tr = `Bir çağrıda en fazla &1 numara olabilir.`.
*     Header and text
      WHEN 'NO_HEADER'.
        CONCATENATE `Enter the sender name (header) exactly as it`
                    ` is approved in the Netgsm panel.` INTO lv_en.
        CONCATENATE `Gönderici adını (başlık) Netgsm panelinde`
                    ` onaylandığı gibi girin.` INTO lv_tr.
      WHEN 'HEADER_LEN'.
        lv_en = `The sender name must have 3 to 11 characters.`.
        lv_tr = `Gönderici adı 3 ile 11 karakter olmalı.`.
      WHEN 'NO_TEXT'.
        lv_en = `The message text is empty.`.
        lv_tr = `Mesaj metni boş.`.
      WHEN 'TOO_LONG'.
        CONCATENATE `The text counts &1 characters; with this`
                    ` character set at most &2 fit into 6 parts.`
                    INTO lv_en.
        CONCATENATE `Metin &1 karakter sayılıyor; bu karakter`
                    ` setiyle 6 parçaya en fazla &2 sığar.`
                    INTO lv_tr.
      WHEN 'TR_UNICODE'.
        CONCATENATE `The text has characters that the Turkish`
                    ` character set cannot send (for example`
                    ` emoji). Choose Unicode.` INTO lv_en.
        CONCATENATE `Metinde Türkçe karakter setinin gönderemediği`
                    ` karakterler var (ör. emoji). Unicode seçin.`
                    INTO lv_tr.
      WHEN 'BAD_ENC'.
        lv_en = `Unknown character set &1.`.
        lv_tr = `Bilinmeyen karakter seti &1.`.
      WHEN 'BAD_IYS'.
        lv_en = `Unknown IYS value &1; use 0, 11 or 12.`.
        lv_tr = `Bilinmeyen İYS değeri &1; 0, 11 ya da 12 olmalı.`.
*     Destination and authorization
      WHEN 'NO_DEST'.
        CONCATENATE `SM59 destination &1 does not exist. Create it`
                    ` as type G (HTTP connection to external`
                    ` server), host api.netgsm.com.tr, port 443,`
                    ` SSL active.` INTO lv_en.
        CONCATENATE `SM59 hedefi &1 yok. G tipinde (dış sunucuya`
                    ` HTTP bağlantısı) oluşturun: host`
                    ` api.netgsm.com.tr, port 443, SSL aktif.`
                    INTO lv_tr.
      WHEN 'DEST_TYPE'.
        lv_en = `SM59 destination &1 has type &2; it must be G.`.
        lv_tr = `SM59 hedefi &1 &2 tipinde; G olmalı.`.
      WHEN 'NO_AUTH'.
        CONCATENATE `You may not use SM59 destination &1`
                    ` (authorization object S_ICF, ICF_FIELD DEST,`
                    ` ICF_VALUE &1).` INTO lv_en.
        CONCATENATE `SM59 hedefi &1 için yetkiniz yok (yetki`
                    ` nesnesi S_ICF, ICF_FIELD DEST, ICF_VALUE &1).`
                    INTO lv_tr.
*     Sending
      WHEN 'DRY_RUN'.
        lv_en = `Preview only: nothing was sent to Netgsm.`.
        lv_tr = `Yalnızca önizleme: Netgsm'e hiçbir şey gitmedi.`.
      WHEN 'NO_CONN'.
        lv_en = `No answer from Netgsm: &1`.
        lv_tr = `Netgsm'den cevap gelmedi: &1`.
      WHEN 'UNSURE'.
        CONCATENATE `The SMS may or may not have been sent: check`
                    ` the delivery report or the Netgsm panel`
                    ` before you send again.` INTO lv_en.
        CONCATENATE `SMS gitmiş de olabilir, gitmemiş de: tekrar`
                    ` göndermeden önce teslim raporuna ya da Netgsm`
                    ` paneline bakın.` INTO lv_tr.
      WHEN 'NO_TRUST'.
        CONCATENATE `SAP does not trust the certificate of`
                    ` *.netgsm.com.tr, so nothing was sent. In`
                    ` STRUST, add the root certificate "USERTrust`
                    ` RSA Certification Authority" to the SSL client`
                    ` PSE of the destination (usually SSL client`
                    ` Anonymous).` INTO lv_en.
        CONCATENATE `SAP *.netgsm.com.tr sertifikasına güvenmiyor,`
                    ` bu yüzden hiçbir şey gitmedi. STRUST'ta`
                    ` "USERTrust RSA Certification Authority" kök`
                    ` sertifikasını hedefin SSL istemci PSE'sine`
                    ` (genellikle SSL client Anonymous) ekleyin.`
                    INTO lv_tr.
      WHEN 'HTTP'.
        lv_en = `Netgsm answered with HTTP &1 &2.`.
        lv_tr = `Netgsm HTTP &1 &2 ile cevap verdi.`.
      WHEN 'BAD_REPLY'.
        lv_en = `Netgsm's answer cannot be read: &1`.
        lv_tr = `Netgsm'in cevabı okunamadı: &1`.
*     Netgsm codes. The same code can mean different things in
*     different services: <SERVICE>_<code> first, then C<code>.
      WHEN 'C00'.
        lv_en = `Netgsm accepted the message.`.
        lv_tr = `Netgsm mesajı kabul etti.`.
      WHEN 'C00_OK'.
        lv_en = `Netgsm answered: OK.`.
        lv_tr = `Netgsm cevabı: tamam.`.
      WHEN 'C01' OR 'C02'.
        lv_en = `Accepted; Netgsm corrected the send date.`.
        lv_tr = `Kabul edildi; Netgsm gönderim tarihini düzeltti.`.
      WHEN 'C20'.
        CONCATENATE `Problem in the message text, or the text is`
                    ` longer than allowed.` INTO lv_en.
        CONCATENATE `Mesaj metninde sorun var ya da metin izin`
                    ` verilenden uzun.` INTO lv_tr.
      WHEN 'C30'.
        CONCATENATE `Wrong user code or password, no API access`
                    ` for the sub-user, or the IP address of SAP is`
                    ` not allowed (Netgsm panel: API IP access).`
                    INTO lv_en.
        CONCATENATE `Kullanıcı kodu ya da şifre yanlış, alt`
                    ` kullanıcının API erişimi yok ya da SAP'nin IP`
                    ` adresine izin verilmemiş (Netgsm paneli: API`
                    ` IP erişim yönetimi).` INTO lv_tr.
      WHEN 'C40'.
        CONCATENATE `This sender name (header) is not defined on`
                    ` your Netgsm account.` INTO lv_en.
        CONCATENATE `Bu gönderici adı (başlık) Netgsm hesabınızda`
                    ` tanımlı değil.` INTO lv_tr.
      WHEN 'C50'.
        lv_en = `Your account cannot send IYS-checked messages.`.
        lv_tr = `Hesabınız İYS kontrollü gönderim yapamıyor.`.
      WHEN 'C51'.
        lv_en = `No IYS brand code is defined for your account.`.
        lv_tr = `Hesabınızda İYS marka kodu tanımlı değil.`.
      WHEN 'C70'.
        lv_en = `Invalid or missing parameter.`.
        lv_tr = `Hatalı ya da eksik parametre.`.
      WHEN 'C80'.
        lv_en = `Sending limit exceeded.`.
        lv_tr = `Gönderim sınırı aşıldı.`.
      WHEN 'C85'.
        CONCATENATE `More than 20 jobs to the same number within`
                    ` one minute.` INTO lv_en.
        CONCATENATE `Aynı numaraya bir dakikada 20'den fazla iş`
                    ` oluşturulamaz.` INTO lv_tr.
      WHEN 'C100'.
        lv_en = `Netgsm system error (&1).`.
        lv_tr = `Netgsm sistem hatası (&1).`.
      WHEN 'OTP_20'.
        CONCATENATE `Problem in the text, or it is too long: an OTP`
                    ` SMS is one part without Turkish letters, at`
                    ` most 155 characters with a sender name that`
                    ` has letters.` INTO lv_en.
        CONCATENATE `Metinde sorun var ya da metin uzun: OTP SMS`
                    ` Türkçe harf içermeyen tek parçadır, harfli`
                    ` gönderici adıyla en fazla 155 karakter.`
                    INTO lv_tr.
      WHEN 'OTP_50'.
        CONCATENATE `Check the number: OTP SMS go only to Turkish`
                    ` mobile numbers.` INTO lv_en.
        CONCATENATE `Numarayı kontrol edin: OTP SMS yalnızca`
                    ` Türkiye cep numaralarına gider.` INTO lv_tr.
      WHEN 'OTP_60'.
        lv_en = `No OTP SMS package on your Netgsm account.`.
        lv_tr = `Netgsm hesabınızda OTP SMS paketi tanımlı değil.`.
      WHEN 'TPL_UNAUTHORIZED'.
        lv_en = `Your account may not use this template.`.
        lv_tr = `Hesabınız bu şablonu kullanamıyor.`.
      WHEN 'TPL_NOT_FOUND'.
        lv_en = `There is no template with this ID.`.
        lv_tr = `Bu numarada bir şablon yok.`.
      WHEN 'TPL_BAD_REQUEST'.
        lv_en = `Values are missing for this template.`.
        lv_tr = `Bu şablon için eksik değer var.`.
      WHEN 'CANCEL_00'.
        lv_en = `The scheduled SMS was cancelled.`.
        lv_tr = `İleri tarihli SMS iptal edildi.`.
      WHEN 'CANCEL_60'.
        lv_en = `There is no job with this ID.`.
        lv_tr = `Bu numarada bir iş yok.`.
      WHEN 'REPORT_60'.
        lv_en = `No records for these criteria (yet).`.
        lv_tr = `Bu kriterlere uyan kayıt (henüz) yok.`.
      WHEN 'REPORT_70'.
        CONCATENATE `Invalid or missing parameter, or the date`
                    ` range is longer than 3 months.` INTO lv_en.
        CONCATENATE `Hatalı ya da eksik parametre ya da tarih`
                    ` aralığı 3 aydan uzun.` INTO lv_tr.
      WHEN 'REPORT_80'.
        CONCATENATE `Query limit: each job ID once a minute, 60`
                    ` queries a minute.` INTO lv_en.
        CONCATENATE `Sorgu sınırı: her iş numarası dakikada bir`
                    ` kez, dakikada en fazla 60 sorgu.` INTO lv_tr.
      WHEN 'INBOX_40'.
        CONCATENATE `No messages. Without a date range each`
                    ` message is listed only once.` INTO lv_en.
        CONCATENATE `Mesaj yok. Tarih aralığı verilmezse her mesaj`
                    ` yalnızca bir kez listelenir.` INTO lv_tr.
      WHEN 'INBOX_50'.
        lv_en = `Wrong date format.`.
        lv_tr = `Tarih biçimi hatalı.`.
      WHEN 'INBOX_60'.
        lv_en = `The date range is longer than 30 days.`.
        lv_tr = `Tarih aralığı 30 günden uzun.`.
      WHEN 'C_OTHER'.
        lv_en = `Netgsm code &1 &2`.
        lv_tr = `Netgsm kodu &1 &2`.
*     Delivery status per number (report)
      WHEN 'S0'.
        lv_en = `waiting`.
        lv_tr = `iletilmeyi bekliyor`.
      WHEN 'S1'.
        lv_en = `delivered`.
        lv_tr = `iletildi`.
      WHEN 'S2'.
        lv_en = `timed out`.
        lv_tr = `zaman aşımı`.
      WHEN 'S3'.
        lv_en = `wrong or restricted number`.
        lv_tr = `hatalı ya da kısıtlı numara`.
      WHEN 'S4'.
        lv_en = `not sent to the operator`.
        lv_tr = `operatöre gönderilemedi`.
      WHEN 'S11'.
        lv_en = `rejected by the operator`.
        lv_tr = `operatör kabul etmedi`.
      WHEN 'S12'.
        lv_en = `send error`.
        lv_tr = `gönderim hatası`.
      WHEN 'S13'.
        lv_en = `duplicate`.
        lv_tr = `mükerrer gönderim`.
      WHEN 'S14'.
        lv_en = `not enough credit`.
        lv_tr = `yetersiz kredi`.
      WHEN 'S15'.
        lv_en = `number is blacklisted`.
        lv_tr = `numara kara listede`.
      WHEN 'S16'.
        lv_en = `rejected by IYS`.
        lv_tr = `İYS reddetti`.
      WHEN 'S17'.
        lv_en = `IYS error`.
        lv_tr = `İYS hatası`.
      WHEN 'S22'.
        lv_en = `no permission for international SMS`.
        lv_tr = `yurt dışı gönderim izni yok`.
*     Operator error codes (report)
      WHEN 'E101'.
        lv_en = `mailbox full`.
        lv_tr = `mesaj kutusu dolu`.
      WHEN 'E102'.
        lv_en = `phone off or out of coverage`.
        lv_tr = `telefon kapalı ya da kapsama dışında`.
      WHEN 'E103'.
        lv_en = `line busy`.
        lv_tr = `hat meşgul`.
      WHEN 'E104'.
        lv_en = `line not active`.
        lv_tr = `hat aktif değil`.
      WHEN 'E105'.
        lv_en = `wrong number`.
        lv_tr = `hatalı numara`.
      WHEN 'E106'.
        lv_en = `blacklisted`.
        lv_tr = `kara listede`.
      WHEN 'E111'.
        lv_en = `timed out`.
        lv_tr = `zaman aşımı`.
      WHEN 'E112'.
        lv_en = `phone does not accept SMS`.
        lv_tr = `cihaz SMS almaya kapalı`.
      WHEN 'E113'.
        lv_en = `phone does not support it`.
        lv_tr = `cihaz desteklemiyor`.
      WHEN 'E114'.
        lv_en = `forwarding failed`.
        lv_tr = `yönlendirme başarısız`.
      WHEN 'E115'.
        lv_en = `timeout at the operator of the number`.
        lv_tr = `hedef operatörde zaman aşımı`.
      WHEN 'E116'.
        lv_en = `unknown subscriber`.
        lv_tr = `tanımlanamayan abone`.
      WHEN 'E117'.
        lv_en = `illegal subscriber`.
        lv_tr = `yasa dışı abone`.
      WHEN 'E119'.
        lv_en = `system error`.
        lv_tr = `sistemsel hata`.
      WHEN 'E_OTHER'.
        lv_en = `operator or system error &1`.
        lv_tr = `operatör ya da sistem hatası &1`.
      WHEN 'NO_JOBS'.
        lv_en = `Enter at least one Netgsm job ID.`.
        lv_tr = `En az bir Netgsm iş numarası (jobid) girin.`.
      WHEN 'TOO_MANY_JOBS'.
        lv_en = `At most &1 job IDs per query.`.
        lv_tr = `Bir sorguda en fazla &1 iş numarası olabilir.`.
*     Application log
      WHEN 'LOG_SAVED'.
        lv_en = `Saved in the application log (SLG1, object &1).`.
        lv_tr = `Uygulama günlüğüne yazıldı (SLG1, nesne &1).`.
      WHEN 'LOG_NONE'.
        CONCATENATE `Application log object &1 is not defined`
                    ` (SLG0); the result is only in this list and`
                    ` in the job log.` INTO lv_en.
        CONCATENATE `Uygulama günlüğü nesnesi &1 tanımlı değil`
                    ` (SLG0); sonuç yalnızca bu listede ve job`
                    ` günlüğünde.` INTO lv_tr.
      WHEN 'LOG_SUMMARY'.
        lv_en = `Header &1, character set &2, &3 part(s)`.
        lv_tr = `Başlık &1, karakter seti &2, &3 parça`.
      WHEN 'LOG_TEXT'.
        lv_en = `Text: &1`.
        lv_tr = `Metin: &1`.
*     Screen
      WHEN 'T_MSG'.
        lv_en = `Message`.
        lv_tr = `Mesaj`.
      WHEN 'T_RUN'.
        lv_en = `What to do`.
        lv_tr = `Ne yapılacak`.
      WHEN 'C_TXT'.
        lv_en = `Each filled line becomes one line of the SMS`.
        lv_tr = `Her dolu satır SMS'te bir satır olur`.
      WHEN 'S_NO'.
        lv_en = `Mobile numbers`.
        lv_tr = `Cep numaraları`.
      WHEN 'P_HEAD'.
        lv_en = `Sender name (header)`.
        lv_tr = `Gönderici adı (başlık)`.
      WHEN 'P_TXT1'.
        lv_en = `Text, line 1`.
        lv_tr = `Metin, 1. satır`.
      WHEN 'P_TXT2'.
        lv_en = `Text, line 2`.
        lv_tr = `Metin, 2. satır`.
      WHEN 'P_TXT3'.
        lv_en = `Text, line 3`.
        lv_tr = `Metin, 3. satır`.
      WHEN 'P_TXT4'.
        lv_en = `Text, line 4`.
        lv_tr = `Metin, 4. satır`.
      WHEN 'P_ENC'.
        lv_en = `Character set`.
        lv_tr = `Karakter seti`.
      WHEN 'P_IYS'.
        lv_en = `Message type (IYS)`.
        lv_tr = `İleti tipi (İYS)`.
      WHEN 'P_DRY'.
        lv_en = `Preview only, send nothing`.
        lv_tr = `Yalnızca önizleme, gönderme`.
      WHEN 'P_LOGTX'.
        lv_en = `Also log the message text`.
        lv_tr = `Mesaj metnini de günlüğe yaz`.
      WHEN 'S_JOB'.
        lv_en = `Netgsm job IDs`.
        lv_tr = `Netgsm iş numaraları`.
      WHEN 'P_DEST'.
        lv_en = `SM59 destination`.
        lv_tr = `SM59 hedefi`.
      WHEN 'ENC_AUTO'.
        lv_en = `Automatic (Turkish only when needed)`.
        lv_tr = `Otomatik (gerekirse Türkçe)`.
      WHEN 'ENC_TR'.
        lv_en = `Turkish characters (TR)`.
        lv_tr = `Türkçe karakterli (TR)`.
      WHEN 'ENC_UNICODE'.
        lv_en = `Unicode (for example emoji)`.
        lv_tr = `Unicode (ör. emoji)`.
      WHEN 'ENC_ASCII'.
        lv_en = `Turkish letters to Latin (c, g, s...)`.
        lv_tr = `Türkçe harfleri sadeleştir (c, g, s...)`.
      WHEN 'IYS_0'.
        lv_en = `Informational (no IYS check)`.
        lv_tr = `Bilgilendirme (İYS kontrolü yok)`.
      WHEN 'IYS_11'.
        lv_en = `Commercial, to individuals`.
        lv_tr = `Ticari, bireysel alıcı`.
      WHEN 'IYS_12'.
        lv_en = `Commercial, to merchants`.
        lv_tr = `Ticari, tacir alıcı`.
*     List and popup
      WHEN 'L_PREVIEW'.
        lv_en = `PREVIEW - nothing sent`.
        lv_tr = `ÖNİZLEME - hiçbir şey gönderilmedi`.
      WHEN 'L_SENT'.
        lv_en = `SENT to Netgsm`.
        lv_tr = `Netgsm'e GÖNDERİLDİ`.
      WHEN 'L_NOT_SENT'.
        lv_en = `NOT SENT`.
        lv_tr = `GÖNDERİLMEDİ`.
      WHEN 'L_RESULT'.
        lv_en = `Result`.
        lv_tr = `Sonuç`.
      WHEN 'L_JOBID'.
        lv_en = `Job ID`.
        lv_tr = `İş numarası`.
      WHEN 'L_HEADER'.
        lv_en = `Sender name`.
        lv_tr = `Gönderici adı`.
      WHEN 'L_ENC'.
        lv_en = `Character set`.
        lv_tr = `Karakter seti`.
      WHEN 'L_SIZE'.
        lv_en = `&1 of &2 characters, &3 part(s)`.
        lv_tr = `&1 / &2 karakter, &3 parça`.
      WHEN 'L_SUFFIX'.
        CONCATENATE `(includes the 5 characters Netgsm adds to`
                    ` an alphanumeric sender name)` INTO lv_en.
        CONCATENATE `(Netgsm'in harfli gönderici adına eklediği`
                    ` 5 karakter dahil)` INTO lv_tr.
      WHEN 'L_RCPT'.
        lv_en = `Recipients: &1 valid, &2 rejected`.
        lv_tr = `Alıcılar: &1 geçerli, &2 reddedildi`.
      WHEN 'L_CREDITS'.
        lv_en = `About &1 SMS credit(s)`.
        lv_tr = `Yaklaşık &1 SMS kredisi`.
      WHEN 'L_TEXT'.
        lv_en = `Text as it will be sent`.
        lv_tr = `Gönderilecek metin`.
      WHEN 'L_REQUEST'.
        lv_en = `Request to Netgsm (numbers masked)`.
        lv_tr = `Netgsm'e gidecek istek (numaralar maskeli)`.
      WHEN 'L_REPORT'.
        lv_en = `Delivery report`.
        lv_tr = `Teslim raporu`.
      WHEN 'L_REPORT_COLS'.
        CONCATENATE `Job ID                      Number`
                    `          Status / error` INTO lv_en.
        CONCATENATE `İş numarası                 Numara`
                    `          Durum / hata` INTO lv_tr.
      WHEN 'L_HEADERS'.
        lv_en = `Sender names on the Netgsm account`.
        lv_tr = `Netgsm hesabındaki gönderici adları`.
      WHEN 'L_CONN_OK'.
        lv_en = `Connection and logon to Netgsm work.`.
        lv_tr = `Netgsm bağlantısı ve girişi çalışıyor.`.
      WHEN 'POP_TITLE'.
        lv_en = `Send SMS for real`.
        lv_tr = `Gerçek SMS gönderimi`.
      WHEN 'POP_QUESTION'.
        CONCATENATE `Send the SMS to &1 number(s) through Netgsm,`
                    ` about &2 SMS credit(s)? This costs money.`
                    INTO lv_en.
        CONCATENATE `SMS Netgsm üzerinden &1 numaraya gönderilsin`
                    ` mi (yaklaşık &2 SMS kredisi)? Ücretlidir.`
                    INTO lv_tr.
      WHEN 'CANCELLED'.
        lv_en = `Cancelled; nothing was sent.`.
        lv_tr = `İptal edildi; hiçbir şey gönderilmedi.`.
      WHEN 'IGNORED'.
        lv_en = `Only single numbers are used; &1 entries ignored.`.
        lv_tr = `Yalnızca tek numaralar alınır; &1 giriş atlandı.`.
*     Version 0.2: actions, schedule, templates, OTP, lists
      WHEN 'OTP_ONE'.
        lv_en = `An OTP SMS goes to exactly one number.`.
        lv_tr = `OTP SMS tam olarak bir numaraya gider.`.
      WHEN 'OTP_CHARS'.
        CONCATENATE `An OTP SMS cannot contain "&1": no Turkish`
                    ` letters, no emoji. Choose the character set`
                    ` "Turkish letters to Latin".` INTO lv_en.
        CONCATENATE `OTP SMS "&1" içeremez: Türkçe harf ve emoji`
                    ` olmaz. "Türkçe harfleri sadeleştir" karakter`
                    ` setini seçin.` INTO lv_tr.
      WHEN 'OTP_LONG'.
        CONCATENATE `An OTP SMS is one part: at most &2`
                    ` characters, this text counts &1.` INTO lv_en.
        CONCATENATE `OTP SMS tek parçadır: en fazla &2 karakter,`
                    ` bu metin &1 karakter.` INTO lv_tr.
      WHEN 'NO_TEMPLATE'.
        lv_en = `Enter the template ID (see "List templates").`.
        lv_tr = `Şablon numarasını girin ("Şablonları listele").`.
      WHEN 'BAD_PARAM'.
        lv_en = `Template value "&1" must look like name=value.`.
        lv_tr = `Şablon değeri "&1" ad=değer biçiminde olmalı.`.
      WHEN 'SCHED_NO_START'.
        lv_en = `An end time needs a send date.`.
        lv_tr = `Son deneme zamanı için gönderim günü gerekir.`.
      WHEN 'SCHED_STOP'.
        lv_en = `The end time must be after the send time.`.
        CONCATENATE `Son deneme zamanı gönderim zamanından sonra`
                    ` olmalı.` INTO lv_tr.
      WHEN 'NO_JOB'.
        lv_en = `Enter a Netgsm job ID.`.
        lv_tr = `Bir Netgsm iş numarası (jobid) girin.`.
      WHEN 'NO_CRITERIA'.
        lv_en = `Enter job IDs or a date range.`.
        lv_tr = `İş numarası ya da tarih aralığı girin.`.
      WHEN 'RANGE_BOTH'.
        lv_en = `Enter both dates of the range, or neither.`.
        lv_tr = `Aralığın iki tarihini de girin ya da hiçbirini.`.
      WHEN 'RANGE_ORDER'.
        lv_en = `The end date is before the start date.`.
        lv_tr = `Bitiş tarihi başlangıç tarihinden önce.`.
      WHEN 'RANGE_LONG'.
        lv_en = `The date range may have at most &1 days.`.
        lv_tr = `Tarih aralığı en fazla &1 gün olabilir.`.
      WHEN 'NOTHING_DONE'.
        lv_en = `Cancelled; nothing was changed.`.
        lv_tr = `Vazgeçildi; hiçbir şey değişmedi.`.
      WHEN 'OP_60'.
        lv_en = `Türk Telekom fixed line`.
        lv_tr = `Türk Telekom sabit`.
      WHEN 'OP_70'.
        lv_en = `unknown operator`.
        lv_tr = `tanımsız operatör`.
      WHEN 'OP_ABROAD'.
        lv_en = `abroad`.
        lv_tr = `yurt dışı`.
      WHEN 'ST_successful'.
        lv_en = `delivered`.
        lv_tr = `iletildi`.
      WHEN 'ST_notEnoughCredit'.
        lv_en = `not enough credit`.
        lv_tr = `yetersiz kredi / paket`.
      WHEN 'ST_iysNotValid'.
        lv_en = `rejected by IYS`.
        lv_tr = `İYS reddetti`.
      WHEN 'ST_blacklist'.
        lv_en = `blacklisted`.
        lv_tr = `kara listede`.
      WHEN 'ST_numberError'.
        lv_en = `wrong number`.
        lv_tr = `hatalı numara`.
      WHEN 'ST_sendingError'.
        lv_en = `send error`.
        lv_tr = `gönderim hatası`.
      WHEN 'ST_operatorError'.
        lv_en = `operator error`.
        lv_tr = `operatör hatası`.
      WHEN 'ST_operatorRefused'.
        lv_en = `refused by the operator`.
        lv_tr = `operatör kabul etmedi`.
      WHEN 'ST_cannotSendToOperator'.
        lv_en = `not sent to the operator`.
        lv_tr = `operatöre gönderilemedi`.
      WHEN 'ST_messageTextError'.
        lv_en = `message length error`.
        lv_tr = `mesaj boyu hatası`.
      WHEN 'ST_notAccceptedByNts' OR 'ST_notAcceptedByNts'.
        lv_en = `NTS error`.
        lv_tr = `NTS hatası`.
      WHEN 'ST_waiting'.
        lv_en = `waiting`.
        lv_tr = `bekliyor`.
      WHEN 'ST_repeated'.
        lv_en = `duplicate`.
        lv_tr = `mükerrer`.
      WHEN 'ST_refunded'.
        lv_en = `charge refunded`.
        lv_tr = `ücret iade edildi`.
      WHEN 'ST_expired'.
        lv_en = `timed out`.
        lv_tr = `zaman aşımı`.
      WHEN 'T_TPL'.
        lv_en = `Template`.
        lv_tr = `Şablon`.
      WHEN 'T_SCH'.
        lv_en = `Later send (Turkish time) and reference`.
        lv_tr = `İleri tarihli gönderim (Türkiye saati), referans`.
      WHEN 'T_JOB'.
        lv_en = `Job IDs and dates`.
        lv_tr = `İş numaraları ve tarihler`.
      WHEN 'T_TLS'.
        lv_en = `Filter`.
        lv_tr = `Filtre`.
      WHEN 'T_CON'.
        lv_en = `Connection`.
        lv_tr = `Bağlantı`.
      WHEN 'C_TPAR'.
        lv_en = `Template values, one per line: name=value`.
        lv_tr = `Şablon değerleri, her satıra bir tane: ad=değer`.
      WHEN 'C_JOB'.
        lv_en = `Cancel and statistics use the first job ID`.
        lv_tr = `İptal ve istatistik ilk iş numarasını kullanır`.
      WHEN 'C_INB'.
        lv_en = `No dates: only new SMS, each one listed once`.
        lv_tr = `Tarihsiz: yalnızca yeni SMS, her biri bir kez`.
      WHEN 'P_ACT'.
        lv_en = `Action`.
        lv_tr = `İşlem`.
      WHEN 'P_NLEN'.
        lv_en = `Also count at Netgsm (free)`.
        lv_tr = `Netgsm'e de saydır (ücretsiz)`.
      WHEN 'P_TID'.
        lv_en = `Template ID`.
        lv_tr = `Şablon numarası`.
      WHEN 'S_TPAR'.
        lv_en = `Values name=value`.
        lv_tr = `Değerler ad=değer`.
      WHEN 'P_SDATE'.
        lv_en = `Send on`.
        lv_tr = `Gönderim günü`.
      WHEN 'P_STIME'.
        lv_en = `Send at`.
        lv_tr = `Gönderim saati`.
      WHEN 'P_EDATE'.
        lv_en = `Stop trying on`.
        lv_tr = `Son deneme günü`.
      WHEN 'P_ETIME'.
        lv_en = `Stop trying at`.
        lv_tr = `Son deneme saati`.
      WHEN 'P_REF'.
        lv_en = `Your reference (referansID)`.
        lv_tr = `Referansınız (referansID)`.
      WHEN 'P_RFROM'.
        lv_en = `From date`.
        lv_tr = `Başlangıç tarihi`.
      WHEN 'P_RTO'.
        lv_en = `To date`.
        lv_tr = `Bitiş tarihi`.
      WHEN 'P_SENDD'.
        lv_en = `Send date (older months)`.
        lv_tr = `Gönderim tarihi (eski aylar)`.
      WHEN 'P_FULL'.
        lv_en = `Show full numbers`.
        lv_tr = `Numaraları tam göster`.
      WHEN 'P_TSRCH'.
        lv_en = `Description contains`.
        lv_tr = `Açıklamada geçen`.
      WHEN 'P_TCONT'.
        lv_en = `Text contains`.
        lv_tr = `Metinde geçen`.
      WHEN 'P_TTYPE'.
        lv_en = `Template type`.
        lv_tr = `Şablon tipi`.
      WHEN 'P_TPUB'.
        lv_en = `Also Netgsm's own templates`.
        lv_tr = `Netgsm'in şablonları da`.
      WHEN 'P_TPAGE'.
        lv_en = `Page (from 0)`.
        lv_tr = `Sayfa (0'dan)`.
      WHEN 'P_DEXT'.
        lv_en = `SM59 destination (templates)`.
        lv_tr = `SM59 hedefi (şablonlar)`.
      WHEN 'ACT_SEND'.
        lv_en = `Send SMS`.
        lv_tr = `SMS gönder`.
      WHEN 'ACT_OTP'.
        lv_en = `Send OTP SMS (one number)`.
        lv_tr = `OTP SMS gönder (tek numara)`.
      WHEN 'ACT_TEMPLATE'.
        lv_en = `Send template SMS`.
        lv_tr = `Şablonlu SMS gönder`.
      WHEN 'ACT_CANCEL'.
        lv_en = `Cancel a scheduled SMS`.
        lv_tr = `İleri tarihli SMS'i iptal et`.
      WHEN 'ACT_REPORT'.
        lv_en = `Delivery report`.
        lv_tr = `Teslim raporu`.
      WHEN 'ACT_STATS'.
        lv_en = `Statistics of a job`.
        lv_tr = `Bir işin istatistiği`.
      WHEN 'ACT_INBOX'.
        lv_en = `Incoming SMS`.
        lv_tr = `Gelen SMS`.
      WHEN 'ACT_HEADERS'.
        lv_en = `Test: list sender names`.
        lv_tr = `Test: gönderici adlarını listele`.
      WHEN 'ACT_TPLLIST'.
        lv_en = `List templates`.
        lv_tr = `Şablonları listele`.
      WHEN 'ACT_LENGTH'.
        lv_en = `Count characters at Netgsm`.
        lv_tr = `Karakterleri Netgsm'e saydır`.
      WHEN 'L_STATS'.
        lv_en = `Statistics`.
        lv_tr = `İstatistik`.
      WHEN 'L_STATS_LINE'.
        lv_en = `&1 SMS, &2 part(s), charged &3`.
        lv_tr = `&1 SMS, &2 parça, ücret &3`.
      WHEN 'L_INBOX'.
        lv_en = `Incoming SMS`.
        lv_tr = `Gelen SMS`.
      WHEN 'L_TEMPLATES'.
        lv_en = `Templates`.
        lv_tr = `Şablonlar`.
      WHEN 'L_PAGE'.
        lv_en = `Page &1 of &2 (from 0), &3 template(s)`.
        lv_tr = `Sayfa &1 / &2 (0'dan), &3 şablon`.
      WHEN 'L_PARAMS'.
        lv_en = `Values: &1`.
        lv_tr = `Değerler: &1`.
      WHEN 'L_LENGTH'.
        lv_en = `Netgsm's count`.
        lv_tr = `Netgsm'in hesabı`.
      WHEN 'L_LEN_LINE'.
        CONCATENATE `&1 part(s), &2 characters in the last part,`
                    ` &3 left until the next part` INTO lv_en.
        CONCATENATE `&1 parça, son parçada &2 karakter, sonraki`
                    ` parçaya &3 karakter` INTO lv_tr.
      WHEN 'L_LEN_LEFT'.
        lv_en = `&1 characters left in 6 parts`.
        lv_tr = `6 parçada &1 karakter yer kaldı`.
      WHEN 'L_LOCAL'.
        CONCATENATE `This program's count: &1, &2 characters,`
                    ` &3 part(s)` INTO lv_en.
        lv_tr = `Programın hesabı: &1, &2 karakter, &3 parça`.
      WHEN 'L_SCHEDULE'.
        lv_en = `Send on &1, stop trying &2 (Turkish time)`.
        lv_tr = `Gönderim &1, son deneme &2 (Türkiye saati)`.
      WHEN 'L_REFERENCE'.
        lv_en = `Reference`.
        lv_tr = `Referans`.
      WHEN 'POP_CANCEL_T'.
        lv_en = `Cancel scheduled SMS`.
        lv_tr = `İleri tarihli SMS iptali`.
      WHEN 'POP_CANCEL_Q'.
        lv_en = `Cancel the scheduled SMS with job ID &1?`.
        lv_tr = `&1 numaralı ileri tarihli SMS iptal edilsin mi?`.
      WHEN OTHERS.
        lv_en = iv_key.
        lv_tr = iv_key.
    ENDCASE.
    rv_text = pick( iv_en = lv_en iv_tr = lv_tr ).
  ENDMETHOD.

ENDCLASS.


*----------------------------------------------------------------------*
* Phone numbers: +90 500 000 00 00, 0500..., 500..., 0090 500...
* all become 5000000000, the 10-digit form Netgsm v2 asks for
*----------------------------------------------------------------------*
CLASS lcl_sms_phone DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS normalize
      IMPORTING
        iv_input            TYPE csequence
      RETURNING
        value(rs_recipient) TYPE lif_sms=>ty_recipient.

    "! Normalizes all, skips empty entries, marks numbers given twice
    CLASS-METHODS normalize_all
      IMPORTING
        it_inputs            TYPE string_table
      RETURNING
        value(rt_recipients) TYPE lif_sms=>ty_recipients.

    "! 5000000034 -> 5** *** ** 34
    CLASS-METHODS mask
      IMPORTING
        iv_number        TYPE csequence
      RETURNING
        value(rv_masked) TYPE string.

    "! Every digit but the last two becomes *
    CLASS-METHODS mask_any
      IMPORTING
        iv_input         TYPE csequence
      RETURNING
        value(rv_masked) TYPE string.
ENDCLASS.


CLASS lcl_sms_phone IMPLEMENTATION.

  METHOD normalize.
    DATA lv_work TYPE c LENGTH 40.
    DATA lv_number TYPE string.
    DATA lv_len TYPE i.

    rs_recipient-input = iv_input.
    lv_work = iv_input.
    TRANSLATE lv_work USING '- . ( ) / '.
    CONDENSE lv_work NO-GAPS.
    IF lv_work(1) = '+'.
      CONCATENATE '00' lv_work+1 INTO lv_work.
    ENDIF.
    lv_number = lv_work.
    lv_len = strlen( lv_number ).

    IF lv_len = 0 OR NOT lv_number CO '0123456789'.
      rs_recipient-reason = lcl_text=>get( 'NUM_CHARS' ).
    ELSEIF lv_len >= 2 AND lv_number(2) = '00'
       AND NOT ( lv_len >= 4 AND lv_number(4) = '0090' ).
      rs_recipient-reason = lcl_text=>get( 'NUM_FOREIGN' ).
    ELSE.
      IF lv_len = 14 AND lv_number(4) = '0090'.
        SHIFT lv_number LEFT BY 4 PLACES.
      ELSEIF lv_len = 12 AND lv_number(2) = '90'.
        SHIFT lv_number LEFT BY 2 PLACES.
      ELSEIF lv_len = 11 AND lv_number(1) = '0'.
        SHIFT lv_number LEFT BY 1 PLACES.
      ENDIF.
      lv_len = strlen( lv_number ).
      IF lv_len <> 10.
        rs_recipient-reason = lcl_text=>get( 'NUM_LENGTH' ).
      ELSEIF lv_number(1) <> '5'.
        rs_recipient-reason = lcl_text=>get( 'NUM_MOBILE' ).
      ELSE.
        rs_recipient-number = lv_number.
        rs_recipient-ok = abap_true.
      ENDIF.
    ENDIF.

    IF rs_recipient-ok = abap_true.
      rs_recipient-masked = mask( rs_recipient-number ).
    ELSE.
      rs_recipient-masked = mask_any( iv_input ).
    ENDIF.
  ENDMETHOD.


  METHOD normalize_all.
    DATA lv_input TYPE string.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.
    DATA lt_seen TYPE SORTED TABLE OF string
                 WITH UNIQUE KEY table_line.

    LOOP AT it_inputs INTO lv_input.
      CONDENSE lv_input.
      IF lv_input IS INITIAL.
        CONTINUE.
      ENDIF.
      ls_recipient = normalize( lv_input ).
      IF ls_recipient-ok = abap_true.
        READ TABLE lt_seen TRANSPORTING NO FIELDS
             WITH TABLE KEY table_line = ls_recipient-number.
        IF sy-subrc = 0.
          ls_recipient-ok = abap_false.
          ls_recipient-reason = lcl_text=>get( 'NUM_DUP' ).
        ELSE.
          INSERT ls_recipient-number INTO TABLE lt_seen.
        ENDIF.
      ENDIF.
      APPEND ls_recipient TO rt_recipients.
    ENDLOOP.
  ENDMETHOD.


  METHOD mask.
    DATA lv_number TYPE string.
    DATA lv_len TYPE i.
    DATA lv_off TYPE i.

    lv_number = iv_number.
    lv_len = strlen( lv_number ).
    IF lv_len <> 10.
      rv_masked = mask_any( lv_number ).
      RETURN.
    ENDIF.
    lv_off = lv_len - 2.
    CONCATENATE lv_number(1) '** *** **' INTO rv_masked.
    CONCATENATE rv_masked ` ` lv_number+lv_off(2) INTO rv_masked.
  ENDMETHOD.


  METHOD mask_any.
    DATA lv_work TYPE c LENGTH 40.
    DATA lv_len TYPE i.
    DATA lv_keep TYPE i.
    DATA lv_pos TYPE i.

    lv_work = iv_input.
    lv_len = strlen( lv_work ).
    lv_keep = lv_len - 2.
    DO lv_len TIMES.
      lv_pos = sy-index - 1.
      IF lv_pos >= lv_keep.
        EXIT.
      ENDIF.
      IF lv_work+lv_pos(1) CO '0123456789'.
        lv_work+lv_pos(1) = '*'.
      ENDIF.
    ENDDO.
    rv_masked = lv_work.
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
CLASS lcl_sms_text DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES ty_kind TYPE c LENGTH 1.
    CONSTANTS:
      BEGIN OF kind,
        basic     TYPE ty_kind VALUE 'B',
        extension TYPE ty_kind VALUE 'E',
        turkish   TYPE ty_kind VALUE 'T',
        other     TYPE ty_kind VALUE 'U',
      END OF kind.

    CLASS-METHODS analyze
      IMPORTING
        iv_text        TYPE csequence
        iv_encoding    TYPE lif_sms=>ty_encoding
        iv_header      TYPE csequence
      RETURNING
        value(rs_info) TYPE lif_sms=>ty_text_info.

    "! What a character costs: basic, extension, Turkish, other
    CLASS-METHODS kind_of
      IMPORTING
        iv_code_point  TYPE i
      RETURNING
        value(rv_kind) TYPE ty_kind.

    "! One of the twelve Turkish letters (c g i o s u, both cases)
    CLASS-METHODS is_turkish_letter
      IMPORTING
        iv_code_point TYPE i
      RETURNING
        value(rv_yes) TYPE abap_bool.

    "! OTP SMS rules (Netgsm): one part, plain GSM letters, no
    "! Turkish letters except o and u with umlaut
    CLASS-METHODS check_otp
      IMPORTING
        iv_text        TYPE csequence
        iv_header      TYPE csequence
        iv_ascii       TYPE abap_bool
      RETURNING
        value(rs_info) TYPE lif_sms=>ty_text_info.

    "! Turkish letters to Latin ones; the rest stays
    CLASS-METHODS to_ascii
      IMPORTING
        iv_text        TYPE csequence
      RETURNING
        value(rv_text) TYPE string.

  PRIVATE SECTION.
    CLASS-METHODS replace_code_point
      IMPORTING
        iv_code_point TYPE i
        iv_with       TYPE c
      CHANGING
        cv_text       TYPE string.
ENDCLASS.


CLASS lcl_sms_text IMPLEMENTATION.

  METHOD analyze.
    DATA lv_text TYPE string.
    DATA lv_len TYPE i.
    DATA lv_pos TYPE i.
    DATA lv_char TYPE c LENGTH 1.
    DATA lv_code_point TYPE i.
    DATA lv_kind TYPE ty_kind.
    DATA lv_basic TYPE i.
    DATA lv_ext TYPE i.
    DATA lv_tr TYPE i.
    DATA lv_other TYPE i.
    DATA lv_letters TYPE i.
    DATA lv_header TYPE string.
    DATA lv_single TYPE i.
    DATA lv_multi TYPE i.
    DATA lv_total TYPE i.
    DATA lv_1 TYPE c LENGTH 12.
    DATA lv_2 TYPE c LENGTH 12.

    lv_text = iv_text.
    REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf
            IN lv_text WITH cl_abap_char_utilities=>newline.

    CASE iv_encoding.
      WHEN lif_sms=>encoding-auto OR lif_sms=>encoding-turkish
        OR lif_sms=>encoding-unicode.
      WHEN lif_sms=>encoding-ascii.
        lv_text = to_ascii( lv_text ).
      WHEN OTHERS.
        rs_info-message = lcl_text=>get( iv_key = 'BAD_ENC'
                                         iv_1   = iv_encoding ).
        RETURN.
    ENDCASE.
    rs_info-text = lv_text.

    lv_len = strlen( lv_text ).
    IF lv_len = 0.
      rs_info-message = lcl_text=>get( 'NO_TEXT' ).
      RETURN.
    ENDIF.

    DO lv_len TIMES.
      lv_pos = sy-index - 1.
      lv_char = lv_text+lv_pos(1).
      TRY.
          lv_code_point = cl_abap_conv_out_ce=>uccpi( lv_char ).
        CATCH cx_root.
          " Half of a surrogate pair (emoji): not GSM, not Turkish
          lv_code_point = 65535.
      ENDTRY.
      lv_kind = kind_of( lv_code_point ).
      CASE lv_kind.
        WHEN kind-basic.
          lv_basic = lv_basic + 1.
        WHEN kind-extension.
          lv_ext = lv_ext + 1.
        WHEN kind-turkish.
          lv_tr = lv_tr + 1.
        WHEN OTHERS.
          lv_other = lv_other + 1.
      ENDCASE.
      IF is_turkish_letter( lv_code_point ) = abap_true.
        lv_letters = lv_letters + 1.
      ENDIF.
    ENDDO.

    CASE iv_encoding.
      WHEN lif_sms=>encoding-unicode.
        rs_info-encoding = lif_sms=>encoding-unicode.
      WHEN lif_sms=>encoding-turkish.
        IF lv_other > 0.
          rs_info-message = lcl_text=>get( 'TR_UNICODE' ).
          RETURN.
        ENDIF.
        rs_info-encoding = lif_sms=>encoding-turkish.
      WHEN OTHERS.
        " AUTO, and ASCII after the conversion
        IF lv_other > 0.
          rs_info-encoding = lif_sms=>encoding-unicode.
        ELSEIF lv_letters > 0.
          rs_info-encoding = lif_sms=>encoding-turkish.
        ELSE.
          rs_info-encoding = lif_sms=>encoding-gsm.
        ENDIF.
    ENDCASE.

    CASE rs_info-encoding.
      WHEN lif_sms=>encoding-gsm.
        rs_info-units = lv_basic + 2 * lv_ext.
        lv_single = 160.
        lv_multi = 153.
        rs_info-max_units = 912.
      WHEN lif_sms=>encoding-turkish.
        rs_info-units = lv_basic + 2 * lv_ext + 2 * lv_tr.
        lv_single = 155.
        lv_multi = 148.
        rs_info-max_units = 883.
      WHEN OTHERS.
        " UTF-16 code units, an emoji counts as two
        rs_info-units = lv_len.
        lv_single = 70.
        lv_multi = 66.
        rs_info-max_units = 391.
    ENDCASE.

    lv_header = iv_header.
    TRANSLATE lv_header TO UPPER CASE.
    IF lv_header CA sy-abcde.
      rs_info-suffix = 5.
    ENDIF.

    lv_total = rs_info-units + rs_info-suffix.
    IF lv_total <= lv_single.
      rs_info-parts = 1.
    ELSE.
      rs_info-parts = lv_total DIV lv_multi.
      IF lv_total MOD lv_multi > 0.
        rs_info-parts = rs_info-parts + 1.
      ENDIF.
    ENDIF.

    IF rs_info-units > rs_info-max_units
       OR rs_info-parts > lif_sms=>max_parts.
      lv_1 = rs_info-units.
      lv_2 = rs_info-max_units.
      CONDENSE: lv_1, lv_2.
      rs_info-message = lcl_text=>get( iv_key = 'TOO_LONG'
                                       iv_1   = lv_1
                                       iv_2   = lv_2 ).
      RETURN.
    ENDIF.
    rs_info-ok = abap_true.
  ENDMETHOD.


  METHOD kind_of.
    CASE iv_code_point.
      WHEN 10 OR 13 OR 95.
        rv_kind = kind-basic.
      WHEN 12 OR 91 OR 92 OR 93 OR 94 OR 123 OR 124 OR 125 OR 126
        OR 8364.
        rv_kind = kind-extension.
      WHEN 231 OR 286 OR 287 OR 304 OR 305 OR 350 OR 351.
        rv_kind = kind-turkish.
      WHEN 161 OR 163 OR 164 OR 165 OR 167 OR 191 OR 196 OR 197
        OR 198 OR 199 OR 201 OR 209 OR 214 OR 216 OR 220 OR 223
        OR 224 OR 228 OR 229 OR 230 OR 232 OR 233 OR 236 OR 241
        OR 242 OR 246 OR 248 OR 249 OR 252
        OR 915 OR 916 OR 920 OR 923 OR 926 OR 928 OR 931 OR 934
        OR 936 OR 937.
        rv_kind = kind-basic.
      WHEN OTHERS.
        IF ( iv_code_point >= 32 AND iv_code_point <= 90 )
           OR ( iv_code_point >= 97 AND iv_code_point <= 122 ).
          rv_kind = kind-basic.
        ELSE.
          rv_kind = kind-other.
        ENDIF.
    ENDCASE.
  ENDMETHOD.


  METHOD is_turkish_letter.
    CASE iv_code_point.
      WHEN 199 OR 231 OR 286 OR 287 OR 304 OR 305 OR 214 OR 246
        OR 350 OR 351 OR 220 OR 252.
        rv_yes = abap_true.
      WHEN OTHERS.
        rv_yes = abap_false.
    ENDCASE.
  ENDMETHOD.


  METHOD to_ascii.
    rv_text = iv_text.
    replace_code_point( EXPORTING iv_code_point = 231 iv_with = 'c'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 199 iv_with = 'C'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 287 iv_with = 'g'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 286 iv_with = 'G'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 305 iv_with = 'i'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 304 iv_with = 'I'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 246 iv_with = 'o'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 214 iv_with = 'O'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 351 iv_with = 's'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 350 iv_with = 'S'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 252 iv_with = 'u'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 220 iv_with = 'U'
                        CHANGING  cv_text = rv_text ).
    " Circumflex letters in loan words
    replace_code_point( EXPORTING iv_code_point = 226 iv_with = 'a'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 194 iv_with = 'A'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 238 iv_with = 'i'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 206 iv_with = 'I'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 251 iv_with = 'u'
                        CHANGING  cv_text = rv_text ).
    replace_code_point( EXPORTING iv_code_point = 219 iv_with = 'U'
                        CHANGING  cv_text = rv_text ).
  ENDMETHOD.


  METHOD check_otp.
    DATA lv_text TYPE string.
    DATA lv_len TYPE i.
    DATA lv_pos TYPE i.
    DATA lv_char TYPE c LENGTH 1.
    DATA lv_code_point TYPE i.
    DATA lv_kind TYPE ty_kind.
    DATA lv_header TYPE string.
    DATA lv_max TYPE i.
    DATA lv_1 TYPE c LENGTH 12.
    DATA lv_2 TYPE c LENGTH 12.

    lv_text = iv_text.
    REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf
            IN lv_text WITH cl_abap_char_utilities=>newline.
    IF iv_ascii = abap_true.
      lv_text = to_ascii( lv_text ).
    ENDIF.
    rs_info-text = lv_text.
    rs_info-encoding = lif_sms=>encoding-gsm.
    rs_info-max_units = 160.
    lv_header = iv_header.
    TRANSLATE lv_header TO UPPER CASE.
    IF lv_header CA sy-abcde.
      rs_info-suffix = 5.
    ENDIF.
    lv_max = rs_info-max_units - rs_info-suffix.

    lv_len = strlen( lv_text ).
    IF lv_len = 0.
      rs_info-message = lcl_text=>get( 'NO_TEXT' ).
      RETURN.
    ENDIF.
    DO lv_len TIMES.
      lv_pos = sy-index - 1.
      lv_char = lv_text+lv_pos(1).
      TRY.
          lv_code_point = cl_abap_conv_out_ce=>uccpi( lv_char ).
        CATCH cx_root.
          lv_code_point = 65535.
      ENDTRY.
      lv_kind = kind_of( lv_code_point ).
      IF lv_kind = kind-other OR lv_kind = kind-turkish
         OR lv_code_point = 199.
        rs_info-message = lcl_text=>get( iv_key = 'OTP_CHARS'
                                         iv_1   = lv_char ).
        RETURN.
      ENDIF.
      IF lv_kind = kind-extension.
        rs_info-units = rs_info-units + 2.
      ELSE.
        rs_info-units = rs_info-units + 1.
      ENDIF.
    ENDDO.
    rs_info-parts = 1.
    IF rs_info-units > lv_max.
      lv_1 = rs_info-units.
      lv_2 = lv_max.
      CONDENSE: lv_1, lv_2.
      rs_info-message = lcl_text=>get( iv_key = 'OTP_LONG'
                                       iv_1   = lv_1
                                       iv_2   = lv_2 ).
      RETURN.
    ENDIF.
    rs_info-max_units = lv_max.
    rs_info-ok = abap_true.
  ENDMETHOD.


  METHOD replace_code_point.
    DATA lv_char TYPE c LENGTH 1.

    lv_char = cl_abap_conv_in_ce=>uccpi( iv_code_point ).
    REPLACE ALL OCCURRENCES OF lv_char IN cv_text WITH iv_with.
  ENDMETHOD.

ENDCLASS.


*----------------------------------------------------------------------*
* Minimal JSON. Writing: escape string values. Reading: the answer
* becomes a flat list of path = value, for example
*   code = 00, jobs/1/jobid = 123, jobs/1/status = 1
* Release 7.00 has no JSON parser of its own (/UI2/CL_JSON is later).
*----------------------------------------------------------------------*
CLASS lcl_sms_json DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES:
      BEGIN OF ty_value,
        path  TYPE string,
        value TYPE string,
      END OF ty_value,
      ty_values TYPE STANDARD TABLE OF ty_value WITH DEFAULT KEY.

    CLASS-METHODS escape
      IMPORTING
        iv_text        TYPE csequence
      RETURNING
        value(rv_json) TYPE string.

    CLASS-METHODS parse
      IMPORTING
        iv_json          TYPE string
      RETURNING
        value(rt_values) TYPE ty_values
      RAISING
        lcx_sms.

    CLASS-METHODS value_of
      IMPORTING
        it_values       TYPE ty_values
        iv_path         TYPE csequence
      RETURNING
        value(rv_value) TYPE string.

    CLASS-METHODS has
      IMPORTING
        it_values     TYPE ty_values
        iv_path       TYPE csequence
      RETURNING
        value(rv_yes) TYPE abap_bool.

  PRIVATE SECTION.
    DATA mv_json TYPE string.
    DATA mv_len TYPE i.
    DATA mv_pos TYPE i.
    DATA mt_values TYPE ty_values.

    METHODS read_value
      IMPORTING
        iv_path TYPE string
      RAISING
        lcx_sms.

    METHODS read_object
      IMPORTING
        iv_path TYPE string
      RAISING
        lcx_sms.

    METHODS read_array
      IMPORTING
        iv_path TYPE string
      RAISING
        lcx_sms.

    METHODS read_string
      RETURNING
        value(rv_value) TYPE string
      RAISING
        lcx_sms.

    METHODS read_literal
      RETURNING
        value(rv_value) TYPE string.

    METHODS skip_blanks.

    METHODS current
      RETURNING
        value(rv_char) TYPE string.

    METHODS add
      IMPORTING
        iv_path  TYPE string
        iv_value TYPE string.

    METHODS fail
      IMPORTING
        iv_what TYPE string
      RAISING
        lcx_sms.

    CLASS-METHODS unescape
      IMPORTING
        iv_raw          TYPE string
      RETURNING
        value(rv_value) TYPE string.

    CLASS-METHODS child_path
      IMPORTING
        iv_path        TYPE string
        iv_name        TYPE csequence
      RETURNING
        value(rv_path) TYPE string.
ENDCLASS.


CLASS lcl_sms_json IMPLEMENTATION.

  METHOD escape.
    DATA lv_char TYPE c LENGTH 1.

    rv_json = iv_text.
    REPLACE ALL OCCURRENCES OF `\` IN rv_json WITH `\\`.
    REPLACE ALL OCCURRENCES OF `"` IN rv_json WITH `\"`.
    lv_char = cl_abap_char_utilities=>newline.
    REPLACE ALL OCCURRENCES OF lv_char IN rv_json WITH `\n`.
    lv_char = cl_abap_char_utilities=>cr_lf(1).
    REPLACE ALL OCCURRENCES OF lv_char IN rv_json WITH `\r`.
    lv_char = cl_abap_char_utilities=>horizontal_tab.
    REPLACE ALL OCCURRENCES OF lv_char IN rv_json WITH `\t`.
  ENDMETHOD.


  METHOD parse.
    DATA lo_parser TYPE REF TO lcl_sms_json.

    CREATE OBJECT lo_parser.
    lo_parser->mv_json = iv_json.
    lo_parser->mv_len = strlen( iv_json ).
    lo_parser->read_value( `` ).
    lo_parser->skip_blanks( ).
    IF lo_parser->mv_pos < lo_parser->mv_len.
      lo_parser->fail( `text after the end` ).
    ENDIF.
    rt_values = lo_parser->mt_values.
  ENDMETHOD.


  METHOD value_of.
    DATA ls_value TYPE ty_value.

    READ TABLE it_values INTO ls_value WITH KEY path = iv_path.
    IF sy-subrc = 0.
      rv_value = ls_value-value.
    ENDIF.
  ENDMETHOD.


  METHOD has.
    READ TABLE it_values TRANSPORTING NO FIELDS
         WITH KEY path = iv_path.
    IF sy-subrc = 0.
      rv_yes = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD read_value.
    DATA lv_char TYPE string.
    DATA lv_value TYPE string.

    skip_blanks( ).
    lv_char = current( ).
    CASE lv_char.
      WHEN `{`.
        read_object( iv_path ).
      WHEN `[`.
        read_array( iv_path ).
      WHEN `"`.
        lv_value = read_string( ).
        add( iv_path = iv_path iv_value = lv_value ).
      WHEN ``.
        fail( `unexpected end` ).
      WHEN OTHERS.
        lv_value = read_literal( ).
        IF lv_value IS INITIAL.
          fail( `unexpected character` ).
        ENDIF.
        IF lv_value = `null`.
          CLEAR lv_value.
        ENDIF.
        add( iv_path = iv_path iv_value = lv_value ).
    ENDCASE.
  ENDMETHOD.


  METHOD read_object.
    DATA lv_name TYPE string.
    DATA lv_char TYPE string.
    DATA lv_path TYPE string.

    mv_pos = mv_pos + 1.
    skip_blanks( ).
    IF current( ) = `}`.
      mv_pos = mv_pos + 1.
      RETURN.
    ENDIF.
    DO.
      skip_blanks( ).
      IF current( ) <> `"`.
        fail( `name expected` ).
      ENDIF.
      lv_name = read_string( ).
      skip_blanks( ).
      IF current( ) <> `:`.
        fail( `colon expected` ).
      ENDIF.
      mv_pos = mv_pos + 1.
      lv_path = child_path( iv_path = iv_path iv_name = lv_name ).
      read_value( lv_path ).
      skip_blanks( ).
      lv_char = current( ).
      mv_pos = mv_pos + 1.
      IF lv_char = `}`.
        EXIT.
      ELSEIF lv_char <> `,`.
        fail( `comma or } expected` ).
      ENDIF.
    ENDDO.
  ENDMETHOD.


  METHOD read_array.
    DATA lv_index TYPE i.
    DATA lv_name TYPE c LENGTH 11.
    DATA lv_char TYPE string.
    DATA lv_path TYPE string.

    mv_pos = mv_pos + 1.
    skip_blanks( ).
    IF current( ) = `]`.
      mv_pos = mv_pos + 1.
      RETURN.
    ENDIF.
    DO.
      lv_index = lv_index + 1.
      lv_name = lv_index.
      CONDENSE lv_name.
      lv_path = child_path( iv_path = iv_path iv_name = lv_name ).
      read_value( lv_path ).
      skip_blanks( ).
      lv_char = current( ).
      mv_pos = mv_pos + 1.
      IF lv_char = `]`.
        EXIT.
      ELSEIF lv_char <> `,`.
        fail( `comma or ] expected` ).
      ENDIF.
    ENDDO.
  ENDMETHOD.


  METHOD read_string.
    DATA lv_start TYPE i.
    DATA lv_from TYPE i.
    DATA lv_quote TYPE i.
    DATA lv_back TYPE i.
    DATA lv_count TYPE i.
    DATA lv_len TYPE i.
    DATA lv_raw TYPE string.

    lv_start = mv_pos + 1.
    lv_from = lv_start.
    DO.
      IF lv_from >= mv_len.
        fail( `string not closed` ).
      ENDIF.
      FIND `"` IN SECTION OFFSET lv_from OF mv_json
           MATCH OFFSET lv_quote.
      IF sy-subrc <> 0.
        fail( `string not closed` ).
      ENDIF.
      " An odd number of backslashes before it escapes the quote
      lv_count = 0.
      lv_back = lv_quote - 1.
      WHILE lv_back >= lv_start AND mv_json+lv_back(1) = `\`.
        lv_count = lv_count + 1.
        lv_back = lv_back - 1.
      ENDWHILE.
      IF lv_count MOD 2 = 0.
        EXIT.
      ENDIF.
      lv_from = lv_quote + 1.
    ENDDO.
    lv_len = lv_quote - lv_start.
    IF lv_len > 0.
      lv_raw = mv_json+lv_start(lv_len).
    ENDIF.
    rv_value = unescape( lv_raw ).
    mv_pos = lv_quote + 1.
  ENDMETHOD.


  METHOD read_literal.
    " A number, true, false or null; anything else is an error
    DATA lv_end TYPE i.
    DATA lv_len TYPE i.
    DATA lv_char TYPE c LENGTH 1.

    lv_end = mv_pos.
    WHILE lv_end < mv_len.
      lv_char = mv_json+lv_end(1).
      IF lv_char CA ',}]'
         OR lv_char = ' '
         OR lv_char = cl_abap_char_utilities=>newline
         OR lv_char = cl_abap_char_utilities=>cr_lf(1)
         OR lv_char = cl_abap_char_utilities=>horizontal_tab.
        EXIT.
      ENDIF.
      lv_end = lv_end + 1.
    ENDWHILE.
    lv_len = lv_end - mv_pos.
    IF lv_len > 0.
      rv_value = mv_json+mv_pos(lv_len).
    ENDIF.
    IF rv_value <> `true` AND rv_value <> `false`
       AND rv_value <> `null` AND NOT rv_value CO '0123456789+-.eE'.
      CLEAR rv_value.
      RETURN.
    ENDIF.
    mv_pos = lv_end.
  ENDMETHOD.


  METHOD skip_blanks.
    DATA lv_char TYPE c LENGTH 1.

    WHILE mv_pos < mv_len.
      lv_char = mv_json+mv_pos(1).
      IF lv_char = ' '
         OR lv_char = cl_abap_char_utilities=>newline
         OR lv_char = cl_abap_char_utilities=>cr_lf(1)
         OR lv_char = cl_abap_char_utilities=>horizontal_tab.
        mv_pos = mv_pos + 1.
      ELSE.
        EXIT.
      ENDIF.
    ENDWHILE.
  ENDMETHOD.


  METHOD current.
    IF mv_pos < mv_len.
      rv_char = mv_json+mv_pos(1).
    ENDIF.
  ENDMETHOD.


  METHOD add.
    DATA ls_value TYPE ty_value.

    ls_value-path = iv_path.
    ls_value-value = iv_value.
    APPEND ls_value TO mt_values.
  ENDMETHOD.


  METHOD fail.
    DATA lv_text TYPE string.
    DATA lv_pos TYPE c LENGTH 11.

    lv_pos = mv_pos.
    CONDENSE lv_pos.
    CONCATENATE iv_what ` at position ` lv_pos INTO lv_text.
    RAISE EXCEPTION TYPE lcx_sms
      EXPORTING
        code = lif_sms=>code-bad_reply
        text = lv_text.
  ENDMETHOD.


  METHOD unescape.
    DATA lv_mark TYPE c LENGTH 1.
    DATA lv_char TYPE c LENGTH 1.
    DATA lv_off TYPE i.
    DATA lv_hex_off TYPE i.
    DATA lv_rest TYPE i.
    DATA lv_hex TYPE c LENGTH 4.
    DATA lv_x TYPE x LENGTH 2.
    DATA lv_code_point TYPE i.

    rv_value = iv_raw.
    FIND `\` IN rv_value.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    " Keep escaped backslashes out of the way first
    lv_mark = cl_abap_conv_in_ce=>uccpi( 1 ).
    REPLACE ALL OCCURRENCES OF `\\` IN rv_value WITH lv_mark.
    REPLACE ALL OCCURRENCES OF `\"` IN rv_value WITH `"`.
    REPLACE ALL OCCURRENCES OF `\/` IN rv_value WITH `/`.
    lv_char = cl_abap_char_utilities=>newline.
    REPLACE ALL OCCURRENCES OF `\n` IN rv_value WITH lv_char.
    lv_char = cl_abap_char_utilities=>cr_lf(1).
    REPLACE ALL OCCURRENCES OF `\r` IN rv_value WITH lv_char.
    lv_char = cl_abap_char_utilities=>horizontal_tab.
    REPLACE ALL OCCURRENCES OF `\t` IN rv_value WITH lv_char.
    REPLACE ALL OCCURRENCES OF `\b` IN rv_value WITH ``.
    REPLACE ALL OCCURRENCES OF `\f` IN rv_value WITH ``.
    DO.
      FIND `\u` IN rv_value MATCH OFFSET lv_off.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.
      lv_hex_off = lv_off + 2.
      lv_rest = strlen( rv_value ) - lv_hex_off.
      IF lv_rest < 4.
        REPLACE SECTION OFFSET lv_off LENGTH 2 OF rv_value WITH `?`.
        CONTINUE.
      ENDIF.
      lv_hex = rv_value+lv_hex_off(4).
      TRANSLATE lv_hex TO UPPER CASE.
      lv_char = '?'.
      IF lv_hex CO '0123456789ABCDEF'.
        lv_x = lv_hex.
        lv_code_point = lv_x.
        TRY.
            lv_char = cl_abap_conv_in_ce=>uccpi( lv_code_point ).
          CATCH cx_root.
            lv_char = '?'.
        ENDTRY.
      ENDIF.
      IF lv_char = ' '.
        REPLACE SECTION OFFSET lv_off LENGTH 6 OF rv_value WITH ` `.
      ELSE.
        REPLACE SECTION OFFSET lv_off LENGTH 6 OF rv_value
                WITH lv_char.
      ENDIF.
    ENDDO.
    REPLACE ALL OCCURRENCES OF lv_mark IN rv_value WITH `\`.
  ENDMETHOD.


  METHOD child_path.
    IF iv_path IS INITIAL.
      rv_path = iv_name.
    ELSE.
      CONCATENATE iv_path `/` iv_name INTO rv_path.
    ENDIF.
  ENDMETHOD.

ENDCLASS.


*----------------------------------------------------------------------*
* What the program needs from the system: authorization, the SM59
* destination and HTTP. The unit tests replace it with a double, so
* they never reach Netgsm.
*----------------------------------------------------------------------*
INTERFACE lif_sms_backend.
  METHODS has_authority
    IMPORTING
      iv_destination TYPE rfcdest
    RETURNING
      value(rv_yes)  TYPE abap_bool.

  "! Type of the SM59 destination, initial when it does not exist
  METHODS destination_type
    IMPORTING
      iv_destination TYPE rfcdest
    RETURNING
      value(rv_type) TYPE rfcdes-rfctype.

  "! Raises lcx_sms only when no answer came back
  METHODS call
    IMPORTING
      iv_destination TYPE rfcdest
      iv_method      TYPE string
      iv_path        TYPE string
      iv_body        TYPE string OPTIONAL
    RETURNING
      value(rs_http) TYPE lif_sms=>ty_http
    RAISING
      lcx_sms.
ENDINTERFACE.


CLASS lcl_sms_backend DEFINITION FINAL.
  PUBLIC SECTION.
    INTERFACES lif_sms_backend.
ENDCLASS.


CLASS lcl_sms_backend IMPLEMENTATION.

  METHOD lif_sms_backend~has_authority.
    AUTHORITY-CHECK OBJECT 'S_ICF'
      ID 'ICF_FIELD' FIELD 'DEST'
      ID 'ICF_VALUE' FIELD iv_destination.
    IF sy-subrc = 0.
      rv_yes = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD lif_sms_backend~destination_type.
    SELECT SINGLE rfctype FROM rfcdes INTO rv_type
           WHERE rfcdest = iv_destination.
    IF sy-subrc <> 0.
      CLEAR rv_type.
    ENDIF.
  ENDMETHOD.


  METHOD lif_sms_backend~call.
    DATA lo_client TYPE REF TO if_http_client.
    DATA lo_out TYPE REF TO cl_abap_conv_out_ce.
    DATA lo_in TYPE REF TO cl_abap_conv_in_ce.
    DATA lv_data TYPE xstring.
    DATA lv_code TYPE i.
    DATA lv_message TYPE string.
    DATA lv_rest TYPE string.
    DATA lv_text TYPE string.

    cl_http_client=>create_by_destination(
      EXPORTING
        destination              = iv_destination
      IMPORTING
        client                   = lo_client
      EXCEPTIONS
        argument_not_found       = 1
        destination_not_found    = 2
        destination_no_authority = 3
        plugin_not_active        = 4
        internal_error           = 5
        OTHERS                   = 6 ).
    IF sy-subrc = 3.
      lv_text = lcl_text=>get( iv_key = 'NO_AUTH'
                               iv_1   = iv_destination ).
      RAISE EXCEPTION TYPE lcx_sms
        EXPORTING
          code = lif_sms=>code-no_auth
          text = lv_text.
    ELSEIF sy-subrc <> 0.
      lv_text = lcl_text=>get( iv_key = 'NO_DEST'
                               iv_1   = iv_destination ).
      RAISE EXCEPTION TYPE lcx_sms
        EXPORTING
          code = lif_sms=>code-no_dest
          text = lv_text.
    ENDIF.

    " A job has no one to answer a logon popup
    lo_client->propertytype_logon_popup = if_http_client=>co_disabled.
    lo_client->propertytype_accept_cookie =
      if_http_client=>co_disabled.
    lo_client->request->set_method( iv_method ).
    cl_http_utility=>set_request_uri( request = lo_client->request
                                      uri     = iv_path ).
    lo_client->request->set_header_field( name  = 'Accept'
                                          value = 'application/json' ).
    IF iv_body IS NOT INITIAL.
      lo_out = cl_abap_conv_out_ce=>create( encoding = 'UTF-8' ).
      lo_out->convert( EXPORTING data   = iv_body
                       IMPORTING buffer = lv_data ).
      lo_client->request->set_header_field(
        name  = 'Content-Type'
        value = 'application/json; charset=utf-8' ).
      lo_client->request->set_data( lv_data ).
    ENDIF.

    lo_client->send(
      EXCEPTIONS
        http_communication_failure = 1
        http_invalid_state         = 2
        http_processing_failed     = 3
        http_invalid_timeout       = 4
        OTHERS                     = 5 ).
    IF sy-subrc = 0.
      lo_client->receive(
        EXCEPTIONS
          http_communication_failure = 1
          http_invalid_state         = 2
          http_processing_failed     = 3
          OTHERS                     = 4 ).
    ENDIF.
    IF sy-subrc <> 0.
      lo_client->get_last_error( IMPORTING message = lv_message ).
      lo_client->close( ).
      IF lv_message CS 'PEER_CERT_UNTRUSTED'.
        " The handshake failed, so no request went out
        lv_text = lcl_text=>get( 'NO_TRUST' ).
        RAISE EXCEPTION TYPE lcx_sms
          EXPORTING
            code = lif_sms=>code-no_trust
            text = lv_text.
      ENDIF.
      " First line only; the details are in the ICM trace (SMICM)
      SPLIT lv_message AT cl_abap_char_utilities=>newline
            INTO lv_message lv_rest.
      lv_text = lcl_text=>get( iv_key = 'NO_CONN'
                               iv_1   = lv_message ).
      RAISE EXCEPTION TYPE lcx_sms
        EXPORTING
          code = lif_sms=>code-no_conn
          text = lv_text.
    ENDIF.

    lo_client->response->get_status(
      IMPORTING
        code   = lv_code
        reason = rs_http-reason ).
    rs_http-status = lv_code.
    lv_data = lo_client->response->get_data( ).
    lo_client->close( ).
    IF lv_data IS NOT INITIAL.
      TRY.
          lo_in = cl_abap_conv_in_ce=>create( encoding = 'UTF-8'
                                              input    = lv_data ).
          lo_in->read( IMPORTING data = rs_http-body ).
        CATCH cx_root.
          rs_http-body = `(not UTF-8)`.
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
CLASS lcl_sms_netgsm DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS constructor
      IMPORTING
        iv_destination     TYPE rfcdest
                           DEFAULT lif_sms=>default_destination
        iv_ext_destination TYPE rfcdest
                           DEFAULT lif_sms=>default_ext_destination
        io_backend         TYPE REF TO lif_sms_backend OPTIONAL.

    "! SMS to one or more numbers, now or at a later time
    METHODS send
      IMPORTING
        it_numbers       TYPE string_table
        iv_text          TYPE csequence
        iv_header        TYPE csequence
        iv_encoding      TYPE lif_sms=>ty_encoding
                         DEFAULT lif_sms=>encoding-auto
        iv_iys           TYPE lif_sms=>ty_iys DEFAULT lif_sms=>iys-info
        is_schedule      TYPE lif_sms=>ty_schedule OPTIONAL
        iv_reference     TYPE csequence OPTIONAL
        iv_dry_run       TYPE abap_bool DEFAULT abap_true
      RETURNING
        value(rs_result) TYPE lif_sms=>ty_result.

    "! OTP SMS: one number, one part, no Turkish letters
    METHODS send_otp
      IMPORTING
        it_numbers       TYPE string_table
        iv_text          TYPE csequence
        iv_header        TYPE csequence
        iv_ascii         TYPE abap_bool DEFAULT abap_false
        iv_dry_run       TYPE abap_bool DEFAULT abap_true
      RETURNING
        value(rs_result) TYPE lif_sms=>ty_result.

    "! Template SMS: a template approved at Netgsm, with values
    METHODS send_template
      IMPORTING
        it_numbers       TYPE string_table
        iv_template_id   TYPE i
        it_params        TYPE lif_sms=>ty_params
        iv_header        TYPE csequence
        iv_encoding      TYPE lif_sms=>ty_encoding
                         DEFAULT lif_sms=>encoding-auto
        iv_iys           TYPE lif_sms=>ty_iys DEFAULT lif_sms=>iys-info
        is_schedule      TYPE lif_sms=>ty_schedule OPTIONAL
        iv_reference     TYPE csequence OPTIONAL
        iv_dry_run       TYPE abap_bool DEFAULT abap_true
      RETURNING
        value(rs_result) TYPE lif_sms=>ty_result.

    "! Cancels a scheduled SMS
    METHODS cancel
      IMPORTING
        iv_jobid         TYPE csequence
      RETURNING
        value(rs_answer) TYPE lif_sms=>ty_answer.

    "! Delivery report by job IDs, a date range, or both
    METHODS report
      IMPORTING
        it_jobids        TYPE string_table OPTIONAL
        iv_from          TYPE d OPTIONAL
        iv_to            TYPE d OPTIONAL
        iv_page          TYPE i OPTIONAL
        iv_page_size     TYPE i OPTIONAL
      RETURNING
        value(rs_report) TYPE lif_sms=>ty_report.

    "! Totals of one job: status, parts, credits
    METHODS stats
      IMPORTING
        iv_jobid        TYPE csequence
        iv_send_date    TYPE d OPTIONAL
      RETURNING
        value(rs_stats) TYPE lif_sms=>ty_stats.

    "! SMS sent to your Netgsm number. Without dates Netgsm returns
    "! only the ones not listed before, and marks them as listed.
    METHODS inbox
      IMPORTING
        iv_from         TYPE d OPTIONAL
        iv_to           TYPE d OPTIONAL
        iv_full_numbers TYPE abap_bool DEFAULT abap_false
      RETURNING
        value(rs_inbox) TYPE lif_sms=>ty_inbox.

    METHODS headers
      RETURNING
        value(rs_headers) TYPE lif_sms=>ty_headers.

    METHODS templates
      IMPORTING
        iv_page             TYPE i DEFAULT 0
        iv_size             TYPE i DEFAULT 50
        iv_public           TYPE abap_bool DEFAULT abap_true
        iv_search           TYPE csequence OPTIONAL
        iv_type             TYPE csequence OPTIONAL
        iv_content          TYPE csequence OPTIONAL
      RETURNING
        value(rs_templates) TYPE lif_sms=>ty_templates.

    "! Netgsm's own count of parts and characters (free)
    METHODS length
      IMPORTING
        iv_text          TYPE csequence
        iv_encoding      TYPE lif_sms=>ty_encoding
                         DEFAULT lif_sms=>encoding-auto
        iv_header        TYPE csequence OPTIONAL
      RETURNING
        value(rs_length) TYPE lif_sms=>ty_length.

    "! Text for a Netgsm code; the same code means different
    "! things in different services
    CLASS-METHODS code_text
      IMPORTING
        iv_action      TYPE lif_sms=>ty_action
        iv_code        TYPE csequence
        iv_description TYPE csequence OPTIONAL
      RETURNING
        value(rv_text) TYPE string.

    "! Date and time in one of Netgsm's formats:
    "! DMYHM ddMMyyyyHHmm, ISO_M yyyy-MM-dd HH:mm,
    "! DOT_S dd.MM.yyyy HH:mm:ss, ISO_S yyyy-MM-dd HH:mm:ss
    CLASS-METHODS format_time
      IMPORTING
        iv_date        TYPE d
        iv_time        TYPE t
        iv_style       TYPE c
      RETURNING
        value(rv_text) TYPE string.

    "! Milliseconds since 1970 (UTC) as Turkish time dd.MM.yyyy ...
    CLASS-METHODS turkish_time
      IMPORTING
        iv_millis      TYPE csequence
      RETURNING
        value(rv_text) TYPE string.

    "! Percent-encoding for a URL query value (UTF-8)
    CLASS-METHODS url_encode
      IMPORTING
        iv_text        TYPE csequence
      RETURNING
        value(rv_text) TYPE string.

  PRIVATE SECTION.
    DATA mv_destination TYPE rfcdest.
    DATA mv_ext_destination TYPE rfcdest.
    DATA mo_backend TYPE REF TO lif_sms_backend.

    "! Checks access, calls Netgsm, reads the answer. Never raises.
    METHODS call_netgsm
      IMPORTING
        iv_action      TYPE lif_sms=>ty_action
        iv_destination TYPE rfcdest
        iv_method      TYPE string
        iv_path        TYPE string
        iv_body        TYPE string OPTIONAL
      EXPORTING
        ev_code        TYPE string
        ev_message     TYPE string
        et_values      TYPE lcl_sms_json=>ty_values
        ev_status      TYPE i.

    "! Destination exists, has type G, and the user may use it
    METHODS check_access
      IMPORTING
        iv_destination TYPE rfcdest
      EXPORTING
        ev_code        TYPE string
        ev_message     TYPE string.

    "! Reads code, description and values; plain codes too
    METHODS read_answer
      IMPORTING
        is_http        TYPE lif_sms=>ty_http
      EXPORTING
        ev_code        TYPE string
        ev_description TYPE string
        et_values      TYPE lcl_sms_json=>ty_values
      RAISING
        lcx_sms.

    "! The checks shared by all sends; they set cs_result-code
    "! when something is wrong
    METHODS check_numbers
      IMPORTING
        it_numbers TYPE string_table
        iv_max     TYPE i
      CHANGING
        cs_result  TYPE lif_sms=>ty_result.

    METHODS check_header
      CHANGING
        cs_result TYPE lif_sms=>ty_result.

    METHODS check_iys
      CHANGING
        cs_result TYPE lif_sms=>ty_result.

    METHODS check_schedule
      CHANGING
        cs_result TYPE lif_sms=>ty_result.

    METHODS check_range
      IMPORTING
        iv_from    TYPE d
        iv_to      TYPE d
        iv_days    TYPE i
      EXPORTING
        ev_code    TYPE string
        ev_message TYPE string.

    "! Sends a prepared body, or stops at the preview
    METHODS finish_send
      IMPORTING
        iv_destination TYPE rfcdest
        iv_path        TYPE string
        iv_body        TYPE string
        iv_dry_run     TYPE abap_bool
      CHANGING
        cs_result      TYPE lif_sms=>ty_result.

    METHODS send_body
      IMPORTING
        is_result      TYPE lif_sms=>ty_result
        iv_masked      TYPE abap_bool
      RETURNING
        value(rv_json) TYPE string.

    METHODS otp_body
      IMPORTING
        is_result      TYPE lif_sms=>ty_result
        iv_masked      TYPE abap_bool
      RETURNING
        value(rv_json) TYPE string.

    METHODS template_body
      IMPORTING
        is_result      TYPE lif_sms=>ty_result
        it_params      TYPE lif_sms=>ty_params
        iv_ascii       TYPE abap_bool
        iv_masked      TYPE abap_bool
      RETURNING
        value(rv_json) TYPE string.

    "! ,"startdate":"...","stopdate":"..." or nothing
    CLASS-METHODS schedule_json
      IMPORTING
        is_schedule    TYPE lif_sms=>ty_schedule
        iv_style       TYPE c
      RETURNING
        value(rv_json) TYPE string.

    CLASS-METHODS reference_json
      IMPORTING
        iv_reference   TYPE string
      RETURNING
        value(rv_json) TYPE string.

    CLASS-METHODS row_path
      IMPORTING
        iv_list        TYPE csequence
        iv_row         TYPE i
        iv_field       TYPE csequence
      RETURNING
        value(rv_path) TYPE string.

    CLASS-METHODS int_text
      IMPORTING
        iv_value       TYPE i
      RETURNING
        value(rv_text) TYPE string.

    CLASS-METHODS status_text
      IMPORTING
        iv_status      TYPE csequence
      RETURNING
        value(rv_text) TYPE string.

    CLASS-METHODS stats_text
      IMPORTING
        iv_status      TYPE csequence
      RETURNING
        value(rv_text) TYPE string.

    CLASS-METHODS error_text
      IMPORTING
        iv_error       TYPE csequence
      RETURNING
        value(rv_text) TYPE string.

    CLASS-METHODS operator_name
      IMPORTING
        iv_operator    TYPE csequence
      RETURNING
        value(rv_name) TYPE string.
ENDCLASS.


CLASS lcl_sms_netgsm IMPLEMENTATION.

  METHOD constructor.
    mv_destination = iv_destination.
    mv_ext_destination = iv_ext_destination.
    IF io_backend IS BOUND.
      mo_backend = io_backend.
    ELSE.
      CREATE OBJECT mo_backend TYPE lcl_sms_backend.
    ENDIF.
  ENDMETHOD.


  METHOD send.
    DATA lv_body TYPE string.
    DATA lv_path TYPE string.

    rs_result-action = lif_sms=>action-send.
    rs_result-header = iv_header.
    rs_result-iys = iv_iys.
    rs_result-schedule = is_schedule.
    rs_result-reference = iv_reference.

    check_numbers( EXPORTING it_numbers = it_numbers
                             iv_max     = lif_sms=>max_recipients
                   CHANGING  cs_result  = rs_result ).
    IF rs_result-code IS INITIAL.
      check_header( CHANGING cs_result = rs_result ).
    ENDIF.
    IF rs_result-code IS INITIAL.
      check_iys( CHANGING cs_result = rs_result ).
    ENDIF.
    IF rs_result-code IS INITIAL.
      check_schedule( CHANGING cs_result = rs_result ).
    ENDIF.
    IF rs_result-code IS NOT INITIAL.
      RETURN.
    ENDIF.

    rs_result-text_info = lcl_sms_text=>analyze(
                            iv_text     = iv_text
                            iv_encoding = iv_encoding
                            iv_header   = rs_result-header ).
    IF rs_result-text_info-ok = abap_false.
      rs_result-code = lif_sms=>code-bad_text.
      rs_result-message = rs_result-text_info-message.
      RETURN.
    ENDIF.

    rs_result-request = send_body( is_result = rs_result
                                   iv_masked = abap_true ).
    lv_body = send_body( is_result = rs_result
                         iv_masked = abap_false ).
    CONCATENATE lif_sms=>api_path `/send` INTO lv_path.
    finish_send( EXPORTING iv_destination = mv_destination
                           iv_path        = lv_path
                           iv_body        = lv_body
                           iv_dry_run     = iv_dry_run
                 CHANGING  cs_result      = rs_result ).
  ENDMETHOD.


  METHOD send_otp.
    DATA lv_body TYPE string.
    DATA lv_path TYPE string.

    rs_result-action = lif_sms=>action-otp.
    rs_result-header = iv_header.
    rs_result-iys = lif_sms=>iys-info.

    check_numbers( EXPORTING it_numbers = it_numbers
                             iv_max     = 1
                   CHANGING  cs_result  = rs_result ).
    IF rs_result-code IS INITIAL.
      check_header( CHANGING cs_result = rs_result ).
    ENDIF.
    IF rs_result-code IS NOT INITIAL.
      RETURN.
    ENDIF.

    rs_result-text_info = lcl_sms_text=>check_otp(
                            iv_text   = iv_text
                            iv_header = rs_result-header
                            iv_ascii  = iv_ascii ).
    IF rs_result-text_info-ok = abap_false.
      rs_result-code = lif_sms=>code-bad_text.
      rs_result-message = rs_result-text_info-message.
      RETURN.
    ENDIF.

    rs_result-request = otp_body( is_result = rs_result
                                  iv_masked = abap_true ).
    lv_body = otp_body( is_result = rs_result
                        iv_masked = abap_false ).
    CONCATENATE lif_sms=>api_path `/otp` INTO lv_path.
    finish_send( EXPORTING iv_destination = mv_destination
                           iv_path        = lv_path
                           iv_body        = lv_body
                           iv_dry_run     = iv_dry_run
                 CHANGING  cs_result      = rs_result ).
  ENDMETHOD.


  METHOD send_template.
    DATA lv_body TYPE string.
    DATA lv_path TYPE string.
    DATA lv_ascii TYPE abap_bool.
    DATA ls_param TYPE lif_sms=>ty_param.

    rs_result-action = lif_sms=>action-template.
    rs_result-header = iv_header.
    rs_result-iys = iv_iys.
    rs_result-schedule = is_schedule.
    rs_result-reference = iv_reference.
    rs_result-template_id = iv_template_id.

    check_numbers( EXPORTING it_numbers = it_numbers
                             iv_max     = lif_sms=>max_recipients
                   CHANGING  cs_result  = rs_result ).
    IF rs_result-code IS INITIAL.
      check_header( CHANGING cs_result = rs_result ).
    ENDIF.
    IF rs_result-code IS INITIAL.
      check_iys( CHANGING cs_result = rs_result ).
    ENDIF.
    IF rs_result-code IS INITIAL.
      check_schedule( CHANGING cs_result = rs_result ).
    ENDIF.
    IF rs_result-code IS NOT INITIAL.
      RETURN.
    ENDIF.
    IF iv_template_id <= 0.
      rs_result-code = lif_sms=>code-bad_input.
      rs_result-message = lcl_text=>get( 'NO_TEMPLATE' ).
      RETURN.
    ENDIF.
    LOOP AT it_params INTO ls_param WHERE name IS INITIAL.
      rs_result-code = lif_sms=>code-bad_input.
      rs_result-message = lcl_text=>get( iv_key = 'BAD_PARAM'
                                         iv_1   = ls_param-value ).
      RETURN.
    ENDLOOP.

    " The template text is at Netgsm, so the program cannot see
    " which characters it has: AUTO means Turkish, to be safe
    CASE iv_encoding.
      WHEN lif_sms=>encoding-auto OR lif_sms=>encoding-turkish.
        rs_result-text_info-encoding = lif_sms=>encoding-turkish.
      WHEN lif_sms=>encoding-unicode.
        rs_result-text_info-encoding = lif_sms=>encoding-unicode.
      WHEN lif_sms=>encoding-ascii.
        rs_result-text_info-encoding = lif_sms=>encoding-gsm.
        lv_ascii = abap_true.
      WHEN OTHERS.
        rs_result-code = lif_sms=>code-bad_input.
        rs_result-message = lcl_text=>get( iv_key = 'BAD_ENC'
                                           iv_1   = iv_encoding ).
        RETURN.
    ENDCASE.

    rs_result-request = template_body( is_result = rs_result
                                       it_params = it_params
                                       iv_ascii  = lv_ascii
                                       iv_masked = abap_true ).
    lv_body = template_body( is_result = rs_result
                             it_params = it_params
                             iv_ascii  = lv_ascii
                             iv_masked = abap_false ).
    CONCATENATE lif_sms=>api_path `/template/send` INTO lv_path.
    finish_send( EXPORTING iv_destination = mv_ext_destination
                           iv_path        = lv_path
                           iv_body        = lv_body
                           iv_dry_run     = iv_dry_run
                 CHANGING  cs_result      = rs_result ).
  ENDMETHOD.


  METHOD cancel.
    DATA lv_body TYPE string.
    DATA lv_path TYPE string.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA lv_status TYPE i.

    rs_answer-jobid = iv_jobid.
    CONDENSE rs_answer-jobid NO-GAPS.
    IF rs_answer-jobid IS INITIAL.
      rs_answer-code = lif_sms=>code-bad_input.
      rs_answer-message = lcl_text=>get( 'NO_JOB' ).
      RETURN.
    ENDIF.
    lv_body = lcl_sms_json=>escape( rs_answer-jobid ).
    CONCATENATE `{"jobid":"` lv_body `"}` INTO lv_body.
    CONCATENATE lif_sms=>api_path `/cancel` INTO lv_path.
    call_netgsm( EXPORTING iv_action      = lif_sms=>action-cancel
                           iv_destination = mv_destination
                           iv_method      = `POST`
                           iv_path        = lv_path
                           iv_body        = lv_body
                 IMPORTING ev_code        = rs_answer-code
                           ev_message     = rs_answer-message
                           et_values      = lt_values
                           ev_status      = lv_status ).
  ENDMETHOD.


  METHOD report.
    DATA lv_jobid TYPE string.
    DATA lv_jobs TYPE string.
    DATA lv_body TYPE string.
    DATA lv_path TYPE string.
    DATA lv_text TYPE string.
    DATA lv_count TYPE i.
    DATA lv_row TYPE i.
    DATA lv_status TYPE i.
    DATA lv_value TYPE string.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA ls_line TYPE lif_sms=>ty_report_line.

    LOOP AT it_jobids INTO lv_jobid.
      CONDENSE lv_jobid NO-GAPS.
      IF lv_jobid IS INITIAL.
        CONTINUE.
      ENDIF.
      lv_count = lv_count + 1.
      lv_jobid = lcl_sms_json=>escape( lv_jobid ).
      IF lv_count = 1.
        CONCATENATE `"jobids":["` lv_jobid `"` INTO lv_jobs.
      ELSE.
        CONCATENATE lv_jobs `,"` lv_jobid `"` INTO lv_jobs.
      ENDIF.
    ENDLOOP.
    IF lv_count > lif_sms=>max_jobids.
      lv_text = int_text( lif_sms=>max_jobids ).
      rs_report-code = lif_sms=>code-bad_input.
      rs_report-message = lcl_text=>get( iv_key = 'TOO_MANY_JOBS'
                                         iv_1   = lv_text ).
      RETURN.
    ENDIF.
    check_range( EXPORTING iv_from    = iv_from
                           iv_to      = iv_to
                           iv_days    = lif_sms=>max_report_days
                 IMPORTING ev_code    = rs_report-code
                           ev_message = rs_report-message ).
    IF rs_report-code IS NOT INITIAL.
      RETURN.
    ENDIF.
    IF lv_count = 0 AND iv_from IS INITIAL.
      rs_report-code = lif_sms=>code-bad_input.
      rs_report-message = lcl_text=>get( 'NO_CRITERIA' ).
      RETURN.
    ENDIF.

    IF lv_count > 0.
      CONCATENATE lv_jobs `]` INTO lv_body.
    ENDIF.
    IF iv_from IS NOT INITIAL.
      lv_text = format_time( iv_date  = iv_from
                             iv_time  = '000000'
                             iv_style = 'DOT_S' ).
      IF lv_body IS NOT INITIAL.
        CONCATENATE lv_body `,` INTO lv_body.
      ENDIF.
      CONCATENATE lv_body `"startdate":"` lv_text `"` INTO lv_body.
      lv_text = format_time( iv_date  = iv_to
                             iv_time  = '235959'
                             iv_style = 'DOT_S' ).
      CONCATENATE lv_body `,"stopdate":"` lv_text `"` INTO lv_body.
    ENDIF.
    IF iv_page > 0.
      lv_text = int_text( iv_page ).
      CONCATENATE lv_body `,"pagenumber":` lv_text INTO lv_body.
    ENDIF.
    IF iv_page_size > 0.
      lv_text = int_text( iv_page_size ).
      CONCATENATE lv_body `,"pagesize":` lv_text INTO lv_body.
    ENDIF.
    CONCATENATE `{` lv_body `}` INTO lv_body.

    CONCATENATE lif_sms=>api_path `/report` INTO lv_path.
    call_netgsm( EXPORTING iv_action      = lif_sms=>action-report
                           iv_destination = mv_destination
                           iv_method      = `POST`
                           iv_path        = lv_path
                           iv_body        = lv_body
                 IMPORTING ev_code        = rs_report-code
                           ev_message     = rs_report-message
                           et_values      = lt_values
                           ev_status      = lv_status ).

    DO.
      lv_row = sy-index.
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `status` ).
      lv_text = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `jobid` ).
      IF lcl_sms_json=>has( it_values = lt_values
                            iv_path   = lv_path ) = abap_false
         AND lcl_sms_json=>has( it_values = lt_values
                                iv_path   = lv_text ) = abap_false.
        EXIT.
      ENDIF.
      CLEAR ls_line.
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `jobid` ).
      ls_line-jobid = lcl_sms_json=>value_of( it_values = lt_values
                                              iv_path   = lv_path ).
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `number` ).
      lv_value = lcl_sms_json=>value_of( it_values = lt_values
                                         iv_path   = lv_path ).
      ls_line-number = lcl_sms_phone=>mask_any( lv_value ).
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `status` ).
      ls_line-status = lcl_sms_json=>value_of( it_values = lt_values
                                               iv_path   = lv_path ).
      ls_line-status_text = status_text( ls_line-status ).
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `operator` ).
      lv_value = lcl_sms_json=>value_of( it_values = lt_values
                                         iv_path   = lv_path ).
      ls_line-operator = operator_name( lv_value ).
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `errorCode` ).
      ls_line-error_code = lcl_sms_json=>value_of(
                             it_values = lt_values
                             iv_path   = lv_path ).
      ls_line-error_text = error_text( ls_line-error_code ).
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `deliveredDate` ).
      ls_line-delivered = lcl_sms_json=>value_of(
                            it_values = lt_values
                            iv_path   = lv_path ).
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `msglen` ).
      ls_line-msglen = lcl_sms_json=>value_of( it_values = lt_values
                                               iv_path   = lv_path ).
      lv_path = row_path( iv_list = `jobs` iv_row = lv_row
                          iv_field = `referansID` ).
      ls_line-reference = lcl_sms_json=>value_of(
                            it_values = lt_values
                            iv_path   = lv_path ).
      APPEND ls_line TO rs_report-lines.
    ENDDO.
  ENDMETHOD.


  METHOD stats.
    DATA lv_jobid TYPE string.
    DATA lv_body TYPE string.
    DATA lv_path TYPE string.
    DATA lv_text TYPE string.
    DATA lv_row TYPE i.
    DATA lv_status TYPE i.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA ls_line TYPE lif_sms=>ty_stats_line.

    lv_jobid = iv_jobid.
    CONDENSE lv_jobid NO-GAPS.
    IF lv_jobid IS INITIAL.
      rs_stats-code = lif_sms=>code-bad_input.
      rs_stats-message = lcl_text=>get( 'NO_JOB' ).
      RETURN.
    ENDIF.
    lv_jobid = lcl_sms_json=>escape( lv_jobid ).
    CONCATENATE `{"jobid":"` lv_jobid `"` INTO lv_body.
    IF iv_send_date IS NOT INITIAL.
      lv_text = format_time( iv_date  = iv_send_date
                             iv_time  = '000000'
                             iv_style = 'ISO_S' ).
      CONCATENATE lv_body `,"senddate":"` lv_text `"` INTO lv_body.
    ENDIF.
    CONCATENATE lv_body `}` INTO lv_body.

    CONCATENATE lif_sms=>api_path `/stats` INTO lv_path.
    call_netgsm( EXPORTING iv_action      = lif_sms=>action-stats
                           iv_destination = mv_destination
                           iv_method      = `POST`
                           iv_path        = lv_path
                           iv_body        = lv_body
                 IMPORTING ev_code        = rs_stats-code
                           ev_message     = rs_stats-message
                           et_values      = lt_values
                           ev_status      = lv_status ).

    DO.
      lv_row = sy-index.
      lv_path = row_path( iv_list = `stats` iv_row = lv_row
                          iv_field = `status` ).
      IF lcl_sms_json=>has( it_values = lt_values
                            iv_path   = lv_path ) = abap_false.
        EXIT.
      ENDIF.
      CLEAR ls_line.
      ls_line-status = lcl_sms_json=>value_of( it_values = lt_values
                                               iv_path   = lv_path ).
      ls_line-status_text = stats_text( ls_line-status ).
      lv_path = row_path( iv_list = `stats` iv_row = lv_row
                          iv_field = `totalSms` ).
      ls_line-total_sms = lcl_sms_json=>value_of(
                            it_values = lt_values
                            iv_path   = lv_path ).
      lv_path = row_path( iv_list = `stats` iv_row = lv_row
                          iv_field = `totalMessageLength` ).
      ls_line-total_parts = lcl_sms_json=>value_of(
                              it_values = lt_values
                              iv_path   = lv_path ).
      lv_path = row_path( iv_list = `stats` iv_row = lv_row
                          iv_field = `chargeStatement` ).
      ls_line-charge = lcl_sms_json=>value_of( it_values = lt_values
                                               iv_path   = lv_path ).
      lv_path = row_path( iv_list = `stats` iv_row = lv_row
                          iv_field = `statement` ).
      ls_line-statement = lcl_sms_json=>value_of(
                            it_values = lt_values
                            iv_path   = lv_path ).
      lv_path = row_path( iv_list = `stats` iv_row = lv_row
                          iv_field = `domestic` ).
      ls_line-domestic = lcl_sms_json=>value_of(
                           it_values = lt_values
                           iv_path   = lv_path ).
      APPEND ls_line TO rs_stats-lines.
    ENDDO.
  ENDMETHOD.


  METHOD inbox.
    DATA lv_path TYPE string.
    DATA lv_text TYPE string.
    DATA lv_row TYPE i.
    DATA lv_status TYPE i.
    DATA lv_value TYPE string.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA ls_line TYPE lif_sms=>ty_inbox_line.

    check_range( EXPORTING iv_from    = iv_from
                           iv_to      = iv_to
                           iv_days    = lif_sms=>max_inbox_days
                 IMPORTING ev_code    = rs_inbox-code
                           ev_message = rs_inbox-message ).
    IF rs_inbox-code IS NOT INITIAL.
      RETURN.
    ENDIF.

    CONCATENATE lif_sms=>api_path `/inbox` INTO lv_path.
    IF iv_from IS NOT INITIAL.
      lv_text = format_time( iv_date  = iv_from
                             iv_time  = '000000'
                             iv_style = 'DMYHM' ).
      CONCATENATE lv_path `?startdate=` lv_text INTO lv_path.
      lv_text = format_time( iv_date  = iv_to
                             iv_time  = '235900'
                             iv_style = 'DMYHM' ).
      CONCATENATE lv_path `&stopdate=` lv_text INTO lv_path.
    ENDIF.
    call_netgsm( EXPORTING iv_action      = lif_sms=>action-inbox
                           iv_destination = mv_destination
                           iv_method      = `GET`
                           iv_path        = lv_path
                 IMPORTING ev_code        = rs_inbox-code
                           ev_message     = rs_inbox-message
                           et_values      = lt_values
                           ev_status      = lv_status ).

    DO.
      lv_row = sy-index.
      lv_path = row_path( iv_list = `messages` iv_row = lv_row
                          iv_field = `id` ).
      IF lcl_sms_json=>has( it_values = lt_values
                            iv_path   = lv_path ) = abap_false.
        EXIT.
      ENDIF.
      CLEAR ls_line.
      ls_line-id = lcl_sms_json=>value_of( it_values = lt_values
                                           iv_path   = lv_path ).
      lv_path = row_path( iv_list = `messages` iv_row = lv_row
                          iv_field = `gorevId` ).
      ls_line-jobid = lcl_sms_json=>value_of( it_values = lt_values
                                              iv_path   = lv_path ).
      lv_path = row_path( iv_list = `messages` iv_row = lv_row
                          iv_field = `kayittar` ).
      lv_value = lcl_sms_json=>value_of( it_values = lt_values
                                         iv_path   = lv_path ).
      ls_line-received = turkish_time( lv_value ).
      lv_path = row_path( iv_list = `messages` iv_row = lv_row
                          iv_field = `gonderen` ).
      lv_value = lcl_sms_json=>value_of( it_values = lt_values
                                         iv_path   = lv_path ).
      IF iv_full_numbers = abap_true.
        ls_line-sender = lv_value.
      ELSE.
        ls_line-sender = lcl_sms_phone=>mask_any( lv_value ).
      ENDIF.
      lv_path = row_path( iv_list = `messages` iv_row = lv_row
                          iv_field = `operator` ).
      ls_line-operator = lcl_sms_json=>value_of(
                           it_values = lt_values
                           iv_path   = lv_path ).
      lv_path = row_path( iv_list = `messages` iv_row = lv_row
                          iv_field = `mesaj` ).
      ls_line-text = lcl_sms_json=>value_of( it_values = lt_values
                                             iv_path   = lv_path ).
      APPEND ls_line TO rs_inbox-lines.
    ENDDO.
  ENDMETHOD.


  METHOD headers.
    DATA lv_path TYPE string.
    DATA lv_status TYPE i.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA ls_value TYPE lcl_sms_json=>ty_value.

    CONCATENATE lif_sms=>api_path `/msgheader` INTO lv_path.
    call_netgsm( EXPORTING iv_action      = lif_sms=>action-headers
                           iv_destination = mv_destination
                           iv_method      = `GET`
                           iv_path        = lv_path
                 IMPORTING ev_code        = rs_headers-code
                           ev_message     = rs_headers-message
                           et_values      = lt_values
                           ev_status      = lv_status ).
    LOOP AT lt_values INTO ls_value.
      IF ls_value-path CP 'msgheaders/*'.
        APPEND ls_value-value TO rs_headers-names.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD templates.
    DATA lv_path TYPE string.
    DATA lv_text TYPE string.
    DATA lv_row TYPE i.
    DATA lv_param TYPE i.
    DATA lv_status TYPE i.
    DATA lv_name TYPE string.
    DATA lv_type TYPE string.
    DATA lv_max TYPE string.
    DATA lv_prefix TYPE string.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA ls_line TYPE lif_sms=>ty_template.

    lv_text = int_text( iv_page ).
    CONCATENATE lif_sms=>api_path `/template/list?page=` lv_text
                INTO lv_path.
    lv_text = int_text( iv_size ).
    CONCATENATE lv_path `&size=` lv_text INTO lv_path.
    IF iv_public = abap_true.
      CONCATENATE lv_path `&includePublic=true` INTO lv_path.
    ELSE.
      CONCATENATE lv_path `&includePublic=false` INTO lv_path.
    ENDIF.
    IF iv_search IS NOT INITIAL.
      lv_text = url_encode( iv_search ).
      CONCATENATE lv_path `&search=` lv_text INTO lv_path.
    ENDIF.
    IF iv_type IS NOT INITIAL.
      lv_text = url_encode( iv_type ).
      CONCATENATE lv_path `&type=` lv_text INTO lv_path.
    ENDIF.
    IF iv_content IS NOT INITIAL.
      lv_text = url_encode( iv_content ).
      CONCATENATE lv_path `&context=` lv_text INTO lv_path.
    ENDIF.

    call_netgsm( EXPORTING iv_action      = lif_sms=>action-templates
                           iv_destination = mv_ext_destination
                           iv_method      = `GET`
                           iv_path        = lv_path
                 IMPORTING ev_code        = rs_templates-code
                           ev_message     = rs_templates-message
                           et_values      = lt_values
                           ev_status      = lv_status ).
    rs_templates-page = lcl_sms_json=>value_of( it_values = lt_values
                                                iv_path   = `page` ).
    rs_templates-pages = lcl_sms_json=>value_of(
                           it_values = lt_values
                           iv_path   = `totalPages` ).
    rs_templates-total = lcl_sms_json=>value_of(
                           it_values = lt_values
                           iv_path   = `totalElements` ).

    DO.
      lv_row = sy-index.
      lv_path = row_path( iv_list = `templates` iv_row = lv_row
                          iv_field = `templateId` ).
      IF lcl_sms_json=>has( it_values = lt_values
                            iv_path   = lv_path ) = abap_false.
        EXIT.
      ENDIF.
      CLEAR ls_line.
      ls_line-id = lcl_sms_json=>value_of( it_values = lt_values
                                           iv_path   = lv_path ).
      lv_path = row_path( iv_list = `templates` iv_row = lv_row
                          iv_field = `type` ).
      ls_line-type = lcl_sms_json=>value_of( it_values = lt_values
                                             iv_path   = lv_path ).
      lv_path = row_path( iv_list = `templates` iv_row = lv_row
                          iv_field = `description` ).
      ls_line-description = lcl_sms_json=>value_of(
                              it_values = lt_values
                              iv_path   = lv_path ).
      lv_path = row_path( iv_list = `templates` iv_row = lv_row
                          iv_field = `templateContent` ).
      ls_line-content = lcl_sms_json=>value_of(
                          it_values = lt_values
                          iv_path   = lv_path ).
      lv_path = row_path( iv_list = `templates` iv_row = lv_row
                          iv_field = `public` ).
      ls_line-public = lcl_sms_json=>value_of( it_values = lt_values
                                               iv_path   = lv_path ).
      lv_path = row_path( iv_list = `templates` iv_row = lv_row
                          iv_field = `registryDate` ).
      ls_line-registered = lcl_sms_json=>value_of(
                             it_values = lt_values
                             iv_path   = lv_path ).
      " parameters/n/name, type, maxLength
      lv_prefix = row_path( iv_list = `templates` iv_row = lv_row
                            iv_field = `parameters` ).
      DO.
        lv_param = sy-index.
        lv_path = row_path( iv_list = lv_prefix iv_row = lv_param
                            iv_field = `name` ).
        IF lcl_sms_json=>has( it_values = lt_values
                              iv_path   = lv_path ) = abap_false.
          EXIT.
        ENDIF.
        lv_name = lcl_sms_json=>value_of( it_values = lt_values
                                          iv_path   = lv_path ).
        lv_path = row_path( iv_list = lv_prefix iv_row = lv_param
                            iv_field = `type` ).
        lv_type = lcl_sms_json=>value_of( it_values = lt_values
                                          iv_path   = lv_path ).
        lv_path = row_path( iv_list = lv_prefix iv_row = lv_param
                            iv_field = `maxLength` ).
        lv_max = lcl_sms_json=>value_of( it_values = lt_values
                                         iv_path   = lv_path ).
        IF lv_max IS NOT INITIAL.
          CONCATENATE lv_type `, ` lv_max INTO lv_type.
        ENDIF.
        CONCATENATE lv_name ` (` lv_type `)` INTO lv_name.
        IF ls_line-parameters IS INITIAL.
          ls_line-parameters = lv_name.
        ELSE.
          CONCATENATE ls_line-parameters `; ` lv_name
                      INTO ls_line-parameters.
        ENDIF.
      ENDDO.
      APPEND ls_line TO rs_templates-lines.
    ENDDO.
  ENDMETHOD.


  METHOD length.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA lv_text TYPE string.
    DATA lv_body TYPE string.
    DATA lv_path TYPE string.
    DATA lv_code TYPE string.
    DATA lv_status TYPE i.
    DATA lt_values TYPE lcl_sms_json=>ty_values.

    ls_info = lcl_sms_text=>analyze( iv_text     = iv_text
                                     iv_encoding = iv_encoding
                                     iv_header   = iv_header ).
    IF ls_info-encoding IS INITIAL.
      rs_length-code = lif_sms=>code-bad_text.
      rs_length-message = ls_info-message.
      RETURN.
    ENDIF.
    rs_length-encoding = ls_info-encoding.
    CASE ls_info-encoding.
      WHEN lif_sms=>encoding-turkish.
        lv_code = `11`.
      WHEN lif_sms=>encoding-unicode.
        lv_code = `8`.
      WHEN OTHERS.
        lv_code = `0`.
    ENDCASE.
    lv_text = lcl_sms_json=>escape( ls_info-text ).
    CONCATENATE `{"context":"` lv_text `","encoding":` lv_code
                INTO lv_body.
    IF ls_info-suffix > 0.
      CONCATENATE lv_body `,"customHeader":true}` INTO lv_body.
    ELSE.
      CONCATENATE lv_body `,"customHeader":false}` INTO lv_body.
    ENDIF.

    CONCATENATE lif_sms=>api_path `/length` INTO lv_path.
    call_netgsm( EXPORTING iv_action      = lif_sms=>action-length
                           iv_destination = mv_destination
                           iv_method      = `POST`
                           iv_path        = lv_path
                           iv_body        = lv_body
                 IMPORTING ev_code        = rs_length-code
                           ev_message     = rs_length-message
                           et_values      = lt_values
                           ev_status      = lv_status ).
    rs_length-parts = lcl_sms_json=>value_of( it_values = lt_values
                                              iv_path   = `parts` ).
    rs_length-used = lcl_sms_json=>value_of( it_values = lt_values
                                             iv_path   = `charsUsed` ).
    rs_length-left = lcl_sms_json=>value_of( it_values = lt_values
                                             iv_path   = `charsLeft` ).
    rs_length-left_part = lcl_sms_json=>value_of(
                            it_values = lt_values
                            iv_path   = `charsLeftUntilNextPart` ).
  ENDMETHOD.


  METHOD code_text.
    DATA lv_code TYPE string.
    DATA lv_key TYPE string.
    DATA lv_prefix TYPE string.
    DATA lv_value TYPE string.
    DATA lv_len TYPE i.

    lv_code = iv_code.
    lv_len = strlen( lv_code ).
    " 100-110: system errors, all the same text
    IF lv_len = 3 AND lv_code(1) = '1' AND lv_code CO '0123456789'.
      lv_code = `100`.
    ENDIF.
    IF iv_action = lif_sms=>action-otp.
      CASE lv_code.
        WHEN `41`.
          lv_code = `40`.
        WHEN `51` OR `52`.
          lv_code = `50`.
      ENDCASE.
    ENDIF.

    CASE iv_action.
      WHEN lif_sms=>action-send.
        lv_prefix = `SEND`.
      WHEN lif_sms=>action-otp.
        lv_prefix = `OTP`.
      WHEN lif_sms=>action-template.
        lv_prefix = `TPL`.
      WHEN lif_sms=>action-cancel.
        lv_prefix = `CANCEL`.
      WHEN lif_sms=>action-report.
        lv_prefix = `REPORT`.
      WHEN lif_sms=>action-inbox.
        lv_prefix = `INBOX`.
      WHEN lif_sms=>action-length.
        lv_prefix = `LENGTH`.
      WHEN OTHERS.
        lv_prefix = `OTHER`.
    ENDCASE.
    CONCATENATE lv_prefix `_` lv_code INTO lv_key.
    rv_text = lcl_text=>get( lv_key ).
    IF rv_text <> lv_key.
      RETURN.
    ENDIF.

    IF lv_code = `00`.
      IF iv_action = lif_sms=>action-send
         OR iv_action = lif_sms=>action-otp
         OR iv_action = lif_sms=>action-template.
        rv_text = lcl_text=>get( 'C00' ).
      ELSE.
        rv_text = lcl_text=>get( 'C00_OK' ).
      ENDIF.
      RETURN.
    ENDIF.

    " C100 shows the original code (100 to 110) in its text
    CONCATENATE `C` lv_code INTO lv_key.
    rv_text = lcl_text=>get( iv_key = lv_key
                             iv_1   = iv_code ).
    IF rv_text <> lv_key.
      RETURN.
    ENDIF.

    lv_value = iv_description.
    IF lv_value IS NOT INITIAL.
      CONCATENATE `(` lv_value `)` INTO lv_value.
    ENDIF.
    rv_text = lcl_text=>get( iv_key = 'C_OTHER'
                             iv_1   = iv_code
                             iv_2   = lv_value ).
  ENDMETHOD.


  METHOD format_time.
    CASE iv_style.
      WHEN 'DMYHM'.
        CONCATENATE iv_date+6(2) iv_date+4(2) iv_date(4)
                    iv_time(2) iv_time+2(2) INTO rv_text.
      WHEN 'ISO_M'.
        CONCATENATE iv_date(4) '-' iv_date+4(2) '-' iv_date+6(2) ` `
                    iv_time(2) ':' iv_time+2(2) INTO rv_text.
      WHEN 'DOT_S'.
        CONCATENATE iv_date+6(2) '.' iv_date+4(2) '.' iv_date(4) ` `
                    iv_time(2) ':' iv_time+2(2) ':' iv_time+4(2)
                    INTO rv_text.
      WHEN OTHERS.
        CONCATENATE iv_date(4) '-' iv_date+4(2) '-' iv_date+6(2) ` `
                    iv_time(2) ':' iv_time+2(2) ':' iv_time+4(2)
                    INTO rv_text.
    ENDCASE.
  ENDMETHOD.


  METHOD turkish_time.
    DATA lv_millis TYPE string.
    DATA lv_seconds TYPE p LENGTH 16 DECIMALS 0.
    DATA lv_days TYPE i.
    DATA lv_rest TYPE i.
    DATA lv_date TYPE d.
    DATA lv_time TYPE t.

    lv_millis = iv_millis.
    CONDENSE lv_millis NO-GAPS.
    IF lv_millis IS INITIAL OR NOT lv_millis CO '0123456789'
       OR strlen( lv_millis ) > 15.
      rv_text = lv_millis.
      RETURN.
    ENDIF.
    lv_seconds = lv_millis.
    lv_seconds = lv_seconds DIV 1000
                 + lif_sms=>turkey_offset_seconds.
    lv_days = lv_seconds DIV 86400.
    lv_rest = lv_seconds MOD 86400.
    lv_date = '19700101'.
    lv_date = lv_date + lv_days.
    lv_time = lv_rest.
    rv_text = format_time( iv_date  = lv_date
                           iv_time  = lv_time
                           iv_style = 'DOT_S' ).
  ENDMETHOD.


  METHOD url_encode.
    DATA lo_out TYPE REF TO cl_abap_conv_out_ce.
    DATA lv_text TYPE string.
    DATA lv_bytes TYPE xstring.
    DATA lv_byte TYPE x LENGTH 1.
    DATA lv_len TYPE i.
    DATA lv_pos TYPE i.
    DATA lv_value TYPE i.
    DATA lv_char TYPE c LENGTH 1.
    DATA lv_hex TYPE c LENGTH 2.

    lv_text = iv_text.
    IF lv_text IS INITIAL.
      RETURN.
    ENDIF.
    lo_out = cl_abap_conv_out_ce=>create( encoding = 'UTF-8' ).
    lo_out->convert( EXPORTING data   = lv_text
                     IMPORTING buffer = lv_bytes ).
    lv_len = xstrlen( lv_bytes ).
    DO lv_len TIMES.
      lv_pos = sy-index - 1.
      lv_byte = lv_bytes+lv_pos(1).
      lv_value = lv_byte.
      " Letters, digits and - . _ ~ stay; the rest becomes %XX
      IF ( lv_value >= 48 AND lv_value <= 57 )
         OR ( lv_value >= 65 AND lv_value <= 90 )
         OR ( lv_value >= 97 AND lv_value <= 122 )
         OR lv_value = 45 OR lv_value = 46 OR lv_value = 95
         OR lv_value = 126.
        lv_char = cl_abap_conv_in_ce=>uccpi( lv_value ).
        CONCATENATE rv_text lv_char INTO rv_text.
      ELSE.
        lv_hex = lv_byte.
        CONCATENATE rv_text '%' lv_hex INTO rv_text.
      ENDIF.
    ENDDO.
  ENDMETHOD.


  METHOD call_netgsm.
    DATA ls_http TYPE lif_sms=>ty_http.
    DATA lv_description TYPE string.
    DATA lx_error TYPE REF TO lcx_sms.

    CLEAR: ev_code, ev_message, et_values, ev_status.
    check_access( EXPORTING iv_destination = iv_destination
                  IMPORTING ev_code        = ev_code
                            ev_message     = ev_message ).
    IF ev_code IS NOT INITIAL.
      RETURN.
    ENDIF.
    TRY.
        ls_http = mo_backend->call( iv_destination = iv_destination
                                    iv_method      = iv_method
                                    iv_path        = iv_path
                                    iv_body        = iv_body ).
        ev_status = ls_http-status.
        read_answer( EXPORTING is_http        = ls_http
                     IMPORTING ev_code        = ev_code
                               ev_description = lv_description
                               et_values      = et_values ).
      CATCH lcx_sms INTO lx_error.
        ev_code = lx_error->code.
        ev_message = lx_error->text.
        RETURN.
    ENDTRY.
    ev_message = code_text( iv_action      = iv_action
                            iv_code        = ev_code
                            iv_description = lv_description ).
  ENDMETHOD.


  METHOD check_access.
    DATA lv_type TYPE rfcdes-rfctype.

    CLEAR: ev_code, ev_message.
    lv_type = mo_backend->destination_type( iv_destination ).
    IF lv_type IS INITIAL.
      ev_code = lif_sms=>code-no_dest.
      ev_message = lcl_text=>get( iv_key = 'NO_DEST'
                                  iv_1   = iv_destination ).
    ELSEIF lv_type <> 'G'.
      ev_code = lif_sms=>code-no_dest.
      ev_message = lcl_text=>get( iv_key = 'DEST_TYPE'
                                  iv_1   = iv_destination
                                  iv_2   = lv_type ).
    ELSEIF mo_backend->has_authority( iv_destination ) = abap_false.
      ev_code = lif_sms=>code-no_auth.
      ev_message = lcl_text=>get( iv_key = 'NO_AUTH'
                                  iv_1   = iv_destination ).
    ENDIF.
  ENDMETHOD.


  METHOD read_answer.
    DATA lv_body TYPE string.
    DATA lv_status TYPE c LENGTH 11.
    DATA lv_text TYPE string.

    CLEAR: ev_code, ev_description, et_values.
    lv_body = is_http-body.
    CONDENSE lv_body.

    IF lv_body IS NOT INITIAL AND lv_body(1) = `{`.
      et_values = lcl_sms_json=>parse( lv_body ).
      ev_code = lcl_sms_json=>value_of( it_values = et_values
                                        iv_path   = `code` ).
      ev_description = lcl_sms_json=>value_of(
                         it_values = et_values
                         iv_path   = `description` ).
      " Statistics and length answer without a code when all is well
      IF ev_code IS INITIAL
         AND ( ev_description = `success`
               OR lcl_sms_json=>has( it_values = et_values
                                     iv_path   = `parts` )
                  = abap_true ).
        ev_code = lif_sms=>code-ok.
      ENDIF.
    ELSEIF lv_body CO '0123456789 '.
      " Older answers are plain text: the code, maybe a job ID
      SPLIT lv_body AT ` ` INTO ev_code ev_description.
    ENDIF.

    " Netgsm also answers with HTTP 406 and a normal code in the
    " body (seen live: 406 with code 00 and 406 with code 30), so
    " the code in the body wins over the HTTP status
    IF ev_code IS INITIAL AND is_http-status <> 200.
      lv_status = is_http-status.
      CONDENSE lv_status.
      lv_text = lcl_text=>get( iv_key = 'HTTP'
                               iv_1   = lv_status
                               iv_2   = is_http-reason ).
      IF lv_body IS NOT INITIAL.
        CONCATENATE lv_text ` ` lv_body INTO lv_text.
      ENDIF.
      RAISE EXCEPTION TYPE lcx_sms
        EXPORTING
          code = lif_sms=>code-http
          text = lv_text.
    ENDIF.

    IF ev_code IS INITIAL.
      lv_text = lcl_text=>get( iv_key = 'BAD_REPLY'
                               iv_1   = lv_body ).
      RAISE EXCEPTION TYPE lcx_sms
        EXPORTING
          code = lif_sms=>code-bad_reply
          text = lv_text.
    ENDIF.
  ENDMETHOD.


  METHOD check_numbers.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.
    DATA lv_max TYPE string.

    cs_result-recipients = lcl_sms_phone=>normalize_all( it_numbers ).
    cs_result-valid = 0.
    LOOP AT cs_result-recipients INTO ls_recipient
         WHERE ok = abap_true.
      cs_result-valid = cs_result-valid + 1.
    ENDLOOP.
    IF cs_result-valid = 0.
      cs_result-code = lif_sms=>code-bad_number.
      cs_result-message = lcl_text=>get( 'NO_NUMBERS' ).
    ELSEIF cs_result-valid > iv_max.
      cs_result-code = lif_sms=>code-bad_number.
      IF iv_max = 1.
        cs_result-message = lcl_text=>get( 'OTP_ONE' ).
      ELSE.
        lv_max = int_text( iv_max ).
        cs_result-message = lcl_text=>get( iv_key = 'TOO_MANY'
                                           iv_1   = lv_max ).
      ENDIF.
    ENDIF.
  ENDMETHOD.


  METHOD check_header.
    DATA lv_len TYPE i.

    lv_len = strlen( cs_result-header ).
    IF lv_len = 0.
      cs_result-code = lif_sms=>code-bad_input.
      cs_result-message = lcl_text=>get( 'NO_HEADER' ).
    ELSEIF lv_len < 3 OR lv_len > 11.
      cs_result-code = lif_sms=>code-bad_input.
      cs_result-message = lcl_text=>get( 'HEADER_LEN' ).
    ENDIF.
  ENDMETHOD.


  METHOD check_iys.
    IF cs_result-iys <> lif_sms=>iys-info
       AND cs_result-iys <> lif_sms=>iys-individual
       AND cs_result-iys <> lif_sms=>iys-merchant.
      cs_result-code = lif_sms=>code-bad_input.
      cs_result-message = lcl_text=>get( iv_key = 'BAD_IYS'
                                         iv_1   = cs_result-iys ).
    ENDIF.
  ENDMETHOD.


  METHOD check_schedule.
    DATA lv_start TYPE c LENGTH 14.
    DATA lv_stop TYPE c LENGTH 14.

    IF cs_result-schedule-start_date IS INITIAL
       OR cs_result-schedule-start_date = '00000000'.
      IF cs_result-schedule-stop_date IS NOT INITIAL
         AND cs_result-schedule-stop_date <> '00000000'.
        cs_result-code = lif_sms=>code-bad_input.
        cs_result-message = lcl_text=>get( 'SCHED_NO_START' ).
      ENDIF.
      CLEAR cs_result-schedule.
      RETURN.
    ENDIF.
    IF cs_result-schedule-stop_date IS INITIAL
       OR cs_result-schedule-stop_date = '00000000'.
      CLEAR: cs_result-schedule-stop_date,
             cs_result-schedule-stop_time.
      RETURN.
    ENDIF.
    CONCATENATE cs_result-schedule-start_date
                cs_result-schedule-start_time INTO lv_start.
    CONCATENATE cs_result-schedule-stop_date
                cs_result-schedule-stop_time INTO lv_stop.
    IF lv_stop <= lv_start.
      cs_result-code = lif_sms=>code-bad_input.
      cs_result-message = lcl_text=>get( 'SCHED_STOP' ).
    ENDIF.
  ENDMETHOD.


  METHOD check_range.
    DATA lv_days TYPE i.
    DATA lv_max TYPE string.

    CLEAR: ev_code, ev_message.
    IF iv_from IS INITIAL AND iv_to IS INITIAL.
      RETURN.
    ENDIF.
    IF iv_from IS INITIAL OR iv_to IS INITIAL.
      ev_code = lif_sms=>code-bad_input.
      ev_message = lcl_text=>get( 'RANGE_BOTH' ).
    ELSEIF iv_to < iv_from.
      ev_code = lif_sms=>code-bad_input.
      ev_message = lcl_text=>get( 'RANGE_ORDER' ).
    ELSE.
      lv_days = iv_to - iv_from.
      IF lv_days > iv_days.
        lv_max = int_text( iv_days ).
        ev_code = lif_sms=>code-bad_input.
        ev_message = lcl_text=>get( iv_key = 'RANGE_LONG'
                                    iv_1   = lv_max ).
      ENDIF.
    ENDIF.
  ENDMETHOD.


  METHOD finish_send.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA lv_unsure TYPE string.

    " Destination and authorization, also for the preview
    check_access( EXPORTING iv_destination = iv_destination
                  IMPORTING ev_code        = cs_result-code
                            ev_message     = cs_result-message ).
    IF cs_result-code IS NOT INITIAL.
      RETURN.
    ENDIF.
    IF iv_dry_run = abap_true.
      cs_result-code = lif_sms=>code-dry_run.
      cs_result-message = lcl_text=>get( 'DRY_RUN' ).
      RETURN.
    ENDIF.

    " From here on, any answer means Netgsm may have it
    call_netgsm( EXPORTING iv_action      = cs_result-action
                           iv_destination = iv_destination
                           iv_method      = `POST`
                           iv_path        = iv_path
                           iv_body        = iv_body
                 IMPORTING ev_code        = cs_result-code
                           ev_message     = cs_result-message
                           et_values      = lt_values
                           ev_status      = cs_result-http_status ).
    IF cs_result-code = lif_sms=>code-no_conn.
      lv_unsure = lcl_text=>get( 'UNSURE' ).
      CONCATENATE cs_result-message lv_unsure
                  INTO cs_result-message SEPARATED BY ` `.
      RETURN.
    ENDIF.
    cs_result-jobid = lcl_sms_json=>value_of( it_values = lt_values
                                              iv_path   = `jobid` ).
    cs_result-description = lcl_sms_json=>value_of(
                              it_values = lt_values
                              iv_path   = `description` ).
    IF cs_result-code = `00` OR cs_result-code = `01`
       OR cs_result-code = `02`.
      cs_result-sent = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD send_body.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.
    DATA lv_text TYPE string.
    DATA lv_number TYPE string.
    DATA lv_header TYPE string.
    DATA lv_extra TYPE string.
    DATA lv_first TYPE abap_bool VALUE abap_true.

    lv_text = lcl_sms_json=>escape( is_result-text_info-text ).
    lv_header = lcl_sms_json=>escape( is_result-header ).
    CONCATENATE `{"msgheader":"` lv_header `"` INTO rv_json.
    CASE is_result-text_info-encoding.
      WHEN lif_sms=>encoding-turkish.
        CONCATENATE rv_json `,"encoding":"TR"` INTO rv_json.
      WHEN lif_sms=>encoding-unicode.
        CONCATENATE rv_json `,"encoding":"UNICODE"` INTO rv_json.
    ENDCASE.
    CONCATENATE rv_json `,"iysfilter":"` is_result-iys `"`
                INTO rv_json.
    lv_extra = schedule_json( is_schedule = is_result-schedule
                              iv_style    = 'DMYHM' ).
    CONCATENATE rv_json lv_extra INTO rv_json.
    lv_extra = reference_json( is_result-reference ).
    CONCATENATE rv_json lv_extra `,"messages":[` INTO rv_json.
    LOOP AT is_result-recipients INTO ls_recipient
         WHERE ok = abap_true.
      IF iv_masked = abap_true.
        lv_number = ls_recipient-masked.
      ELSE.
        lv_number = ls_recipient-number.
      ENDIF.
      IF lv_first = abap_false.
        CONCATENATE rv_json `,` INTO rv_json.
      ENDIF.
      lv_first = abap_false.
      CONCATENATE rv_json `{"msg":"` lv_text `","no":"` lv_number `"}`
                  INTO rv_json.
    ENDLOOP.
    CONCATENATE rv_json `]}` INTO rv_json.
  ENDMETHOD.


  METHOD otp_body.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.
    DATA lv_text TYPE string.
    DATA lv_number TYPE string.
    DATA lv_header TYPE string.

    READ TABLE is_result-recipients INTO ls_recipient
         WITH KEY ok = abap_true.
    IF iv_masked = abap_true.
      lv_number = ls_recipient-masked.
    ELSE.
      lv_number = ls_recipient-number.
    ENDIF.
    lv_text = lcl_sms_json=>escape( is_result-text_info-text ).
    lv_header = lcl_sms_json=>escape( is_result-header ).
    CONCATENATE `{"msgheader":"` lv_header `","msg":"` lv_text
                `","no":"` lv_number `"}` INTO rv_json.
  ENDMETHOD.


  METHOD template_body.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.
    DATA ls_param TYPE lif_sms=>ty_param.
    DATA lv_params TYPE string.
    DATA lv_name TYPE string.
    DATA lv_value TYPE string.
    DATA lv_number TYPE string.
    DATA lv_header TYPE string.
    DATA lv_extra TYPE string.
    DATA lv_id TYPE string.
    DATA lv_first TYPE abap_bool VALUE abap_true.

    " The same values for every number
    LOOP AT it_params INTO ls_param.
      lv_name = lcl_sms_json=>escape( ls_param-name ).
      lv_value = ls_param-value.
      IF iv_ascii = abap_true.
        lv_value = lcl_sms_text=>to_ascii( lv_value ).
      ENDIF.
      lv_value = lcl_sms_json=>escape( lv_value ).
      IF lv_params IS NOT INITIAL.
        CONCATENATE lv_params `,` INTO lv_params.
      ENDIF.
      CONCATENATE lv_params `"` lv_name `":"` lv_value `"`
                  INTO lv_params.
    ENDLOOP.

    lv_header = lcl_sms_json=>escape( is_result-header ).
    CONCATENATE `{"msgheader":"` lv_header `"` INTO rv_json.
    CASE is_result-text_info-encoding.
      WHEN lif_sms=>encoding-turkish.
        CONCATENATE rv_json `,"encoding":"TR"` INTO rv_json.
      WHEN lif_sms=>encoding-unicode.
        CONCATENATE rv_json `,"encoding":"UNICODE"` INTO rv_json.
    ENDCASE.
    CONCATENATE rv_json `,"iysfilter":"` is_result-iys `"`
                INTO rv_json.
    lv_extra = schedule_json( is_schedule = is_result-schedule
                              iv_style    = 'ISO_M' ).
    CONCATENATE rv_json lv_extra INTO rv_json.
    lv_extra = reference_json( is_result-reference ).
    CONCATENATE rv_json lv_extra `,"templates":[` INTO rv_json.
    lv_id = int_text( is_result-template_id ).
    LOOP AT is_result-recipients INTO ls_recipient
         WHERE ok = abap_true.
      IF iv_masked = abap_true.
        lv_number = ls_recipient-masked.
      ELSE.
        lv_number = ls_recipient-number.
      ENDIF.
      IF lv_first = abap_false.
        CONCATENATE rv_json `,` INTO rv_json.
      ENDIF.
      lv_first = abap_false.
      CONCATENATE rv_json `{"templateId":` lv_id `,"number":"`
                  lv_number `","params":{` lv_params `}}`
                  INTO rv_json.
    ENDLOOP.
    CONCATENATE rv_json `]}` INTO rv_json.
  ENDMETHOD.


  METHOD schedule_json.
    DATA lv_text TYPE string.

    IF is_schedule-start_date IS INITIAL.
      RETURN.
    ENDIF.
    lv_text = format_time( iv_date  = is_schedule-start_date
                           iv_time  = is_schedule-start_time
                           iv_style = iv_style ).
    CONCATENATE `,"startdate":"` lv_text `"` INTO rv_json.
    IF is_schedule-stop_date IS NOT INITIAL.
      lv_text = format_time( iv_date  = is_schedule-stop_date
                             iv_time  = is_schedule-stop_time
                             iv_style = iv_style ).
      CONCATENATE rv_json `,"stopdate":"` lv_text `"` INTO rv_json.
    ENDIF.
  ENDMETHOD.


  METHOD reference_json.
    DATA lv_text TYPE string.

    IF iv_reference IS INITIAL.
      RETURN.
    ENDIF.
    lv_text = lcl_sms_json=>escape( iv_reference ).
    CONCATENATE `,"referansID":"` lv_text `"` INTO rv_json.
  ENDMETHOD.


  METHOD row_path.
    DATA lv_row TYPE string.

    lv_row = int_text( iv_row ).
    CONCATENATE iv_list `/` lv_row `/` iv_field INTO rv_path.
  ENDMETHOD.


  METHOD int_text.
    DATA lv_char TYPE c LENGTH 11.

    lv_char = iv_value.
    CONDENSE lv_char.
    rv_text = lv_char.
  ENDMETHOD.


  METHOD status_text.
    DATA lv_key TYPE string.

    CASE iv_status.
      WHEN '0' OR '1' OR '2' OR '3' OR '4' OR '11' OR '12' OR '13'
        OR '14' OR '15' OR '16' OR '17' OR '22'.
        CONCATENATE `S` iv_status INTO lv_key.
        rv_text = lcl_text=>get( lv_key ).
      WHEN OTHERS.
        rv_text = iv_status.
    ENDCASE.
  ENDMETHOD.


  METHOD stats_text.
    DATA lv_key TYPE string.

    CONCATENATE `ST_` iv_status INTO lv_key.
    rv_text = lcl_text=>get( lv_key ).
    IF rv_text = lv_key.
      rv_text = iv_status.
    ENDIF.
  ENDMETHOD.


  METHOD error_text.
    DATA lv_key TYPE string.

    CASE iv_error.
      WHEN '' OR '0'.
        CLEAR rv_text.
      WHEN '101' OR '102' OR '103' OR '104' OR '105' OR '106'
        OR '111' OR '112' OR '113' OR '114' OR '115' OR '116'
        OR '117' OR '119'.
        CONCATENATE `E` iv_error INTO lv_key.
        rv_text = lcl_text=>get( lv_key ).
      WHEN OTHERS.
        rv_text = lcl_text=>get( iv_key = 'E_OTHER'
                                 iv_1   = iv_error ).
    ENDCASE.
  ENDMETHOD.


  METHOD operator_name.
    CASE iv_operator.
      WHEN '10'.
        rv_name = `Vodafone`.
      WHEN '20'.
        rv_name = `Türk Telekom`.
      WHEN '30'.
        rv_name = `Turkcell`.
      WHEN '40'.
        rv_name = `Netgsm STH`.
      WHEN '41'.
        rv_name = `Netgsm Mobil`.
      WHEN '60'.
        rv_name = lcl_text=>get( 'OP_60' ).
      WHEN '70'.
        rv_name = lcl_text=>get( 'OP_70' ).
      WHEN '160'.
        rv_name = `KKTC Vodafone`.
      WHEN '880'.
        rv_name = `KKTC Turkcell`.
      WHEN '212' OR '213' OR '214' OR '215'.
        rv_name = lcl_text=>get( 'OP_ABROAD' ).
      WHEN OTHERS.
        rv_name = iv_operator.
    ENDCASE.
  ENDMETHOD.

ENDCLASS.



*----------------------------------------------------------------------*
* Application log (SLG1). Object ZCHE_SMS has to be created once in
* SLG0; without it nothing is saved and the program says so. The
* message text is only logged when asked for.
*----------------------------------------------------------------------*
CLASS lcl_sms_log DEFINITION FINAL.
  PUBLIC SECTION.
    CONSTANTS object TYPE balobj_d VALUE 'ZCHE_SMS'.

    CLASS-METHODS write
      IMPORTING
        is_result      TYPE lif_sms=>ty_result
        iv_with_text   TYPE abap_bool
      RETURNING
        value(rv_saved) TYPE abap_bool.

    "! One line, for a cancel
    CLASS-METHODS write_simple
      IMPORTING
        iv_action       TYPE lif_sms=>ty_action
        iv_code         TYPE string
        iv_message      TYPE string
        iv_jobid        TYPE string
      RETURNING
        value(rv_saved) TYPE abap_bool.

  PRIVATE SECTION.
    CLASS-METHODS create
      IMPORTING
        iv_extnumber     TYPE csequence
      RETURNING
        value(rv_handle) TYPE balloghndl.

    CLASS-METHODS save
      IMPORTING
        iv_handle       TYPE balloghndl
      RETURNING
        value(rv_saved) TYPE abap_bool.

    CLASS-METHODS add
      IMPORTING
        iv_handle TYPE balloghndl
        iv_type   TYPE symsgty
        iv_text   TYPE string.
ENDCLASS.


CLASS lcl_sms_log IMPLEMENTATION.

  METHOD write.
    DATA lv_handle TYPE balloghndl.
    DATA lv_type TYPE symsgty.
    DATA lv_text TYPE string.
    DATA lv_parts TYPE c LENGTH 11.
    DATA lv_action TYPE string.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.

    IF is_result-jobid IS NOT INITIAL.
      lv_handle = create( is_result-jobid ).
    ELSE.
      lv_handle = create( is_result-code ).
    ENDIF.
    IF lv_handle IS INITIAL.
      RETURN.
    ENDIF.

    IF is_result-sent = abap_true.
      lv_type = 'S'.
    ELSE.
      lv_type = 'E'.
    ENDIF.
    lv_action = is_result-action.
    CONCATENATE lv_action ` ` is_result-code `: ` is_result-message
                INTO lv_text.
    IF is_result-jobid IS NOT INITIAL.
      CONCATENATE lv_text ` (jobid ` is_result-jobid `)` INTO lv_text.
    ENDIF.
    add( iv_handle = lv_handle iv_type = lv_type iv_text = lv_text ).

    lv_parts = is_result-text_info-parts.
    CONDENSE lv_parts.
    lv_text = lcl_text=>get( iv_key = 'LOG_SUMMARY'
                             iv_1   = is_result-header
                             iv_2   = is_result-text_info-encoding
                             iv_3   = lv_parts ).
    add( iv_handle = lv_handle iv_type = 'I' iv_text = lv_text ).

    LOOP AT is_result-recipients INTO ls_recipient.
      IF ls_recipient-ok = abap_true.
        lv_text = ls_recipient-masked.
        add( iv_handle = lv_handle iv_type = 'I' iv_text = lv_text ).
      ELSE.
        CONCATENATE ls_recipient-masked `: ` ls_recipient-reason
                    INTO lv_text.
        add( iv_handle = lv_handle iv_type = 'W' iv_text = lv_text ).
      ENDIF.
    ENDLOOP.

    IF iv_with_text = abap_true
       AND is_result-text_info-text IS NOT INITIAL.
      lv_text = lcl_text=>get( iv_key = 'LOG_TEXT'
                               iv_1   = is_result-text_info-text ).
      add( iv_handle = lv_handle iv_type = 'I' iv_text = lv_text ).
    ENDIF.

    rv_saved = save( lv_handle ).
  ENDMETHOD.


  METHOD write_simple.
    DATA lv_handle TYPE balloghndl.
    DATA lv_type TYPE symsgty.
    DATA lv_text TYPE string.
    DATA lv_action TYPE string.

    lv_handle = create( iv_jobid ).
    IF lv_handle IS INITIAL.
      RETURN.
    ENDIF.
    IF iv_code = lif_sms=>code-ok.
      lv_type = 'S'.
    ELSE.
      lv_type = 'E'.
    ENDIF.
    lv_action = iv_action.
    CONCATENATE lv_action ` ` iv_code `: ` iv_message INTO lv_text.
    add( iv_handle = lv_handle iv_type = lv_type iv_text = lv_text ).
    rv_saved = save( lv_handle ).
  ENDMETHOD.


  METHOD create.
    DATA ls_log TYPE bal_s_log.

    ls_log-object = object.
    ls_log-extnumber = iv_extnumber.
    ls_log-aluser = sy-uname.
    ls_log-alprog = sy-cprog.
    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log      = ls_log
      IMPORTING
        e_log_handle = rv_handle
      EXCEPTIONS
        OTHERS       = 1.
    IF sy-subrc <> 0.
      CLEAR rv_handle.
    ENDIF.
  ENDMETHOD.


  METHOD save.
    DATA lt_handles TYPE bal_t_logh.

    APPEND iv_handle TO lt_handles.
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_t_log_handle = lt_handles
      EXCEPTIONS
        OTHERS         = 1.
    IF sy-subrc = 0.
      rv_saved = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD add.
    " Free text is limited to 200 characters per message
    DATA lv_chunk TYPE c LENGTH 200.
    DATA lv_len TYPE i.
    DATA lv_off TYPE i.
    DATA lv_take TYPE i.

    lv_len = strlen( iv_text ).
    WHILE lv_off < lv_len.
      lv_take = lv_len - lv_off.
      IF lv_take > 200.
        lv_take = 200.
      ENDIF.
      lv_chunk = iv_text+lv_off(lv_take).
      CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
        EXPORTING
          i_log_handle = iv_handle
          i_msgty      = iv_type
          i_text       = lv_chunk
        EXCEPTIONS
          OTHERS       = 1.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.
      lv_off = lv_off + lv_take.
    ENDWHILE.
  ENDMETHOD.

ENDCLASS.


*----------------------------------------------------------------------*
* Selection screen. Choose the action; the screen shows only its
* fields. Save it as a variant for a job.
*----------------------------------------------------------------------*
DATA gv_number TYPE c LENGTH 40.
DATA gv_jobid TYPE c LENGTH 40.
DATA gv_param TYPE c LENGTH 132.
DATA gv_action TYPE lif_sms=>ty_action.

SELECTION-SCREEN BEGIN OF BLOCK b_act WITH FRAME TITLE t_act.
PARAMETERS p_act LIKE gv_action AS LISTBOX VISIBLE LENGTH 40
                 USER-COMMAND act DEFAULT 'SEND' OBLIGATORY.
PARAMETERS p_dry AS CHECKBOX DEFAULT 'X' MODIF ID snd.
PARAMETERS p_logtx AS CHECKBOX MODIF ID snd.
PARAMETERS p_nlen AS CHECKBOX MODIF ID nln.
SELECTION-SCREEN END OF BLOCK b_act.

SELECTION-SCREEN BEGIN OF BLOCK b_msg WITH FRAME TITLE t_msg.
SELECT-OPTIONS s_no FOR gv_number NO INTERVALS MODIF ID num.
PARAMETERS p_head TYPE c LENGTH 11 LOWER CASE MODIF ID hdr.
SELECTION-SCREEN COMMENT /1(70) c_txt MODIF ID txt.
PARAMETERS p_txt1 TYPE c LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID txt.
PARAMETERS p_txt2 TYPE c LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID txt.
PARAMETERS p_txt3 TYPE c LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID txt.
PARAMETERS p_txt4 TYPE c LENGTH 132 LOWER CASE VISIBLE LENGTH 45
                  MODIF ID txt.
PARAMETERS p_enc TYPE c LENGTH 7 AS LISTBOX VISIBLE LENGTH 40
                 DEFAULT 'AUTO' MODIF ID enc.
PARAMETERS p_iys TYPE c LENGTH 2 AS LISTBOX VISIBLE LENGTH 40
                 DEFAULT '0' MODIF ID iys.
SELECTION-SCREEN END OF BLOCK b_msg.

SELECTION-SCREEN BEGIN OF BLOCK b_tpl WITH FRAME TITLE t_tpl.
PARAMETERS p_tid TYPE n LENGTH 9 MODIF ID tpl.
SELECTION-SCREEN COMMENT /1(70) c_tpar MODIF ID tpl.
SELECT-OPTIONS s_tpar FOR gv_param NO INTERVALS LOWER CASE
                      MODIF ID tpl.
SELECTION-SCREEN END OF BLOCK b_tpl.

SELECTION-SCREEN BEGIN OF BLOCK b_sch WITH FRAME TITLE t_sch.
PARAMETERS p_sdate TYPE d MODIF ID sch.
PARAMETERS p_stime TYPE t MODIF ID sch.
PARAMETERS p_edate TYPE d MODIF ID sch.
PARAMETERS p_etime TYPE t MODIF ID sch.
PARAMETERS p_ref TYPE c LENGTH 50 LOWER CASE MODIF ID sch.
SELECTION-SCREEN END OF BLOCK b_sch.

SELECTION-SCREEN BEGIN OF BLOCK b_job WITH FRAME TITLE t_job.
SELECTION-SCREEN COMMENT /1(70) c_job MODIF ID job.
SELECT-OPTIONS s_job FOR gv_jobid NO INTERVALS MODIF ID job.
PARAMETERS p_rfrom TYPE d MODIF ID rdt.
PARAMETERS p_rto TYPE d MODIF ID rdt.
PARAMETERS p_sendd TYPE d MODIF ID sdt.
SELECTION-SCREEN COMMENT /1(70) c_inb MODIF ID inb.
PARAMETERS p_full AS CHECKBOX MODIF ID inb.
SELECTION-SCREEN END OF BLOCK b_job.

SELECTION-SCREEN BEGIN OF BLOCK b_tls WITH FRAME TITLE t_tls.
PARAMETERS p_tsrch TYPE c LENGTH 50 LOWER CASE MODIF ID tls.
PARAMETERS p_tcont TYPE c LENGTH 50 LOWER CASE MODIF ID tls.
PARAMETERS p_ttype TYPE c LENGTH 40 MODIF ID tls.
PARAMETERS p_tpub AS CHECKBOX DEFAULT 'X' MODIF ID tls.
PARAMETERS p_tpage TYPE n LENGTH 4 MODIF ID tls.
SELECTION-SCREEN END OF BLOCK b_tls.

SELECTION-SCREEN BEGIN OF BLOCK b_con WITH FRAME TITLE t_con.
PARAMETERS p_dest TYPE rfcdest DEFAULT 'ZCHE_NETGSM' OBLIGATORY.
PARAMETERS p_dext TYPE rfcdest DEFAULT 'ZCHE_NETGSM_EXT'
                  MODIF ID ext.
SELECTION-SCREEN END OF BLOCK b_con.


*----------------------------------------------------------------------*
* The program around the classes: screen, list, job log, popup
*----------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS set_texts.
    CLASS-METHODS set_screen.
    CLASS-METHODS run.

    "! Is a screen group (MODIF ID) used by this action?
    CLASS-METHODS shows
      IMPORTING
        iv_group      TYPE csequence
        iv_action     TYPE lif_sms=>ty_action
      RETURNING
        value(rv_yes) TYPE abap_bool.

    "! name=value lines to template values
    CLASS-METHODS params_of
      IMPORTING
        it_lines         TYPE string_table
      RETURNING
        value(rt_params) TYPE lif_sms=>ty_params.

  PRIVATE SECTION.
    TYPES ty_texts TYPE STANDARD TABLE OF rsseltexts
                   WITH DEFAULT KEY.

    CLASS-DATA go_sms TYPE REF TO lcl_sms_netgsm.

    CLASS-METHODS set_listboxes.

    CLASS-METHODS run_send.
    CLASS-METHODS run_cancel.
    CLASS-METHODS run_report.
    CLASS-METHODS run_stats.
    CLASS-METHODS run_inbox.
    CLASS-METHODS run_headers.
    CLASS-METHODS run_templates.
    CLASS-METHODS run_length.

    "! The send of the chosen action with the screen's values
    CLASS-METHODS send_from_screen
      IMPORTING
        iv_dry_run       TYPE abap_bool
      RETURNING
        value(rs_result) TYPE lif_sms=>ty_result.

    CLASS-METHODS screen_text
      RETURNING
        value(rv_text) TYPE string.

    CLASS-METHODS screen_numbers
      RETURNING
        value(rt_numbers) TYPE string_table.

    CLASS-METHODS screen_jobids
      RETURNING
        value(rt_jobids) TYPE string_table.

    CLASS-METHODS confirm
      IMPORTING
        iv_title      TYPE string
        iv_question   TYPE string
      RETURNING
        value(rv_yes) TYPE abap_bool.

    CLASS-METHODS show_result
      IMPORTING
        is_result TYPE lif_sms=>ty_result.

    CLASS-METHODS show_length
      IMPORTING
        is_length TYPE lif_sms=>ty_length.

    CLASS-METHODS show_log_state
      IMPORTING
        iv_saved TYPE abap_bool.

    CLASS-METHODS heading
      IMPORTING
        iv_key TYPE csequence.

    CLASS-METHODS write_code
      IMPORTING
        iv_code    TYPE string
        iv_message TYPE string.

    CLASS-METHODS write_long
      IMPORTING
        iv_text   TYPE string
        iv_indent TYPE i DEFAULT 3.

    CLASS-METHODS credits
      IMPORTING
        is_result       TYPE lif_sms=>ty_result
      RETURNING
        value(rv_count) TYPE string.

    "! Success to the job log; an error cancels a background job
    CLASS-METHODS finish
      IMPORTING
        iv_ok   TYPE abap_bool
        iv_text TYPE string.

    CLASS-METHODS add_text
      IMPORTING
        iv_name  TYPE csequence
        iv_kind  TYPE c
      CHANGING
        ct_texts TYPE ty_texts.

    CLASS-METHODS add_value
      IMPORTING
        iv_key    TYPE csequence
        iv_text   TYPE csequence
      CHANGING
        ct_values TYPE vrm_values.
ENDCLASS.


CLASS lcl_app IMPLEMENTATION.

  METHOD set_texts.
    DATA lt_texts TYPE ty_texts.

    t_act = lcl_text=>get( 'T_RUN' ).
    t_msg = lcl_text=>get( 'T_MSG' ).
    t_tpl = lcl_text=>get( 'T_TPL' ).
    t_sch = lcl_text=>get( 'T_SCH' ).
    t_job = lcl_text=>get( 'T_JOB' ).
    t_tls = lcl_text=>get( 'T_TLS' ).
    t_con = lcl_text=>get( 'T_CON' ).
    c_txt = lcl_text=>get( 'C_TXT' ).
    c_tpar = lcl_text=>get( 'C_TPAR' ).
    c_job = lcl_text=>get( 'C_JOB' ).
    c_inb = lcl_text=>get( 'C_INB' ).

    add_text( EXPORTING iv_name = 'P_ACT' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_DRY' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_LOGTX' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_NLEN' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'S_NO' iv_kind = 'S'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_HEAD' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TXT1' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TXT2' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TXT3' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TXT4' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_ENC' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_IYS' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TID' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'S_TPAR' iv_kind = 'S'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_SDATE' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_STIME' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_EDATE' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_ETIME' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_REF' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'S_JOB' iv_kind = 'S'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_RFROM' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_RTO' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_SENDD' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_FULL' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TSRCH' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TCONT' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TTYPE' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TPUB' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_TPAGE' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_DEST' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).
    add_text( EXPORTING iv_name = 'P_DEXT' iv_kind = 'P'
              CHANGING  ct_texts = lt_texts ).

    " If this fails, the screen shows the field names; nothing else
    " changes
    CALL FUNCTION 'SELECTION_TEXTS_MODIFY'
      EXPORTING
        program  = sy-repid
      TABLES
        seltexts = lt_texts
      EXCEPTIONS
        OTHERS   = 1.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
  ENDMETHOD.


  METHOD add_text.
    DATA ls_text TYPE rsseltexts.

    ls_text-name = iv_name.
    ls_text-kind = iv_kind.
    ls_text-text = lcl_text=>get( iv_name ).
    APPEND ls_text TO ct_texts.
  ENDMETHOD.


  METHOD set_screen.
    DATA lv_show TYPE abap_bool.

    set_listboxes( ).
    LOOP AT SCREEN.
      IF screen-group1 IS INITIAL.
        CONTINUE.
      ENDIF.
      lv_show = shows( iv_group  = screen-group1
                       iv_action = p_act ).
      IF lv_show = abap_false.
        screen-active = '0'.
        MODIFY SCREEN.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD shows.
    DATA lv_actions TYPE string.
    DATA lv_action TYPE string.

    CASE iv_group.
      WHEN 'SND' OR 'NUM'.
        lv_actions = `SEND OTP TEMPLATE`.
      WHEN 'HDR' OR 'ENC'.
        lv_actions = `SEND OTP TEMPLATE LENGTH`.
      WHEN 'TXT'.
        lv_actions = `SEND OTP LENGTH`.
      WHEN 'IYS' OR 'SCH'.
        lv_actions = `SEND TEMPLATE`.
      WHEN 'NLN'.
        lv_actions = `SEND`.
      WHEN 'TPL'.
        lv_actions = `TEMPLATE`.
      WHEN 'JOB'.
        lv_actions = `CANCEL REPORT STATS`.
      WHEN 'RDT'.
        lv_actions = `REPORT INBOX`.
      WHEN 'SDT'.
        lv_actions = `STATS`.
      WHEN 'INB'.
        lv_actions = `INBOX`.
      WHEN 'TLS'.
        lv_actions = `TPLLIST`.
      WHEN 'EXT'.
        lv_actions = `TEMPLATE TPLLIST`.
      WHEN OTHERS.
        rv_yes = abap_true.
        RETURN.
    ENDCASE.
    lv_action = iv_action.
    CONCATENATE ` ` lv_actions ` ` INTO lv_actions.
    CONCATENATE ` ` lv_action ` ` INTO lv_action.
    IF lv_actions CS lv_action.
      rv_yes = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD set_listboxes.
    DATA lt_values TYPE vrm_values.
    DATA lv_text TYPE string.

    lv_text = lcl_text=>get( 'ACT_SEND' ).
    add_value( EXPORTING iv_key = lif_sms=>action-send iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_OTP' ).
    add_value( EXPORTING iv_key = lif_sms=>action-otp iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_TEMPLATE' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-template
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_CANCEL' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-cancel
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_REPORT' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-report
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_STATS' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-stats
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_INBOX' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-inbox
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_HEADERS' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-headers
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_TPLLIST' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-templates
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ACT_LENGTH' ).
    add_value( EXPORTING iv_key  = lif_sms=>action-length
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    CALL FUNCTION 'VRM_SET_VALUES'
      EXPORTING
        id     = 'P_ACT'
        values = lt_values
      EXCEPTIONS
        OTHERS = 1.
    IF sy-subrc <> 0.
      CLEAR lt_values.
    ENDIF.

    CLEAR lt_values.
    lv_text = lcl_text=>get( 'ENC_AUTO' ).
    add_value( EXPORTING iv_key  = lif_sms=>encoding-auto
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ENC_TR' ).
    add_value( EXPORTING iv_key  = lif_sms=>encoding-turkish
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ENC_UNICODE' ).
    add_value( EXPORTING iv_key  = lif_sms=>encoding-unicode
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'ENC_ASCII' ).
    add_value( EXPORTING iv_key  = lif_sms=>encoding-ascii
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    CALL FUNCTION 'VRM_SET_VALUES'
      EXPORTING
        id     = 'P_ENC'
        values = lt_values
      EXCEPTIONS
        OTHERS = 1.
    IF sy-subrc <> 0.
      CLEAR lt_values.
    ENDIF.

    CLEAR lt_values.
    lv_text = lcl_text=>get( 'IYS_0' ).
    add_value( EXPORTING iv_key = lif_sms=>iys-info iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'IYS_11' ).
    add_value( EXPORTING iv_key  = lif_sms=>iys-individual
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    lv_text = lcl_text=>get( 'IYS_12' ).
    add_value( EXPORTING iv_key  = lif_sms=>iys-merchant
                         iv_text = lv_text
               CHANGING  ct_values = lt_values ).
    CALL FUNCTION 'VRM_SET_VALUES'
      EXPORTING
        id     = 'P_IYS'
        values = lt_values
      EXCEPTIONS
        OTHERS = 1.
    IF sy-subrc <> 0.
      CLEAR lt_values.
    ENDIF.
  ENDMETHOD.


  METHOD add_value.
    DATA ls_value TYPE vrm_value.

    ls_value-key = iv_key.
    ls_value-text = iv_text.
    APPEND ls_value TO ct_values.
  ENDMETHOD.


  METHOD run.
    CREATE OBJECT go_sms
      EXPORTING
        iv_destination     = p_dest
        iv_ext_destination = p_dext.
    CASE p_act.
      WHEN lif_sms=>action-send OR lif_sms=>action-otp
        OR lif_sms=>action-template.
        run_send( ).
      WHEN lif_sms=>action-cancel.
        run_cancel( ).
      WHEN lif_sms=>action-report.
        run_report( ).
      WHEN lif_sms=>action-stats.
        run_stats( ).
      WHEN lif_sms=>action-inbox.
        run_inbox( ).
      WHEN lif_sms=>action-headers.
        run_headers( ).
      WHEN lif_sms=>action-templates.
        run_templates( ).
      WHEN lif_sms=>action-length.
        run_length( ).
    ENDCASE.
  ENDMETHOD.


  METHOD params_of.
    DATA lv_line TYPE string.
    DATA ls_param TYPE lif_sms=>ty_param.
    DATA lv_off TYPE i.
    DATA lv_rest TYPE i.

    LOOP AT it_lines INTO lv_line.
      IF lv_line IS INITIAL.
        CONTINUE.
      ENDIF.
      CLEAR ls_param.
      FIND '=' IN lv_line MATCH OFFSET lv_off.
      IF sy-subrc <> 0 OR lv_off = 0.
        " No name: send_template rejects it with the line
        ls_param-value = lv_line.
      ELSE.
        ls_param-name = lv_line(lv_off).
        CONDENSE ls_param-name.
        lv_off = lv_off + 1.
        lv_rest = strlen( lv_line ) - lv_off.
        IF lv_rest > 0.
          ls_param-value = lv_line+lv_off(lv_rest).
        ENDIF.
      ENDIF.
      APPEND ls_param TO rt_params.
    ENDLOOP.
  ENDMETHOD.


  METHOD send_from_screen.
    DATA ls_schedule TYPE lif_sms=>ty_schedule.
    DATA lt_lines TYPE string_table.
    DATA lt_params TYPE lif_sms=>ty_params.
    DATA lv_line TYPE string.
    DATA lv_ascii TYPE abap_bool.
    DATA lv_template TYPE i.
    DATA ls_param LIKE LINE OF s_tpar.
    DATA lt_numbers TYPE string_table.
    DATA lv_text TYPE string.

    lt_numbers = screen_numbers( ).
    lv_text = screen_text( ).
    ls_schedule-start_date = p_sdate.
    ls_schedule-start_time = p_stime.
    ls_schedule-stop_date = p_edate.
    ls_schedule-stop_time = p_etime.

    CASE p_act.
      WHEN lif_sms=>action-otp.
        IF p_enc = lif_sms=>encoding-ascii.
          lv_ascii = abap_true.
        ENDIF.
        rs_result = go_sms->send_otp( it_numbers = lt_numbers
                                      iv_text    = lv_text
                                      iv_header  = p_head
                                      iv_ascii   = lv_ascii
                                      iv_dry_run = iv_dry_run ).
      WHEN lif_sms=>action-template.
        LOOP AT s_tpar[] INTO ls_param WHERE sign = 'I'.
          lv_line = ls_param-low.
          APPEND lv_line TO lt_lines.
        ENDLOOP.
        lt_params = params_of( lt_lines ).
        lv_template = p_tid.
        rs_result = go_sms->send_template(
                      it_numbers     = lt_numbers
                      iv_template_id = lv_template
                      it_params      = lt_params
                      iv_header      = p_head
                      iv_encoding    = p_enc
                      iv_iys         = p_iys
                      is_schedule    = ls_schedule
                      iv_reference   = p_ref
                      iv_dry_run     = iv_dry_run ).
      WHEN OTHERS.
        rs_result = go_sms->send( it_numbers   = lt_numbers
                                  iv_text      = lv_text
                                  iv_header    = p_head
                                  iv_encoding  = p_enc
                                  iv_iys       = p_iys
                                  is_schedule  = ls_schedule
                                  iv_reference = p_ref
                                  iv_dry_run   = iv_dry_run ).
    ENDCASE.
  ENDMETHOD.


  METHOD run_send.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA ls_length TYPE lif_sms=>ty_length.
    DATA lv_text TYPE string.
    DATA lv_title TYPE string.
    DATA lv_valid TYPE string.
    DATA lv_credits TYPE string.
    DATA lv_saved TYPE abap_bool.
    DATA lv_sms_text TYPE string.

    " Always check first; a real send only follows a clean preview
    ls_result = send_from_screen( abap_true ).
    IF ls_result-code <> lif_sms=>code-dry_run OR p_dry = abap_true.
      show_result( ls_result ).
      IF p_nlen = abap_true AND p_act = lif_sms=>action-send
         AND ls_result-code = lif_sms=>code-dry_run.
        lv_sms_text = screen_text( ).
        ls_length = go_sms->length( iv_text     = lv_sms_text
                                    iv_encoding = p_enc
                                    iv_header   = p_head ).
        show_length( ls_length ).
      ENDIF.
      IF ls_result-code = lif_sms=>code-dry_run.
        finish( iv_ok = abap_true iv_text = ls_result-message ).
      ELSE.
        finish( iv_ok = abap_false iv_text = ls_result-message ).
      ENDIF.
      RETURN.
    ENDIF.

    IF sy-batch = abap_false.
      lv_valid = ls_result-valid.
      CONDENSE lv_valid.
      lv_credits = credits( ls_result ).
      lv_title = lcl_text=>get( 'POP_TITLE' ).
      lv_text = lcl_text=>get( iv_key = 'POP_QUESTION'
                               iv_1   = lv_valid
                               iv_2   = lv_credits ).
      IF confirm( iv_title = lv_title iv_question = lv_text )
         = abap_false.
        show_result( ls_result ).
        lv_text = lcl_text=>get( 'CANCELLED' ).
        finish( iv_ok = abap_true iv_text = lv_text ).
        RETURN.
      ENDIF.
    ENDIF.

    ls_result = send_from_screen( abap_false ).
    lv_saved = lcl_sms_log=>write( is_result    = ls_result
                                   iv_with_text = p_logtx ).
    show_result( ls_result ).
    show_log_state( lv_saved ).
    CONCATENATE ls_result-code `: ` ls_result-message INTO lv_text.
    IF ls_result-jobid IS NOT INITIAL.
      CONCATENATE lv_text ` (jobid ` ls_result-jobid `)` INTO lv_text.
    ENDIF.
    finish( iv_ok = ls_result-sent iv_text = lv_text ).
  ENDMETHOD.


  METHOD run_cancel.
    DATA lt_jobids TYPE string_table.
    DATA lv_jobid TYPE string.
    DATA ls_answer TYPE lif_sms=>ty_answer.
    DATA lv_title TYPE string.
    DATA lv_text TYPE string.
    DATA lv_ok TYPE abap_bool.
    DATA lv_saved TYPE abap_bool.

    lt_jobids = screen_jobids( ).
    READ TABLE lt_jobids INTO lv_jobid INDEX 1.
    IF sy-batch = abap_false AND lv_jobid IS NOT INITIAL.
      lv_title = lcl_text=>get( 'POP_CANCEL_T' ).
      lv_text = lcl_text=>get( iv_key = 'POP_CANCEL_Q'
                               iv_1   = lv_jobid ).
      IF confirm( iv_title = lv_title iv_question = lv_text )
         = abap_false.
        lv_text = lcl_text=>get( 'NOTHING_DONE' ).
        finish( iv_ok = abap_true iv_text = lv_text ).
        RETURN.
      ENDIF.
    ENDIF.

    ls_answer = go_sms->cancel( lv_jobid ).
    lv_saved = lcl_sms_log=>write_simple(
                 iv_action  = lif_sms=>action-cancel
                 iv_code    = ls_answer-code
                 iv_message = ls_answer-message
                 iv_jobid   = ls_answer-jobid ).
    heading( 'ACT_CANCEL' ).
    write_code( iv_code    = ls_answer-code
                iv_message = ls_answer-message ).
    IF ls_answer-jobid IS NOT INITIAL.
      lv_text = lcl_text=>get( 'L_JOBID' ).
      CONCATENATE lv_text `: ` ls_answer-jobid INTO lv_text.
      write_long( lv_text ).
    ENDIF.
    show_log_state( lv_saved ).
    IF ls_answer-code = lif_sms=>code-ok.
      lv_ok = abap_true.
    ENDIF.
    finish( iv_ok = lv_ok iv_text = ls_answer-message ).
  ENDMETHOD.


  METHOD run_report.
    DATA ls_report TYPE lif_sms=>ty_report.
    DATA ls_line TYPE lif_sms=>ty_report_line.
    DATA lv_ok TYPE abap_bool.
    DATA lv_text TYPE string.
    DATA lv_job TYPE c LENGTH 27.
    DATA lv_num TYPE c LENGTH 15.
    DATA lt_jobids TYPE string_table.

    lt_jobids = screen_jobids( ).
    ls_report = go_sms->report( it_jobids = lt_jobids
                                iv_from   = p_rfrom
                                iv_to     = p_rto ).
    heading( 'L_REPORT' ).
    write_code( iv_code    = ls_report-code
                iv_message = ls_report-message ).
    IF ls_report-lines IS NOT INITIAL.
      SKIP.
      lv_text = lcl_text=>get( 'L_REPORT_COLS' ).
      WRITE: / lv_text COLOR COL_HEADING.
    ENDIF.
    LOOP AT ls_report-lines INTO ls_line.
      lv_text = ls_line-status_text.
      IF ls_line-error_text IS NOT INITIAL.
        CONCATENATE lv_text ` / ` ls_line-error_text INTO lv_text.
      ENDIF.
      lv_job = ls_line-jobid.
      lv_num = ls_line-number.
      WRITE: / lv_job, lv_num, lv_text, ls_line-operator,
               ls_line-delivered, ls_line-reference.
    ENDLOOP.

    IF ls_report-code = `00` OR ls_report-code = `60`.
      lv_ok = abap_true.
    ENDIF.
    finish( iv_ok = lv_ok iv_text = ls_report-message ).
  ENDMETHOD.


  METHOD run_stats.
    DATA lt_jobids TYPE string_table.
    DATA lv_jobid TYPE string.
    DATA ls_stats TYPE lif_sms=>ty_stats.
    DATA ls_line TYPE lif_sms=>ty_stats_line.
    DATA lv_text TYPE string.
    DATA lv_abroad TYPE string.
    DATA lv_ok TYPE abap_bool.

    lt_jobids = screen_jobids( ).
    READ TABLE lt_jobids INTO lv_jobid INDEX 1.
    ls_stats = go_sms->stats( iv_jobid     = lv_jobid
                              iv_send_date = p_sendd ).
    heading( 'L_STATS' ).
    write_code( iv_code    = ls_stats-code
                iv_message = ls_stats-message ).
    LOOP AT ls_stats-lines INTO ls_line.
      lv_text = lcl_text=>get( iv_key = 'L_STATS_LINE'
                               iv_1   = ls_line-total_sms
                               iv_2   = ls_line-total_parts
                               iv_3   = ls_line-charge ).
      CONCATENATE ls_line-status_text `: ` lv_text ` (`
                  ls_line-statement `)` INTO lv_text.
      IF ls_line-domestic = `false`.
        lv_abroad = lcl_text=>get( 'OP_ABROAD' ).
        CONCATENATE lv_text ` ` lv_abroad INTO lv_text.
      ENDIF.
      write_long( lv_text ).
    ENDLOOP.
    IF ls_stats-code = `00`.
      lv_ok = abap_true.
    ENDIF.
    finish( iv_ok = lv_ok iv_text = ls_stats-message ).
  ENDMETHOD.


  METHOD run_inbox.
    DATA ls_inbox TYPE lif_sms=>ty_inbox.
    DATA ls_line TYPE lif_sms=>ty_inbox_line.
    DATA lv_text TYPE string.
    DATA lv_ok TYPE abap_bool.

    ls_inbox = go_sms->inbox( iv_from         = p_rfrom
                              iv_to           = p_rto
                              iv_full_numbers = p_full ).
    heading( 'L_INBOX' ).
    write_code( iv_code    = ls_inbox-code
                iv_message = ls_inbox-message ).
    LOOP AT ls_inbox-lines INTO ls_line.
      SKIP.
      CONCATENATE ls_line-received ls_line-sender ls_line-operator
                  INTO lv_text SEPARATED BY `   `.
      WRITE: / lv_text COLOR COL_KEY.
      write_long( iv_text = ls_line-text iv_indent = 5 ).
    ENDLOOP.
    IF ls_inbox-code = `00` OR ls_inbox-code = `40`.
      lv_ok = abap_true.
    ENDIF.
    finish( iv_ok = lv_ok iv_text = ls_inbox-message ).
  ENDMETHOD.


  METHOD run_headers.
    DATA ls_headers TYPE lif_sms=>ty_headers.
    DATA lv_name TYPE string.
    DATA lv_text TYPE string.
    DATA lv_ok TYPE abap_bool.

    ls_headers = go_sms->headers( ).
    heading( 'L_HEADERS' ).
    write_code( iv_code    = ls_headers-code
                iv_message = ls_headers-message ).
    IF ls_headers-code = `00`.
      lv_ok = abap_true.
      lv_text = lcl_text=>get( 'L_CONN_OK' ).
      WRITE: / lv_text COLOR COL_POSITIVE.
    ENDIF.
    SKIP.
    LOOP AT ls_headers-names INTO lv_name.
      WRITE: /3 lv_name.
    ENDLOOP.
    finish( iv_ok = lv_ok iv_text = ls_headers-message ).
  ENDMETHOD.


  METHOD run_templates.
    DATA ls_templates TYPE lif_sms=>ty_templates.
    DATA ls_line TYPE lif_sms=>ty_template.
    DATA lv_page TYPE i.
    DATA lv_text TYPE string.
    DATA lv_ok TYPE abap_bool.

    lv_page = p_tpage.
    ls_templates = go_sms->templates( iv_page    = lv_page
                                      iv_public  = p_tpub
                                      iv_search  = p_tsrch
                                      iv_type    = p_ttype
                                      iv_content = p_tcont ).
    heading( 'L_TEMPLATES' ).
    write_code( iv_code    = ls_templates-code
                iv_message = ls_templates-message ).
    IF ls_templates-code = `00`.
      lv_ok = abap_true.
      lv_text = lcl_text=>get( iv_key = 'L_PAGE'
                               iv_1   = ls_templates-page
                               iv_2   = ls_templates-pages
                               iv_3   = ls_templates-total ).
      write_long( lv_text ).
    ENDIF.
    LOOP AT ls_templates-lines INTO ls_line.
      SKIP.
      CONCATENATE ls_line-id ls_line-type ls_line-description
                  INTO lv_text SEPARATED BY `   `.
      WRITE: / lv_text COLOR COL_KEY.
      write_long( iv_text = ls_line-content iv_indent = 5 ).
      IF ls_line-parameters IS NOT INITIAL.
        lv_text = lcl_text=>get( iv_key = 'L_PARAMS'
                                 iv_1   = ls_line-parameters ).
        write_long( iv_text = lv_text iv_indent = 5 ).
      ENDIF.
    ENDLOOP.
    finish( iv_ok = lv_ok iv_text = ls_templates-message ).
  ENDMETHOD.


  METHOD run_length.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA ls_length TYPE lif_sms=>ty_length.
    DATA lv_1 TYPE c LENGTH 11.
    DATA lv_2 TYPE c LENGTH 11.
    DATA lv_3 TYPE c LENGTH 11.
    DATA lv_text TYPE string.
    DATA lv_ok TYPE abap_bool.
    DATA lv_sms_text TYPE string.

    lv_sms_text = screen_text( ).
    ls_info = lcl_sms_text=>analyze( iv_text     = lv_sms_text
                                     iv_encoding = p_enc
                                     iv_header   = p_head ).
    heading( 'ACT_LENGTH' ).
    IF ls_info-encoding IS NOT INITIAL.
      lv_1 = ls_info-units.
      lv_2 = ls_info-max_units.
      lv_3 = ls_info-parts.
      CONDENSE: lv_1, lv_2, lv_3.
      lv_text = lcl_text=>get( iv_key = 'L_LOCAL'
                               iv_1   = ls_info-encoding
                               iv_2   = lv_1
                               iv_3   = lv_3 ).
      write_long( lv_text ).
    ENDIF.
    ls_length = go_sms->length( iv_text     = lv_sms_text
                                iv_encoding = p_enc
                                iv_header   = p_head ).
    show_length( ls_length ).
    IF ls_length-code = `00`.
      lv_ok = abap_true.
    ENDIF.
    finish( iv_ok = lv_ok iv_text = ls_length-message ).
  ENDMETHOD.


  METHOD screen_text.
    DATA lv_line TYPE string.
    DATA lt_lines TYPE string_table.

    lv_line = p_txt1.
    APPEND lv_line TO lt_lines.
    lv_line = p_txt2.
    APPEND lv_line TO lt_lines.
    lv_line = p_txt3.
    APPEND lv_line TO lt_lines.
    lv_line = p_txt4.
    APPEND lv_line TO lt_lines.
    LOOP AT lt_lines INTO lv_line.
      IF lv_line IS INITIAL.
        CONTINUE.
      ENDIF.
      IF rv_text IS INITIAL.
        rv_text = lv_line.
      ELSE.
        CONCATENATE rv_text lv_line INTO rv_text
                    SEPARATED BY cl_abap_char_utilities=>newline.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD screen_numbers.
    DATA ls_no LIKE LINE OF s_no.
    DATA lv_number TYPE string.
    DATA lv_ignored TYPE i.
    DATA lv_count TYPE c LENGTH 11.
    DATA lv_text TYPE string.

    LOOP AT s_no[] INTO ls_no.
      IF ls_no-sign = 'I' AND ( ls_no-option = 'EQ'
                                OR ls_no-option IS INITIAL ).
        lv_number = ls_no-low.
        APPEND lv_number TO rt_numbers.
      ELSE.
        lv_ignored = lv_ignored + 1.
      ENDIF.
    ENDLOOP.
    IF lv_ignored > 0.
      lv_count = lv_ignored.
      CONDENSE lv_count.
      lv_text = lcl_text=>get( iv_key = 'IGNORED' iv_1 = lv_count ).
      MESSAGE lv_text TYPE 'S' DISPLAY LIKE 'W'.
    ENDIF.
  ENDMETHOD.


  METHOD screen_jobids.
    DATA ls_job LIKE LINE OF s_job.
    DATA lv_jobid TYPE string.

    LOOP AT s_job[] INTO ls_job WHERE sign = 'I'.
      lv_jobid = ls_job-low.
      APPEND lv_jobid TO rt_jobids.
    ENDLOOP.
  ENDMETHOD.


  METHOD confirm.
    DATA lv_answer TYPE c LENGTH 1.

    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = iv_title
        text_question         = iv_question
        default_button        = '2'
        display_cancel_button = space
      IMPORTING
        answer                = lv_answer
      EXCEPTIONS
        OTHERS                = 1.
    IF sy-subrc = 0 AND lv_answer = '1'.
      rv_yes = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD show_result.
    DATA lv_text TYPE string.
    DATA lv_value TYPE string.
    DATA lv_1 TYPE c LENGTH 11.
    DATA lv_2 TYPE c LENGTH 11.
    DATA lv_3 TYPE c LENGTH 11.
    DATA lv_rejected TYPE i.
    DATA lv_label TYPE c LENGTH 20.
    DATA lv_credits TYPE string.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.

    IF is_result-code = lif_sms=>code-dry_run.
      lv_text = lcl_text=>get( 'L_PREVIEW' ).
      WRITE: / lv_text COLOR COL_TOTAL.
    ELSEIF is_result-sent = abap_true.
      lv_text = lcl_text=>get( 'L_SENT' ).
      WRITE: / lv_text COLOR COL_POSITIVE.
    ELSE.
      lv_text = lcl_text=>get( 'L_NOT_SENT' ).
      WRITE: / lv_text COLOR COL_NEGATIVE.
    ENDIF.
    lv_text = lcl_text=>get( 'ACT_SEND' ).
    CASE is_result-action.
      WHEN lif_sms=>action-otp.
        lv_text = lcl_text=>get( 'ACT_OTP' ).
      WHEN lif_sms=>action-template.
        lv_text = lcl_text=>get( 'ACT_TEMPLATE' ).
    ENDCASE.
    WRITE: / lv_text.
    SKIP.

    lv_label = lcl_text=>get( 'L_RESULT' ).
    WRITE: / lv_label.
    CONCATENATE is_result-code `: ` is_result-message INTO lv_text.
    write_long( lv_text ).
    IF is_result-jobid IS NOT INITIAL.
      lv_label = lcl_text=>get( 'L_JOBID' ).
      WRITE: / lv_label, is_result-jobid.
    ENDIF.
    lv_label = lcl_text=>get( 'L_HEADER' ).
    WRITE: / lv_label, is_result-header.
    IF is_result-template_id > 0.
      lv_label = lcl_text=>get( 'P_TID' ).
      lv_1 = is_result-template_id.
      CONDENSE lv_1.
      WRITE: / lv_label, lv_1.
    ENDIF.
    IF is_result-schedule-start_date IS NOT INITIAL.
      lv_text = lcl_sms_netgsm=>format_time(
                  iv_date  = is_result-schedule-start_date
                  iv_time  = is_result-schedule-start_time
                  iv_style = 'DOT_S' ).
      lv_value = `-`.
      IF is_result-schedule-stop_date IS NOT INITIAL.
        lv_value = lcl_sms_netgsm=>format_time(
                     iv_date  = is_result-schedule-stop_date
                     iv_time  = is_result-schedule-stop_time
                     iv_style = 'DOT_S' ).
      ENDIF.
      lv_text = lcl_text=>get( iv_key = 'L_SCHEDULE'
                               iv_1   = lv_text
                               iv_2   = lv_value ).
      write_long( lv_text ).
    ENDIF.
    IF is_result-reference IS NOT INITIAL.
      lv_label = lcl_text=>get( 'L_REFERENCE' ).
      WRITE: / lv_label, is_result-reference.
    ENDIF.

    IF is_result-text_info-encoding IS NOT INITIAL.
      lv_label = lcl_text=>get( 'L_ENC' ).
      WRITE: / lv_label, is_result-text_info-encoding.
    ENDIF.
    IF is_result-text_info-parts > 0.
      lv_1 = is_result-text_info-units.
      lv_2 = is_result-text_info-max_units.
      lv_3 = is_result-text_info-parts.
      CONDENSE: lv_1, lv_2, lv_3.
      lv_text = lcl_text=>get( iv_key = 'L_SIZE'
                               iv_1   = lv_1
                               iv_2   = lv_2
                               iv_3   = lv_3 ).
      WRITE: / lv_text.
      IF is_result-text_info-suffix > 0.
        lv_text = lcl_text=>get( 'L_SUFFIX' ).
        WRITE: / lv_text.
      ENDIF.
    ENDIF.

    LOOP AT is_result-recipients INTO ls_recipient
         WHERE ok = abap_false.
      lv_rejected = lv_rejected + 1.
    ENDLOOP.
    lv_1 = is_result-valid.
    lv_2 = lv_rejected.
    CONDENSE: lv_1, lv_2.
    SKIP.
    lv_text = lcl_text=>get( iv_key = 'L_RCPT'
                             iv_1   = lv_1
                             iv_2   = lv_2 ).
    WRITE: / lv_text.
    IF is_result-valid > 0
       AND ( is_result-text_info-parts > 0
             OR is_result-action = lif_sms=>action-template ).
      lv_credits = credits( is_result ).
      lv_text = lcl_text=>get( iv_key = 'L_CREDITS'
                               iv_1   = lv_credits ).
      WRITE: / lv_text.
    ENDIF.
    LOOP AT is_result-recipients INTO ls_recipient.
      IF ls_recipient-ok = abap_true.
        WRITE: /3 ls_recipient-masked COLOR COL_POSITIVE.
      ELSE.
        WRITE: /3 ls_recipient-masked COLOR COL_NEGATIVE,
                  ls_recipient-reason.
      ENDIF.
    ENDLOOP.

    IF is_result-code = lif_sms=>code-dry_run.
      IF is_result-text_info-text IS NOT INITIAL.
        SKIP.
        heading( 'L_TEXT' ).
        write_long( is_result-text_info-text ).
      ENDIF.
      SKIP.
      heading( 'L_REQUEST' ).
      write_long( is_result-request ).
    ENDIF.
  ENDMETHOD.


  METHOD show_length.
    DATA lv_text TYPE string.

    SKIP.
    heading( 'L_LENGTH' ).
    IF is_length-code = `00`.
      lv_text = lcl_text=>get( iv_key = 'L_LEN_LINE'
                               iv_1   = is_length-parts
                               iv_2   = is_length-used
                               iv_3   = is_length-left_part ).
      CONCATENATE is_length-encoding `: ` lv_text INTO lv_text.
      write_long( lv_text ).
      lv_text = lcl_text=>get( iv_key = 'L_LEN_LEFT'
                               iv_1   = is_length-left ).
      write_long( lv_text ).
    ELSE.
      write_code( iv_code    = is_length-code
                  iv_message = is_length-message ).
    ENDIF.
  ENDMETHOD.


  METHOD show_log_state.
    DATA lv_text TYPE string.

    SKIP.
    IF iv_saved = abap_true.
      lv_text = lcl_text=>get( iv_key = 'LOG_SAVED'
                               iv_1   = lcl_sms_log=>object ).
    ELSE.
      lv_text = lcl_text=>get( iv_key = 'LOG_NONE'
                               iv_1   = lcl_sms_log=>object ).
    ENDIF.
    write_long( lv_text ).
  ENDMETHOD.


  METHOD heading.
    DATA lv_text TYPE string.

    lv_text = lcl_text=>get( iv_key ).
    WRITE: / lv_text COLOR COL_HEADING.
  ENDMETHOD.


  METHOD write_code.
    DATA lv_text TYPE string.

    CONCATENATE iv_code `: ` iv_message INTO lv_text.
    write_long( lv_text ).
  ENDMETHOD.


  METHOD write_long.
    " Line by line, at most 120 characters each
    DATA lt_lines TYPE string_table.
    DATA lv_line TYPE string.
    DATA lv_len TYPE i.
    DATA lv_off TYPE i.
    DATA lv_take TYPE i.
    DATA lv_blank TYPE i.
    DATA lv_piece TYPE c LENGTH 120.

    SPLIT iv_text AT cl_abap_char_utilities=>newline
          INTO TABLE lt_lines.
    LOOP AT lt_lines INTO lv_line.
      lv_len = strlen( lv_line ).
      IF lv_len = 0.
        SKIP.
        CONTINUE.
      ENDIF.
      lv_off = 0.
      WHILE lv_off < lv_len.
        lv_take = lv_len - lv_off.
        IF lv_take > 120.
          lv_take = 120.
          " Break at the last blank, not inside a word
          FIND ALL OCCURRENCES OF ` ` IN SECTION OFFSET lv_off
               LENGTH lv_take OF lv_line MATCH OFFSET lv_blank.
          IF sy-subrc = 0 AND lv_blank > lv_off.
            lv_take = lv_blank - lv_off + 1.
          ENDIF.
        ENDIF.
        lv_piece = lv_line+lv_off(lv_take).
        WRITE AT /iv_indent lv_piece.
        lv_off = lv_off + lv_take.
      ENDWHILE.
    ENDLOOP.
  ENDMETHOD.


  METHOD credits.
    DATA lv_count TYPE i.
    DATA lv_char TYPE c LENGTH 11.

    IF is_result-action = lif_sms=>action-template.
      " The template text is at Netgsm: parts unknown here
      lv_char = is_result-valid.
      CONDENSE lv_char.
      CONCATENATE lv_char ` x ?` INTO rv_count.
      RETURN.
    ENDIF.
    lv_count = is_result-valid * is_result-text_info-parts.
    lv_char = lv_count.
    CONDENSE lv_char.
    rv_count = lv_char.
  ENDMETHOD.


  METHOD finish.
    IF iv_ok = abap_true.
      MESSAGE iv_text TYPE 'S'.
    ELSEIF sy-batch = abap_true.
      " Ends the job as cancelled, so job monitoring sees it
      MESSAGE iv_text TYPE 'E'.
    ELSE.
      MESSAGE iv_text TYPE 'S' DISPLAY LIKE 'E'.
    ENDIF.
  ENDMETHOD.

ENDCLASS.


INITIALIZATION.
  lcl_app=>set_texts( ).

AT SELECTION-SCREEN OUTPUT.
  lcl_app=>set_screen( ).

START-OF-SELECTION.
  lcl_app=>run( ).


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
FORM send_sms USING it_numbers TYPE string_table
                    iv_text    TYPE csequence
                    iv_header  TYPE csequence
                    iv_dry_run TYPE abap_bool
              CHANGING cv_code    TYPE string
                       cv_jobid   TYPE string
                       cv_message TYPE string.

  PERFORM send_sms_opt USING it_numbers iv_text iv_header iv_dry_run
                             lif_sms=>encoding-auto lif_sms=>iys-info
                             abap_false
                       CHANGING cv_code cv_jobid cv_message.
ENDFORM.


*&---------------------------------------------------------------------*
*& Same with the options: iv_encoding AUTO, TR, UNICODE or ASCII;
*& iv_iys '0', '11' or '12'; iv_log_text 'X' logs the message text.
*&---------------------------------------------------------------------*
FORM send_sms_opt USING it_numbers  TYPE string_table
                        iv_text     TYPE csequence
                        iv_header   TYPE csequence
                        iv_dry_run  TYPE abap_bool
                        iv_encoding TYPE csequence
                        iv_iys      TYPE csequence
                        iv_log_text TYPE abap_bool
                  CHANGING cv_code    TYPE string
                           cv_jobid   TYPE string
                           cv_message TYPE string.

  DATA ls_schedule TYPE lif_sms=>ty_schedule.

  PERFORM send_sms_at USING it_numbers iv_text iv_header iv_dry_run
                            iv_encoding iv_iys iv_log_text
                            ls_schedule ``
                      CHANGING cv_code cv_jobid cv_message.
ENDFORM.


*&---------------------------------------------------------------------*
*& Send later: is_schedule holds date and time in Turkish time (an
*& initial start date means now); iv_reference is your own ID for
*& the delivery report (referansID). Cancel with FORM cancel_sms.
*&---------------------------------------------------------------------*
FORM send_sms_at USING it_numbers   TYPE string_table
                       iv_text      TYPE csequence
                       iv_header    TYPE csequence
                       iv_dry_run   TYPE abap_bool
                       iv_encoding  TYPE csequence
                       iv_iys       TYPE csequence
                       iv_log_text  TYPE abap_bool
                       is_schedule  TYPE lif_sms=>ty_schedule
                       iv_reference TYPE csequence
                 CHANGING cv_code    TYPE string
                          cv_jobid   TYPE string
                          cv_message TYPE string.

  DATA lo_sms TYPE REF TO lcl_sms_netgsm.
  DATA ls_result TYPE lif_sms=>ty_result.
  DATA lv_encoding TYPE lif_sms=>ty_encoding.
  DATA lv_iys TYPE lif_sms=>ty_iys.

  lv_encoding = iv_encoding.
  lv_iys = iv_iys.
  CREATE OBJECT lo_sms.
  ls_result = lo_sms->send( it_numbers   = it_numbers
                            iv_text      = iv_text
                            iv_header    = iv_header
                            iv_encoding  = lv_encoding
                            iv_iys       = lv_iys
                            is_schedule  = is_schedule
                            iv_reference = iv_reference
                            iv_dry_run   = iv_dry_run ).
  IF ls_result-code <> lif_sms=>code-dry_run.
    lcl_sms_log=>write( is_result    = ls_result
                        iv_with_text = iv_log_text ).
  ENDIF.
  cv_code = ls_result-code.
  cv_jobid = ls_result-jobid.
  cv_message = ls_result-message.
ENDFORM.


*&---------------------------------------------------------------------*
*& OTP SMS: one number, one part, no Turkish letters (iv_ascii 'X'
*& turns them into Latin ones). Needs an OTP package at Netgsm.
*&---------------------------------------------------------------------*
FORM send_otp USING iv_number  TYPE csequence
                    iv_text    TYPE csequence
                    iv_header  TYPE csequence
                    iv_ascii   TYPE abap_bool
                    iv_dry_run TYPE abap_bool
              CHANGING cv_code    TYPE string
                       cv_jobid   TYPE string
                       cv_message TYPE string.

  DATA lo_sms TYPE REF TO lcl_sms_netgsm.
  DATA ls_result TYPE lif_sms=>ty_result.
  DATA lt_numbers TYPE string_table.
  DATA lv_number TYPE string.

  lv_number = iv_number.
  APPEND lv_number TO lt_numbers.
  CREATE OBJECT lo_sms.
  ls_result = lo_sms->send_otp( it_numbers = lt_numbers
                                iv_text    = iv_text
                                iv_header  = iv_header
                                iv_ascii   = iv_ascii
                                iv_dry_run = iv_dry_run ).
  IF ls_result-code <> lif_sms=>code-dry_run.
    " An OTP text is a secret code: never logged
    lcl_sms_log=>write( is_result    = ls_result
                        iv_with_text = abap_false ).
  ENDIF.
  cv_code = ls_result-code.
  cv_jobid = ls_result-jobid.
  cv_message = ls_result-message.
ENDFORM.


*&---------------------------------------------------------------------*
*& Template SMS: it_params holds lines name=value, the same values
*& for every number. Template IDs: action "List templates".
*&---------------------------------------------------------------------*
FORM send_template USING it_numbers     TYPE string_table
                         iv_template_id TYPE i
                         it_params      TYPE string_table
                         iv_header      TYPE csequence
                         iv_dry_run     TYPE abap_bool
                   CHANGING cv_code    TYPE string
                            cv_jobid   TYPE string
                            cv_message TYPE string.

  DATA lo_sms TYPE REF TO lcl_sms_netgsm.
  DATA ls_result TYPE lif_sms=>ty_result.
  DATA lt_params TYPE lif_sms=>ty_params.

  lt_params = lcl_app=>params_of( it_params ).
  CREATE OBJECT lo_sms.
  ls_result = lo_sms->send_template( it_numbers     = it_numbers
                                     iv_template_id = iv_template_id
                                     it_params      = lt_params
                                     iv_header      = iv_header
                                     iv_dry_run     = iv_dry_run ).
  IF ls_result-code <> lif_sms=>code-dry_run.
    lcl_sms_log=>write( is_result    = ls_result
                        iv_with_text = abap_false ).
  ENDIF.
  cv_code = ls_result-code.
  cv_jobid = ls_result-jobid.
  cv_message = ls_result-message.
ENDFORM.


*&---------------------------------------------------------------------*
*& Cancels an SMS scheduled for later. cv_code '00' = cancelled.
*&---------------------------------------------------------------------*
FORM cancel_sms USING iv_jobid TYPE csequence
                CHANGING cv_code    TYPE string
                         cv_message TYPE string.

  DATA lo_sms TYPE REF TO lcl_sms_netgsm.
  DATA ls_answer TYPE lif_sms=>ty_answer.

  CREATE OBJECT lo_sms.
  ls_answer = lo_sms->cancel( iv_jobid ).
  lcl_sms_log=>write_simple( iv_action  = lif_sms=>action-cancel
                             iv_code    = ls_answer-code
                             iv_message = ls_answer-message
                             iv_jobid   = ls_answer-jobid ).
  cv_code = ls_answer-code.
  cv_message = ls_answer-message.
ENDFORM.


*&---------------------------------------------------------------------*
*& ABAP Unit tests: Program > Execute > Unit Tests (Ctrl+Shift+F10).
*& They use a test double instead of SM59 and HTTP, so they never
*& reach Netgsm and send nothing. Numbers in them are made up.
*& Written for release 7.00: CL_AUNIT_ASSERT, and risk level and
*& duration as "#AU pseudo comments.
*&---------------------------------------------------------------------*
CLASS ltd_backend DEFINITION FINAL FOR TESTING.
  PUBLIC SECTION.
    INTERFACES lif_sms_backend.

    DATA authorized TYPE abap_bool VALUE abap_true.
    DATA dest_type TYPE rfcdes-rfctype VALUE 'G'.
    DATA status TYPE i VALUE 200.
    DATA reply TYPE string.
    DATA no_answer TYPE abap_bool.
    DATA no_answer_code TYPE string VALUE `NO_CONN`.
    DATA calls TYPE i.
    DATA last_method TYPE string.
    DATA last_path TYPE string.
    DATA last_body TYPE string.
    DATA last_destination TYPE rfcdest.
ENDCLASS.


CLASS ltd_backend IMPLEMENTATION.

  METHOD lif_sms_backend~has_authority.
    rv_yes = authorized.
  ENDMETHOD.


  METHOD lif_sms_backend~destination_type.
    rv_type = dest_type.
  ENDMETHOD.


  METHOD lif_sms_backend~call.
    calls = calls + 1.
    last_destination = iv_destination.
    last_method = iv_method.
    last_path = iv_path.
    last_body = iv_body.
    IF no_answer = abap_true.
      RAISE EXCEPTION TYPE lcx_sms
        EXPORTING
          code = no_answer_code
          text = `timeout`.
    ENDIF.
    rs_http-status = status.
    rs_http-body = reply.
  ENDMETHOD.

ENDCLASS.


*----------------------------------------------------------------------*
* Helpers for the tests: characters by code point, repeated text
*----------------------------------------------------------------------*
CLASS ltu_chars DEFINITION FINAL FOR TESTING.
  PUBLIC SECTION.
    CLASS-METHODS char
      IMPORTING
        iv_code_point  TYPE i
      RETURNING
        value(rv_text) TYPE string.

    "! Text from UTF-8 bytes, for an emoji
    CLASS-METHODS utf8
      IMPORTING
        iv_bytes       TYPE xstring
      RETURNING
        value(rv_text) TYPE string.

    CLASS-METHODS repeat
      IMPORTING
        iv_text        TYPE string
        iv_times       TYPE i
      RETURNING
        value(rv_text) TYPE string.
ENDCLASS.


CLASS ltu_chars IMPLEMENTATION.

  METHOD char.
    DATA lv_char TYPE c LENGTH 1.

    lv_char = cl_abap_conv_in_ce=>uccpi( iv_code_point ).
    rv_text = lv_char.
  ENDMETHOD.


  METHOD utf8.
    DATA lo_in TYPE REF TO cl_abap_conv_in_ce.

    lo_in = cl_abap_conv_in_ce=>create( encoding = 'UTF-8'
                                        input    = iv_bytes ).
    lo_in->read( IMPORTING data = rv_text ).
  ENDMETHOD.


  METHOD repeat.
    DO iv_times TIMES.
      CONCATENATE rv_text iv_text INTO rv_text.
    ENDDO.
  ENDMETHOD.

ENDCLASS.


CLASS ltc_phone DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    METHODS accepts_turkish_forms FOR TESTING.
    METHODS rejects_others FOR TESTING.
    METHODS marks_duplicates FOR TESTING.
    METHODS masks FOR TESTING.

    METHODS assert_number
      IMPORTING
        iv_input  TYPE string
        iv_number TYPE string.

    METHODS assert_rejected
      IMPORTING
        iv_input TYPE string.
ENDCLASS.


CLASS ltc_phone IMPLEMENTATION.

  METHOD accepts_turkish_forms.
    assert_number( iv_input  = `+90 500 111 22 33`
                   iv_number = `5001112233` ).
    assert_number( iv_input  = `0090 500 111 22 33`
                   iv_number = `5001112233` ).
    assert_number( iv_input  = `90 500 1112233`
                   iv_number = `5001112233` ).
    assert_number( iv_input  = `0500 111 22 33`
                   iv_number = `5001112233` ).
    assert_number( iv_input  = `(0500) 111-22-33`
                   iv_number = `5001112233` ).
    assert_number( iv_input  = `500.111.22.33`
                   iv_number = `5001112233` ).
    assert_number( iv_input  = `5001112233`
                   iv_number = `5001112233` ).
  ENDMETHOD.


  METHOD rejects_others.
    " Landline, too short, too long, letters, foreign, sign only
    assert_rejected( `0212 000 00 00` ).
    assert_rejected( `500 111 22` ).
    assert_rejected( `0500 111 22 334` ).
    assert_rejected( `0500 ABC 22 33` ).
    assert_rejected( `+49 151 0000000` ).
    assert_rejected( `+` ).
  ENDMETHOD.


  METHOD marks_duplicates.
    DATA lt_inputs TYPE string_table.
    DATA lt_recipients TYPE lif_sms=>ty_recipients.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.
    DATA lv_count TYPE i.

    APPEND `0500 111 22 33` TO lt_inputs.
    APPEND `` TO lt_inputs.
    APPEND `+905001112233` TO lt_inputs.
    APPEND `5001112244` TO lt_inputs.
    lt_recipients = lcl_sms_phone=>normalize_all( lt_inputs ).

    DESCRIBE TABLE lt_recipients LINES lv_count.
    cl_aunit_assert=>assert_equals( act = lv_count
                                    exp = 3
                                    msg = 'empty entry skipped' ).
    READ TABLE lt_recipients INTO ls_recipient INDEX 2.
    cl_aunit_assert=>assert_equals( act = ls_recipient-ok
                                    exp = abap_false
                                    msg = 'second one is a duplicate' ).
    READ TABLE lt_recipients INTO ls_recipient INDEX 3.
    cl_aunit_assert=>assert_equals( act = ls_recipient-ok
                                    exp = abap_true
                                    msg = 'other number stays' ).
  ENDMETHOD.


  METHOD masks.
    DATA lv_masked TYPE string.

    lv_masked = lcl_sms_phone=>mask( '5001112233' ).
    cl_aunit_assert=>assert_equals( act = lv_masked
                                    exp = `5** *** ** 33`
                                    msg = 'mask' ).
    lv_masked = lcl_sms_phone=>mask_any( '0212 000 00 45' ).
    cl_aunit_assert=>assert_equals( act = lv_masked
                                    exp = `**** *** ** 45`
                                    msg = 'mask_any' ).
  ENDMETHOD.


  METHOD assert_number.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.

    ls_recipient = lcl_sms_phone=>normalize( iv_input ).
    cl_aunit_assert=>assert_equals( act = ls_recipient-ok
                                    exp = abap_true
                                    msg = iv_input ).
    cl_aunit_assert=>assert_equals( act = ls_recipient-number
                                    exp = iv_number
                                    msg = iv_input ).
  ENDMETHOD.


  METHOD assert_rejected.
    DATA ls_recipient TYPE lif_sms=>ty_recipient.

    ls_recipient = lcl_sms_phone=>normalize( iv_input ).
    cl_aunit_assert=>assert_equals( act = ls_recipient-ok
                                    exp = abap_false
                                    msg = iv_input ).
    cl_aunit_assert=>assert_not_initial( act = ls_recipient-reason
                                         msg = iv_input ).
  ENDMETHOD.

ENDCLASS.


CLASS ltc_text DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    METHODS gsm_part_limits FOR TESTING.
    METHODS header_suffix FOR TESTING.
    METHODS turkish_chooses_tr FOR TESTING.
    METHODS soft_turkish_letters FOR TESTING.
    METHODS extension_counts_two FOR TESTING.
    METHODS emoji_chooses_unicode FOR TESTING.
    METHODS tr_refuses_emoji FOR TESTING.
    METHODS ascii_converts FOR TESTING.
    METHODS too_long FOR TESTING.
    METHODS empty_text FOR TESTING.

    "! Analyzes a text of iv_times letters a
    METHODS letters
      IMPORTING
        iv_times       TYPE i
        iv_header      TYPE string
        iv_encoding    TYPE lif_sms=>ty_encoding
                       DEFAULT lif_sms=>encoding-auto
      RETURNING
        value(rs_info) TYPE lif_sms=>ty_text_info.

    METHODS emoji_text
      RETURNING
        value(rv_text) TYPE string.
ENDCLASS.


CLASS ltc_text IMPLEMENTATION.

  METHOD letters.
    DATA lv_text TYPE string.

    lv_text = ltu_chars=>repeat( iv_text = `a` iv_times = iv_times ).
    rs_info = lcl_sms_text=>analyze( iv_text     = lv_text
                                     iv_encoding = iv_encoding
                                     iv_header   = iv_header ).
  ENDMETHOD.


  METHOD emoji_text.
    DATA lv_emoji TYPE string.

    " ok + grinning face (U+1F600), two UTF-16 code units
    lv_emoji = ltu_chars=>utf8( 'F09F9880' ).
    CONCATENATE `ok ` lv_emoji INTO rv_text.
  ENDMETHOD.


  METHOD gsm_part_limits.
    DATA ls_info TYPE lif_sms=>ty_text_info.

    " Numeric sender name: no suffix
    ls_info = letters( iv_times = 160 iv_header = `8500000000` ).
    cl_aunit_assert=>assert_equals( act = ls_info-encoding
                                    exp = lif_sms=>encoding-gsm
                                    msg = 'plain text is GSM' ).
    cl_aunit_assert=>assert_equals( act = ls_info-parts
                                    exp = 1
                                    msg = '160 fit one part' ).
    ls_info = letters( iv_times = 161 iv_header = `8500000000` ).
    cl_aunit_assert=>assert_equals( act = ls_info-parts
                                    exp = 2
                                    msg = '161 need two parts' ).
    ls_info = letters( iv_times = 307 iv_header = `8500000000` ).
    cl_aunit_assert=>assert_equals( act = ls_info-parts
                                    exp = 3
                                    msg = '307 = 2 x 153 + 1' ).
  ENDMETHOD.


  METHOD header_suffix.
    DATA ls_info TYPE lif_sms=>ty_text_info.

    ls_info = letters( iv_times = 155 iv_header = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_info-suffix
                                    exp = 5
                                    msg = 'suffix for letters' ).
    cl_aunit_assert=>assert_equals( act = ls_info-parts
                                    exp = 1
                                    msg = '155 + 5 = 160' ).
    ls_info = letters( iv_times = 156 iv_header = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_info-parts
                                    exp = 2
                                    msg = '156 + 5 > 160' ).
  ENDMETHOD.


  METHOD turkish_chooses_tr.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA lv_1 TYPE string.
    DATA lv_2 TYPE string.
    DATA lv_text TYPE string.

    " Capital I with dot and s with cedilla: 2 + 2 characters
    lv_1 = ltu_chars=>char( 304 ).
    lv_2 = ltu_chars=>char( 351 ).
    CONCATENATE lv_1 lv_2 INTO lv_text.
    ls_info = lcl_sms_text=>analyze(
                iv_text     = lv_text
                iv_encoding = lif_sms=>encoding-auto
                iv_header   = '8500000000' ).
    cl_aunit_assert=>assert_equals( act = ls_info-encoding
                                    exp = lif_sms=>encoding-turkish
                                    msg = 'Turkish letters, TR' ).
    cl_aunit_assert=>assert_equals( act = ls_info-units
                                    exp = 4
                                    msg = 'shift letters count 2' ).
  ENDMETHOD.


  METHOD soft_turkish_letters.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA lv_1 TYPE string.
    DATA lv_2 TYPE string.
    DATA lv_text TYPE string.

    " o and u with umlaut are GSM letters: TR, but 1 each
    lv_1 = ltu_chars=>char( 246 ).
    lv_2 = ltu_chars=>char( 252 ).
    CONCATENATE lv_1 lv_2 INTO lv_text.
    ls_info = lcl_sms_text=>analyze(
                iv_text     = lv_text
                iv_encoding = lif_sms=>encoding-auto
                iv_header   = '8500000000' ).
    cl_aunit_assert=>assert_equals( act = ls_info-encoding
                                    exp = lif_sms=>encoding-turkish
                                    msg = 'still Turkish' ).
    cl_aunit_assert=>assert_equals( act = ls_info-units
                                    exp = 2
                                    msg = 'one each' ).
  ENDMETHOD.


  METHOD extension_counts_two.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA lv_euro TYPE string.
    DATA lv_text TYPE string.

    lv_euro = ltu_chars=>char( 8364 ).
    CONCATENATE `10 ` lv_euro ` [x]` INTO lv_text.
    ls_info = lcl_sms_text=>analyze(
                iv_text     = lv_text
                iv_encoding = lif_sms=>encoding-auto
                iv_header   = '8500000000' ).
    cl_aunit_assert=>assert_equals( act = ls_info-encoding
                                    exp = lif_sms=>encoding-gsm
                                    msg = 'GSM extension' ).
    " "10 " 3, euro 2, " " 1, "[" 2, "x" 1, "]" 2
    cl_aunit_assert=>assert_equals( act = ls_info-units
                                    exp = 11
                                    msg = 'extension counts 2' ).
  ENDMETHOD.


  METHOD emoji_chooses_unicode.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA lv_text TYPE string.

    lv_text = emoji_text( ).
    ls_info = lcl_sms_text=>analyze(
                iv_text     = lv_text
                iv_encoding = lif_sms=>encoding-auto
                iv_header   = '8500000000' ).
    cl_aunit_assert=>assert_equals( act = ls_info-encoding
                                    exp = lif_sms=>encoding-unicode
                                    msg = 'emoji, Unicode' ).
    cl_aunit_assert=>assert_equals( act = ls_info-units
                                    exp = 5
                                    msg = 'code units' ).
    ls_info = letters( iv_times    = 71
                       iv_header   = `8500000000`
                       iv_encoding = lif_sms=>encoding-unicode ).
    cl_aunit_assert=>assert_equals( act = ls_info-parts
                                    exp = 2
                                    msg = '71 Unicode = 2 parts' ).
  ENDMETHOD.


  METHOD tr_refuses_emoji.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA lv_text TYPE string.

    lv_text = emoji_text( ).
    ls_info = lcl_sms_text=>analyze(
                iv_text     = lv_text
                iv_encoding = lif_sms=>encoding-turkish
                iv_header   = '8500000000' ).
    cl_aunit_assert=>assert_equals( act = ls_info-ok
                                    exp = abap_false
                                    msg = 'TR cannot send emoji' ).
  ENDMETHOD.


  METHOD ascii_converts.
    DATA ls_info TYPE lif_sms=>ty_text_info.
    DATA lv_u TYPE string.
    DATA lv_s TYPE string.
    DATA lv_capital_i TYPE string.
    DATA lv_dotless_i TYPE string.
    DATA lv_g TYPE string.
    DATA lv_text TYPE string.

    " "Gunes Isigi" written with Turkish letters
    lv_u = ltu_chars=>char( 252 ).
    lv_s = ltu_chars=>char( 351 ).
    lv_capital_i = ltu_chars=>char( 304 ).
    lv_dotless_i = ltu_chars=>char( 305 ).
    lv_g = ltu_chars=>char( 287 ).
    CONCATENATE `G` lv_u `ne` lv_s ` ` lv_capital_i lv_s lv_dotless_i
                lv_g lv_dotless_i INTO lv_text.
    ls_info = lcl_sms_text=>analyze(
                iv_text     = lv_text
                iv_encoding = lif_sms=>encoding-ascii
                iv_header   = '8500000000' ).
    cl_aunit_assert=>assert_equals( act = ls_info-text
                                    exp = `Gunes Isigi`
                                    msg = 'Latin letters' ).
    cl_aunit_assert=>assert_equals( act = ls_info-encoding
                                    exp = lif_sms=>encoding-gsm
                                    msg = 'plain GSM after it' ).
  ENDMETHOD.


  METHOD too_long.
    DATA ls_info TYPE lif_sms=>ty_text_info.

    ls_info = letters( iv_times = 912 iv_header = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_info-ok
                                    exp = abap_true
                                    msg = '912 GSM characters fit' ).
    cl_aunit_assert=>assert_equals( act = ls_info-parts
                                    exp = 6
                                    msg = 'in 6 parts' ).
    ls_info = letters( iv_times = 913 iv_header = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_info-ok
                                    exp = abap_false
                                    msg = '913 do not' ).
  ENDMETHOD.


  METHOD empty_text.
    DATA ls_info TYPE lif_sms=>ty_text_info.

    ls_info = letters( iv_times = 0 iv_header = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_info-ok
                                    exp = abap_false
                                    msg = 'empty' ).
  ENDMETHOD.

ENDCLASS.


CLASS ltc_json DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    METHODS reads_flat FOR TESTING RAISING lcx_sms.
    METHODS reads_arrays FOR TESTING RAISING lcx_sms.
    METHODS keeps_blanks_and_escapes FOR TESTING RAISING lcx_sms.
    METHODS rejects_broken FOR TESTING.
    METHODS escapes FOR TESTING.

    METHODS assert_value
      IMPORTING
        it_values TYPE lcl_sms_json=>ty_values
        iv_path   TYPE string
        iv_exp    TYPE string.

    METHODS assert_broken
      IMPORTING
        iv_json TYPE string.
ENDCLASS.


CLASS ltc_json IMPLEMENTATION.

  METHOD assert_value.
    DATA lv_act TYPE string.

    lv_act = lcl_sms_json=>value_of( it_values = it_values
                                     iv_path   = iv_path ).
    cl_aunit_assert=>assert_equals( act = lv_act
                                    exp = iv_exp
                                    msg = iv_path ).
  ENDMETHOD.


  METHOD assert_broken.
    TRY.
        lcl_sms_json=>parse( iv_json ).
        cl_aunit_assert=>fail( iv_json ).
      CATCH lcx_sms.
        RETURN.
    ENDTRY.
  ENDMETHOD.


  METHOD reads_flat.
    DATA lv_json TYPE string.
    DATA lt_values TYPE lcl_sms_json=>ty_values.

    CONCATENATE `{"code":"00","jobid":"17377215342605050417149344",`
                `"description":"queued"}` INTO lv_json.
    lt_values = lcl_sms_json=>parse( lv_json ).
    assert_value( it_values = lt_values
                  iv_path   = `jobid`
                  iv_exp    = `17377215342605050417149344` ).
    assert_value( it_values = lt_values
                  iv_path   = `description`
                  iv_exp    = `queued` ).
  ENDMETHOD.


  METHOD reads_arrays.
    DATA lv_json TYPE string.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA lv_has TYPE abap_bool.

    CONCATENATE `{ "code" : "00", "jobs" : [ {"jobid":"1","status":1},`
                ` {"jobid":"2","status":"3","x":null,"y":true} ],`
                ` "empty":[], "obj":{} }` INTO lv_json.
    lt_values = lcl_sms_json=>parse( lv_json ).
    assert_value( it_values = lt_values
                  iv_path   = `jobs/1/status`
                  iv_exp    = `1` ).
    assert_value( it_values = lt_values
                  iv_path   = `jobs/2/status`
                  iv_exp    = `3` ).
    assert_value( it_values = lt_values
                  iv_path   = `jobs/2/y`
                  iv_exp    = `true` ).
    lv_has = lcl_sms_json=>has( it_values = lt_values
                                iv_path   = `jobs/3/jobid` ).
    cl_aunit_assert=>assert_equals( act = lv_has
                                    exp = abap_false
                                    msg = 'no third row' ).
  ENDMETHOD.


  METHOD keeps_blanks_and_escapes.
    DATA lv_json TYPE string.
    DATA lt_values TYPE lcl_sms_json=>ty_values.
    DATA lv_capital_i TYPE string.
    DATA lv_exp TYPE string.

    CONCATENATE `{"a":" x y ","b":"q\"\\n\\\"",`
                `"c":"İ z"}` INTO lv_json.
    lt_values = lcl_sms_json=>parse( lv_json ).
    assert_value( it_values = lt_values
                  iv_path   = `a`
                  iv_exp    = ` x y ` ).
    assert_value( it_values = lt_values
                  iv_path   = `b`
                  iv_exp    = `q"\n\"` ).
    lv_capital_i = ltu_chars=>char( 304 ).
    CONCATENATE lv_capital_i ` z` INTO lv_exp.
    assert_value( it_values = lt_values
                  iv_path   = `c`
                  iv_exp    = lv_exp ).
  ENDMETHOD.


  METHOD rejects_broken.
    assert_broken( `{"code":"00"` ).
    assert_broken( `<html>` ).
    assert_broken( `{"code" "00"}` ).
    assert_broken( `{"a":"open}` ).
  ENDMETHOD.


  METHOD escapes.
    DATA lv_text TYPE string.
    DATA lv_act TYPE string.

    CONCATENATE `a"b\c` cl_abap_char_utilities=>newline `d`
                INTO lv_text.
    lv_act = lcl_sms_json=>escape( lv_text ).
    cl_aunit_assert=>assert_equals( act = lv_act
                                    exp = `a\"b\\c\nd`
                                    msg = 'escape' ).
  ENDMETHOD.

ENDCLASS.


CLASS ltc_send DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    DATA mo_backend TYPE REF TO ltd_backend.
    DATA mo_cut TYPE REF TO lcl_sms_netgsm.
    DATA mt_numbers TYPE string_table.

    METHODS setup.
    METHODS dry_run_calls_nothing FOR TESTING.
    METHODS sends_and_reads_jobid FOR TESTING.
    METHODS body_has_netgsm_fields FOR TESTING.
    METHODS turkish_body FOR TESTING.
    METHODS netgsm_error_codes FOR TESTING.
    METHODS no_authority FOR TESTING.
    METHODS no_destination FOR TESTING.
    METHODS no_valid_number FOR TESTING.
    METHODS bad_header FOR TESTING.
    METHODS no_answer_is_unsure FOR TESTING.
    METHODS untrusted_is_not_sent FOR TESTING.
    METHODS http_error FOR TESTING.
    METHODS plain_text_answer FOR TESTING.
    METHODS report_reads_jobs FOR TESTING.
    METHODS report_limits FOR TESTING.
    METHODS lists_headers FOR TESTING.

    METHODS send
      IMPORTING
        iv_dry_run       TYPE abap_bool DEFAULT abap_false
        iv_header        TYPE string DEFAULT `FIRMA`
        iv_text          TYPE string DEFAULT `Job ZFI_CLOSE failed`
      RETURNING
        value(rs_result) TYPE lif_sms=>ty_result.

    METHODS assert_contains
      IMPORTING
        iv_text TYPE string
        iv_part TYPE string.

    METHODS assert_lacks
      IMPORTING
        iv_text TYPE string
        iv_part TYPE string.
ENDCLASS.


CLASS ltc_send IMPLEMENTATION.

  METHOD setup.
    CREATE OBJECT mo_backend.
    CREATE OBJECT mo_cut
      EXPORTING
        iv_destination     = 'ZCHE_TEST'
        iv_ext_destination = 'ZCHE_TEST_EXT'
        io_backend         = mo_backend.
    CLEAR mt_numbers.
    APPEND `0500 111 22 33` TO mt_numbers.
    APPEND `0500 111 22 44` TO mt_numbers.
    APPEND `0212 000 00 00` TO mt_numbers.
  ENDMETHOD.


  METHOD send.
    rs_result = mo_cut->send( it_numbers = mt_numbers
                              iv_text    = iv_text
                              iv_header  = iv_header
                              iv_dry_run = iv_dry_run ).
  ENDMETHOD.


  METHOD assert_contains.
    IF iv_text NS iv_part.
      cl_aunit_assert=>fail( iv_part ).
    ENDIF.
  ENDMETHOD.


  METHOD assert_lacks.
    IF iv_text CS iv_part.
      cl_aunit_assert=>fail( iv_part ).
    ENDIF.
  ENDMETHOD.


  METHOD dry_run_calls_nothing.
    DATA ls_result TYPE lif_sms=>ty_result.

    ls_result = send( iv_dry_run = abap_true ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-dry_run
                                    msg = 'dry run' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
    cl_aunit_assert=>assert_equals( act = ls_result-valid
                                    exp = 2
                                    msg = 'two valid numbers' ).
    " The preview shows masked numbers only
    assert_lacks( iv_text = ls_result-request iv_part = `5001112233` ).
    assert_contains( iv_text = ls_result-request
                     iv_part = `"no":"5** *** ** 33"` ).
  ENDMETHOD.


  METHOD sends_and_reads_jobid.
    DATA ls_result TYPE lif_sms=>ty_result.

    mo_backend->reply =
      `{"code":"00","jobid":"1737721534","description":"queued"}`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = `00`
                                    msg = 'code' ).
    cl_aunit_assert=>assert_equals( act = ls_result-sent
                                    exp = abap_true
                                    msg = 'sent' ).
    cl_aunit_assert=>assert_equals( act = ls_result-jobid
                                    exp = `1737721534`
                                    msg = 'jobid' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 1
                                    msg = 'one call, no retry' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_method
                                    exp = `POST`
                                    msg = 'method' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = `/sms/rest/v2/send`
                                    msg = 'path' ).
  ENDMETHOD.


  METHOD body_has_netgsm_fields.
    DATA lv_body TYPE string.

    mo_backend->reply = `{"code":"00","jobid":"1"}`.
    send( ).
    lv_body = mo_backend->last_body.
    assert_contains( iv_text = lv_body
                     iv_part = `{"msgheader":"FIRMA",` ).
    assert_contains( iv_text = lv_body
                     iv_part = `"iysfilter":"0"` ).
    assert_contains(
      iv_text = lv_body
      iv_part = `{"msg":"Job ZFI_CLOSE failed","no":"5001112233"}` ).
    assert_contains( iv_text = lv_body
                     iv_part = `"no":"5001112244"` ).
    " Rejected number not sent; plain GSM needs no encoding field
    assert_lacks( iv_text = lv_body iv_part = `0212` ).
    assert_lacks( iv_text = lv_body iv_part = `"encoding"` ).
  ENDMETHOD.


  METHOD turkish_body.
    DATA lv_s TYPE string.
    DATA lv_text TYPE string.

    lv_s = ltu_chars=>char( 351 ).
    CONCATENATE `Ba` lv_s `ar` cl_abap_char_utilities=>newline `"ok"`
                INTO lv_text.
    mo_backend->reply = `{"code":"00","jobid":"1"}`.
    send( iv_text = lv_text ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `"encoding":"TR"` ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `\n\"ok\"` ).
  ENDMETHOD.


  METHOD netgsm_error_codes.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA lv_exp TYPE string.

    mo_backend->reply = `{"code":"30","jobid":null,"description":""}`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-sent
                                    exp = abap_false
                                    msg = '30 is not sent' ).
    lv_exp = lcl_text=>get( 'C30' ).
    cl_aunit_assert=>assert_equals( act = ls_result-message
                                    exp = lv_exp
                                    msg = '30 explained' ).
    mo_backend->reply = `{"code":"40"}`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = `40`
                                    msg = '40' ).
    mo_backend->reply = `{"code":"85"}`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-sent
                                    exp = abap_false
                                    msg = '85 is not sent' ).
  ENDMETHOD.


  METHOD no_authority.
    DATA ls_result TYPE lif_sms=>ty_result.

    mo_backend->authorized = abap_false.
    ls_result = send( iv_dry_run = abap_true ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-no_auth
                                    msg = 'preview checks too' ).
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-no_auth
                                    msg = 'no authority' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
  ENDMETHOD.


  METHOD no_destination.
    DATA ls_result TYPE lif_sms=>ty_result.

    CLEAR mo_backend->dest_type.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-no_dest
                                    msg = 'missing' ).
    mo_backend->dest_type = '3'.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-no_dest
                                    msg = 'wrong type' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
  ENDMETHOD.


  METHOD no_valid_number.
    DATA ls_result TYPE lif_sms=>ty_result.

    CLEAR mt_numbers.
    APPEND `0212 000 00 00` TO mt_numbers.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_number
                                    msg = 'no valid number' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
  ENDMETHOD.


  METHOD bad_header.
    DATA ls_result TYPE lif_sms=>ty_result.

    ls_result = send( iv_header = `` ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'no header' ).
    ls_result = send( iv_header = `AB` ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'too short' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
  ENDMETHOD.


  METHOD no_answer_is_unsure.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA lv_unsure TYPE string.

    mo_backend->no_answer = abap_true.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-no_conn
                                    msg = 'no connection' ).
    cl_aunit_assert=>assert_equals( act = ls_result-sent
                                    exp = abap_false
                                    msg = 'not marked as sent' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 1
                                    msg = 'no retry' ).
    lv_unsure = lcl_text=>get( 'UNSURE' ).
    assert_contains( iv_text = ls_result-message iv_part = lv_unsure ).
  ENDMETHOD.


  METHOD untrusted_is_not_sent.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA lv_unsure TYPE string.

    mo_backend->no_answer = abap_true.
    mo_backend->no_answer_code = lif_sms=>code-no_trust.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-no_trust
                                    msg = 'certificate' ).
    " The handshake failed, so the program is sure nothing went out
    lv_unsure = lcl_text=>get( 'UNSURE' ).
    assert_lacks( iv_text = ls_result-message iv_part = lv_unsure ).
  ENDMETHOD.


  METHOD http_error.
    DATA ls_result TYPE lif_sms=>ty_result.

    mo_backend->status = 406.
    mo_backend->reply = `Not Acceptable`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-http
                                    msg = 'HTTP status' ).
    assert_contains( iv_text = ls_result-message iv_part = `406` ).
    " A code in the body wins over the HTTP status
    mo_backend->reply = `{"code":"30","description":"x"}`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = `30`
                                    msg = '406 with a code' ).
  ENDMETHOD.


  METHOD plain_text_answer.
    DATA ls_result TYPE lif_sms=>ty_result.

    mo_backend->reply = `30`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = `30`
                                    msg = 'plain code' ).
    mo_backend->reply = `<html>error</html>`.
    ls_result = send( ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_reply
                                    msg = 'unreadable' ).
  ENDMETHOD.


  METHOD report_reads_jobs.
    DATA lt_jobids TYPE string_table.
    DATA ls_report TYPE lif_sms=>ty_report.
    DATA ls_line TYPE lif_sms=>ty_report_line.
    DATA lv_count TYPE i.
    DATA lv_exp TYPE string.

    APPEND `1737721534` TO lt_jobids.
    CONCATENATE
      `{"code":"00","jobs":[`
      `{"jobid":"1737721534","number":"905001112233","status":"1",`
      `"operator":"30","msglen":1,"deliveredDate":"07.11.2026",`
      `"errorCode":"0"},`
      `{"jobid":"1737721534","number":"905001112244","status":"2",`
      `"operator":"10","errorCode":"102"}],"description":"success"}`
      INTO mo_backend->reply.
    ls_report = mo_cut->report( it_jobids = lt_jobids ).

    cl_aunit_assert=>assert_equals( act = mo_backend->last_body
                                    exp = `{"jobids":["1737721534"]}`
                                    msg = 'request' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = `/sms/rest/v2/report`
                                    msg = 'path' ).
    DESCRIBE TABLE ls_report-lines LINES lv_count.
    cl_aunit_assert=>assert_equals( act = lv_count
                                    exp = 2
                                    msg = 'two lines' ).
    READ TABLE ls_report-lines INTO ls_line INDEX 1.
    lv_exp = lcl_text=>get( 'S1' ).
    cl_aunit_assert=>assert_equals( act = ls_line-status_text
                                    exp = lv_exp
                                    msg = 'delivered' ).
    cl_aunit_assert=>assert_equals( act = ls_line-operator
                                    exp = `Turkcell`
                                    msg = 'operator' ).
    assert_lacks( iv_text = ls_line-number iv_part = `5001112233` ).
    READ TABLE ls_report-lines INTO ls_line INDEX 2.
    lv_exp = lcl_text=>get( 'E102' ).
    cl_aunit_assert=>assert_equals( act = ls_line-error_text
                                    exp = lv_exp
                                    msg = 'operator error' ).
  ENDMETHOD.


  METHOD report_limits.
    DATA lt_jobids TYPE string_table.
    DATA ls_report TYPE lif_sms=>ty_report.

    ls_report = mo_cut->report( it_jobids = lt_jobids ).
    cl_aunit_assert=>assert_equals( act = ls_report-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'none' ).
    DO 51 TIMES.
      APPEND `1` TO lt_jobids.
    ENDDO.
    ls_report = mo_cut->report( it_jobids = lt_jobids ).
    cl_aunit_assert=>assert_equals( act = ls_report-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'too many' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
  ENDMETHOD.


  METHOD lists_headers.
    DATA ls_headers TYPE lif_sms=>ty_headers.
    DATA lv_count TYPE i.

    mo_backend->reply = `{"code":"00","msgheaders":["FIRMA","FIRMA2"]}`.
    ls_headers = mo_cut->headers( ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_method
                                    exp = `GET`
                                    msg = 'GET' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = `/sms/rest/v2/msgheader`
                                    msg = 'path' ).
    DESCRIBE TABLE ls_headers-names LINES lv_count.
    cl_aunit_assert=>assert_equals( act = lv_count
                                    exp = 2
                                    msg = 'two names' ).
  ENDMETHOD.

ENDCLASS.


CLASS ltc_services DEFINITION FINAL FOR TESTING.
  "#AU Risk_Level Harmless
  "#AU Duration Short
  PRIVATE SECTION.
    DATA mo_backend TYPE REF TO ltd_backend.
    DATA mo_cut TYPE REF TO lcl_sms_netgsm.
    DATA mt_numbers TYPE string_table.

    METHODS setup.
    METHODS schedule_and_reference FOR TESTING.
    METHODS schedule_order FOR TESTING.
    METHODS otp_request FOR TESTING.
    METHODS otp_rules FOR TESTING.
    METHODS otp_codes FOR TESTING.
    METHODS template_request FOR TESTING.
    METHODS template_checks FOR TESTING.
    METHODS template_values FOR TESTING.
    METHODS cancel_job FOR TESTING.
    METHODS report_by_dates FOR TESTING.
    METHODS statistics FOR TESTING.
    METHODS inbox_messages FOR TESTING.
    METHODS template_list FOR TESTING.
    METHODS netgsm_length FOR TESTING.
    METHODS helpers FOR TESTING.

    METHODS assert_contains
      IMPORTING
        iv_text TYPE string
        iv_part TYPE string.

    METHODS assert_text
      IMPORTING
        iv_act TYPE string
        iv_key TYPE string
        iv_1   TYPE string OPTIONAL.
ENDCLASS.


CLASS ltc_services IMPLEMENTATION.

  METHOD setup.
    CREATE OBJECT mo_backend.
    CREATE OBJECT mo_cut
      EXPORTING
        iv_destination     = 'ZCHE_TEST'
        iv_ext_destination = 'ZCHE_TEST_EXT'
        io_backend         = mo_backend.
    CLEAR mt_numbers.
    APPEND `0500 111 22 33` TO mt_numbers.
  ENDMETHOD.


  METHOD assert_contains.
    IF iv_text NS iv_part.
      cl_aunit_assert=>fail( iv_part ).
    ENDIF.
  ENDMETHOD.


  METHOD assert_text.
    DATA lv_exp TYPE string.

    lv_exp = lcl_text=>get( iv_key = iv_key iv_1 = iv_1 ).
    cl_aunit_assert=>assert_equals( act = iv_act
                                    exp = lv_exp
                                    msg = iv_key ).
  ENDMETHOD.


  METHOD schedule_and_reference.
    DATA ls_schedule TYPE lif_sms=>ty_schedule.
    DATA ls_result TYPE lif_sms=>ty_result.

    ls_schedule-start_date = '20261108'.
    ls_schedule-start_time = '093000'.
    ls_schedule-stop_date = '20261108'.
    ls_schedule-stop_time = '180000'.
    mo_backend->reply = `{"code":"00","jobid":"77"}`.
    ls_result = mo_cut->send( it_numbers   = mt_numbers
                              iv_text      = `Toplanti 10:00`
                              iv_header    = `FIRMA`
                              is_schedule  = ls_schedule
                              iv_reference = `SAP-4711`
                              iv_dry_run   = abap_false ).
    cl_aunit_assert=>assert_equals( act = ls_result-jobid
                                    exp = `77`
                                    msg = 'job ID' ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `"startdate":"081120260930"` ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `,"stopdate":"081120261800"` ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `"referansID":"SAP-4711"` ).
  ENDMETHOD.


  METHOD schedule_order.
    DATA ls_schedule TYPE lif_sms=>ty_schedule.
    DATA ls_result TYPE lif_sms=>ty_result.

    ls_schedule-start_date = '20261108'.
    ls_schedule-start_time = '093000'.
    ls_schedule-stop_date = '20261108'.
    ls_schedule-stop_time = '080000'.
    ls_result = mo_cut->send( it_numbers  = mt_numbers
                              iv_text     = `x`
                              iv_header   = `FIRMA`
                              is_schedule = ls_schedule
                              iv_dry_run  = abap_false ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'stop before start' ).
    CLEAR ls_schedule.
    ls_schedule-stop_date = '20261108'.
    ls_result = mo_cut->send( it_numbers  = mt_numbers
                              iv_text     = `x`
                              iv_header   = `FIRMA`
                              is_schedule = ls_schedule
                              iv_dry_run  = abap_false ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'stop without start' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
  ENDMETHOD.


  METHOD otp_request.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA lv_exp TYPE string.

    mo_backend->reply = `{"jobid":"88","code":"00","description":"x"}`.
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = `Kod: 123456`
                                  iv_header  = `FIRMA`
                                  iv_dry_run = abap_false ).
    cl_aunit_assert=>assert_equals( act = ls_result-sent
                                    exp = abap_true
                                    msg = 'sent' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = `/sms/rest/v2/otp`
                                    msg = 'path' ).
    CONCATENATE `{"msgheader":"FIRMA","msg":"Kod: 123456",`
                `"no":"5001112233"}` INTO lv_exp.
    cl_aunit_assert=>assert_equals( act = mo_backend->last_body
                                    exp = lv_exp
                                    msg = 'body' ).
    cl_aunit_assert=>assert_equals( act = ls_result-text_info-parts
                                    exp = 1
                                    msg = 'one part' ).
  ENDMETHOD.


  METHOD otp_rules.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA lv_text TYPE string.
    DATA lv_s TYPE string.

    " Two numbers
    APPEND `0500 111 22 44` TO mt_numbers.
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = `Kod 1`
                                  iv_header  = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_number
                                    msg = 'one number only' ).
    DELETE mt_numbers INDEX 2.

    " s with cedilla: refused, or turned into s
    lv_s = ltu_chars=>char( 351 ).
    CONCATENATE `Kod ` lv_s `ifre` INTO lv_text.
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = lv_text
                                  iv_header  = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_text
                                    msg = 'Turkish letter' ).
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = lv_text
                                  iv_header  = `FIRMA`
                                  iv_ascii   = abap_true ).
    cl_aunit_assert=>assert_equals( act = ls_result-text_info-text
                                    exp = `Kod sifre`
                                    msg = 'ASCII' ).

    " 155 characters fit with a sender name with letters, 156 not
    lv_text = ltu_chars=>repeat( iv_text = `a` iv_times = 155 ).
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = lv_text
                                  iv_header  = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-dry_run
                                    msg = '155 fit' ).
    CONCATENATE lv_text `a` INTO lv_text.
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = lv_text
                                  iv_header  = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_text
                                    msg = '156 do not' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->calls
                                    exp = 0
                                    msg = 'no HTTP call' ).
  ENDMETHOD.


  METHOD otp_codes.
    DATA ls_result TYPE lif_sms=>ty_result.

    mo_backend->reply = `{"code":"60","description":"no package"}`.
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = `Kod 1`
                                  iv_header  = `FIRMA`
                                  iv_dry_run = abap_false ).
    assert_text( iv_act = ls_result-message iv_key = `OTP_60` ).
    mo_backend->reply = `{"code":"41"}`.
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = `Kod 1`
                                  iv_header  = `FIRMA`
                                  iv_dry_run = abap_false ).
    assert_text( iv_act = ls_result-message iv_key = `C40` ).
    mo_backend->reply = `{"code":"105"}`.
    ls_result = mo_cut->send_otp( it_numbers = mt_numbers
                                  iv_text    = `Kod 1`
                                  iv_header  = `FIRMA`
                                  iv_dry_run = abap_false ).
    assert_text( iv_act = ls_result-message
                 iv_key = `C100`
                 iv_1   = `105` ).
  ENDMETHOD.


  METHOD template_request.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA ls_schedule TYPE lif_sms=>ty_schedule.
    DATA lt_params TYPE lif_sms=>ty_params.
    DATA ls_param TYPE lif_sms=>ty_param.

    ls_param-name = `ad`.
    ls_param-value = `Ali`.
    APPEND ls_param TO lt_params.
    ls_param-name = `talepno`.
    ls_param-value = `123`.
    APPEND ls_param TO lt_params.
    ls_schedule-start_date = '20261108'.
    ls_schedule-start_time = '093000'.
    mo_backend->reply = `{"code":"00","jobid":"99"}`.
    ls_result = mo_cut->send_template( it_numbers     = mt_numbers
                                       iv_template_id = 97
                                       it_params      = lt_params
                                       iv_header      = `FIRMA`
                                       is_schedule    = ls_schedule
                                       iv_dry_run     = abap_false ).
    cl_aunit_assert=>assert_equals( act = ls_result-jobid
                                    exp = `99`
                                    msg = 'job ID' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_destination
                                    exp = 'ZCHE_TEST_EXT'
                                    msg = 'second destination' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = `/sms/rest/v2/template/send`
                                    msg = 'path' ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `"encoding":"TR"` ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `"startdate":"2026-11-08 09:30"` ).
    assert_contains(
      iv_text = mo_backend->last_body
      iv_part = `{"templateId":97,"number":"5001112233","params":` ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `{"ad":"Ali","talepno":"123"}}]}` ).
  ENDMETHOD.


  METHOD template_checks.
    DATA ls_result TYPE lif_sms=>ty_result.
    DATA lt_params TYPE lif_sms=>ty_params.

    ls_result = mo_cut->send_template( it_numbers     = mt_numbers
                                       iv_template_id = 0
                                       it_params      = lt_params
                                       iv_header      = `FIRMA` ).
    cl_aunit_assert=>assert_equals( act = ls_result-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'no template ID' ).
    mo_backend->reply = `{"code":"NOT_FOUND","description":"x"}`.
    ls_result = mo_cut->send_template( it_numbers     = mt_numbers
                                       iv_template_id = 5
                                       it_params      = lt_params
                                       iv_header      = `FIRMA`
                                       iv_dry_run     = abap_false ).
    assert_text( iv_act = ls_result-message
                 iv_key = `TPL_NOT_FOUND` ).
  ENDMETHOD.


  METHOD template_values.
    DATA lt_lines TYPE string_table.
    DATA lt_params TYPE lif_sms=>ty_params.
    DATA ls_param TYPE lif_sms=>ty_param.

    APPEND `ad=Ali` TO lt_lines.
    APPEND `url=a=b` TO lt_lines.
    APPEND `no equal sign` TO lt_lines.
    lt_params = lcl_app=>params_of( lt_lines ).
    READ TABLE lt_params INTO ls_param INDEX 2.
    cl_aunit_assert=>assert_equals( act = ls_param-value
                                    exp = `a=b`
                                    msg = 'first = splits' ).
    READ TABLE lt_params INTO ls_param INDEX 3.
    cl_aunit_assert=>assert_initial( act = ls_param-name
                                     msg = 'no name' ).
  ENDMETHOD.


  METHOD cancel_job.
    DATA ls_answer TYPE lif_sms=>ty_answer.

    mo_backend->reply =
      `{"code":"00","jobid":"123","description":"job canceled"}`.
    ls_answer = mo_cut->cancel( ` 123 ` ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_body
                                    exp = `{"jobid":"123"}`
                                    msg = 'body' ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = `/sms/rest/v2/cancel`
                                    msg = 'path' ).
    assert_text( iv_act = ls_answer-message iv_key = `CANCEL_00` ).
    mo_backend->reply = `{"code":"60","jobid":"123"}`.
    ls_answer = mo_cut->cancel( `123` ).
    assert_text( iv_act = ls_answer-message iv_key = `CANCEL_60` ).
  ENDMETHOD.


  METHOD report_by_dates.
    DATA ls_report TYPE lif_sms=>ty_report.
    DATA lv_exp TYPE string.

    mo_backend->reply = `{"code":"60","jobs":null}`.
    ls_report = mo_cut->report( iv_from = '20261101'
                                iv_to   = '20261107' ).
    CONCATENATE `{"startdate":"01.11.2026 00:00:00",`
                `"stopdate":"07.11.2026 23:59:59"}` INTO lv_exp.
    cl_aunit_assert=>assert_equals( act = mo_backend->last_body
                                    exp = lv_exp
                                    msg = 'body' ).
    assert_text( iv_act = ls_report-message iv_key = `REPORT_60` ).
    ls_report = mo_cut->report( iv_from = '20260101'
                                iv_to   = '20261107' ).
    cl_aunit_assert=>assert_equals( act = ls_report-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'more than 3 months' ).
    ls_report = mo_cut->report( iv_from = '20261101' ).
    cl_aunit_assert=>assert_equals( act = ls_report-code
                                    exp = lif_sms=>code-bad_input
                                    msg = 'one date only' ).
  ENDMETHOD.


  METHOD statistics.
    DATA ls_stats TYPE lif_sms=>ty_stats.
    DATA ls_line TYPE lif_sms=>ty_stats_line.
    DATA lv_count TYPE i.

    CONCATENATE
      `{"stats":[{"status":"repeated","totalMessageLength":0,`
      `"totalSms":1,"chargeStatement":"","statement":"uncharged",`
      `"domestic":true},{"status":"successful",`
      `"totalMessageLength":3,"totalSms":3,"chargeStatement":`
      `"3.0 unit(s) from: ","statement":"charged","domestic":true}],`
      `"description":"success"}`
      INTO mo_backend->reply.
    ls_stats = mo_cut->stats( iv_jobid     = `123`
                              iv_send_date = '20261001' ).
    cl_aunit_assert=>assert_equals( act = ls_stats-code
                                    exp = `00`
                                    msg = 'success without code' ).
    assert_contains( iv_text = mo_backend->last_body
                     iv_part = `"senddate":"2026-10-01 00:00:00"` ).
    DESCRIBE TABLE ls_stats-lines LINES lv_count.
    cl_aunit_assert=>assert_equals( act = lv_count
                                    exp = 2
                                    msg = 'two lines' ).
    READ TABLE ls_stats-lines INTO ls_line INDEX 2.
    assert_text( iv_act = ls_line-status_text
                 iv_key = `ST_successful` ).
    cl_aunit_assert=>assert_equals( act = ls_line-total_parts
                                    exp = `3`
                                    msg = 'parts' ).
  ENDMETHOD.


  METHOD inbox_messages.
    DATA ls_inbox TYPE lif_sms=>ty_inbox.
    DATA lv_exp TYPE string.
    DATA ls_line TYPE lif_sms=>ty_inbox_line.

    CONCATENATE
      `{"code":"00","messages":[{"id":121386491,"gorevId":"1202",`
      `"kayittar":"1770000000000","mesaj":"Tamam","operator":`
      `"Netgsm","gonderen":"5001112233"}],"description":"success"}`
      INTO mo_backend->reply.
    ls_inbox = mo_cut->inbox( iv_from = '20261101'
                              iv_to   = '20261107' ).
    CONCATENATE `/sms/rest/v2/inbox?startdate=011120260000`
                `&stopdate=071120262359` INTO lv_exp.
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = lv_exp
                                    msg = 'path' ).
    READ TABLE ls_inbox-lines INTO ls_line INDEX 1.
    cl_aunit_assert=>assert_equals( act = ls_line-received
                                    exp = `02.02.2026 05:40:00`
                                    msg = 'Turkish time' ).
    cl_aunit_assert=>assert_equals( act = ls_line-sender
                                    exp = `********33`
                                    msg = 'masked' ).
    cl_aunit_assert=>assert_equals( act = ls_line-text
                                    exp = `Tamam`
                                    msg = 'text' ).
    ls_inbox = mo_cut->inbox( ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = `/sms/rest/v2/inbox`
                                    msg = 'only new ones' ).
  ENDMETHOD.


  METHOD template_list.
    DATA ls_templates TYPE lif_sms=>ty_templates.
    DATA lv_exp TYPE string.
    DATA ls_line TYPE lif_sms=>ty_template.

    CONCATENATE
      `{"code":"00","description":"success","templates":[{`
      `"templateId":97,"templateContent":"Merhaba ${ad}",`
      `"type":"SUPPORT_TICKET_UPDATE","description":"Destek",`
      `"registryDate":"11.09.2026 14:30:14","parameters":[`
      `{"id":82,"name":"ad","type":"TEXT","maxLength":50},`
      `{"id":83,"name":"talepno","type":"BIGINT","maxLength":null}`
      `],"public":false}],"page":0,"size":1,"totalElements":2,`
      `"totalPages":2}`
      INTO mo_backend->reply.
    ls_templates = mo_cut->templates( iv_search = `destek talebi` ).
    cl_aunit_assert=>assert_equals( act = mo_backend->last_destination
                                    exp = 'ZCHE_TEST_EXT'
                                    msg = 'second destination' ).
    CONCATENATE `/sms/rest/v2/template/list?page=0&size=50`
                `&includePublic=true&search=destek%20talebi`
                INTO lv_exp.
    cl_aunit_assert=>assert_equals( act = mo_backend->last_path
                                    exp = lv_exp
                                    msg = 'path' ).
    READ TABLE ls_templates-lines INTO ls_line INDEX 1.
    cl_aunit_assert=>assert_equals( act = ls_line-id
                                    exp = `97`
                                    msg = 'ID' ).
    cl_aunit_assert=>assert_equals(
      act = ls_line-parameters
      exp = `ad (TEXT, 50); talepno (BIGINT)`
      msg = 'parameters' ).
    cl_aunit_assert=>assert_equals( act = ls_templates-total
                                    exp = `2`
                                    msg = 'total' ).
  ENDMETHOD.


  METHOD netgsm_length.
    DATA ls_length TYPE lif_sms=>ty_length.
    DATA lv_exp TYPE string.

    CONCATENATE `{"parts":1,"charsUsed":29,"charsLeft":888,`
                `"charsLeftUntilNextPart":131}`
                INTO mo_backend->reply.
    ls_length = mo_cut->length( iv_text   = `Merhaba, sifreniz 123456`
                                iv_header = `FIRMA` ).
    CONCATENATE `{"context":"Merhaba, sifreniz 123456","encoding":0,`
                `"customHeader":true}` INTO lv_exp.
    cl_aunit_assert=>assert_equals( act = mo_backend->last_body
                                    exp = lv_exp
                                    msg = 'body' ).
    cl_aunit_assert=>assert_equals( act = ls_length-code
                                    exp = `00`
                                    msg = 'no code means OK' ).
    cl_aunit_assert=>assert_equals( act = ls_length-used
                                    exp = `29`
                                    msg = 'used' ).
  ENDMETHOD.


  METHOD helpers.
    DATA lv_text TYPE string.
    DATA lv_c TYPE string.

    lv_c = ltu_chars=>char( 231 ).
    CONCATENATE `a b/` lv_c INTO lv_text.
    lv_text = lcl_sms_netgsm=>url_encode( lv_text ).
    cl_aunit_assert=>assert_equals( act = lv_text
                                    exp = `a%20b%2F%C3%A7`
                                    msg = 'URL encoding' ).
    lv_text = lcl_sms_netgsm=>turkish_time( `abc` ).
    cl_aunit_assert=>assert_equals( act = lv_text
                                    exp = `abc`
                                    msg = 'not a number' ).
    lv_text = lcl_sms_netgsm=>format_time( iv_date  = '20260411'
                                           iv_time  = '010000'
                                           iv_style = 'DMYHM' ).
    cl_aunit_assert=>assert_equals( act = lv_text
                                    exp = `110420260100`
                                    msg = 'Netgsm example' ).
  ENDMETHOD.

ENDCLASS.
