# harvester-bundle-sanitizer

A lightweight Bash utility designed to recursively unpack and deterministically anonymize sensitive data (hostnames, FQDNs, private IP addresses, VM names, and storage volumes) inside SUSE Harvester, RKE2, and Longhorn support bundles before sharing them externally.

## How It Works

1. **Recursive Unpacking:** Recursively extracts all nested archives (`.zip`, `.txz`, `.tar.xz`, `.tar.gz`, `.tgz`) in place and removes the original compressed files to ensure full coverage.
2. **Deterministic Mapping (`mapping.tsv`):** Scans configurations and logs to build a key-value replacement dictionary sorted by descending string length to prevent partial substring collisions.
3. **Interactive Approval & Scrubbing:** Pauses for manual inspection and editing of `mapping.tsv` before executing a bulk in-place `sed` replacement across text files only.

## Usage

Always run the script against a **copy** of the extracted support bundle directory:

```bash
cp -R supportbundle_xxxx test_bundle
./sanitize.sh test_bundle
