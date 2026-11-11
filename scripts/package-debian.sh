#!/usr/bin/env bash
set -euo pipefail;

action="${PODLET_ACTION:-all}";
username="${PODLET_USERNAME:-${DEBFULLNAME:-}}";
email="${PODLET_EMAIL:-${DEBEMAIL:-}}";
signing_key="${PODLET_GPG_SIGN_KEY:-${DEB_SIGN_KEYID:-}}";
version="${PODLET_VERSION:-}";
output_dir="${PODLET_OUTPUT_DIR:-}";
repo_dir="${PODLET_REPO_DIR:-}";
cache_dir="${PODLET_CACHE_DIR:-}";
origin="${PODLET_ORIGIN:-Podlet}";
label="${PODLET_LABEL:-Podlet}";
amd64_package="${PODLET_AMD64_PACKAGE:-}";
arm64_package="${PODLET_ARM64_PACKAGE:-}";
jobs="${PODLET_JOBS:-}";
install_deps="${PODLET_INSTALL_DEPS:-false}";
skip_fetch="${PODLET_SKIP_FETCH:-false}";
no_sign_build="${PODLET_NO_SIGN_BUILD:-false}";
ci="${PODLET_CI:-${CI:-false}}";

while (($#)); do
  case "$1" in
    --help|-h)
      printf '%s\n' \
        'Usage: package-debian.sh [--action build|repo|all] [OPTIONS]' \
        'Native Debian 13 amd64/arm64 only. CLI arguments override environment values.' \
        '' \
        '  --username NAME          PODLET_USERNAME (or DEBFULLNAME); maintainer full name' \
        '  --email ADDRESS          PODLET_EMAIL (or DEBEMAIL); maintainer email' \
        '  --gpg-sign-key FPR       PODLET_GPG_SIGN_KEY (or DEB_SIGN_KEYID); full primary fingerprint' \
        '  --action ACTION          PODLET_ACTION; build, repo, or all (default: all)' \
        '  --version VERSION        PODLET_VERSION; build defaults to debian/changelog' \
        '  --output-dir DIR         PODLET_OUTPUT_DIR; default: CHECKOUT/dist/debian' \
        '  --repo-dir DIR           PODLET_REPO_DIR; default: OUTPUT_DIR/apt' \
        '  --cache-dir DIR          PODLET_CACHE_DIR; default: CHECKOUT/.debian-cargo-home' \
        '  --origin TEXT            PODLET_ORIGIN; new repository Origin (default: Podlet)' \
        '  --label TEXT             PODLET_LABEL; new repository Label (default: Podlet)' \
        '  --amd64-package FILE     PODLET_AMD64_PACKAGE; existing main package' \
        '  --arm64-package FILE     PODLET_ARM64_PACKAGE; existing main package' \
        '  --jobs NUMBER            PODLET_JOBS; default: processor count' \
        '  --install-deps           PODLET_INSTALL_DEPS; permit apt-get installation' \
        '  --skip-fetch             PODLET_SKIP_FETCH; use the existing Cargo cache' \
        '  --no-sign-build          PODLET_NO_SIGN_BUILD; repository is still signed' \
        '  --ci                     PODLET_CI (or CI); require an already usable signing agent' \
        '' \
        'Boolean environment values: true/false or 1/0. GNUPGHOME selects the existing keyring.' \
        'Names and email are required for build/all. A signing key is required except for unsigned build-only.' \
        'Repo-only requires at least one --amd64-package or --arm64-package.' \
        'Relative paths resolve from the calling directory. No deployment or client configuration is performed.' \
        '' \
        'Example: package-debian.sh --username "Your Name" --email you@example.com --gpg-sign-key FINGERPRINT' \
        'Example: package-debian.sh --action build --username "Your Name" --email you@example.com --no-sign-build';
      exit 0;
      ;;
    --install-deps) install_deps=true; shift ;;
    --skip-fetch) skip_fetch=true; shift ;;
    --no-sign-build) no_sign_build=true; shift ;;
    --ci) ci=true; shift ;;
    --action|--username|--email|--gpg-sign-key|--version|--output-dir|--repo-dir|--cache-dir|--origin|--label|--amd64-package|--arm64-package|--jobs)
      if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        printf 'Missing value for %s\n' "$1" >&2;
        exit 1;
      fi;
      case "$1" in
        --action) action="$2" ;;
        --username) username="$2" ;;
        --email) email="$2" ;;
        --gpg-sign-key) signing_key="$2" ;;
        --version) version="$2" ;;
        --output-dir) output_dir="$2" ;;
        --repo-dir) repo_dir="$2" ;;
        --cache-dir) cache_dir="$2" ;;
        --origin) origin="$2" ;;
        --label) label="$2" ;;
        --amd64-package) amd64_package="$2" ;;
        --arm64-package) arm64_package="$2" ;;
        --jobs) jobs="$2" ;;
      esac;
      shift 2;
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac;
done;

# Resolve and validate the effective contract before invoking privileged or stateful tools.
for setting in install_deps skip_fetch no_sign_build ci; do
  case "${!setting}" in
    true|1) printf -v "$setting" '%s' true ;;
    false|0) printf -v "$setting" '%s' false ;;
    *) printf 'Invalid boolean for %s: use true/false or 1/0.\n' "$setting" >&2; exit 1 ;;
  esac;
done;
if [[ "$action" != build && "$action" != repo && "$action" != all ]]; then
  printf '%s\n' 'Invalid action: choose build, repo, or all.' >&2;
  exit 1;
fi;
if [[ "$action" != repo ]] && { [[ ! "$username" =~ [^[:space:]] || "$username" == *[[:cntrl:]\<\>\\]* ]] \
  || [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }; then
  printf '%s\n' 'Supply --username (maintainer full name) and a valid --email without control characters.' >&2;
  exit 1;
fi;
if [[ -n "$version" && ! "$version" =~ ^[0-9][A-Za-z0-9.+~:-]*$ ]]; then
  printf '%s\n' 'Invalid Debian version.' >&2;
  exit 1;
fi;
if [[ -n "$jobs" && ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' '--jobs must be a positive integer.' >&2;
  exit 1;
fi;
if [[ ! "$origin" =~ [^[:space:]] || ! "$label" =~ [^[:space:]] \
  || "$origin" == *[[:cntrl:]]* || "$label" == *[[:cntrl:]]* ]]; then
  printf '%s\n' 'Origin and label must be nonempty single-line values.' >&2;
  exit 1;
fi;
needs_key=true;
if [[ "$action" == build && "$no_sign_build" == true ]]; then needs_key=false; fi;
if [[ "$needs_key" == true && ! "$signing_key" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
  printf '%s\n' 'Supply --gpg-sign-key with a full primary-key fingerprint.' >&2;
  exit 1;
fi;
if [[ "$action" == repo && -z "$amd64_package" && -z "$arm64_package" ]]; then
  printf '%s\n' 'Repo action requires --amd64-package or --arm64-package.' >&2;
  exit 1;
fi;
if [[ "$action" == build && ( -n "$amd64_package" || -n "$arm64_package" ) ]]; then
  printf '%s\n' 'Existing package inputs apply only to repo/all actions.' >&2;
  exit 1;
fi;
for value in "$output_dir" "$repo_dir" "$cache_dir" "$amd64_package" "$arm64_package"; do
  if [[ "$value" == *[[:cntrl:]]* ]]; then
    printf '%s\n' 'Paths must not contain control characters.' >&2;
    exit 1;
  fi;
done;
if [[ ! -r /etc/os-release ]]; then
  printf '%s\n' 'Run this workflow on native Debian 13.' >&2;
  exit 1;
fi;
# shellcheck source=/dev/null
source /etc/os-release;
if [[ "${ID:-}" != debian || "${VERSION_ID:-}" != 13 ]]; then
  printf '%s\n' 'Run this workflow on native Debian 13.' >&2;
  exit 1;
fi;
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)";
for file in Cargo.toml Cargo.lock debian/control debian/changelog debian/rules scripts/update-apt-repo.sh; do
  if [[ ! -f "$project_dir/$file" ]]; then
    printf 'Missing workflow source: %s\n' "$file" >&2;
    exit 1;
  fi;
done;

# dpkg/coreutils are Essential Debian tools; reject invalid explicit inputs before optional apt-get.
if [[ -n "$version" ]]; then dpkg --validate-version "$version"; fi;
output_dir="$(realpath -m -- "${output_dir:-$project_dir/dist/debian}")";
repo_dir="$(realpath -m -- "${repo_dir:-$output_dir/apt}")";
cache_dir="$(realpath -m -- "${cache_dir:-$project_dir/.debian-cargo-home}")";
if [[ "$output_dir" == "$project_dir" || "$cache_dir" == "$project_dir" \
  || "$repo_dir" == "$project_dir" || "$output_dir" == / || "$cache_dir" == / || "$repo_dir" == / ]]; then
  printf '%s\n' 'Output, cache, and repository paths must be dedicated subdirectories, not filesystem/source roots.' >&2;
  exit 1;
fi;

# Installation is explicit; only this block may elevate privileges or modify system packages.
dependencies=(dpkg-dev binutils coreutils gawk tar);
tools=(bash dpkg dpkg-deb awk sed grep tr mktemp tar realpath nproc cp mv ln chmod mkdir rmdir rm install dirname basename cmp);
if [[ "$action" != repo ]]; then
  dependencies+=(build-essential debhelper cargo rustc ca-certificates devscripts lintian jq);
  tools+=(cargo rustc dh dpkg-buildpackage dpkg-parsechangelog dch dscverify lintian jq cmp);
fi;
if [[ "$needs_key" == true ]]; then
  dependencies+=(gnupg gpgv);
  tools+=(gpg gpgv);
fi;
if [[ "$action" != build ]]; then
  dependencies+=(reprepro);
  tools+=(reprepro);
fi;
if [[ "$install_deps" == true ]]; then
  if ! command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' 'apt-get is required for --install-deps.' >&2;
    exit 1;
  fi;
  elevate=();
  if ((EUID != 0)); then
    if ! command -v sudo >/dev/null 2>&1; then
      printf '%s\n' 'sudo is required to install dependencies from an ordinary account.' >&2;
      exit 1;
    fi;
    elevate=(sudo);
    if [[ "$ci" == true ]]; then elevate+=(-n); fi;
  fi;
  # An empty array must be guarded on macOS Bash 3.2, even though execution targets Debian.
  if ((${#elevate[@]})); then
    "${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update;
    "${elevate[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${dependencies[@]}";
  else
    DEBIAN_FRONTEND=noninteractive apt-get update;
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${dependencies[@]}";
  fi;
fi;
missing=();
for tool in "${tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then missing+=("$tool"); fi;
done;
if ((${#missing[@]})); then
  printf 'Missing required tools: %s\n' "${missing[*]}" >&2;
  printf 'Install with --install-deps, or: sudo apt-get install --no-install-recommends %s\n' "${dependencies[*]}" >&2;
  exit 1;
fi;
architecture="$(dpkg --print-architecture)";
case "$architecture" in
  amd64) rust_target=x86_64-unknown-linux-gnu ;;
  arm64) rust_target=aarch64-unknown-linux-gnu ;;
  *) printf 'Unsupported native architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac;
if [[ "$action" != repo ]]; then
  rust_host="$(rustc -vV | awk '/^host: / { print $2 }')";
  if [[ "$rust_host" != "$rust_target" ]]; then
    printf 'Expected native Rust compiler %s; got %s.\n' "$rust_target" "$rust_host" >&2;
    exit 1;
  fi;
  if [[ ( "$architecture" == amd64 && -n "$amd64_package" ) || ( "$architecture" == arm64 && -n "$arm64_package" ) ]]; then
    printf '%s\n' 'Do not supply an existing package for the architecture being built.' >&2;
    exit 1;
  fi;
  version="${version:-$(dpkg-parsechangelog --file "$project_dir/debian/changelog" --show-field Version)}";
fi;
if [[ -n "$version" ]]; then dpkg --validate-version "$version"; fi;
jobs="${jobs:-$(nproc)}";

# Validate both supplied inputs before starting a build or mutating the repository.
batch_version="$version";
packages=();
for input_arch in amd64 arm64; do
  if [[ "$input_arch" == amd64 ]]; then input_file="$amd64_package"; else input_file="$arm64_package"; fi;
  if [[ -z "$input_file" ]]; then continue; fi;
  input_file="$(realpath -e -- "$input_file")";
  if [[ ! -f "$input_file" || "$input_file" != *.deb ]]; then
    printf 'Not a .deb file: %s\n' "$input_file" >&2;
    exit 1;
  fi;
  package_name="$(dpkg-deb -f "$input_file" Package)";
  package_arch="$(dpkg-deb -f "$input_file" Architecture)";
  package_version="$(dpkg-deb -f "$input_file" Version)";
  if [[ "$package_name" != podlet || "$package_arch" != "$input_arch" ]]; then
    printf 'Expected the main podlet package for %s: %s\n' "$input_arch" "$input_file" >&2;
    exit 1;
  fi;
  dpkg --validate-version "$package_version";
  if [[ -n "$batch_version" && "$package_version" != "$batch_version" ]]; then
    printf '%s\n' 'All packages and any requested version must match exactly.' >&2;
    exit 1;
  fi;
  batch_version="$package_version";
  packages+=("$input_file");
done;

work_dir='';
publish_dir='';
artifact_lock='';
trap 'if [[ -n "$work_dir" ]]; then rm -rf -- "$work_dir"; fi; if [[ -n "$publish_dir" ]]; then rm -rf -- "$publish_dir"; fi; if [[ -n "$artifact_lock" ]]; then rmdir -- "$artifact_lock"; fi' EXIT;
trap 'exit 130' INT;
trap 'exit 143' TERM;
if [[ "$action" != repo ]]; then
  artifact_dir="$output_dir/$version/$architecture";
  if [[ -e "$artifact_dir" || -L "$artifact_dir" ]]; then
    printf 'Refusing to replace artifact directory: %s\n' "$artifact_dir" >&2;
    exit 1;
  fi;
  mkdir -p -- "$output_dir/$version";
  if ! mkdir -- "$output_dir/$version/.$architecture.lock"; then
    printf '%s\n' 'Another build owns the artifact lock; check for an active process before removing a stale lock.' >&2;
    exit 1;
  fi;
  artifact_lock="$output_dir/$version/.$architecture.lock";
fi;
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/podlet-workflow.XXXXXX")";

if [[ "$needs_key" == true ]]; then
  signing_key="$(printf '%s' "$signing_key" | tr '[:lower:]' '[:upper:]')";
  gpg_command="$(command -v gpg)";
  if [[ "$ci" == true ]]; then
    # Native tools require an executable signing command, rather than a command with extra arguments.
    mkdir -- "$work_dir/bin";
    printf '#!/usr/bin/env bash\nexec %q --batch --no-tty --pinentry-mode error "$@";\n' "$gpg_command" > "$work_dir/bin/gpg";
    chmod 755 "$work_dir/bin/gpg";
    export PATH="$work_dir/bin:$PATH";
  fi;
  actual_key="$(gpg --batch --with-colons --list-secret-keys "$signing_key" | awk -F: '$1 == "fpr" && !seen { print $10; seen=1 }')";
  if [[ "$actual_key" != "$signing_key" ]]; then
    printf '%s\n' 'The requested primary GPG key is unavailable.' >&2;
    exit 1;
  fi;
  printf '%s\n' 'Podlet signing preflight' > "$work_dir/probe";
  gpg --batch --local-user "$signing_key" --output "$work_dir/probe.sig" --detach-sign "$work_dir/probe";
  gpg --batch --export-options export-minimal --export "$signing_key" > "$work_dir/keyring.gpg";
  if [[ ! -s "$work_dir/keyring.gpg" ]]; then
    printf '%s\n' 'The public signing key export was empty.' >&2;
    exit 1;
  fi;
fi;

if [[ "$action" != repo ]]; then
  # Copy the working source, excluding local state, and edit metadata only inside that copy.
  source_dir="$work_dir/source";
  mkdir -- "$source_dir";
  exclusions=(--exclude=./.git --exclude=./target --exclude=./dist --exclude=./reports --exclude=./tests \
    --exclude=./.debian-cargo-home --exclude=./.pytest_cache --exclude=./debian/.debhelper \
    --exclude=./debian/podlet --exclude=./debian/podlet-dbgsym --exclude=./debian/files \
    --exclude=./debian/debhelper-build-stamp '--exclude=./debian/*.log' '--exclude=./debian/*.substvars' \
    '--exclude=./debian/*.debhelper');
  for directory in "$output_dir" "$repo_dir" "$cache_dir"; do
    if [[ "$directory" == "$project_dir/"* ]]; then exclusions+=("--exclude=./${directory#"$project_dir/"}"); fi;
  done;
  tar -C "$project_dir" "${exclusions[@]}" -cf "$work_dir/source.tar" .;
  tar -C "$source_dir" -xf "$work_dir/source.tar";
  rm -- "$work_dir/source.tar";
  mkdir -p -- "$cache_dir";
  ln -s -- "$cache_dir" "$source_dir/.debian-cargo-home";
  export DEBFULLNAME="$username" DEBEMAIL="$email";
  export CARGO_HOME="$source_dir/.debian-cargo-home";
  export DEB_BUILD_OPTIONS="parallel=$jobs";
  unset DEB_BUILD_PROFILES;
  cd -- "$source_dir";
  maintainer="$username <$email>";
  awk -v maintainer="$maintainer" '/^Maintainer:/ { print "Maintainer: " maintainer; count++; next } { print } END { if (count != 1) exit 1 }' \
    debian/control > "$work_dir/control";
  mv -- "$work_dir/control" debian/control;
  # Replace a same-version top entry in the copy, rather than creating duplicate changelog versions.
  previous_version="$(dpkg-parsechangelog --show-field Version)";
  mv -- debian/changelog "$work_dir/previous-changelog";
  dch --no-conf --changelog debian/changelog --create --package podlet --newversion "$version" --distribution trixie \
    --force-distribution 'Build from the working source for a private APT repository.';
  if [[ "$previous_version" == "$version" ]]; then
    awk 'NR == 1 { next } /^podlet \(/ { history=1 } history { print }' "$work_dir/previous-changelog" > "$work_dir/changelog-history";
  else
    cp -- "$work_dir/previous-changelog" "$work_dir/changelog-history";
  fi;
  if [[ -s "$work_dir/changelog-history" ]]; then
    printf '\n' >> debian/changelog;
    while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$work_dir/changelog-history" >> debian/changelog;
  fi;
  if [[ "$skip_fetch" == false ]]; then
    CARGO_NET_OFFLINE=false cargo fetch --locked --target "$rust_target";
  fi;
  build_options=(--build=binary);
  if [[ "$no_sign_build" == true ]]; then
    build_options+=(--no-sign);
  else
    build_options+=(--sign-backend=gpg "--sign-command=$(command -v gpg)" "--sign-key=$signing_key" --force-sign);
  fi;
  CARGO_NET_OFFLINE=true dpkg-buildpackage "${build_options[@]}";
  cmp -- "$project_dir/Cargo.lock" Cargo.lock;
  archive_version="${version#*:}";
  main_package="$work_dir/podlet_${archive_version}_${architecture}.deb";
  changes="$work_dir/podlet_${archive_version}_${architecture}.changes";
  buildinfo="$work_dir/podlet_${archive_version}_${architecture}.buildinfo";
  for file in "$main_package" "$changes" "$buildinfo"; do
    if [[ ! -s "$file" ]]; then printf 'Missing build artifact: %s\n' "$file" >&2; exit 1; fi;
  done;
  for field in Package Version Architecture Maintainer; do
    value="$(dpkg-deb -f "$main_package" "$field")";
    case "$field" in
      Package) expected=podlet ;;
      Version) expected="$version" ;;
      Architecture) expected="$architecture" ;;
      Maintainer) expected="$maintainer" ;;
    esac;
    if [[ "$value" != "$expected" ]]; then
      printf 'Unexpected %s in built package: %s\n' "$field" "$value" >&2;
      exit 1;
    fi;
  done;
  dpkg-deb --info "$main_package";
  dpkg-deb --contents "$main_package";
  lintian "$changes";
  if [[ "$no_sign_build" == true ]]; then
    dscverify --no-conf --no-default-keyrings --nosigcheck "$changes" "$buildinfo";
  else
    dscverify --no-conf --no-default-keyrings --keyring "$work_dir/keyring.gpg" "$changes" "$buildinfo";
    for file in "$changes" "$buildinfo"; do gpgv --keyring "$work_dir/keyring.gpg" "$file"; done;
  fi;
  dpkg-deb --extract "$main_package" "$work_dir/extracted";
  binary_version="$("$work_dir/extracted/usr/bin/podlet" --version)";
  upstream_version="$(cargo metadata --locked --offline --no-deps --format-version 1 | jq -er '.packages[] | select(.name == "podlet") | .version')";
  if [[ -z "$upstream_version" || "$binary_version" != "podlet $upstream_version" ]]; then
    printf 'Unexpected extracted executable version: %s\n' "$binary_version" >&2;
    exit 1;
  fi;
  "$work_dir/extracted/usr/bin/podlet" --skip-services-check --podman-version 5.4 \
    podman run quay.io/podman/hello > "$work_dir/smoke.container";
  if ! grep -Fxq '[Container]' "$work_dir/smoke.container" \
    || ! grep -Fxq 'Image=quay.io/podman/hello' "$work_dir/smoke.container"; then
    printf '%s\n' 'The extracted executable did not generate the expected Quadlet.' >&2;
    exit 1;
  fi;
  publish_dir="$(mktemp -d "$output_dir/$version/.$architecture.XXXXXX")";
  shopt -s nullglob;
  artifacts=("$work_dir/"*.deb "$changes" "$buildinfo");
  cp -- "${artifacts[@]}" "$publish_dir/";
  # Stage on the destination filesystem, then publish without replacing another run's artifacts.
  mv -T --no-clobber -- "$publish_dir" "$artifact_dir";
  if [[ -d "$publish_dir" ]]; then
    printf 'Artifact destination appeared during the build: %s\n' "$artifact_dir" >&2;
    exit 1;
  fi;
  publish_dir='';
  main_package="$artifact_dir/$(basename -- "$main_package")";
  packages+=("$main_package");
  printf 'Verified build artifacts: %s\n' "$artifact_dir";
fi;

if [[ "$action" != build ]]; then
  cd -- "$project_dir";
  if [[ ! -f "$repo_dir/conf/distributions" ]]; then
    bash "$project_dir/scripts/update-apt-repo.sh" init --repo-dir "$repo_dir" --signing-key "$signing_key" \
      --origin "$origin" --label "$label";
  fi;
  bash "$project_dir/scripts/update-apt-repo.sh" import --repo-dir "$repo_dir" --signing-key "$signing_key" -- "${packages[@]}";
  reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" check trixie;
  reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" checkpool;
  # A consistent repository can still contain an older package if reprepro skipped an import.
  for package in "${packages[@]}"; do
    package_arch="$(dpkg-deb -f "$package" Architecture)";
    package_version="$(dpkg-deb -f "$package" Version)";
    # These placeholders are expanded by reprepro, not by the shell.
    # shellcheck disable=SC2016
    installed_version="$(reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" \
      --architecture "$package_arch" --list-format '${version}\n' list trixie podlet)";
    # shellcheck disable=SC2016
    installed_file="$(reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" \
      --architecture "$package_arch" --list-format '${$fullfilename}\n' list trixie podlet)";
    if [[ "$installed_version" != "$package_version" || ! -f "$installed_file" ]] \
      || ! cmp -s -- "$package" "$installed_file"; then
      printf 'Repository does not contain the selected %s package with identical contents.\n' "$package_arch" >&2;
      exit 1;
    fi;
  done;
  for file in InRelease Release.gpg; do
    if [[ "$file" == InRelease ]]; then
      gpgv --keyring "$work_dir/keyring.gpg" "$repo_dir/public/dists/trixie/$file";
    else
      gpgv --keyring "$work_dir/keyring.gpg" "$repo_dir/public/dists/trixie/$file" "$repo_dir/public/dists/trixie/Release";
    fi;
  done;
  printf 'Verified local APT repository: %s/public/\n' "$repo_dir";
fi;
