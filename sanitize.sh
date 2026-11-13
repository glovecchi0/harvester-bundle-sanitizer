#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"

if [[ -z "$INPUT_PATH" || ! -e "$INPUT_PATH" ]]; then
  echo "Usage: $0 <path_to_supportbundle.zip | path_to_extracted_dir>"
  exit 1
fi

BASE_NAME="$(basename "$INPUT_PATH")"
CLEAN_NAME="${BASE_NAME%.zip}"
CLEAN_NAME="${CLEAN_NAME%.tar.gz}"
CLEAN_NAME="${CLEAN_NAME%.tgz}"
WORK_DIR="./sanitized_${CLEAN_NAME}"

if [[ -d "$WORK_DIR" ]]; then
  echo "Error: Output directory '$WORK_DIR' already exists. Remove or rename it first."
  exit 1
fi

mkdir -p "$WORK_DIR"

if [[ -f "$INPUT_PATH" && "$INPUT_PATH" == *.zip ]]; then
  echo "Extracting initial zip archive into '$WORK_DIR'..."
  unzip -q -o "$INPUT_PATH" -d "$WORK_DIR"
elif [[ -d "$INPUT_PATH" ]]; then
  echo "Copying input directory into '$WORK_DIR'..."
  cp -R "$INPUT_PATH"/* "$WORK_DIR"/
else
  echo "Unsupported input format. Please provide a .zip file or a directory."
  rm -rf "$WORK_DIR"
  exit 1
fi

echo "=========================================================="
echo " STEP 1: Recursive extraction of nested archives"
echo "=========================================================="

unpack_archives() {
  local dir="$1"
  local found=0

  while IFS= read -r -d '' zip_file; do
    echo "[UNZIP] $zip_file"
    local dest_dir="${zip_file%.zip}"
    mkdir -p "$dest_dir"
    unzip -q -o "$zip_file" -d "$dest_dir"
    rm -f "$zip_file"
    found=1
  done < <(find "$dir" -type f -name "*.zip" -print0)

  while IFS= read -r -d '' txz_file; do
    echo "[UNTAR.XZ] $txz_file"
    local dest_dir="${txz_file%.txz}"
    dest_dir="${dest_dir%.tar.xz}"
    mkdir -p "$dest_dir"
    tar -xf "$txz_file" -C "$dest_dir"
    rm -f "$txz_file"
    found=1
  done < <(find "$dir" -type f \( -name "*.txz" -o -name "*.tar.xz" \) -print0)

  while IFS= read -r -d '' tgz_file; do
    echo "[UNTAR.GZ] $tgz_file"
    local dest_dir="${tgz_file%.tgz}"
    dest_dir="${dest_dir%.tar.gz}"
    mkdir -p "$dest_dir"
    tar -xzf "$tgz_file" -C "$dest_dir"
    rm -f "$tgz_file"
    found=1
  done < <(find "$dir" -type f \( -name "*.tar.gz" -o -name "*.tgz" \) -print0)

  while IFS= read -r -d '' tar_file; do
    echo "[UNTAR] $tar_file"
    local dest_dir="${tar_file%.tar}"
    mkdir -p "$dest_dir"
    tar -xf "$tar_file" -C "$dest_dir"
    rm -f "$tar_file"
    found=1
  done < <(find "$dir" -type f -name "*.tar" -print0)

  if [[ "$found" -eq 1 ]]; then
    unpack_archives "$dir"
  fi
}

unpack_archives "$WORK_DIR"

BUNDLE_ROOT=$(find "$WORK_DIR" -maxdepth 2 -type d -name "yamls" -exec dirname {} \; | head -n 1 || echo "$WORK_DIR")
echo "Bundle root detected: $BUNDLE_ROOT"
echo ""

echo "=========================================================="
echo " STEP 2: Direct path extraction for mapping.tsv"
echo "=========================================================="

MAP_FILE="mapping.tsv"
> "$MAP_FILE"

extract_k8s_names() {
  local yaml_file="$1"
  [[ -f "$yaml_file" ]] || return 0
  awk '
    /^[[:space:]]*metadata:[[:space:]]*$/ { in_meta=1; next }
    in_meta && /^[[:space:]]*name:[[:space:]]*/ { gsub(/["'\'']/, "", $2); print $2; in_meta=0; next }
    in_meta && /^[^[:space:]]/ { in_meta=0 }
  ' "$yaml_file" 2>/dev/null | tr -d '\r' | sort -u
}

IGNORE_REGEX="^(default|kube-root-ca\.crt|default-token-.*|rootdisk|image|image-[a-z0-9]+|disruption-budget-.*|disk-[0-9a-zA-Z-]+|cdrom-[0-9a-zA-Z-]+|cloudinitdisk|default-nic|nic-[0-9]+|guest-agent|qemu-guest-agent|virt-launcher|rancher|harvester)$"

# 1. Nodes directly from yamls/cluster/v1/nodes.yaml (RFC 1123 lowercase-hyphen compliant)
NODE_IDX=1
NODES_YAML="$BUNDLE_ROOT/yamls/cluster/v1/nodes.yaml"
if [[ -f "$NODES_YAML" ]]; then
  while read -r NODE_NAME; do
    [[ -n "$NODE_NAME" ]] || continue
    echo -e "${NODE_NAME}\tnode-0${NODE_IDX}" >> "$MAP_FILE"

    PREFIX=$(echo "$NODE_NAME" | sed -E 's/-(harv|node|worker|mgmt)[0-9]*$//i')
    if [[ -n "$PREFIX" && "$PREFIX" != "$NODE_NAME" && ${#PREFIX} -gt 3 ]]; then
      echo -e "${PREFIX}\tcustomer-site" >> "$MAP_FILE"
    fi
    ((NODE_IDX++))
  done < <(extract_k8s_names "$NODES_YAML")
fi

# 2. Customer namespaces & objects directly from yamls/namespaced/<ns>/ (RFC 1123 compliant)
NS_IDX=1
VM_IDX=1
OBJ_IDX=1
NAMESPACED_DIR="$BUNDLE_ROOT/yamls/namespaced"

if [[ -d "$NAMESPACED_DIR" ]]; then
  for ns_dir in "$NAMESPACED_DIR"/*; do
    [[ -d "$ns_dir" ]] || continue
    NS_NAME="$(basename "$ns_dir")"

    if [[ "$NS_NAME" =~ ^(default|kube-.*|cattle-.*|harvester-.*|longhorn-.*|fleet-.*|local|calico-.*|tigera-.*|cert-manager|monitoring)$ ]]; then
      continue
    fi

    echo -e "${NS_NAME}\tcustomer-ns-${NS_IDX}" >> "$MAP_FILE"
    ((NS_IDX++))

    VM_YAML="$ns_dir/kubevirt.io/v1/virtualmachines.yaml"
    if [[ -f "$VM_YAML" ]]; then
      while read -r VM_NAME; do
        [[ -n "$VM_NAME" ]] || continue
        [[ "$VM_NAME" =~ $IGNORE_REGEX ]] && continue
        echo -e "${VM_NAME}\tcustomer-vm-${VM_IDX}" >> "$MAP_FILE"
        ((VM_IDX++))
      done < <(extract_k8s_names "$VM_YAML")
    fi

    for target_yaml in \
      "$ns_dir/v1/persistentvolumeclaims.yaml" \
      "$ns_dir/v1/pods.yaml" \
      "$ns_dir/kubevirt.io/v1/virtualmachineinstances.yaml" \
      "$ns_dir/snapshot.storage.k8s.io/v1/volumesnapshots.yaml"; do
      [[ -f "$target_yaml" ]] || continue
      while read -r OBJ_NAME; do
        [[ -n "$OBJ_NAME" ]] || continue
        [[ "$OBJ_NAME" =~ $IGNORE_REGEX ]] && continue
        if ! grep -q "^${OBJ_NAME}[[:space:]]" "$MAP_FILE"; then
          echo -e "${OBJ_NAME}\tcustomer-obj-${OBJ_IDX}" >> "$MAP_FILE"
          ((OBJ_IDX++))
        fi
      done < <(extract_k8s_names "$target_yaml")
    done
  done
fi

# 3. Search domains directly from nodes/*/configs/etc/{resolv.conf,hosts}
DOM_IDX=1
while read -r dom; do
  dom=$(echo "$dom" | tr -d '\r')
  [[ -n "$dom" ]] || continue
  echo -e "${dom}\tcustomer-domain-${DOM_IDX}" >> "$MAP_FILE"
  ((DOM_IDX++))
done < <(
  find "$BUNDLE_ROOT/nodes" -type f \( -name "resolv.conf" -o -name "hosts" \) 2>/dev/null \
    | xargs -r grep -hoE "\b([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}\b" 2>/dev/null \
    | sort -u \
    | grep -viE "(cluster\.local|localhost|localdomain|suse|rancher)" || true
)

# Deduplicate & sort by descending string length
sort -u -k1,1 "$MAP_FILE" -o "$MAP_FILE"
if [[ -s "$MAP_FILE" ]]; then
  awk '{ print length($1), $0 }' "$MAP_FILE" | sort -nr | cut -d" " -f2- > "${MAP_FILE}.tmp" && mv "${MAP_FILE}.tmp" "$MAP_FILE"
fi

echo "Mapping file generated at: $MAP_FILE"
echo "Total unique entries identified: $(wc -l < "$MAP_FILE")"
echo ""
cat "$MAP_FILE"
echo ""

echo "=========================================================="
echo " STEP 3: Pre-replacement review and manual approval"
echo "=========================================================="
read -p "Proceed with in-place replacement? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted. '$MAP_FILE' and '$WORK_DIR' preserved."
  exit 0
fi

# Single-pass in-memory regex replacement
python3 - "$MAP_FILE" "$BUNDLE_ROOT" << 'EOF'
import os, re, sys

map_file, root_dir = sys.argv[1], sys.argv[2]

mapping = {}
with open(map_file, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\r\n")
        if "\t" in line:
            orig, repl = line.split("\t", 1)
            if orig and repl:
                mapping[orig] = repl

if not mapping:
    sys.exit(0)

sorted_keys = sorted(mapping.keys(), key=len, reverse=True)
pattern = re.compile("|".join(re.escape(k) for k in sorted_keys))

all_files = []
for dirpath, _, filenames in os.walk(root_dir):
    for fn in filenames:
        all_files.append(os.path.join(dirpath, fn))

total = len(all_files)
modified_count = 0

for idx, filepath in enumerate(all_files, 1):
    rel = os.path.relpath(filepath, root_dir)
    sys.stdout.write(f"\r[{idx}/{total}] {rel[:75]:<75}")
    sys.stdout.flush()

    try:
        with open(filepath, "rb") as f:
            raw = f.read()
        if b"\x00" in raw[:8192]:
            continue
        text = raw.decode("utf-8", errors="surrogateescape")
        new_text, count = pattern.subn(lambda m: mapping[m.group(0)], text)
        if count > 0:
            with open(filepath, "wb") as f:
                f.write(new_text.encode("utf-8", errors="surrogateescape"))
            modified_count += 1
    except Exception:
        pass

print(f"\nSanitized {modified_count} files out of {total} scanned.")
EOF

echo "Renaming matching directories and files..."
while IFS=$'\t' read -r orig repl; do
  if [[ -n "$orig" && -n "$repl" ]]; then
    find "$WORK_DIR" -depth -name "*${orig}*" | while read -r path; do
      dir=$(dirname "$path")
      base=$(basename "$path")
      new_base="${base//$orig/$repl}"
      if [[ "$base" != "$new_base" ]]; then
        echo "  [RENAME] $base -> $new_base"
        mv "$path" "$dir/$new_base" 2>/dev/null || true
      fi
    done
  fi
done < "$MAP_FILE"

echo "=== Completed! Scrubbed bundle ready at: $BUNDLE_ROOT ==="
