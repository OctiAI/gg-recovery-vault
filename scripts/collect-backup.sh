#!/usr/bin/env bash
set -Eeuo pipefail

bundle_path="${1:?bundle path is required}"
repository_root="${2:?repository root is required}"
incoming_dir="${repository_root}/.incoming"
hourly_dir="${repository_root}/backups/hourly"
archive_dir="${repository_root}/backups/archive"
max_age_seconds="${MAX_BACKUP_AGE_SECONDS:-10800}"

rm -rf "${incoming_dir}"
mkdir -p "${incoming_dir}" "${hourly_dir}" "${archive_dir}"

mapfile -t bundle_entries < <(tar -tf "${bundle_path}")
[ "${#bundle_entries[@]}" -eq 2 ] || { echo "Unexpected export bundle contents." >&2; exit 1; }

for entry in "${bundle_entries[@]}"; do
  case "${entry}" in
    goalsgraph-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.dump.age|goalsgraph-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.dump.age.json) ;;
    *) echo "Unsafe export bundle entry." >&2; exit 1 ;;
  esac
done

tar -C "${incoming_dir}" --no-same-owner --no-same-permissions -xf "${bundle_path}"

shopt -s nullglob
age_files=("${incoming_dir}"/goalsgraph-????????T??????Z.dump.age)
manifest_files=("${incoming_dir}"/goalsgraph-????????T??????Z.dump.age.json)
[ "${#age_files[@]}" -eq 1 ] || { echo "Expected one encrypted backup." >&2; exit 1; }
[ "${#manifest_files[@]}" -eq 1 ] || { echo "Expected one backup manifest." >&2; exit 1; }

age_file="${age_files[0]}"
manifest_file="${manifest_files[0]}"
source_name="$(jq -r '.source_name // empty' "${manifest_file}")"
created_at="$(jq -r '.created_at // empty' "${manifest_file}")"
expected_sha256="$(jq -r '.ciphertext_sha256 // empty' "${manifest_file}")"
expected_bytes="$(jq -r '.ciphertext_bytes // empty' "${manifest_file}")"

[ "$(jq -r '.schema // empty' "${manifest_file}")" = "goalsgraph-age-v1" ] || { echo "Unexpected manifest schema." >&2; exit 1; }
[ "${source_name}.age" = "${age_file##*/}" ] || { echo "Manifest does not match ciphertext name." >&2; exit 1; }
case "${expected_sha256}" in ''|*[!0-9a-f]*) echo "Invalid manifest checksum." >&2; exit 1 ;; esac
case "${expected_bytes}" in ''|*[!0-9]*) echo "Invalid manifest length." >&2; exit 1 ;; esac

actual_sha256="$(sha256sum "${age_file}" | awk '{print $1}')"
actual_bytes="$(wc -c < "${age_file}")"
[ "${expected_sha256}" = "${actual_sha256}" ] || { echo "Ciphertext checksum mismatch." >&2; exit 1; }
[ "${expected_bytes}" = "${actual_bytes}" ] || { echo "Ciphertext length mismatch." >&2; exit 1; }

source_timestamp="${source_name#goalsgraph-}"
source_timestamp="${source_timestamp%.dump}"
source_epoch="$(date -u -d "${source_timestamp:0:4}-${source_timestamp:4:2}-${source_timestamp:6:2} ${source_timestamp:9:2}:${source_timestamp:11:2}:${source_timestamp:13:2} UTC" +%s)"
created_epoch="$(date -u -d "${created_at}" +%s)"
now_epoch="$(date -u +%s)"
[ "${source_epoch}" -le "${now_epoch}" ] || { echo "Future source timestamp." >&2; exit 1; }
[ "${created_epoch}" -le "${now_epoch}" ] || { echo "Future manifest timestamp." >&2; exit 1; }
[ $((now_epoch - source_epoch)) -le "${max_age_seconds}" ] || { echo "Backup source is stale." >&2; exit 1; }
[ $((now_epoch - created_epoch)) -le "${max_age_seconds}" ] || { echo "Backup manifest is stale." >&2; exit 1; }

destination_base="${hourly_dir}/${source_timestamp}"
cp "${age_file}" "${destination_base}.dump.age"
cp "${manifest_file}" "${destination_base}.dump.age.json"

week="$(date -u -d "${created_at}" +%G-W%V)"
archive_base="${archive_dir}/${week}"
if [ ! -e "${archive_base}.dump.age" ] && [ ! -e "${archive_base}.dump.age.json" ]; then
  cp "${age_file}" "${archive_base}.dump.age"
  cp "${manifest_file}" "${archive_base}.dump.age.json"
fi

cutoff_epoch=$((now_epoch - 35 * 24 * 60 * 60))
for manifest in "${hourly_dir}"/*.dump.age.json; do
  [ -e "${manifest}" ] || continue
  name="${manifest##*/}"
  timestamp="${name%.dump.age.json}"
  timestamp_epoch="$(date -u -d "${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2} UTC" +%s)"
  if [ "${timestamp_epoch}" -lt "${cutoff_epoch}" ]; then
    rm -f "${hourly_dir}/${timestamp}.dump.age" "${manifest}"
  fi
done

mapfile -t archive_manifests < <(find "${archive_dir}" -maxdepth 1 -type f -name '*.dump.age.json' -printf '%f\n' | LC_ALL=C sort -r)
for ((index = 13; index < ${#archive_manifests[@]}; index++)); do
  archive_manifest="${archive_manifests[index]}"
  rm -f "${archive_dir}/${archive_manifest%.json}" "${archive_dir}/${archive_manifest}"
done

rm -rf "${incoming_dir}"
git -C "${repository_root}" add backups
if ! git -C "${repository_root}" diff --cached --quiet; then
  git -C "${repository_root}" -c user.name='GoalsGraph Recovery Collector' -c user.email='recovery-collector@users.noreply.github.com' commit -m "Archive encrypted backup ${source_timestamp}"
  git -C "${repository_root}" push origin HEAD:main
fi
