# Netgsm validation results

[Türkçe](VALIDATION.tr.md) · [Overview](README.md) · [Setup and usage](WALKTHROUGH.md)

Tests in A4H client 001 (SAP_BASIS 816) verified the SMS preview and the connection to Netgsm. The test account had no approved sender name. Netgsm returned `40` for the live OTP attempt. No SMS reached the phone and the attempt incurred no charge.

## OTP logging regression

On 20 November 2026 all 51 unit tests passed locally using the Open ABAP runtime and a simulated Netgsm backend. The new test failed on the previous implementation. Three additional checks captured the messages passed to the application log. With text logging enabled, the OTP body was absent and ordinary SMS text was present. With logging disabled, ordinary SMS text was also absent. This run did not contact Netgsm. Commit `086925f` was activated without warnings on A4H/001 (SAP_BASIS 816) the same day. All 51 ABAP Unit tests passed.

## Results observed in SAP

| Check | Observed result |
|---|---|
| ABAP Unit | All 51 tests across five classes passed using simulated HTTP responses. [A4H test record](https://github.com/Cheditte/abap-sms-netgsm/pull/5) |
| OTP preview with text logging selected | `DRY_RUN`. The result showed one masked recipient and one part. The OTP text and request body were absent. |
| SMS preview | `DRY_RUN` for sender `FIRMA`, one valid recipient and one SMS part. The result masks the recipient’s number. [Preview](docs/img/S11-preview.png) |
| Delivery report with one date | The program requested the second date and returned `BAD_INPUT`. [Report screen](docs/img/S25-report-one-date.png) |
| Cancel a nonexistent job | Netgsm returned `60` for the sample job ID `123`. [Cancellation result](docs/img/S23-cancel-unknown-job.png) |

## Checks against a live Netgsm account

| Operation | Observed result |
|---|---|
| Connection and authentication | Both HTTPS destinations connected after the root certificate was added in STRUST. Adding the SAP server’s outbound IP to the Netgsm allowlist resolved the initial code `30`. |
| Sender names | Netgsm returned `00` and an empty list of approved names. [Netgsm response](docs/img/S20-sender-names.png) |
| Templates | The template service returned `00` and 51 templates. |
| Character count | The sample text `ığüşöç` used 10 units. Netgsm counted 15 including the five-character suffix (` B021`) for the alphabetic sender name. |
| Delivery report and inbox | For the date range tested, the report returned `60` (no records) and the inbox returned `40` (no messages). |

## Checks still open

- Delivery of standard, scheduled, template and OTP messages to a phone. The [recipient view](WALKTHROUGH.md#what-the-recipient-sees) is an illustration.
- Cancelling a real scheduled job, reading a real job’s statistics and finding an OTP job ID in a delivery report.
- Sender name case sensitivity, the recipient limit per request and the report query limit.
- Running on SAP_BASIS 7.00 and sending from a background job.
