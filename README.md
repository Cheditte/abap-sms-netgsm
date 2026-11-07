# abap-sms-netgsm

> **English** | [Türkçe](README.tr.md)

**Send SMS from SAP through [Netgsm](https://www.netgsm.com.tr), with ABAP only.** No middleware and no script on the server. SAP calls Netgsm's HTTPS API itself.

**One program, nothing else to create.** Copy one file into SE38 and activate it. There are no tables, no data elements and no function group. The Netgsm password stays in SM59, never in the code.

> **Status: v0.2, not released yet.** Written for SAP_BASIS 7.00 (ECC 6.0) and later, but so far run only on an SAP ABAP Platform trial system (SAP_BASIS 816). See [What has been verified](#what-has-been-verified). **No real SMS has been sent with it yet, and no call has reached a Netgsm account yet.**

## What it does

Pick an **action** on the screen. The screen then shows only the fields that action needs.

| Action | What it does | Netgsm package | Cost |
|---|---|---|---|
| **Send SMS** | One text to one or more numbers, now or at a later time (Turkish time), with your own reference | Bulk SMS (Toplu SMS) | per SMS |
| **Send OTP SMS** | One number, one part, no Turkish letters. Delivered within 3 minutes, without filters (IYS, blacklist, duplicates) | OTP SMS | per SMS |
| **Send template SMS** | A template approved at Netgsm, with your values for `${...}` | Bulk SMS | per SMS |
| **Cancel a scheduled SMS** | Cancels a send that is set for later | | free |
| **Delivery report** | Status per number, by job ID or date range (up to 3 months) | | free |
| **Statistics of a job** | Totals of one job: delivered, failed, parts, credits | | free |
| **Incoming SMS** | SMS sent to your Netgsm number | | free |
| **Test: list sender names** | The approved sender names on the account; the first connection test | | free |
| **List templates** | Your templates and Netgsm's public ones, with their values | | free |
| **Count characters at Netgsm** | Netgsm's own count of parts and characters for a text | | free |

Every send can be **previewed first** (the default). The preview checks everything and shows the exact request; nothing goes out. A real send asks for confirmation in a popup. It also works **as a job step** and **from your own ABAP** (`PERFORM send_sms IN PROGRAM zche_sms_netgsm`, see [Use it from your programs](#use-it-from-your-programs)).

What happens on every send:

1. **Numbers.** `+90 500 000 00 00`, `0500 000 00 00`, `500 000 00 00` and `0090…` all become the 10-digit form Netgsm wants. Landlines, foreign numbers and typos are rejected one by one, with the reason. A number given twice is sent once.
2. **Text.** The program picks the character set: Turkish letters mean Turkish, emoji mean Unicode. It counts the characters and parts as Netgsm does. A text that needs more than 6 parts (or more than 1 for OTP) is not sent.
3. **Checks.** The SM59 destination must exist and the user must be allowed to use it (authorization object `S_ICF`). Both are checked in the preview too.
4. **Send.** One request to Netgsm, **never repeated automatically**: a second request could mean a second paid SMS.
5. **Log.** If you created log object `ZCHE_SMS`, the result goes to the application log (SLG1). Numbers are masked (`5** *** ** 34`), and the message text is logged only if you ask for it.

### What it does not do, and why

| Netgsm service | Why not |
|---|---|
| Blacklist add/remove, IYS address upload and search | Netgsm wants the user code and password **inside the request body**. SM59 cannot put them there, so the program would have to read the password. That is against the rule of this project. Use the Netgsm panel. |
| Forwarding incoming SMS to a URL, IYS webhook | Netgsm would call SAP. That needs an ICF service and a class, not a copy/paste program. "Incoming SMS" reads them instead. |
| WhatsApp OTP, voice messages, legacy XML services | Other products or other APIs. |
| SMS API v3 (newer API) | It needs the password in a JSON body to get a token (same reason as above). See [Why REST v2](#why-netgsm-rest-v2-and-not-v3). |

## What you need

| What | Why | From whom |
|---|---|---|
| A Netgsm account with a **Bulk SMS** and/or **OTP SMS** package | The SMS is sent and billed by Netgsm. OTP SMS needs its own package. | Your company's Netgsm owner |
| An **API sub-user** on that account | Since 15 February 2024 Netgsm requires an API-type sub-user for API access | Netgsm panel, main account ([step 1](#1-netgsm-panel)) |
| An **approved sender name** (header), e.g. `FIRMA` | Every SMS goes out under an approved name | Netgsm panel ([step 1](#1-netgsm-panel)) |
| SAP_BASIS 7.00 or later | The code is classic ABAP. It is checked with [abaplint](https://abaplint.org) in 7.00 mode, but has only run on 8.16 | |
| A developer key and a transport (or `$TMP` to try) | To create the program in SE38 | Basis |
| Access from the SAP server to `api.netgsm.com.tr` and `ext-api.netgsm.com.tr`, port 443 | SAP calls Netgsm directly. The second host serves templates only. | Network team |
| The root certificate **USERTrust RSA Certification Authority** in STRUST | Without it the HTTPS connection fails ([step 3](#3-strust-trust-netgsms-certificate)) | Basis |
| Two SM59 destinations of type G (one if you do not use templates) | Hold the address and the Netgsm password ([step 4](#4-sm59-the-connection-and-the-password)) | Basis |
| The public IP address SAP uses to reach the internet | Only if you turn on Netgsm's IP restriction | Network team |

## Setup, step by step

### 1. Netgsm panel

Log on to the Netgsm web panel with the **main account**. Only the main account can create sub-users.

1. **Package.** For alerts and normal SMS: **Bulk SMS** (Toplu SMS). For one-time codes: **OTP SMS**. OTP is cheaper, but it allows only one number, one part and no Turkish letters, and Netgsm describes it for codes such as passwords and confirmations.
2. **API sub-user.** Go to *Abonelik İşlemleri → Alt Kullanıcı Hesapları* and create a sub-user of type **API**. Netgsm says a representative approves it, and that creating it grants API access. Note two values:
   - **User code**: your Netgsm subscriber number, e.g. `312XXXXXXX` or `850XXXXXXX`. It goes into SM59 as the user.
   - **Password** of the sub-user. It goes into SM59 as the password and nowhere else.
3. **Sender name.** Under *SMS Hizmeti → SMS Ayarları → Gönderici Adlarım* request a name with 3 to 11 characters and wait for approval. Type it into SAP **exactly** as approved: Netgsm's newer API treats upper and lower case as different, and the older one has not been checked.
4. **IP restriction (recommended).** Under *Abonelik İşlemleri → API işlemleri → API IP Erişim Yönetimi* you can allow API calls only from listed addresses. Add the **public** address that SAP's traffic leaves from; the network team knows it. If it is missing, Netgsm answers with code `30`.
5. **Commercial messages.** For advertising and campaign SMS, Turkish law requires the recipient's consent in İYS (İleti Yönetim Sistemi), and Netgsm needs an İYS brand code on your account. Plain alerts to your own staff are "informational" (`0`), the default.
6. **Templates (optional).** Template SMS use texts approved at Netgsm. Ask Netgsm how to add your own. The action *List templates* shows what your account can use.

Menu names are as Netgsm's documentation gives them in November 2026. The panel may look different.

### 2. Install the program

1. Open [`src/zche_sms_netgsm.prog.abap`](src/zche_sms_netgsm.prog.abap) and copy the whole file (**Copy raw file**).
2. In **SE38**, create program `ZCHE_SMS_NETGSM`: title `SMS from SAP through Netgsm`, type **Executable program**, your package (or **Local object** to try).
3. Delete everything SE38 put in, paste, and **activate** (Ctrl+F3).
4. Check: **Program → Execute → Unit Tests** (in ADT, Ctrl+Shift+F10). **50 tests** must pass. They use a test double and never call Netgsm.

The screen texts come from the code, in English, or in Turkish when you log on in Turkish.

**If you get "line too long" when you activate:** your editor is set to the old 72-character lines. Untick *Utilities → Settings → ABAP Editor → Editor → Downwards-compatible line length (72)* and paste again. The source stays within 72 columns, so normally this does not happen.

**abapGit (optional):** the repository is also an abapGit repository with the same single program.

### 3. STRUST: trust Netgsm's certificate

On the trial system the first call failed with `SSSLERR_PEER_CERT_UNTRUSTED`. The program shows this as code `NO_TRUST`, and in that case nothing was sent. Both hosts use the same certificate (checked on 7 November 2026):

```
*.netgsm.com.tr   (api.netgsm.com.tr and ext-api.netgsm.com.tr)
 └ Sectigo Public Server Authentication CA DV R36
    └ Sectigo Public Server Authentication Root R46
       └ USERTrust RSA Certification Authority   ← root, add this one
```

1. Get the root certificate. Either open `https://api.netgsm.com.tr` in a browser, show the certificate, select **USERTrust RSA Certification Authority** and export it as Base64 (`.cer`), or download it from Sectigo's site.
2. In **STRUST**, open **SSL client Anonymous**. That is `ANONYM`; use your own PSE if your destination has one.
3. Click **Import certificate**, choose the file, then **Add to Certificate List**, then **Save**.
4. If the connection test still fails, ask Basis to make the ICM reload the PSE.

### 4. SM59: the connection and the password

Create two **HTTP connections to an external server** (type **G**). Skip the second one if you do not use templates.

| Tab / field | `ZCHE_NETGSM` | `ZCHE_NETGSM_EXT` (templates) |
|---|---|---|
| Technical settings → Host | `api.netgsm.com.tr` | `ext-api.netgsm.com.tr` |
| Port | `443` | `443` |
| Path prefix | **empty**; the program sends `/sms/rest/v2/...` itself | **empty** |
| Logon & Security → Basic Authentication → User | Netgsm **user code** (step 1) | the same |
| Password | the **API sub-user's password** (step 1) | the same |
| Logon & Security → SSL | **Active**, certificate list **ANONYM** (or the PSE from step 3) | the same |
| Logon & Security → Authorization for Destination | `ZCHE_NETGSM` (recommended, see below) | `ZCHE_NETGSM_EXT` |

Other names work too: enter them in the *SM59 destination* fields on the screen.

SAP keeps the password in its secure storage. The program never reads it: SM59 adds it to every request as HTTP Basic authentication.

**Who may send.** With *Authorization for Destination* filled, SAP lets only users who have authorization object **`S_ICF`** with `ICF_FIELD = DEST` and `ICF_VALUE = <destination>` use the destination. The program runs the same check itself before the preview and before every call, so a missing authorization gives a clear message (`NO_AUTH`). Put `S_ICF` into the role of the people and the batch user that may send SMS. To limit who may start the program, use `S_PROGRAM` or a transaction code.

### 5. First run: connection test

1. Start `ZCHE_SMS_NETGSM` (SA38), choose the action **Test: list sender names** and press **Execute**.
2. Expected: `00: Netgsm answered: OK.`, then *Connection and logon to Netgsm work.*, then the list of your approved sender names. This costs nothing.

| Answer | Meaning |
|---|---|
| `NO_DEST` | The SM59 destination is missing or not type G. |
| `NO_AUTH` | Your user lacks `S_ICF` for the destination. |
| `NO_TRUST` | STRUST step missing. Nothing was sent. |
| `NO_CONN` | No connection: network, proxy or firewall. |
| `30` | Wrong user code or password, no API access for the sub-user, or SAP's IP is not allowed. |

### 6. Preview, then send

1. Choose **Send SMS** (or **Send OTP SMS**). Enter one or more **mobile numbers**, the **sender name** and up to four **text lines**; each filled line becomes a line in the SMS.
2. Leave **Preview only** ticked and press **Execute**. You see:
   - the character set, the character count and the parts;
   - the masked numbers, and the rejected numbers with the reason;
   - the exact request that would go to Netgsm, with the numbers masked.

   Tick *Also count at Netgsm* to compare with Netgsm's own count (free).
3. Untick **Preview only** and execute again. A popup asks for confirmation and shows the estimated SMS credits. **This costs money.**
4. Note the **job ID**. Later, choose **Delivery report**, enter the job ID and execute. Netgsm says reports can take a few minutes to appear.

**Later send:** fill *Send on* and *Send at* (Turkish time, UTC+3). *Stop trying on/at* is optional; without it Netgsm keeps trying for 21 hours. To take it back, use **Cancel a scheduled SMS** with the job ID.

**Template SMS:** find the template ID with **List templates**. Then choose **Send template SMS**, enter the ID and one `name=value` line per `${name}` in the template. Character set *Automatic* sends templates as Turkish, because the program cannot see the template text.

### 7. Application log (optional)

To keep a record in SLG1, create log object **`ZCHE_SMS`** once in **SLG0**; no subobject is needed. Without it the program still works: the result is only in the list and in the job log, and the list says so. The log holds the action, code, job ID, sender name, character set, parts and **masked** numbers. The text is logged only when you tick **Also log the message text**. Texts sent with `PERFORM send_otp` are never logged, because they are codes.

## Use it from your programs

```abap
DATA lt_numbers TYPE string_table.
DATA lv_code    TYPE string.
DATA lv_jobid   TYPE string.
DATA lv_message TYPE string.

APPEND `0500 000 00 00` TO lt_numbers.          " made-up number
PERFORM send_sms IN PROGRAM zche_sms_netgsm IF FOUND
  USING    lt_numbers `ZFI_CLOSE failed, see SM37` `FIRMA` abap_false
  CHANGING lv_code lv_jobid lv_message.

IF lv_code <> '00'.
  " not sent, or not sure: lv_message says which
ENDIF.
```

| FORM | For |
|---|---|
| `send_sms` | numbers, text, sender name, preview flag |
| `send_sms_opt` | the same plus character set (`AUTO`, `TR`, `UNICODE`, `ASCII`), IYS type (`0`, `11`, `12`), log the text |
| `send_sms_at` | the same plus a later send time (`lif_sms=>ty_schedule`, Turkish time) and your reference |
| `send_otp` | one number, text, sender name, turn Turkish letters into Latin ones, preview flag |
| `send_template` | numbers, template ID, `name=value` lines, sender name, preview flag |
| `cancel_sms` | job ID of a later send |

- Code `00` means Netgsm accepted the request, and the job ID is set. Anything else means not sent or not sure, and the message explains.
- With the preview flag set, everything is checked and nothing is sent (`DRY_RUN`).
- There is no popup and no list. The destinations are `ZCHE_NETGSM` and `ZCHE_NETGSM_EXT`, and the calling user needs `S_ICF` for them.
- The log entry is written in the caller's LUW: if the caller rolls back, it is gone too.

**Job step:** save a variant of the screen with the action and its values, untick *Preview only*, and add `ZCHE_SMS_NETGSM` with that variant as a step. In the background there is no popup, and an error ends the job as *Cancelled* so job monitoring sees it.

## Characters, length and cost

From Netgsm's documentation:

| Character set | 1 part | per part when split | most in 6 parts |
|---|---|---|---|
| GSM (no Turkish letters) | 160 | 153 | 912 |
| Turkish (`TR`) | 155 | 148 | 883 |
| Unicode (e.g. emoji) | 70 | 66 | 391 |
| OTP SMS | 160, one part only | | |

- `ç ğ ı ş Ğ İ Ş` and `€ [ ] { } ^ ~ \ |` count as **two** characters.
- With a sender name that has letters, Netgsm adds " B021" to the end of the text (a BTK rule since 2016). That costs 5 characters, and the program counts them, so OTP has 155 characters left.
- **ASCII** turns Turkish letters into Latin ones (ç → c) before sending. It is cheaper, but the text changes. OTP SMS need it if the text has Turkish letters.
- Netgsm bills **number of recipients × number of parts**. The program shows that estimate; Netgsm's invoice is what counts. For templates the parts are not known before sending.

## Result codes

Netgsm uses the same codes for different things in different services; the program explains each in context.

| Code | Meaning |
|---|---|
| `00` | Accepted (send) / OK (everything else). |
| `20` | Problem in the text, or text too long. |
| `30` | Wrong user code or password, no API access, or IP not allowed. |
| `40` | Sender name not defined (send, OTP). For incoming SMS: no new messages. |
| `50`, `51` | Account cannot send İYS-checked messages / no İYS brand code. OTP: check the number. |
| `60` | Report: no records. Cancel: no such job. OTP: no OTP package. Incoming SMS: range over 30 days. |
| `70` | Invalid or missing parameter. |
| `80` | Limit exceeded. |
| `85` | More than 20 jobs to the same number within one minute. |
| `100`–`110` | Netgsm system error. |
| `NOT_FOUND`, `UNAUTHORIZED`, `BAD_REQUEST` | Template: no such ID / not allowed / values missing. |
| `DRY_RUN` | Preview: everything checked, nothing sent. |
| `BAD_NUMBER`, `BAD_TEXT`, `BAD_INPUT` | Rejected by the program before calling Netgsm. |
| `NO_DEST`, `NO_AUTH` | SM59 destination missing or wrong type / no `S_ICF` authorization. |
| `NO_TRUST` | Certificate not trusted (STRUST). Nothing was sent. |
| `NO_CONN` | No answer. **The SMS may or may not have been sent**: check the delivery report or the Netgsm panel before sending again. |
| `HTTP_ERROR`, `BAD_REPLY` | Netgsm answered with an HTTP error, or with something the program cannot read. |

## What has been verified

On the SAP ABAP Platform trial system A4H (SAP_BASIS 816), 7 November 2026:

- abaplint in 7.00 mode found nothing. The program activates without warnings, and **50 of 50** unit tests pass.
- The unit tests cover every request the program builds and every answer from the Netgsm documentation: send, later send, OTP, template, cancel, report, statistics, incoming SMS, sender names, template list, length. They check paths, bodies, codes, masking and the local checks.
- Run through the program's selection screen (`SUBMIT` with values):
  - Previews: a later send with reference, an OTP SMS, and a template SMS.
  - An OTP text with a Turkish letter was refused, as expected.
  - A report with one date only was refused, as expected.
- `PERFORM send_sms` from another program: `NO_DEST` without a destination, `BAD_NUMBER` without numbers.
- Real HTTPS calls to `api.netgsm.com.tr` and `ext-api.netgsm.com.tr` through SM59 reached the TLS handshake. They failed with `NO_TRUST`, because the trial system lacks the USERTrust root. That is where step 3 comes from.

**Not verified yet:**

- Any answer from a real Netgsm account: send, OTP, report, statistics, incoming SMS, templates, length, cancel.
- That the screen hides and shows fields per action in SAP GUI. Only `SUBMIT` with values has been run.
- Release 7.00 itself. Only the syntax is checked for 7.00.
- From Netgsm's documentation, not tried:
  - whether v2 treats upper and lower case in the sender name as different;
  - the most recipients per request (the program allows 100);
  - whether the delivery report also covers OTP job IDs;
  - whether a statistics send date without a time works;
  - the report query limit (the documentation says both 10 and 60 per minute).

## Why Netgsm REST v2 and not v3

Netgsm has two SMS APIs. The newer v3 wants the password in a JSON body to get a token, which SM59 cannot add, so the code would have to read the password. v2 accepts HTTP Basic authentication, which SM59 sends itself. That keeps the password out of the code. Netgsm's JavaScript SDK calls v2 "legacy", but the documentation gives no end date.

## Sources

- Netgsm documentation (REST v2): <https://www.netgsm.com.tr/dokuman/>
- Netgsm SMS API v3 documentation: <https://api-docs.netgsm.com.tr/>
- [DESIGN.md](DESIGN.md): design decisions, in Turkish

---

[MIT license](LICENSE) · not affiliated with Netgsm · [Issues and feedback](https://github.com/Cheditte/abap-sms-netgsm/issues)
