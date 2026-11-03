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
EOF
)
printf '%s\n' "$manifest" | kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -c "cat > '$DEST/manifest.txt'"
kubectl -n "$NAMESPACE" exec "$POD" -- chmod -R a+rwX "$DEST"
echo "cache sync complete; provenance:"
printf '%s\n' "$manifest"
