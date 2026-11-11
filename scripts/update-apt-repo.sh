#!/usr/bin/env bash
set -euo pipefail;

action="${1:-}";
if (($#)); then shift; fi;
repo_dir="${PODLET_REPO_DIR:-}";
signing_key='';
origin='';
label='';
upload_method='';
destination='';
dry_run=false;
aws_profile='';
aws_region='';
s3_endpoint_url='';
upload_options=false;
# Scope upload environment settings to upload, so ambient CI values do not affect init/import.
if [[ "$action" == upload ]]; then
  upload_method="${PODLET_UPLOAD_METHOD:-}";
  destination="${PODLET_UPLOAD_DESTINATION:-}";
  dry_run="${PODLET_UPLOAD_DRY_RUN:-false}";
  aws_profile="${PODLET_AWS_PROFILE:-}";
  aws_region="${PODLET_AWS_REGION:-}";
  s3_endpoint_url="${PODLET_S3_ENDPOINT_URL:-}";
fi;
packages=();
while (($#)); do
  case "$1" in
    --help|-h) action=help; shift ;;
    --dry-run) dry_run=true; upload_options=true; shift ;;
    --repo-dir|--signing-key|--origin|--label|--upload-method|--destination|--aws-profile|--aws-region|--s3-endpoint-url)
      if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        printf 'Missing value for %s\n' "$1" >&2;
        exit 1;
      fi;
      case "$1" in
        --repo-dir) repo_dir="$2" ;;
        --signing-key) signing_key="$2" ;;
        --origin) origin="$2" ;;
        --label) label="$2" ;;
        --upload-method) upload_method="$2"; upload_options=true ;;
        --destination) destination="$2"; upload_options=true ;;
        --aws-profile) aws_profile="$2"; upload_options=true ;;
        --aws-region) aws_region="$2"; upload_options=true ;;
        --s3-endpoint-url) s3_endpoint_url="$2"; upload_options=true ;;
      esac;
      shift 2;
      ;;
    --) shift; packages=("$@"); break ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac;
done;
if [[ "$action" == help || "$action" == --help || "$action" == -h ]]; then
  printf '%s\n' \
    'Usage: update-apt-repo.sh init --repo-dir DIR --signing-key FINGERPRINT --origin ORIGIN --label LABEL' \
    '       update-apt-repo.sh import --repo-dir DIR --signing-key FINGERPRINT -- PACKAGE.deb [PACKAGE.deb]' \
    '       update-apt-repo.sh upload --repo-dir DIR --upload-method rsync|s3 --destination DEST [OPTIONS]' \
    '' \
    'init/import use GNUPGHOME and an existing private signing key. upload uses only the exported public key.' \
    'Serve only DIR/public/. Upload never deletes remote files or changes server/bucket access policies.' \
    '' \
    'Upload arguments override environment values:' \
    '  --repo-dir DIR           PODLET_REPO_DIR; existing managed repository' \
    '  --upload-method METHOD   PODLET_UPLOAD_METHOD; rsync or s3' \
    '  --destination DEST       PODLET_UPLOAD_DESTINATION; SSH destination or s3://BUCKET/PREFIX/' \
    '  --dry-run                PODLET_UPLOAD_DRY_RUN; true/false or 1/0 (default: false)' \
    '  --aws-profile NAME       PODLET_AWS_PROFILE; optional native AWS profile override' \
    '  --aws-region REGION      PODLET_AWS_REGION; optional native AWS region override' \
    '  --s3-endpoint-url URL     PODLET_S3_ENDPOINT_URL; optional HTTP(S) S3-compatible endpoint' \
    '' \
    'Upload requires reprepro, gpgv, hashing/filesystem tools, and rsync 3+ or AWS CLI v2.' \
    'SSH requires rsync 3+ on the remote host. Native SSH/AWS configuration supplies authentication.' \
    'Dry runs may authenticate/list remote state, but do not write remotely.' \
    '' \
    'Example: update-apt-repo.sh upload --repo-dir /srv/repository --upload-method rsync --destination user@apt-host:/srv/www/podlet/' \
    'Example: update-apt-repo.sh upload --repo-dir /srv/repository --upload-method s3 --destination s3://apt-bucket/podlet/ --dry-run';
  exit 0;
fi;

if [[ "$action" == upload ]]; then
  # Validate the upload contract before accessing repository state or invoking a transport.
  if [[ -z "$repo_dir" || ( "$upload_method" != rsync && "$upload_method" != s3 ) || -z "$destination" ]]; then
    printf '%s\n' 'Upload requires --repo-dir, --upload-method rsync|s3, and --destination.' >&2;
    exit 1;
  fi;
  if [[ -n "$signing_key" || -n "$origin" || -n "$label" || ${#packages[@]} != 0 ]]; then
    printf '%s\n' 'Upload accepts no signing-key, origin, label, or package inputs; sign/export the repository first.' >&2;
    exit 1;
  fi;
  case "$dry_run" in
    true|1) dry_run=true ;;
    false|0) dry_run=false ;;
    *) printf '%s\n' 'Invalid upload dry-run boolean: use true/false or 1/0.' >&2; exit 1 ;;
  esac;
  for value in "$repo_dir" "$destination" "$aws_profile" "$aws_region" "$s3_endpoint_url"; do
    if [[ "$value" == *[[:cntrl:]]* || "$value" == -* ]]; then
      printf '%s\n' 'Upload paths/options must contain no control characters or leading option markers.' >&2;
      exit 1;
    fi;
  done;
  if [[ "$upload_method" == rsync ]]; then
    rsync_destination_pattern='^([A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9_.-]*:/[^/]';
    remote_path="${destination#*:}";
    if [[ ! "$destination" =~ $rsync_destination_pattern || "$remote_path" =~ ^/+$ \
      || "$remote_path" =~ (^|/)\.\.?(/|$) ]]; then
      printf '%s\n' 'Use an SSH rsync destination HOST:/absolute/non-root/path/; configure ports/IPv6 with an SSH host alias.' >&2;
      exit 1;
    fi;
    if [[ -n "$aws_profile" || -n "$aws_region" || -n "$s3_endpoint_url" ]]; then
      printf '%s\n' 'AWS options apply only to the s3 upload method.' >&2;
      exit 1;
    fi;
    transport_tools=(rsync ssh);
  else
    if [[ ! "$destination" =~ ^s3://[A-Za-z0-9][A-Za-z0-9.-]*(/.*)?$ ]]; then
      printf '%s\n' 'Use an S3 destination s3://BUCKET[/PREFIX]/.' >&2;
      exit 1;
    fi;
    if [[ -n "$s3_endpoint_url" ]]; then
      endpoint_pattern='^https?://[^/?#[:space:]]+(/[^[:space:]]*)?$';
      authority="${s3_endpoint_url#*://}";
      authority="${authority%%/*}";
      if [[ ! "$s3_endpoint_url" =~ $endpoint_pattern || "$authority" == *@* \
        || "$s3_endpoint_url" == *'?'* || "$s3_endpoint_url" == *'#'* ]]; then
        printf '%s\n' 'S3 endpoint must be an HTTP(S) URL without credentials, query, or fragment.' >&2;
        exit 1;
      fi;
    fi;
    transport_tools=(aws);
  fi;
  while [[ "$destination" == */ ]]; do destination="${destination%/}"; done;
  destination+='/';
  for tool in reprepro gpgv awk find cp cmp mktemp mkdir rmdir rm tr wc "${transport_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'Missing upload tool: %s\n' "$tool" >&2;
      exit 1;
    fi;
  done;
  if command -v sha256sum >/dev/null 2>&1; then
    hash_command=(sha256sum);
  elif command -v shasum >/dev/null 2>&1; then
    hash_command=(shasum -a 256);
  else
    printf '%s\n' 'Upload requires sha256sum or shasum.' >&2;
    exit 1;
  fi;
  if [[ "$upload_method" == rsync ]]; then
    transport_version="$(rsync --version)";
    if [[ ! "$transport_version" =~ ^rsync[[:space:]]+version[[:space:]]+([0-9]+)\. ]] \
      || ((BASH_REMATCH[1] < 3)); then
      printf '%s\n' 'Upload requires rsync 3 or later, locally and on the remote host.' >&2;
      exit 1;
    fi;
  else
    transport_version="$(aws --version 2>&1)";
    if [[ ! "$transport_version" =~ ^aws-cli/2\. ]]; then
      printf '%s\n' 'S3 upload requires AWS CLI v2.' >&2;
      exit 1;
    fi;
  fi;
  if [[ ! -d "$repo_dir" ]]; then
    printf '%s\n' 'Upload requires an existing managed repository directory.' >&2;
    exit 1;
  fi;
  repo_dir="$(cd -- "$repo_dir" && pwd -P)";
  public="$repo_dir/public";
  if [[ ! -f "$repo_dir/conf/distributions" || ! -d "$repo_dir/db" || ! -d "$public/dists/trixie" \
    || -L "$public" ]]; then
    printf '%s\n' 'Upload requires the managed conf/db state and a regular public/dists/trixie tree.' >&2;
    exit 1;
  fi;
  if ! mkdir -- "$repo_dir/.podlet-update.lock"; then
    printf '%s\n' 'Repository is locked; another update/upload may be running.' >&2;
    exit 1;
  fi;
  work_dir='';
  trap 'if [[ -n "$work_dir" ]]; then rm -rf -- "$work_dir"; fi; rmdir -- "$repo_dir/.podlet-update.lock"' EXIT;
  trap 'exit 130' INT;
  trap 'exit 143' TERM;
  work_dir="$(mktemp -d "$repo_dir/.podlet-upload.XXXXXX")";
  selected=("$public/dists" "$public/podlet-archive-keyring.gpg");
  if [[ -e "$public/pool" || -L "$public/pool" ]]; then
    if [[ ! -d "$public/pool" ]]; then printf '%s\n' 'public/pool must be a directory.' >&2; exit 1; fi;
    selected+=("$public/pool");
  fi;
  # Inspect before copying; no symlink, FIFO, device, or socket is part of the public snapshot.
  find "${selected[@]}" ! -type d ! -type f -print > "$work_dir/unsafe-files";
  if [[ -s "$work_dir/unsafe-files" ]]; then
    printf '%s\n' 'Refusing to upload symlinks or special files in public repository content.' >&2;
    exit 1;
  fi;
  for file in podlet-archive-keyring.gpg dists/trixie/InRelease dists/trixie/Release dists/trixie/Release.gpg; do
    if [[ ! -s "$public/$file" ]]; then printf 'Missing public upload artifact: %s\n' "$file" >&2; exit 1; fi;
  done;
  reprepro --basedir "$repo_dir" --outdir "$public" check trixie;
  reprepro --basedir "$repo_dir" --outdir "$public" checkpool;
  snapshot="$work_dir/public";
  mkdir -- "$snapshot";
  cp -R -- "${selected[@]}" "$snapshot/";
  mkdir -p -- "$snapshot/pool";
  release="$snapshot/dists/trixie/Release";
  gpgv --keyring "$snapshot/podlet-archive-keyring.gpg" --output "$work_dir/verified-release" "$snapshot/dists/trixie/InRelease";
  gpgv --keyring "$snapshot/podlet-archive-keyring.gpg" "$snapshot/dists/trixie/Release.gpg" "$release";
  cmp -- "$work_dir/verified-release" "$release";
  # Validate the signed index manifest before trusting paths or bytes from the snapshot.
  awk '/^SHA256:$/ { active=1; next } /^[^[:space:]]/ { active=0 } active && NF { print }' "$release" > "$work_dir/hash-entries";
  if [[ ! -s "$work_dir/hash-entries" ]]; then
    printf '%s\n' 'Release must contain SHA256 index entries.' >&2;
    exit 1;
  fi;
  while read -r digest size path extra; do
    if [[ ! "$digest" =~ ^[[:xdigit:]]{64}$ || ! "$size" =~ ^(0|[1-9][0-9]*)$ \
      || ! "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._+/-]*$ || "$path" =~ (^|/)\.\.?(/|$) || -n "$extra" ]]; then
      printf '%s\n' 'Invalid or unsafe SHA256 index entry in Release.' >&2;
      exit 1;
    fi;
    index="$snapshot/dists/trixie/$path";
    if [[ ! -f "$index" ]]; then printf 'Missing signed index: %s\n' "$path" >&2; exit 1; fi;
    actual_size="$(wc -c < "$index")";
    actual_size="${actual_size//[[:space:]]/}";
    actual_hash="$("${hash_command[@]}" < "$index")";
    actual_hash="${actual_hash%% *}";
    digest="$(printf '%s' "$digest" | tr '[:upper:]' '[:lower:]')";
    if [[ "$actual_size" != "$size" || "$actual_hash" != "$digest" ]]; then
      printf 'Signed index size/checksum mismatch: %s\n' "$path" >&2;
      exit 1;
    fi;
  done < "$work_dir/hash-entries";
  # Isolate mutable indexes from the three top-level release publication files.
  mkdir -- "$work_dir/indexes";
  cp -R -- "$snapshot/dists" "$work_dir/indexes/";
  rm -- "$work_dir/indexes/dists/trixie/Release" "$work_dir/indexes/dists/trixie/Release.gpg" "$work_dir/indexes/dists/trixie/InRelease";
  if [[ "$upload_method" == rsync ]]; then
    rsync_options=(--recursive --times --omit-dir-times --perms --checksum --delay-updates --protect-args \
      '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r' --rsh='ssh -o BatchMode=yes');
    if [[ "$dry_run" == true ]]; then rsync_options+=(--dry-run); fi;
    rsync "${rsync_options[@]}" -- "$snapshot/pool/" "${destination}pool/";
    rsync "${rsync_options[@]}" -- "$snapshot/podlet-archive-keyring.gpg" "$destination";
    rsync "${rsync_options[@]}" -- "$work_dir/indexes/dists/" "${destination}dists/";
    for file in Release Release.gpg InRelease; do
      rsync "${rsync_options[@]}" -- "$snapshot/dists/trixie/$file" "${destination}dists/trixie/$file";
    done;
  else
    aws_options=(--no-cli-pager --no-cli-auto-prompt);
    if [[ -n "$aws_profile" ]]; then aws_options+=(--profile "$aws_profile"); fi;
    if [[ -n "$aws_region" ]]; then aws_options+=(--region "$aws_region"); fi;
    if [[ -n "$s3_endpoint_url" ]]; then aws_options+=(--endpoint-url "$s3_endpoint_url"); fi;
    transfer_options=(--no-follow-symlinks --only-show-errors --no-progress);
    if [[ "$dry_run" == true ]]; then transfer_options+=(--dryrun); fi;
    aws "${aws_options[@]}" s3 sync "$snapshot/pool/" "${destination}pool/" "${transfer_options[@]}";
    aws "${aws_options[@]}" s3 cp "$snapshot/podlet-archive-keyring.gpg" "${destination}podlet-archive-keyring.gpg" \
      "${transfer_options[@]}" --cache-control no-cache;
    aws "${aws_options[@]}" s3 cp "$work_dir/indexes/dists/" "${destination}dists/" \
      --recursive "${transfer_options[@]}" --cache-control no-cache;
    for file in Release Release.gpg InRelease; do
      aws "${aws_options[@]}" s3 cp "$snapshot/dists/trixie/$file" "${destination}dists/trixie/$file" \
        "${transfer_options[@]}" --cache-control no-cache;
    done;
  fi;
  if [[ "$dry_run" == true ]]; then
    printf 'Upload dry run completed for %s; no remote writes performed.\n' "$destination";
  else
    printf 'Repository upload completed: %s\n' "$destination";
  fi;
  exit 0;
fi;
if [[ "$upload_options" == true ]]; then
  printf '%s\n' 'Upload-specific options require the upload action.' >&2;
  exit 1;
fi;
if [[ "$action" != init && "$action" != import ]]; then
  printf '%s\n' 'Choose init, import, or upload; use --help for usage.' >&2;
  exit 1;
fi;
if [[ -z "$repo_dir" || ! "$signing_key" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
  printf '%s\n' 'Supply --repo-dir and a full GPG primary-key fingerprint with --signing-key.' >&2;
  exit 1;
fi;
if [[ "$action" == init ]]; then
  if [[ ! "$origin" =~ [^[:space:]] || ! "$label" =~ [^[:space:]] \
    || "$origin" == *[[:cntrl:]]* || "$label" == *[[:cntrl:]]* || ${#packages[@]} != 0 ]]; then
    printf '%s\n' 'Initialization requires single-line --origin and --label, and no packages.' >&2;
    exit 1;
  fi;
elif [[ -n "$origin" || -n "$label" || ${#packages[@]} == 0 || ${#packages[@]} -gt 2 ]]; then
  printf '%s\n' 'Import accepts one or two packages and reuses the configured origin and label.' >&2;
  exit 1;
fi;
for tool in reprepro gpg awk mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$tool" >&2;
    exit 1;
  fi;
done;
if [[ "$action" == import ]]; then
  for tool in dpkg dpkg-deb; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'Missing required tool: %s\n' "$tool" >&2;
      exit 1;
    fi;
  done;
fi;
signing_key="$(printf '%s' "$signing_key" | tr '[:lower:]' '[:upper:]')";
actual_key="$(gpg --batch --with-colons --list-secret-keys "$signing_key" | awk -F: '$1 == "fpr" { print $10; exit }')";
if [[ "$actual_key" != "$signing_key" ]]; then
  printf '%s\n' 'The requested primary signing key is unavailable in the current GPG keyring.' >&2;
  exit 1;
fi;

# Validate the entire input batch before changing repository state.
batch_version='';
seen_architectures=' ';
for index in "${!packages[@]}"; do
  package="${packages[$index]}";
  if [[ ! -f "$package" || "$package" != *.deb ]]; then
    printf 'Not a .deb file: %s\n' "$package" >&2;
    exit 1;
  fi;
  packages[index]="$(cd -- "$(dirname -- "$package")" && pwd -P)/$(basename -- "$package")";
  package="${packages[$index]}";
  package_name="$(dpkg-deb -f "$package" Package)";
  architecture="$(dpkg-deb -f "$package" Architecture)";
  version="$(dpkg-deb -f "$package" Version)";
  if [[ "$package_name" != podlet || ( "$architecture" != amd64 && "$architecture" != arm64 ) ]]; then
    printf 'Expected podlet for amd64 or arm64: %s\n' "$package" >&2;
    exit 1;
  fi;
  dpkg --validate-version "$version";
  if [[ "$seen_architectures" == *" $architecture "* || ( -n "$batch_version" && "$version" != "$batch_version" ) ]]; then
    printf '%s\n' 'Supply at most one package per architecture, with identical versions in a batch.' >&2;
    exit 1;
  fi;
  batch_version="$version";
  seen_architectures+="$architecture ";
done;

if [[ "$action" == import && ! -f "$repo_dir/conf/distributions" ]]; then
  printf '%s\n' 'Repository is not initialized; run init first.' >&2;
  exit 1;
fi;
# Public artifacts need predictable read permissions even for an operator with umask 077.
umask 022;
mkdir -p -- "$repo_dir";
repo_dir="$(cd -- "$repo_dir" && pwd -P)";
# Serialize complete batches, in addition to reprepro's per-command database locks.
if ! mkdir -- "$repo_dir/.podlet-update.lock"; then
  printf '%s\n' 'Repository is locked; another update may be running.' >&2;
  exit 1;
fi;
work_dir='';
trap 'if [[ -n "$work_dir" ]]; then rm -rf -- "$work_dir"; fi; rmdir -- "$repo_dir/.podlet-update.lock"' EXIT;
trap 'exit 130' INT;
trap 'exit 143' TERM;
work_dir="$(mktemp -d "$repo_dir/.podlet-update.XXXXXX")";
config="$repo_dir/conf/distributions";
if [[ "$action" == init ]]; then
  if [[ -e "$config" || -L "$config" || -e "$repo_dir/db" || -e "$repo_dir/public" ]]; then
    printf '%s\n' 'Refusing to initialize over existing repository configuration, database, or public files.' >&2;
    exit 1;
  fi;
  printf '%s\n' "Origin: $origin" "Label: $label" 'Suite: trixie' 'Codename: trixie' \
    'Architectures: amd64 arm64' 'Components: main' 'Description: Podlet packages for Debian 13' \
    "SignWith: $signing_key" 'DebIndices: Packages Release . .gz' > "$work_dir/distributions";
  config="$work_dir/distributions";
else
  # Allow identity/description edits, while requiring the signed trixie/main contract.
  if ! awk -v key="$signing_key" '
    /^Codename:/ { codename++; if ($0 != "Codename: trixie") bad=1 }
    /^Suite:/ { suite++; if ($0 != "Suite: trixie") bad=1 }
    /^Components:/ { components++; if ($0 != "Components: main") bad=1 }
    /^Architectures:/ { architectures++; if ($0 != "Architectures: amd64 arm64") bad=1 }
    /^SignWith:/ { signing++; if ($0 != "SignWith: " key) bad=1 }
    END { exit (bad || codename != 1 || suite != 1 || components != 1 || architectures != 1 || signing != 1) }
  ' "$config"; then
    printf '%s\n' 'Configuration must retain trixie/main, amd64 arm64, and the supplied signing fingerprint.' >&2;
    exit 1;
  fi;
fi;

# Prove the secret key can sign before any package import; passphrases use gpg-agent/pinentry.
gpg --batch --local-user "$signing_key" --output "$work_dir/probe.sig" --detach-sign "$config";
gpg --batch --export-options export-minimal --export "$signing_key" > "$work_dir/keyring.gpg";
if [[ ! -s "$work_dir/keyring.gpg" ]]; then
  printf '%s\n' 'Public-key export was empty.' >&2;
  exit 1;
fi;
if [[ "$action" == init ]]; then
  mkdir -p -- "$repo_dir/conf" "$repo_dir/db";
  chmod 700 "$repo_dir/conf" "$repo_dir/db";
  install -m644 "$config" "$repo_dir/conf/distributions";
fi;
mkdir -p -- "$repo_dir/public";
if ((${#packages[@]})); then
  for package in "${packages[@]}"; do
    # Keep old pool files while published indexes still reference the previous release.
    reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" --keepunreferencedfiles \
      --export=never --component main includedeb trixie "$package";
  done;
fi;
reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" export trixie;
for file in InRelease Release Release.gpg; do
  if [[ ! -s "$repo_dir/public/dists/trixie/$file" ]]; then
    printf 'Missing signed release artifact: %s\n' "$file" >&2;
    exit 1;
  fi;
done;
install -m644 "$work_dir/keyring.gpg" "$repo_dir/public/podlet-archive-keyring.gpg";
printf 'Repository ready in %s/public/ (serve only this directory).\n' "$repo_dir";
