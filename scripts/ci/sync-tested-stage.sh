#!/usr/bin/env bash
# Publish the exact, user-tested Orbis-Win 02.14 stage and its matching parity
# inputs to the private Actions cache. Run only after hardware testing passes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRATCH_ROOT=${SCRATCH_ROOT:-$HOME/codex_scratch}
RECOVERED=${PS4_RECOVERED_ROOT:-$SCRATCH_ROOT/v006-recovered}
STAGE=${PS4_TESTED_STAGE:-$RECOVERED/orbis-0214/final/pkg-stage}
ELF_DIR=${PS4_TESTED_ELF_DIR:-$RECOVERED/orbis-0214/final/prx}
RUNTIME_SOURCE=${PS4_TESTED_RUNTIME_SOURCE:-$RECOVERED/playden-runtime}
HOST_WINE=${PS4_TESTED_HOST_WINE:-$RECOVERED/wine-host}
WINE_SOURCE=${PS4_TESTED_WINE_SOURCE:-$RECOVERED/wine-test-1075}
NAMESPACE=${ACTIONS_RUNNER_NAMESPACE:-actions-runner}
POD=${ACTIONS_CACHE_POD:-orbis-cache-seed}
DEST=/orbis-cache/deps
WORK="$SCRATCH_ROOT/orbis-win-tested-0214-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$WORK"

for path in "$STAGE/eboot.bin" "$STAGE/sce_module/relocated_wine_app.prx" \
            "$ELF_DIR/ntdll.shared.elf" "$ELF_DIR/wineserver.shared.elf" \
            "$RUNTIME_SOURCE/tools/build_wine_ps5.sh" \
            "$HOST_WINE/source/dlls/kernelbase/debug.c"; do
  [[ -s $path ]] || { echo "missing tested input: $path" >&2; exit 1; }
done
grep -aFq 'GLDS10043-02.14-pw47f0cef-sampler0' \
  "$STAGE/sce_module/relocated_wine_app.prx" || {
  echo "stage marker is not the game-tested 02.14 runtime" >&2; exit 1;
}
[[ $(git -C "$RUNTIME_SOURCE" rev-parse --short=7 HEAD) == 47f0cef ]] || {
  echo "expected Playden runtime source commit 47f0cef" >&2; exit 1;
}
[[ $(git -C "$WINE_SOURCE" rev-parse --short=7 HEAD) == e3e9c6e ]] || {
  echo "expected Wine source commit e3e9c6e (patch 1075)" >&2; exit 1;
}

mkdir -p "$WORK/tested-0214/upstream-root/tools" \
  "$WORK/tested-0214/upstream-root/.deps/wine-host/source/dlls/kernelbase"
cp -a "$STAGE" "$WORK/tested-0214/pkg-stage"
cp -a "$ELF_DIR" "$WORK/tested-0214/prx"
cp "$RUNTIME_SOURCE/tools/build_wine_ps5.sh" \
  "$WORK/tested-0214/upstream-root/tools/build_wine_ps5.sh"
cp "$HOST_WINE/source/dlls/kernelbase/debug.c" \
  "$WORK/tested-0214/upstream-root/.deps/wine-host/source/dlls/kernelbase/debug.c"

echo "== parity-check the exact tested stage with its matching symbols"
python3 -I "$ROOT/scripts/check-ps4-package-parity.py" "$STAGE" "$STAGE" \
  --elf-dir "$ELF_DIR" --upstream-root "$WORK/tested-0214/upstream-root" \
  | tee "$WORK/tested-0214/parity-source.txt"

tree_hash=$(find "$STAGE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
{
  echo "stage=Orbis-Win-02.14-user-tested"
  echo "stage_tree_sha256=$tree_hash"
  echo "runtime_build_marker=GLDS10043-02.14-pw47f0cef-sampler0"
  echo "runtime_source_commit=$(git -C "$RUNTIME_SOURCE" rev-parse HEAD)"
  echo "wine_source_commit=$(git -C "$WINE_SOURCE" rev-parse HEAD)"
  echo "native_glue_commit=f318960"
  echo "ntdll_prx_sha256=$(sha256sum "$STAGE/sce_module/ntdll.prx" | cut -d' ' -f1)"
  echo "app_prx_sha256=$(sha256sum "$STAGE/sce_module/relocated_wine_app.prx" | cut -d' ' -f1)"
  echo "elf_dir_sha256=$(find "$ELF_DIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  echo "parity_source_report=$(sha256sum "$WORK/tested-0214/parity-source.txt" | cut -d' ' -f1)"
  echo "synced_at=$(date -u +%FT%TZ)"
} > "$WORK/tested-0214/manifest.txt"

kubectl apply -f "$ROOT/scripts/ci/cache-seed-pod.yaml"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=180s
kubectl -n "$NAMESPACE" exec "$POD" -- mkdir -p "$DEST"
echo "== atomically sync 02.14 stage and parity inputs to $DEST/tested-0214"
tar -C "$WORK" -cf - tested-0214 |
  kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -c '
    set -eu
    dest=$1
    incoming="$dest/.tested-0214.incoming"
    previous="$dest/.tested-0214.previous"
    rm -rf "$incoming" "$previous"
    mkdir -p "$incoming"
    tar -C "$incoming" -xf -
    if [ -e "$dest/tested-0214" ]; then mv "$dest/tested-0214" "$previous"; fi
    mv "$incoming/tested-0214" "$dest/tested-0214"
    rm -rf "$incoming" "$previous"
    chmod -R a+rX "$dest/tested-0214"
  ' sh "$DEST"
kubectl -n "$NAMESPACE" exec "$POD" -- cat "$DEST/tested-0214/manifest.txt"
echo "tested-stage cache is ready; retained source parity report: $WORK/tested-0214/parity-source.txt"
