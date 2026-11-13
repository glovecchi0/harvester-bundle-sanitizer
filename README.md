# harvester-bundle-sanitizer

A fast, lightweight utility designed to recursively unpack and deterministically anonymize sensitive customer identifiers inside SUSE Harvester, RKE2, and Longhorn support bundles—making them safe to share with **AI assistants and LLMs for troubleshooting** while preserving full compatibility with `support-bundle-kit simulator`.

## Why This Exists

Troubleshooting complex Harvester, KubeVirt, and Longhorn issues with AI tools often requires sharing logs, cluster manifests, and configuration dumps. However, raw support bundles expose customer-specific hostnames, site names, FQDNs, application namespaces, VM names, and storage volume identifiers.

`harvester-bundle-sanitizer` scrubs all customer-identifying metadata in seconds while preserving:
- **Kubernetes RFC 1123 naming compliance** (`node-01`, `customer-ns-1`, `customer-vm-1`, `customer-obj-1`) so the sanitized bundle loads cleanly into `support-bundle-kit simulator` and `kubectl`.
- **RFC 1918 private IP addresses and VLAN topology**, keeping network routing, VIPs, and storage connectivity intact for accurate AI-assisted root-cause analysis.

## How It Works

1. **Non-Destructive Workspace & Recursive Unpacking:** Copies/extracts the input `.zip` archive or directory into `./sanitized_<bundle_name>` without modifying the original file, recursively unpacking all nested node and `scc_supportconfig` archives (`.zip`, `.txz`, `.tar.xz`, `.tar.gz`, `.tgz`, `.tar`).
2. **Direct Path Extraction & Deterministic Mapping (`mapping.tsv`):** Inspects exact bundle paths (`yamls/cluster/v1/nodes.yaml`, `yamls/namespaced/<ns>/`, and `nodes/*/configs/etc/{resolv.conf,hosts}`) to extract node hostnames, site prefixes, search domains, customer namespaces, VMs, VMIs, PVCs, and pods—ignoring upstream system components and event hashes. Entries are sorted by descending string length to prevent partial substring collisions.
3. **Interactive Approval, Fast Scrubbing & Path Renaming:** Pauses for manual review of `mapping.tsv` before running a single-pass in-memory regex replacement across all text files and renaming matching directories and files on disk.

## Usage

1. Run the sanitizer against a support bundle `.zip` or extracted folder:
   ```bash
   ./sanitize.sh ~/Downloads/supportbundle_xxxx.zip
   ```
2. Review the generated `mapping.tsv` when prompted (edit it in another terminal if needed) and press `y` to apply the replacements.
3. Verify zero customer leaks and load the scrubbed bundle into `support-bundle-kit simulator`:
   ```bash
   support-bundle-kit simulator --reset --bundle-path "./sanitized_supportbundle_xxxx/supportbundle_xxxx"
   export KUBECONFIG=$HOME/.sim/admin.kubeconfig
   kubectl get nodes
   kubectl get vm -A
   ```

## Security Note

`mapping.tsv`, `*.sed`, and `sanitized_*/` contain cleartext mappings or customer bundle data and are excluded via `.gitignore`. Always verify `git status` before committing changes.
