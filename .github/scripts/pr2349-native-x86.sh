#!/usr/bin/env bash
set -euo pipefail

# The experiment checkout contains this script and its adjacent candidate patch.
# All measured revisions use one separate source path and one Cargo target path.
BASE_SHA=9ef20b6d3cafff78e137b5829522f2bd1009b1cf
ORIGINAL_SHA=0420502f7679f650709379bf0a0b61304b499d51
CURRENT_SHA=8588ad0bd736d5bfb9ab4aa3aaa00a9042e78b6e
RUST_VERSION=1.98.1
CARGO_CODSPEED_VERSION=5.0.1
RUNNER_VERSION=4.19.1
HARNESS_ROOT="$(git rev-parse --show-toplevel)"
HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_ROOT="${RUNNER_TEMP:?This script runs on a dedicated GitHub Actions runner}/pr2349-native-x86"
SOURCE_ROOT="$EXPERIMENT_ROOT/source"
RESULTS_ROOT="$EXPERIMENT_ROOT/results"
SNAPSHOT_ROOT="$EXPERIMENT_ROOT/binaries"
TOOLS_ROOT="$EXPERIMENT_ROOT/tools"
CANDIDATE_PATCH="$HARNESS_DIR/pr2349-outline-enum.patch"
export CARGO_TARGET_DIR="$EXPERIMENT_ROOT/cargo-target"
export RUSTUP_TOOLCHAIN="$RUST_VERSION"
export CARGO_TERM_COLOR=never

[[ "$(uname -m)" == x86_64 ]]
[[ ! -e "$EXPERIMENT_ROOT" ]]
mkdir -p "$SOURCE_ROOT" "$RESULTS_ROOT" "$SNAPSHOT_ROOT" "$TOOLS_ROOT"
exec > >(tee -a "$RESULTS_ROOT/experiment.log") 2>&1
trap 'status=$?; printf "%s\n" "$status" > "$RESULTS_ROOT/exit-status.txt"' EXIT
cp "$CANDIDATE_PATCH" "$RESULTS_ROOT/candidate.patch"
cp "${BASH_SOURCE[0]}" "$RESULTS_ROOT/harness.sh"

download_checked() {
    local url="$1" output="$2" checksum="$3"
    curl --fail --location --retry 3 --silent --show-error "$url" -o "$output"
    printf '%s  %s\n' "$checksum" "$output" | sha256sum --check --status
}

# Install exact release artifacts, without running unpinned installation scripts.
download_checked \
    "https://github.com/CodSpeedHQ/codspeed/releases/download/v$RUNNER_VERSION/codspeed-runner-x86_64-unknown-linux-musl.tar.gz" \
    "$TOOLS_ROOT/runner.tar.gz" \
    9ea9a9c1e919f229b8b43c679c053eee513648cb08a826beb1a3ba7881a370ca
tar -xzf "$TOOLS_ROOT/runner.tar.gz" -C "$TOOLS_ROOT"
mapfile -t runner_binaries < <(find "$TOOLS_ROOT" -type f -name codspeed)
[[ "${#runner_binaries[@]}" == 1 ]]
install -m 755 "${runner_binaries[0]}" "$TOOLS_ROOT/codspeed"
download_checked \
    "https://github.com/CodSpeedHQ/codspeed-rust/releases/download/v$CARGO_CODSPEED_VERSION/cargo-codspeed-x86_64-unknown-linux-musl" \
    "$TOOLS_ROOT/cargo-codspeed" \
    df4b2618fda2aa19f8b92e8d745548a49d9ce20785472eeb584fdc2c99624395
chmod 755 "$TOOLS_ROOT/cargo-codspeed"
export PATH="$TOOLS_ROOT:$PATH"
rustup toolchain install "$RUST_VERSION" --profile minimal

# Preserve exact runtime versions and machine facts, without dumping environment.
{
    uname -a
    cat /etc/os-release
    lscpu
    rustc -Vv
    cargo --version
    cargo codspeed --version || [[ "$?" == 1 ]]
    codspeed --version
    printf 'base=%s\noriginal=%s\ncurrent=%s\nsource=%s\ntarget=%s\n' \
        "$BASE_SHA" "$ORIGINAL_SHA" "$CURRENT_SHA" "$SOURCE_ROOT" "$CARGO_TARGET_DIR"
    git -C "$HARNESS_ROOT" rev-parse HEAD
    sha256sum "$CANDIDATE_PATCH"
} > "$RESULTS_ROOT/environment.txt"

# Install 4.19.1's exact Valgrind fork and libc debug symbols. Only consult the
# official Ubuntu sources, avoiding unrelated third-party apt index failures.
download_checked \
    https://github.com/CodSpeedHQ/valgrind-codspeed/releases/download/3.26.0-0codspeed6/valgrind_3.26.0-0codspeed6_ubuntu-24.04_amd64.deb \
    "$TOOLS_ROOT/valgrind.deb" \
    454becce1a232bba1c408ed8aad4a20afa78acfbaba072cef2bf1c0a636ebd71
[[ -f /etc/apt/sources.list.d/ubuntu.sources ]]
apt_options=(
    -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources
    -o Dir::Etc::sourceparts=-
)
sudo apt-get "${apt_options[@]}" update
sudo apt-get "${apt_options[@]}" install -y --allow-downgrades \
    "$TOOLS_ROOT/valgrind.deb" libc6-dbg
valgrind --version >> "$RESULTS_ROOT/environment.txt"
dpkg-query -W valgrind libc6 libc6-dbg >> "$RESULTS_ROOT/environment.txt"
setarch x86_64 --addr-no-randomize true

# Fetch only these immutable public revisions, without stored credentials.
git init "$SOURCE_ROOT"
git -C "$SOURCE_ROOT" fetch --no-tags --depth=1 \
    https://github.com/carthage-software/mago.git \
    "$BASE_SHA:refs/heads/experiment-base" \
    "$ORIGINAL_SHA:refs/heads/experiment-original" \
    "$CURRENT_SHA:refs/heads/experiment-current"
# Fetch full trees directly: the harness checkout is shallow, and git archive
# excludes Rust files because this repository marks them export-ignore.
git -C "$SOURCE_ROOT" diff "$BASE_SHA" "$ORIGINAL_SHA" \
    > "$RESULTS_ROOT/original-pr.patch"
git -C "$SOURCE_ROOT" diff "$ORIGINAL_SHA" "$CURRENT_SHA" \
    > "$RESULTS_ROOT/current-pr-update.patch"

restore_source() {
    local variant="$1" revision
    case "$variant" in
        base) revision="$BASE_SHA" ;;
        original) revision="$ORIGINAL_SHA" ;;
        current|candidate) revision="$CURRENT_SHA" ;;
        *) return 1 ;;
    esac
    # This is the dedicated source clone created above, never the PR checkout.
    git -C "$SOURCE_ROOT" checkout --force --detach "$revision"
    git -C "$SOURCE_ROOT" clean -ffdx
    if [[ "$variant" == candidate ]]; then
        git -C "$SOURCE_ROOT" apply --check "$CANDIDATE_PATCH"
        git -C "$SOURCE_ROOT" apply "$CANDIDATE_PATCH"
    fi
}

# Preserve the CI package and feature selection even though measurement below
# selects only the comparator binary. This keeps feature unification consistent.
package_args=(
    -p mago-syntax -p mago-codex -p mago-twig-syntax
    -p mago-analyzer -p mago-prelude
)
benchmark_binary="$CARGO_TARGET_DIR/codspeed/analysis/mago-codex/comparator"
for variant in base original current candidate; do
    restore_source "$variant"
    (
        cd "$SOURCE_ROOT"
        python3 - <<'PY'
import pathlib
import tomllib
packages = tomllib.loads(pathlib.Path("Cargo.lock").read_text())["package"]
versions = [p["version"] for p in packages if p["name"] == "codspeed"]
assert versions == ["4.7.0"], versions
PY
        sha256sum Cargo.lock > "$RESULTS_ROOT/$variant-lock.sha256"
        # Force Cargo to reconsider the changed comparator even if source mtimes
        # were preserved by a checkout or an input preparation step.
        touch crates/codex/src/ttype/comparator/union_comparator.rs
        cargo codspeed build --locked --bench comparator "${package_args[@]}" \
            --features mago-prelude/build 2>&1 | tee "$RESULTS_ROOT/$variant-build.log"
        [[ -x "$benchmark_binary" ]]
        cp "$benchmark_binary" "$SNAPSHOT_ROOT/$variant"
        sha256sum "$benchmark_binary" > "$RESULTS_ROOT/$variant-binary.sha256"
    )
done
cmp "$RESULTS_ROOT/base-lock.sha256" "$RESULTS_ROOT/original-lock.sha256"
cmp "$RESULTS_ROOT/current-lock.sha256" "$RESULTS_ROOT/candidate-lock.sha256"
for pair in "base original" "current candidate"; do
    read -r before after <<< "$pair"
    if cmp -s "$SNAPSHOT_ROOT/$before" "$SNAPSHOT_ROOT/$after"; then
        printf 'Unexpected identical binaries for %s and %s\n' "$before" "$after"
        exit 1
    fi
done

# Four balanced orders: every variant occupies every position once.
# Compare original/base for the report and candidate/current for the proposed fix.
# Binaries are restored without rebuilding; each run gets its matching source.
orders=(
    "base original candidate current"
    "original current base candidate"
    "current candidate original base"
    "candidate base current original"
)
printf 'round\tposition\tvariant\tprofile\n' > "$RESULTS_ROOT/run-order.tsv"
for round_index in "${!orders[@]}"; do
    read -r -a variants <<< "${orders[$round_index]}"
    for position_index in "${!variants[@]}"; do
        variant="${variants[$position_index]}"
        round="$((round_index + 1))"
        position="$((position_index + 1))"
        profile="$RESULTS_ROOT/$variant-$round"
        mkdir -p "$profile"
        restore_source "$variant"
        cp "$SNAPSHOT_ROOT/$variant" "$benchmark_binary"
        printf '%s\t%s\t%s\t%s\n' "$round" "$position" "$variant" "$profile" \
            >> "$RESULTS_ROOT/run-order.tsv"
        (
            cd "$SOURCE_ROOT"
            # LocalProvider with skip-upload bypasses auth and repository APIs.
            # Cargo metadata uses already fetched dependencies in offline mode.
            env -u GITHUB_ACTIONS -u BUILDKITE -u GITLAB_CI \
                -u CODSPEED_TOKEN -u CODSPEED_OAUTH_TOKEN \
                CODSPEED_EXPERIMENTAL_FAIR_SCHED=false \
                CODSPEED_EXPERIMENTAL_CYCLE_ESTIMATION=false \
                CODSPEED_EXPERIMENTAL_EXCLUDE_ALLOCATIONS=false \
                CARGO_NET_OFFLINE=true \
                codspeed run -m simulation --skip-upload --skip-setup \
                --profile-folder "$profile" \
                -- 'cargo codspeed run -p mago-codex --bench comparator' \
                2>&1 | tee "$RESULTS_ROOT/$variant-$round.log"
        )
        [[ -n "$(find "$profile" -type f -name '*.out' -print -quit)" ]]
    done
done

# Capture event/trigger/summary records for quick inspection; raw profiles remain
# authoritative. CodSpeed's backend nanosecond conversion is not run here.
python3 - "$RESULTS_ROOT" <<'PY'
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
records = []
for profile in sorted(root.glob("*-*")):
    if not profile.is_dir():
        continue
    for path in sorted(profile.rglob("*.out")):
        records.append({
            "profile": str(path.relative_to(root)),
            "records": [
                line for line in path.read_text(errors="replace").splitlines()
                if line.startswith(("part:", "desc:", "events:", "summary:", "totals:"))
            ],
        })
(root / "profile-records.json").write_text(json.dumps(records, indent=2) + "\n")
assert records, "No raw Callgrind profiles found"
PY
