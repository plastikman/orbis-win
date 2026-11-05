#!/usr/bin/env bash
# Copy the validated local build inputs to the runner's private NFS PVC.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
NAMESPACE=${ACTIONS_RUNNER_NAMESPACE:-actions-runner}
POD=${ACTIONS_CACHE_POD:-orbis-cache-seed}
DEST=/orbis-cache/deps

for path in prospero-win mesa-build sdk/orbis-sdk-v1 build/ps4-wine-sdk \
  build/orbw00053-iret-selectors-wow64native; do
  [[ -d "$ROOT/$path" ]] || { echo "missing local cache input: $ROOT/$path" >&2; exit 1; }
done
[[ -f "$HOME/.cache/orbis-ports/openssl11/lib/libssl.so.1.1" ]] || {
  echo "missing local OpenSSL 1.1 package cache" >&2; exit 1;
}

kubectl apply -f "$ROOT/scripts/ci/cache-seed-pod.yaml"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=180s
kubectl -n "$NAMESPACE" exec "$POD" -- mkdir -p \
  "$DEST/prospero-win" "$DEST/mesa-build" "$DEST/sdk" "$DEST/build" \
  "$DEST/openssl11/lib"

copy_tree() {
  local source=$1 target=$2
  echo "sync $source -> $target"
  tar -C "$ROOT/$source" -cf - . |
    kubectl -n "$NAMESPACE" exec -i "$POD" -- tar -C "$DEST/$target" -xf -
}

copy_tree prospero-win prospero-win
copy_tree mesa-build mesa-build
tar -C "$ROOT/sdk" -cf - orbis-sdk-v1 |
  kubectl -n "$NAMESPACE" exec -i "$POD" -- tar -C "$DEST/sdk" -xf -
copy_tree build/ps4-wine-sdk build/ps4-wine-sdk
copy_tree build/orbw00053-iret-selectors-wow64native build/orbw00053-iret-selectors-wow64native
tar -C "$HOME/.cache/orbis-ports/openssl11" -cf - lib |
  kubectl -n "$NAMESPACE" exec -i "$POD" -- tar -C "$DEST/openssl11" -xf -

# ABI-v4 build inputs for scripts/ci/build-abi4-package.sh (~7.5 GB). Only the
# trees the build reads: the synced prospero-win source with its wine-host
# build/install, the Unix wine-ps5 build, and the native WoW64 PE outputs. The
# sync directory's many package/stage experiments are deliberately left out.
# prepare-runner.sh links ABI4 back to this exact path because the generated
# makefiles and the .deps/wine-ps5 symlink embed it.
ABI4=${PW_ABI4_ROOT:-/home/zpeirce/codex_scratch/abi4-upstream-port-20261104}
for p in source build/wine-ps5 native mesa-zink; do
  [[ -e "$ABI4/$p" ]] || { echo "missing ABI-v4 input: $ABI4/$p" >&2; exit 1; }
done
kubectl -n "$NAMESPACE" exec "$POD" -- mkdir -p "$DEST/abi4/build" "$DEST/baseline-1090"
echo "sync $ABI4/{source,build/wine-ps5,native,mesa-zink} -> $DEST/abi4"
tar -C "$ABI4" -cf - source build/wine-ps5 native mesa-zink |
  kubectl -n "$NAMESPACE" exec -i "$POD" -- tar -C "$DEST/abi4" -xf -
# The hardware-validated baseline the parity gate compares every build against.
BASELINE=$ROOT/pkgout/falloutnv-no-relro-kept-data-1090
[[ -f "$BASELINE/pkg-stage/eboot.bin" ]] || { echo "missing baseline stage: $BASELINE" >&2; exit 1; }
tar -C "$BASELINE" -cf - pkg-stage |
  kubectl -n "$NAMESPACE" exec -i "$POD" -- tar -C "$DEST/baseline-1090" -xf -

manifest=$(cat <<EOF
seeded_at=$(date -u +%FT%TZ)
root_commit=$(git -C "$ROOT" rev-parse HEAD)
root_status=$(git -C "$ROOT" status --short | tr '\n' ';')
prospero_win_commit=$(git -C "$ROOT/prospero-win" rev-parse HEAD)
prospero_win_branch=$(git -C "$ROOT/prospero-win" branch --show-current)
prospero_win_diff_sha256=$(git -C "$ROOT/prospero-win" diff --binary | sha256sum | cut -d' ' -f1)
mesa_commit=$(git -C "$ROOT/mesa-build/mesa-ps4" rev-parse HEAD)
mesa_branch=$(git -C "$ROOT/mesa-build/mesa-ps4" branch --show-current)
mesa_diff_sha256=$(git -C "$ROOT/mesa-build/mesa-ps4" diff --binary | sha256sum | cut -d' ' -f1)
sdk=orbis-sdk-v1
abi4_root=$ABI4
abi4_commit=$(git -C "$ABI4/source" rev-parse HEAD)
abi4_branch=$(git -C "$ABI4/source" branch --show-current)
abi4_diff_sha256=$(git -C "$ABI4/source" diff --binary | sha256sum | cut -d' ' -f1)
abi4_wow64native_sha256=$(sha256sum "$ABI4/native/x86_64-windows/wow64native.dll" | cut -d' ' -f1)
baseline_1090_eboot_sha256=$(sha256sum "$BASELINE/pkg-stage/eboot.bin" | cut -d' ' -f1)
EOF
)
printf '%s\n' "$manifest" | kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -c "cat > '$DEST/manifest.txt'"
kubectl -n "$NAMESPACE" exec "$POD" -- chmod -R a+rwX "$DEST"
echo "cache sync complete; provenance:"
printf '%s\n' "$manifest"
