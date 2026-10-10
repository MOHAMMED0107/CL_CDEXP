# Work in progress

New phone-pro.sh features being built and tested (not yet merged into `tools/phone-pro.sh`):

- `features/free-space` – Free up space
- `features/battery-drain` – Battery drain detective
- `features/stolen-ready` – Lost-or-stolen check + emergency card
- `features/scam-shield` – OTP & SIM scam shield
- `features/go-wireless` – Use the script over Wi-Fi

Each folder has `feature.sh` (the code), `test/` (fake-phone tests) and `notes.md`.
`harness/` holds the test runner and the script that merges finished features into `tools/phone-pro.sh`.
`tools/phone-pro.sh` is always the latest working version you can use.
