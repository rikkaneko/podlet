# Debian 13 packages and APT repository

Build Podlet on **native Debian 13 (Trixie)**, once on amd64 and once on arm64, using `debian/`, debhelper, and `dpkg-buildpackage`. Prefetch the locked Rust crates before the build; Cargo builds and tests run offline. Import the resulting main `.deb` files into a signed `reprepro` repository and serve its `public/` directory over HTTPS.

## Dependencies

| Purpose | Debian packages |
| --- | --- |
| Build and package | `build-essential debhelper cargo rustc dpkg-dev binutils ca-certificates` |
| Changelog maintenance | `devscripts` (provides `dch`) |
| Workflow automation | Build/repository tools above plus `jq gnupg gpgv lintian`; Debian's `coreutils gawk tar` |
| Repository management | `reprepro gnupg dpkg-dev` |
| Repository upload | `reprepro gpgv` and hashing/filesystem utilities; `rsync` 3+ plus `openssh-client`, or AWS CLI **v2** |
| Verification | `lintian python3-pytest`; `shellcheck` for the repository script |
| APT clients | `apt ca-certificates`; `curl gnupg` for key setup |
| Podlet runtime | Shared libraries calculated by debhelper; `podman` is recommended |

The build uses debhelper compatibility level 13 and Debian's standard make, compiler, and packaging tools. [`dh`](https://manpages.debian.org/trixie/debhelper/dh.1.en.html) sequences installation, stripping/debug-symbol handling, dependency calculation, metadata, documentation compression, permissions, and archive creation. `debian/rules` supplies the Cargo build/test steps. No Cargo packaging plugin or custom package-assembly script is needed.

[Debian 13 provides Rust 1.85.1](https://packages.debian.org/trixie/rustc), matching Podlet's declared Rust 1.85 minimum. The complete locked Podlet dependency graph has **not been built with that compiler here**. If Cargo reports an incompatible compiler or dependency, preserve the exact error and `Cargo.lock`; do not use `cargo update` or `--ignore-rust-version` to hide it. Resolve the compiler requirement explicitly before publishing.

## Automate the workflow

[`scripts/package-debian.sh`](../scripts/package-debian.sh) runs the native tools for you: it prefetches crates, builds/tests offline through debhelper, signs and verifies build metadata, runs Lintian and extracted-binary smoke checks, and initializes or updates a signed local APT repository. It stops before server upload, web-server configuration, client APT changes, or system installation of the built package. Publish the result with the separate explicit [upload action](#upload-the-repository).

Run on native Debian 13 amd64 or arm64. `--username` is the Debian maintainer's **full name**, not a Linux account. Use an existing signing key and an already configured GPG agent:

```sh
export GPG_TTY="$(tty)";
bash scripts/package-debian.sh \
  --username 'Your Name' \
  --email 'you@example.com' \
  --gpg-sign-key 'YOUR_FULL_PRIMARY_KEY_FINGERPRINT' \
  --repo-dir /srv/debian-repository;
```

The default action is `all`. It builds the current architecture and imports its main package; add the matching counterpart using `--amd64-package` or `--arm64-package` to include both architectures. The repository directory must be writable by your account. Dependencies are checked by default. Add **`--install-deps`** to permit `apt-get update/install`; this is the only step that uses sudo when necessary. In CI, sudo must work noninteractively.

| Option | Environment variable | Default / meaning |
| --- | --- | --- |
| `--action build\|repo\|all` | `PODLET_ACTION` | `all`; build only, import existing binaries, or build then import |
| `--username NAME` | `PODLET_USERNAME`, fallback `DEBFULLNAME` | Required for build/all; maintainer full name |
| `--email ADDRESS` | `PODLET_EMAIL`, fallback `DEBEMAIL` | Required for build/all |
| `--gpg-sign-key FINGERPRINT` | `PODLET_GPG_SIGN_KEY`, fallback `DEB_SIGN_KEYID` | Required except for unsigned build-only |
| `--version VERSION` | `PODLET_VERSION` | Build: `debian/changelog`; repo: infer from supplied packages, or require this version if set |
| `--output-dir DIR` | `PODLET_OUTPUT_DIR` | Checkout's `dist/debian` |
| `--repo-dir DIR` | `PODLET_REPO_DIR` | `OUTPUT_DIR/apt`; serve only `public/` |
| `--cache-dir DIR` | `PODLET_CACHE_DIR` | Checkout's `.debian-cargo-home` |
| `--origin TEXT` | `PODLET_ORIGIN` | `Podlet`; only used when initializing a new repository |
| `--label TEXT` | `PODLET_LABEL` | `Podlet`; only used when initializing a new repository |
| `--amd64-package FILE` | `PODLET_AMD64_PACKAGE` | Existing main amd64 `.deb` for repo/all |
| `--arm64-package FILE` | `PODLET_ARM64_PACKAGE` | Existing main arm64 `.deb` for repo/all |
| `--jobs NUMBER` | `PODLET_JOBS` | Processor count; passed to Debian's parallel build option |
| `--install-deps` | `PODLET_INSTALL_DEPS` | `false`; explicitly permit dependency installation |
| `--skip-fetch` | `PODLET_SKIP_FETCH` | `false`; use the populated crate cache without fetching |
| `--no-sign-build` | `PODLET_NO_SIGN_BUILD` | `false`; unsigned build metadata; repository signing remains mandatory |
| `--ci` | `PODLET_CI`, fallback `CI` | `false`; require a noninteractive signing agent |
| `--help` | N/A | Show usage and defaults without side effects |

CLI values override environment values. Boolean environment variables accept `true`/`false` or `1`/`0`. Relative paths resolve from the directory where you invoke the script. `GNUPGHOME` selects the existing keyring. No key generation, key import, or passphrase argument is implemented; CI must provision its key/agent before invoking the workflow. With `--ci`, the signing probe and GPG signing command refuse pinentry prompts and fail if the key cannot sign immediately.

The script copies the working source to a temporary directory, changes maintainer/version metadata only there, and links the reusable crate cache. It preserves the original `debian/control`, `debian/changelog`, and `Cargo.lock`. Cargo tests stay enabled even if the caller has inherited `nocheck` build settings. [`dscverify`](https://manpages.debian.org/trixie/devscripts/dscverify.1.en.html) checks artifact sizes/checksums and, for signed builds, metadata signatures against the exported signing key. Only verified artifacts are collected under `OUTPUT_DIR/VERSION/ARCH/`, including any debug-symbol package. Existing artifact directories are never replaced. Import uses only main `podlet` binaries, then checks the selected versions and exact archive contents in the repository pool as well as release signatures.

For CI, build once on each native architecture. Builders without a signing key can produce unsigned build metadata:

```sh
export PODLET_ACTION=build;
export PODLET_USERNAME='CI Packager';
export PODLET_EMAIL='packages@example.com';
export PODLET_VERSION='0.3.2-1';
export PODLET_NO_SIGN_BUILD=true;
export PODLET_CI=true;
bash scripts/package-debian.sh;
```

Collect the two main `.deb` files as CI artifacts. On the repository runner, provide an existing signing key and import both:

```sh
export PODLET_ACTION=repo;
export PODLET_GPG_SIGN_KEY='YOUR_FULL_PRIMARY_KEY_FINGERPRINT';
export PODLET_AMD64_PACKAGE='/artifacts/amd64/podlet_0.3.2-1_amd64.deb';
export PODLET_ARM64_PACKAGE='/artifacts/arm64/podlet_0.3.2-1_arm64.deb';
export PODLET_REPO_DIR='/srv/debian-repository';
export PODLET_CI=true;
bash scripts/package-debian.sh;
```

Omit `PODLET_NO_SIGN_BUILD` or set it to `false` and provide the key on builders to sign build metadata too. Repo-only accepts already built binaries based on the operator's selected inputs; it verifies their metadata and imported contents, not the original build provenance. Both architecture versions must match. Reusing an existing repository retains its origin/label and requires the same signing fingerprint as its configuration.

Failures stop the workflow and remove temporary files, while preserving the shared cache and any artifacts already verified. If repository import/checking fails after a successful build, retry with `--action repo` and the saved package paths instead of rebuilding into the same artifact directory. An uncatchable interruption can leave `.ARCH.lock` under the version output directory; remove it with `rmdir` only after confirming no workflow is running. Repository import recovery follows the manual instructions below. Custom output/cache/repository directories must stay out of Git.

The manual steps below remain available when you want to invoke Debian tools directly.

## Prepare and build on each architecture

On both native Debian machines:

```sh
sudo apt-get update;
sudo apt-get install --no-install-recommends build-essential debhelper cargo rustc dpkg-dev binutils ca-certificates devscripts;
cd /path/to/podlet;
rustc --version;
cargo --version;
```

Use the **same source revision and package version** on both builders. `debian/control` contains the package maintainer identity; `debian/changelog` supplies the Debian version, initially `0.3.2-1`. The initial maintainer was taken from the local Git identity when these definitions were added, rather than assigning packaging responsibility to upstream. If you maintain this package under another identity, edit the control file's `Maintainer` and the changelog signature accordingly. To mark the initial entry for your repository:

```sh
export DEBFULLNAME='Your Name';
export DEBEMAIL='you@example.com';
dch --release --distribution trixie;
```

Perform the network-enabled preparation step, then build as an ordinary user:

```sh
export CARGO_HOME="$PWD/.debian-cargo-home";
rust_target="$(rustc -vV | sed -n 's/^host: //p')";
CARGO_NET_OFFLINE=false cargo fetch --locked --target "$rust_target";
dpkg-buildpackage --build=binary --no-sign;
```

Prefetch must succeed with the same compiler/toolchain and lockfile used for the build. The rules explicitly select Debian's native GNU/Linux Rust target, use `--locked --offline`, and set `CARGO_NET_OFFLINE=true`. Missing cached crates fail the build instead of triggering downloads. Repeat the prefetch step when changing the lockfile, target, or compiler. Cargo's registry cache stays in `.debian-cargo-home/`; compiled files go in `target/debian/`. Debian's initial clean removes compiled output and debhelper state while retaining the prefetched cache. To discard that cache later, remove `.debian-cargo-home/` explicitly after all builds finish.

[`dpkg-buildpackage`](https://manpages.debian.org/trixie/dpkg-dev/dpkg-buildpackage.1.en.html) runs tests through debhelper and writes artifacts to the **parent directory** of the checkout. For the initial version, the main packages are:

```text
../podlet_0.3.2-1_amd64.deb
../podlet_0.3.2-1_arm64.deb
```

Each native build also produces `.changes` and `.buildinfo` files. Debhelper may produce an additional `podlet-dbgsym` package; import only the main `podlet` package into the repository workflow below. The package installs `/usr/bin/podlet` and documentation under `/usr/share/doc/podlet/`. Shared-library requirements such as `libc6` and `libgcc-s1` are calculated from the actual binary through `${shlibs:Depends}`, rather than hardcoded. `Recommends: podman` supports inspecting existing objects; command and Compose conversion can be used without Podman. There are no package installation hooks or service units.

The source-controlled packaging files belong in the PR. Generated `.deb`, `.changes`, `.buildinfo`, crate caches, debhelper state, and public repository content do not. Native tools can replace existing local output files; increment the Debian version whenever publishing changed contents. For a packaging revision:

```sh
dch --newversion 0.3.2-2 --distribution trixie 'Update Debian packaging.';
dpkg-buildpackage --build=binary --no-sign;
```

This is a binary-package workflow for your repository, preserving upstream's crates.io lockfile. The `3.0 (quilt)` source format declaration is conventional packaging metadata; this guide does not prepare an upstream orig tarball or a self-contained Debian source package. Prefetching crates is still required after a fresh checkout. It is distinct from the [Debian Rust team's `dh-cargo` workflow](https://wiki.debian.org/Teams/RustPackaging/Policy), which uses Debian-packaged crate sources. Keep the corresponding source and license information available to recipients, including modified MPL-covered files where applicable.

## Sign the build metadata

Use an existing GPG key with signing capability to sign the build's `.changes` and `.buildinfo` files. After prefetching the crates as above, run the following from the checkout, replacing the fingerprint with your own:

```sh
sudo apt-get install --no-install-recommends gnupg devscripts;
gpg --list-secret-keys --keyid-format long --with-fingerprint;
export GPG_TTY="$(tty)";
signing_key='YOUR_FULL_PRIMARY_KEY_FINGERPRINT';

dpkg-buildpackage --build=binary --sign-backend=gpg --sign-key="$signing_key" --force-sign;
```

This replaces the earlier `--no-sign` build command. GPG uses your current keyring (`GNUPGHOME` if set) and `gpg-agent`/pinentry for the passphrase. `--force-sign` also enables signing when `debian/changelog` still says `UNRELEASED`. See the [Debian package signing options](https://manpages.debian.org/trixie/dpkg-dev/dpkg-buildpackage.1.en.html).

Alternatively, build with `--no-sign` and sign the existing output afterward. On a separate signing machine, keep the `.changes` file and its referenced `.buildinfo` file together and adjust the path below:

```sh
architecture="$(dpkg --print-architecture)";
version="$(dpkg-parsechangelog --show-field Version)";
debsign -k"$signing_key" "../podlet_${version#*:}_${architecture}.changes";
```

Use the **builder's architecture** in the filename if the signing machine has a different architecture. [`debsign`](https://manpages.debian.org/trixie/devscripts/debsign.1.en.html) signs the referenced build metadata and updates its checksums in the `.changes` file. Verify the resulting signatures, using the same filenames:

```sh
gpg --verify "../podlet_${version#*:}_${architecture}.changes";
gpg --verify "../podlet_${version#*:}_${architecture}.buildinfo";
```

For the sign-during-build option, set `architecture` and `version` as shown above before verifying. This signs build metadata; it does not embed a signature inside each `.deb`. APT authenticates repository downloads through the signed `InRelease` or `Release.gpg` metadata described under [Initialize the repository](#initialize-the-repository). You may use the same key for both purposes. Builds can also remain unsigned while the repository is signed on a separate machine; builders then do not need the private key. Keep private keys outside Git and the public repository tree.

## Verify each package on Debian

```sh
sudo apt-get install --no-install-recommends lintian python3-pytest shellcheck;
bash -n scripts/update-apt-repo.sh;
shellcheck scripts/update-apt-repo.sh;
python3 -m pytest -q tests/test_debian_workflow.py;
python3 -m pytest -q tests/test_apt_repo_upload.py;

architecture="$(dpkg --print-architecture)";
version="$(dpkg-parsechangelog --show-field Version)";
package="$PWD/../podlet_${version#*:}_${architecture}.deb";
dpkg-deb --info "$package";
dpkg-deb --contents "$package";
lintian "../podlet_${version#*:}_${architecture}.changes";
scratch="$(mktemp -d)";
dpkg-deb --extract "$package" "$scratch";
"$scratch/usr/bin/podlet" --version;
"$scratch/usr/bin/podlet" --skip-services-check --podman-version 5.4 podman run quay.io/podman/hello;
```

The normal package build runs `cargo test --release --locked --offline`; use `DEB_BUILD_OPTIONS=nocheck` only when deliberately skipping tests, and record that skip. Review Lintian findings before publishing. Check install/remove on a disposable native Debian machine of **each architecture**:

```sh
sudo apt-get install "$package";
podlet --version;
podlet --skip-services-check --podman-version 5.4 podman run quay.io/podman/hello;
sudo apt-get remove podlet;
```

[Debian 13 ships Podman 5.4.2](https://packages.debian.org/trixie/podman). This checkout defaults to compatibility with 5.8, so use `--podman-version 5.4` for Trixie's Podman. The application default is preserved. The smoke check generates text; it does not pull images or start containers.

## Initialize the repository

Use `/srv/debian-repository` as a general Debian repository directory, with one shared configuration/database and public tree for all packages in it. The directory name is an operator choice; the scripts still default to the paths listed above unless `--repo-dir` or `PODLET_REPO_DIR` is set. Use a separate repository root for Ubuntu or another distribution, and separate S3 prefixes such as `debian/`, `ubuntu/`, and `fedora/`. Debian releases belong under `dists/`; architectures have separate indexes within each release.

Choose either automatic or manual initialization below, not both for the same directory. Both produce the same signed Trixie layout. The helper currently initializes/checks Trixie and imports only Podlet packages; direct `reprepro` commands can manage other packages. Adding suites requires corresponding configuration and review of the helper's Trixie-specific upload verification. Keep one publisher per repository root.

### Common preparation

On the repository management machine, install the tools and choose a private working directory owned by your ordinary account:

```sh
sudo apt-get install --no-install-recommends reprepro gnupg gpgv dpkg-dev;
sudo install -d -o "$(id -un)" -g "$(id -gn)" /srv/debian-repository;
```

Use an existing GPG key capable of signing. For a new repository identity, create one interactively **yourself**, outside the public directory, then record its full primary-key fingerprint:

```sh
# Only if you need a new key: gpg --full-generate-key;
gpg --list-secret-keys --keyid-format long --with-fingerprint;
export GPG_TTY="$(tty)";
```

Both approaches use your current GPG keyring (`GNUPGHOME` if set) and `gpg-agent`/pinentry for passphrases. Use the full primary-key fingerprint, not an email, short key ID, or subkey fingerprint. Set these variables in the shell used for the following steps:

```sh
repo_dir='/srv/debian-repository';
signing_key='YOUR_FULL_PRIMARY_KEY_FINGERPRINT';
```

### Automatic initialization with the helper

Replace the repository identity with your own:

```sh
bash /path/to/podlet/scripts/update-apt-repo.sh init \
  --repo-dir /srv/debian-repository \
  --signing-key "$signing_key" \
  --origin 'Example Operations' \
  --label 'Example Debian Packages';
```

Initialization refuses to replace existing configuration, database, or public files. It creates a signed, initially empty repository with codename and suite `trixie`, component `main`, and architectures `amd64 arm64`. Using `trixie` keeps clients on Debian 13 when Debian's `stable` alias changes.

### Manual initialization with reprepro

For a new repository only, create the private state directories and public output directory:

```sh
umask 022;
install -d -m700 "$repo_dir/conf" "$repo_dir/db";
install -d -m755 "$repo_dir/public";
```

Open `$repo_dir/conf/distributions` in your editor and enter the following. Replace the fingerprint and repository identity; do not overwrite an existing repository configuration:

```text
Origin: Example Operations
Label: Example Debian Packages
Suite: trixie
Codename: trixie
Architectures: amd64 arm64
Components: main
Description: Packages for Debian 13
SignWith: YOUR_FULL_PRIMARY_KEY_FINGERPRINT
DebIndices: Packages Release . .gz
```

Export the public key and generate the initially empty signed repository. Use the same fingerprint as the configuration's `SignWith` value:

```sh
gpg --batch --export-options export-minimal --export "$signing_key" \
  > "$repo_dir/public/archive-keyring.gpg";
test -s "$repo_dir/public/archive-keyring.gpg";

reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" export trixie;
```

Stop if any command fails. The `archive-keyring.gpg` filename is retained for compatibility with the upload helper; the key can authenticate a repository containing multiple packages. Neither approach publishes the repository automatically.

### Verify either initialization approach

```sh
gpgv --keyring "$repo_dir/public/archive-keyring.gpg" \
  "$repo_dir/public/dists/trixie/InRelease";
gpgv --keyring "$repo_dir/public/archive-keyring.gpg" \
  "$repo_dir/public/dists/trixie/Release.gpg" \
  "$repo_dir/public/dists/trixie/Release";
```

## Import packages

Transfer both packages to a directory outside the public document root. For example, from each builder:

```sh
scp ../podlet_0.3.2-1_amd64.deb repo-owner@repo.example.com:/srv/debian-incoming/;
# Run the following command on the arm64 builder instead.
scp ../podlet_0.3.2-1_arm64.deb repo-owner@repo.example.com:/srv/debian-incoming/;
```

Create `/srv/debian-incoming/` with suitable ownership before copying. Choose either import approach on the repository management machine. Inspect package names, versions, and architectures with `dpkg-deb --field FILE Package Version Architecture` before importing, and use matching Podlet versions for both architectures.

### Automatic import with the helper

```sh
bash /path/to/podlet/scripts/update-apt-repo.sh import \
  --repo-dir /srv/debian-repository \
  --signing-key "$signing_key" -- \
  /srv/debian-incoming/podlet_0.3.2-1_amd64.deb \
  /srv/debian-incoming/podlet_0.3.2-1_arm64.deb;
```

Import accepts one or two packages. Every package must be named `podlet` internally and have architecture `amd64` or `arm64`. A batch must have identical version strings and at most one package per architecture. Use a two-package batch for coordinated releases; separate imports can temporarily expose different versions on the two architectures.

All package metadata and signing-key availability are checked before imports. Imports reuse `conf/distributions`; origin and label edits are retained. Keep the generated codename, suite, architectures, component, and `SignWith` fields intact. Each batch imports without exporting intermediate indexes, retains old pool files, then exports signed metadata once. Existing identical packages are no-ops; `reprepro` will not normally replace a newer version with an older one. Always increment the Debian package version when changing contents.

### Manual import with reprepro

Use the `repo_dir` variable from initialization. Import packages without exporting intermediate indexes, then export once after all imports succeed:

```sh
reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" \
  --keepunreferencedfiles --export=never --component main \
  includedeb trixie \
  /srv/debian-incoming/podlet_0.3.2-1_amd64.deb \
  /srv/debian-incoming/podlet_0.3.2-1_arm64.deb;

reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" export trixie;
reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" list trixie;
reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" check trixie;
reprepro --basedir "$repo_dir" --outdir "$repo_dir/public" checkpool;
```

Stop on any failed import/check and do not publish until it is resolved. Repeat the import with other compatible Debian packages to add them to this same repository; `reprepro` maintains their entries in the shared indexes and pool. The direct commands do not enforce the helper's Podlet-only, matching-version, or two-package batch checks. Use higher versions when publishing changed packages. Verify the release signatures again after export.

### Recovery and concurrent updates

The update lock covers the helper script's entire batch. Manual commands do not acquire the helper's workflow lock. Do not run imports, exports, or uploads concurrently, including manual commands alongside either helper. A failed import or export is **not a database transaction**: packages may already be recorded. Correct the problem and rerun the same import, or regenerate metadata explicitly:

```sh
reprepro --basedir /srv/debian-repository --outdir /srv/debian-repository/public export trixie;
```

Do not publish files from a failed run. If signing failed during initialization after configuration was installed, fix the key/agent and run the export command above, then rerun an import to export the public key. After an uncatchable interruption, remove `.podlet-update.lock` with `rmdir` only after confirming no updater is running.

## Directory layout and HTTPS hosting

The resulting layout follows the [Debian repository format](https://wiki.debian.org/DebianRepository/Format); [`reprepro`](https://manpages.debian.org/trixie/reprepro/reprepro.1.en.html) manages the package pool, indexes, and release signatures:

```text
/srv/debian-repository/
  conf/distributions
  db/
  public/
    archive-keyring.gpg
    dists/trixie/
      InRelease
      Release
      Release.gpg
      main/binary-amd64/Packages
      main/binary-amd64/Packages.gz
      main/binary-arm64/Packages
      main/binary-arm64/Packages.gz
    pool/main/p/podlet/
      podlet_0.3.2-1_amd64.deb
      podlet_0.3.2-1_arm64.deb
```

Configure your existing HTTPS server so `https://repo.example.com/debian/` maps to **only** `/srv/debian-repository/public/`. It must serve the repository files unchanged. The script uses umask `022` for new public artifacts and mode `0700` for newly initialized `conf/` and `db/`. Allow the web-server account to traverse any pre-existing parent directories; give write access only to the repository owner. Existing parent permissions are preserved.

Keep `conf/`, `db/`, incoming packages, and GPG private keys outside the document root. Back up `conf/` and `db/` together with the pool; the database is persistent state. Back up the signing key separately. For a separate web server, publish a completed public tree using snapshots or an equivalent coordinated transfer; copying mutable indexes and packages in arbitrary order can cause transient checksum errors. For in-place hosting, clients can retry during an update; old pool files are retained so old indexes continue to resolve package downloads.

## Upload the repository

Use `scripts/update-apt-repo.sh upload` to publish an existing signed **managed** repository. Its local `conf/`, `db/`, and `public/` must be present for repository/pool consistency checks. Upload uses `gpgv` and the exported public key; no private signing key is needed. No upload runs automatically after `init`, `import`, or `package-debian.sh`.

The helper selects only `public/pool/`, `public/dists/`, and `public/archive-keyring.gpg`. It rejects symlinks/special files, freezes a temporary snapshot, verifies both release signatures and matching `InRelease` plaintext, and checks the signed SHA256 index sizes/hashes before transfer. Private repository state and unrelated public-root files are excluded. Allow disk space for a full public snapshot and one active publisher per destination.

For rsync over SSH, install **rsync 3+ on both machines** and use an existing SSH configuration. The absolute non-root destination directory must already exist and be writable by the SSH account. Use host aliases for custom ports or IPv6. SSH runs in batch mode with normal host-key verification:

```sh
sudo apt-get install --no-install-recommends rsync openssh-client reprepro gpgv;
bash scripts/update-apt-repo.sh upload \
  --repo-dir /srv/debian-repository \
  --upload-method rsync \
  --destination 'repo-owner@apt-host:/srv/www/debian/' \
  --dry-run;
```

For S3, publish the Debian repository to its own `debian/` prefix so other distributions can use independent prefixes in the same bucket. The HTTPS repository URL must map directly to that prefix, without an extra `public/` directory level. For example, `s3://my-linux-packages/debian/` maps to `https://my-linux-packages.s3.us-east-1.amazonaws.com/debian/` for a bucket in `us-east-1`. Use an HTTPS S3 REST endpoint or your configured CDN; S3 website endpoints do not support HTTPS. See [AWS's endpoint documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html) and [website endpoint limitations](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteEndpoints.html).

Install [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and supply an existing AWS profile, credential provider, or role. The helper rejects AWS CLI v1. The destination is a bucket and optional prefix representing the public repository URL root:

```sh
bash scripts/update-apt-repo.sh upload \
  --repo-dir /srv/debian-repository \
  --upload-method s3 \
  --destination 's3://my-linux-packages/debian/' \
  --aws-profile packages \
  --aws-region us-east-1 \
  --dry-run;
```

For an S3-compatible service, add `--s3-endpoint-url 'https://objects.example.com'`. Credentials stay in native AWS configuration/environment/role providers, not endpoint URLs or script arguments. The script does not configure bucket policies, public ACLs, HTTPS routing, CDN, SSH keys, or client APT sources. Configure the intended read access and repository URL separately; TLS and SSH verification remain enabled.

| Argument | Environment variable | Meaning |
| --- | --- | --- |
| `--repo-dir DIR` | `PODLET_REPO_DIR` | Existing managed repository |
| `--upload-method rsync\|s3` | `PODLET_UPLOAD_METHOD` | Required transport; no default |
| `--destination DEST` | `PODLET_UPLOAD_DESTINATION` | Required SSH destination or `s3://BUCKET[/PREFIX]/` |
| `--dry-run` | `PODLET_UPLOAD_DRY_RUN` | Default `false`; accepts `true`/`false` or `1`/`0` |
| `--aws-profile NAME` | `PODLET_AWS_PROFILE` | Optional S3 profile override |
| `--aws-region REGION` | `PODLET_AWS_REGION` | Optional S3 region override |
| `--s3-endpoint-url URL` | `PODLET_S3_ENDPOINT_URL` | Optional HTTP(S) S3 endpoint override |

CLI arguments override environment settings. Native AWS settings such as `AWS_PROFILE`, `AWS_REGION`, and credential-provider configuration remain effective when not overridden. Upload environment options are scoped to `upload`, so they do not alter `init`/`import`. Upload accepts no `--signing-key`, origin/label, or package inputs: sign/export locally first.

For environment-only CI:

```sh
export PODLET_REPO_DIR='/srv/debian-repository';
export PODLET_UPLOAD_METHOD=s3;
export PODLET_UPLOAD_DESTINATION='s3://my-linux-packages/debian/';
export PODLET_AWS_PROFILE=packages;
export PODLET_UPLOAD_DRY_RUN=true;
bash scripts/update-apt-repo.sh upload;
```

Dry runs perform local verification and may authenticate/list the remote destination, but write no remote files. Remove `--dry-run` or set `PODLET_UPLOAD_DRY_RUN=false` for an actual upload. Remote files and objects are never deleted.

Publication transfers packages and the public key first, indexes next, then `Release`, `Release.gpg`, and **`InRelease` last**. rsync uses protected arguments, content checksums, delayed file replacement, and readable public modes. S3 uses [`sync`](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html) for pool objects and forced [`cp`](https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html) for mutable indexes/key/release files, with `Cache-Control: no-cache` on mutable metadata. It sets no ACL or gzip `Content-Encoding`.

If a phase fails, later phases do not run. Fix the transport/authentication error and rerun the upload; old pool objects remain available. Temporary snapshots and the lock are cleaned on normal/error exit. After an uncatchable interruption, confirm no publisher is running before removing a stale `.podlet-update.lock` or abandoned `.podlet-upload.*` snapshot. The local lock does not coordinate publishers on different machines.

This is staged, in-place publication rather than a globally atomic repository switch. Clients may see transient index hash mismatches while old release metadata and new indexes overlap; retry after publication finishes. Atomic serving requires an external snapshot-switch/deployment mechanism. Transport success does not establish end-to-end HTTPS/APT availability; verify the configured client URL separately.

## Configure Debian clients

Replace the hostname, obtain the expected signing fingerprint through your trusted administrative channel, then download and inspect the public key before installation:

```sh
sudo apt-get install --no-install-recommends ca-certificates curl gnupg;
curl --fail --show-error --location https://repo.example.com/debian/archive-keyring.gpg \
  --output /tmp/archive-keyring.gpg;
gpg --show-keys --with-fingerprint /tmp/archive-keyring.gpg;
# Compare the full primary fingerprint with the expected value before continuing.
sudo install -d -m755 /etc/apt/keyrings;
sudo install -m644 /tmp/archive-keyring.gpg /etc/apt/keyrings/archive-keyring.gpg;
```

Create `/etc/apt/sources.list.d/podlet.sources` with your editor:

```text
Types: deb
URIs: https://repo.example.com/debian/
Suites: trixie
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/archive-keyring.gpg
```

The [deb822 source format and `Signed-By`](https://manpages.debian.org/trixie/apt/sources.list.5.en.html) restrict this source to its dedicated key. Do not use `apt-key`, `trusted=yes`, or disable signature checks.

```sh
sudo apt-get update;
apt-cache policy podlet;
sudo apt-get install podlet;
podlet --podman-version 5.4 podman run quay.io/podman/hello;
```

For updates, build a higher version on both builders, import both packages, publish the completed tree, then run `sudo apt-get update; sudo apt-get install --only-upgrade podlet;` on clients. Old pool files are retained deliberately; plan cleanup separately after clients have refreshed their indexes. To roll back application code, rebuild the previous source with a **higher** package version and import it; do not silently replace a published version.

## Verification scope and troubleshooting

`tests/test_debian_workflow.py` executes the actual orchestration script and repository helper with isolated fake native tools. It checks argument/environment precedence, input validation, explicit dependency-install gating, both native targets, temporary metadata edits, cached/offline builds, signing command selection, verification failures, repository reuse, exact imported contents, output refusal, and cleanup. The tests never install packages, use a real private key, or publish remotely. Their fixture archives and signatures do not establish a real Debian build or cryptographic verification result. Run the native Podlet build, Lintian, signatures/checksums, APT, and installation checks on Debian 13 before publishing.

`tests/test_apt_repo_upload.py` uses real local files and hash calculations with simulated GPG/reprepro/rsync/AWS boundaries. It checks publication order, argument safety, source validation, snapshot stability, dry runs, failure short-circuiting, and cleanup. It makes no SSH connections or AWS calls and does not establish genuine signature verification or live hosting behavior.

| Symptom | Check |
| --- | --- |
| Missing Debian includes or unsupported architecture | Use native Debian 13 with its rustc/debhelper packages on amd64 or arm64; cross builds are rejected. |
| Offline build cannot find a crate | Complete `cargo fetch --locked --target ...` using the documented local CARGO_HOME; do not enable network inside the build. |
| Cargo compiler/dependency failure | Save the error, compiler versions, and lockfile; resolve the compiler requirement explicitly. |
| `dpkg-shlibdeps` cannot find a library | Build on Debian 13 with its library metadata installed; do not suppress missing-library errors. |
| Package contents changed | Increment the version with `dch`; native tools may replace local artifacts, but published versions must remain immutable. |
| Key unavailable or signing fails | Check `GNUPGHOME`, primary fingerprint, key validity, `GPG_TTY`, agent, and pinentry access. |
| Import/version conflict | Inspect `dpkg-deb -f FILE Package Version Architecture`; supply matching versions and one file per architecture. |
| APT signature/key error | Confirm the fingerprint, readable dedicated keyring, `Signed-By`, and freshly signed metadata. |
| HTTP 404 or checksum mismatch | Check the public-root mapping and complete publication of `dists/` plus `pool/`; retry after an update finishes. |

No Docker, Kubernetes, k3s, or remote deployment tests are run by these scripts.
