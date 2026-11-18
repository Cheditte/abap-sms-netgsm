# abap-sms-netgsm

[Türkçe](README.md) · [English](README.en.md)

![abap-sms-netgsm sends a notification from SAP to a phone through Netgsm](docs/img/abap-sms-netgsm-cover.jpg)

When a document is ready in SAP, you can notify someone by SMS. Enter the recipients and message in `ZCHE_SMS_NETGSM`. The preview shows how many recipients have valid numbers and how many SMS parts the message will use.

[Prepare an example SMS in SAP](WALKTHROUGH.md#6-preview-then-send) · [See the recipient’s view](WALKTHROUGH.md#what-the-recipient-sees)

## What do you want to do?

| Goal | Where to start |
|---|---|
| Prepare the Netgsm account and SAP connection | [Setup walkthrough](WALKTHROUGH.md) |
| Prepare a message for one or more recipients, schedule it, or use a template | [Preview and send](WALKTHROUGH.md#6-preview-then-send) |
| Send a one-time code | Choose the OTP SMS package and preview the request for one recipient. [Walkthrough](WALKTHROUGH.md) |
| Read delivery reports, incoming SMS or job statistics | Choose the relevant action. For date-range queries, enter both dates. [Result codes](WALKTHROUGH.md#result-codes) |
| Call the tool from my ABAP program | [PERFORM example with preview](WALKTHROUGH.md#use-it-from-your-programs) |
| See what was tested with a real account | [Validation and limits](VALIDATION.md) |

## First run

1. **Netgsm.** Apply for a sender name early. The application requires documents and KEP submission, and approval can take days. Prepare the API sub-user password and allow the SAP server’s outbound IP.
2. **SAP.** Activate the program in SE38. Configure the certificate chain in STRUST and the `ZCHE_NETGSM` connection in SM59. Templates also use `ZCHE_NETGSM_EXT`. [Program source](src/zche_sms_netgsm.prog.abap)
3. **Free check.** In SA38 run `ZCHE_SMS_NETGSM` and list sender names. An empty list with `00` confirms that the connection works. Sends with an undefined sender name are rejected with `40`.

## Validation

All 50 unit tests passed on A4H client 001 (SAP_BASIS 816). Queries against a real account verified both HTTPS destinations, template listing and character counting. The account had no approved sender name, so delivery to a phone remains unverified. [Test results](VALIDATION.md) · [Changes](CHANGELOG.md) · [MIT license](LICENSE)
