#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-}"

if [[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
  echo "Usage: $0 <path_to_supportbundle_dir>"
  exit 1
fi

echo "=========================================================="
echo " STEP 1: Recursive extraction of all nested archives"
echo "=========================================================="

unpack_archives() {
  local dir="$1"
  local found=0

  # Find and extract .zip files
  while IFS= read -r -d '' zip_file; do
    echo "[UNZIP] Extracting: $zip_file"
    local dest_dir="${zip_file%.zip}"
    mkdir -p "$dest_dir"
    unzip -q -o "$zip_file" -d "$dest_dir"
    rm -f "$zip_file"
    found=1
  done < <(find "$dir" -type f -name "*.zip" -print0)

  # Find and extract .txz / .tar.xz files
  while IFS= read -r -d '' txz_file; do
    echo "[UNTAR.XZ] Extracting: $txz_file"
    local dest_dir="${txz_file%.txz}"
    dest_dir="${dest_dir%.tar.xz}"
    mkdir -p "$dest_dir"
    tar -xf "$txz_file" -C "$dest_dir"
    rm -f "$txz_file"
    found=1
  done < <(find "$dir" -type f \( -name "*.txz" -o -name "*.tar.xz" \) -print0)

  # Find and extract .tar.gz / .tgz files
  while IFS= read -r -d '' tgz_file; do
    echo "[UNTAR.GZ] Extracting: $tgz_file"
    local dest_dir="${tgz_file%.tgz}"
    dest_dir="${dest_dir%.tar.gz}"
    mkdir -p "$dest_dir"
    tar -xzf "$tgz_file" -C "$dest_dir"
    rm -f "$tgz_file"
    found=1
  done < <(find "$dir" -type f \( -name "*.tar.gz" -o -name "*.tgz" \) -print0)

  # Re-run recursively if any archives were unpacked to catch nested ones
  if [[ "$found" -eq 1 ]]; then
    unpack_archives "$dir"
  fi
}

unpack_archives "$TARGET_DIR"
echo "All archives have been extracted and removed."
echo ""

echo "=========================================================="
echo " STEP 2: Automatic generation of anonymization mapping"
echo "=========================================================="

MAP_FILE="mapping.tsv"
> "$MAP_FILE"

# 1. Node hostnames (from nodes/ directories)
NODE_IDX=1
if [[ -d "$TARGET_DIR/nodes" ]]; then
  for node_dir in "$TARGET_DIR"/nodes/*; do
    if [[ -d "$node_dir" ]]; then
      NODE_NAME="$(basename "$node_dir")"
      echo -e "${NODE_NAME}\tNODE_0${NODE_IDX}" >> "$MAP_FILE"
      ((NODE_IDX++))
    fi
  done
fi

# 2. Custom FQDNs / Domains from YAML/config files (excluding known upstream domains)
find "$TARGET_DIR" -type f \( -name "*.yaml" -o -name "*.config" -o -name "*release*" \) 2>/dev/null | while read -r f; do
  grep -oE "([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}" "$f" 2>/dev/null || true
done | sort -u | grep -vE "(rancher\.io|suse\.com|k8s\.io|opensuse\.org|github\.com|kernel\.org)" | awk '{print $1 "\tDOMAIN_OR_FQDN"}' >> "$MAP_FILE" || true

# 3. Private IPv4 addresses (RFC1918)
IP_IDX=1
grep -rhoE "\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})\b" "$TARGET_DIR" 2>/dev/null \
  | sort -u \
  | grep -vE "(127\.0\.0\.1|0\.0\.0\.0)" \
  | while read -r ip; do
      echo -e "${ip}\tIP_ADDR_${IP_IDX}" >> "$MAP_FILE"
      ((IP_IDX++))
    done || true

# 4. Custom VM / Volume naming patterns (e.g., chsu-*, gapteq-*, etc.)
grep -rhoE "\b(ch[a-z0-9]+-[a-z0-9-]+|gapteq-[a-z0-9-]+)\b" "$TARGET_DIR" 2>/dev/null \
  | sort -u \
  | awk '{print $1 "\tVM_OR_VOLUME_" NR}' >> "$MAP_FILE" || true

# Deduplicate mapping preserving unique keys
sort -u -k1,1 "$MAP_FILE" -o "$MAP_FILE"

# CRITICAL: Sort by descending string length of the original key
# to prevent shorter substrings from breaking longer identifiers
awk '{ print length($1), $0 }' "$MAP_FILE" | sort -nr | cut -d" " -f2- > "${MAP_FILE}.tmp" && mv "${MAP_FILE}.tmp" "$MAP_FILE"

echo "Mapping file generated at: $MAP_FILE"
echo "Total unique entries identified: $(wc -l < "$MAP_FILE")"
echo ""
echo "--- Preview of top 15 replacement rules ---"
head -n 15 "$MAP_FILE"
echo "-------------------------------------------"

echo ""
echo "=========================================================="
echo " STEP 3: Pre-sed review and manual approval"
echo "=========================================================="
echo "You can now open another terminal to inspect or edit '$MAP_FILE'."
read -p "Are you satisfied with the mapping? Proceed with in-place sed replacement? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Operation aborted. '$MAP_FILE' has been preserved, and no log files were modified."
  exit 0
fi

echo "Applying replacements with sed..."

# Build sed command script
SED_SCRIPT="apply_replace.sed"
> "$SED_SCRIPT"
while IFS=$'\t' read -r orig repl; do
  if [[ -n "$orig" && -n "$repl" ]]; then
    # Escape dots for sed regex compatibility
    escaped_orig=$(echo "$orig" | sed 's/\./\\./g')
    echo "s/${escaped_orig}/${repl}/g" >> "$SED_SCRIPT"
  fi
done < "$MAP_FILE"

# Handle sed in-place flag differences between macOS (BSD) and Linux (GNU)
SED_INPLACE=(-i)
if [[ "$OSTYPE" == "darwin"* ]]; then
  SED_INPLACE=(-i '')
fi

# Find and run sed ONLY on text files (grep -Iq skips binaries to prevent corruption)
find "$TARGET_DIR" -type f -exec grep -Iq . {} \; -print | while read -r text_file; do
  sed "${SED_INPLACE[@]}" -f "$SED_SCRIPT" "$text_file" 2>/dev/null || true
done

rm -f "$SED_SCRIPT"

echo "=== Anonymization completed successfully! ==="
echo "The directory '$TARGET_DIR' is now scrubbed and ready for sharing."
