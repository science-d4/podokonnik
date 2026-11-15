#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source_root=""
label=""
scenario=steady
warmup=25
seconds=30
build_only=false
run_only=false
cpu_particles=false
candidate=false
festive=false
decorations=off
results_root="$ROOT/.build/gpu-simulation/results"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-root) shift; source_root="$1" ;;
        --label) shift; label="$1" ;;
        --scenario) shift; scenario="$1" ;;
        --warmup) shift; warmup="$1" ;;
        --seconds) shift; seconds="$1" ;;
        --build-only) build_only=true ;;
        --run-only) run_only=true ;;
        --cpu-particles) cpu_particles=true ;;
        --candidate) candidate=true ;;
        --festive) festive=true ;;
        --decorations) shift; decorations="$1" ;;
        --results-root) shift; results_root="$1" ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [ -z "$source_root" ] || [ -z "$label" ]; then
    printf '%s\n' 'Usage: --source-root <project root containing Sources> --label <baseline|candidate> [--scenario steady|blizzard] [--build-only|--run-only] [--candidate] [--cpu-particles]' >&2
    exit 2
fi
case "$label" in *[!a-zA-Z0-9_-]*|'') printf '%s\n' 'Invalid label' >&2; exit 2 ;; esac
case "$scenario" in steady|blizzard) ;; *) printf '%s\n' 'Invalid scenario' >&2; exit 2 ;; esac
case "$decorations" in off|all) ;; *) printf '%s\n' 'Invalid decorations' >&2; exit 2 ;; esac
if [ "$build_only" = true ] && [ "$run_only" = true ]; then exit 2; fi
source_root="$(cd "$source_root" && pwd)"
test -d "$source_root/Sources"
output="$results_root/$label"
binary="$output/GPUSimulationBenchmark"
mkdir -p "$output" "$ROOT/.build/module-cache"
if [ "$run_only" = false ]; then
    for previous in "$output"/*.json; do
        if [ -e "$previous" ]; then printf 'Existing results require a fresh build label: %s\n' "$previous" >&2; exit 2; fi
    done
    source_files=()
    while IFS= read -r file; do source_files+=("$file"); done < <(rg --files "$source_root/Sources" | rg '\.swift$' | rg -v '/Main\.swift$' | sort)
    shasum -a 256 "${source_files[@]}" > "$output/source-inputs.sha256"
    compiled=()
    for file in "${source_files[@]}"; do
        relative="${file#"$source_root/"}"
        target="$output/inputs/$relative"
        mkdir -p "$(dirname "$target")"
        cp "$file" "$target"
        compiled+=("$target")
    done
    cp Tests/GPUSimulationBenchmark.swift "$output/inputs/GPUSimulationBenchmark.swift"
    cp Scripts/benchmark-gpu-simulation.sh "$output/inputs/benchmark-gpu-simulation.sh"
    shasum -a 256 -c "$output/source-inputs.sha256" > "$output/source-copy-check.txt"
    shasum -a 256 "${compiled[@]}" "$output/inputs/GPUSimulationBenchmark.swift" \
        "$output/inputs/benchmark-gpu-simulation.sh" > "$output/checked-inputs.sha256"
    flags=(-O -whole-module-optimization -parse-as-library -swift-version 5 -target arm64-apple-macos14.0)
    if [ "$candidate" = true ]; then flags+=(-D GPU_SIMULATION_CANDIDATE); fi
    if [ "$festive" = true ]; then flags+=(-D FESTIVE_FEATURES); fi
    xcrun swiftc "${flags[@]}" -module-cache-path "$ROOT/.build/module-cache" "${compiled[@]}" \
        "$output/inputs/GPUSimulationBenchmark.swift" -o "$binary"
    shasum -a 256 -c "$output/checked-inputs.sha256" > "$output/compiled-input-check.txt"
    shasum -a 256 "$binary" > "$output/binary.sha256"
    {
        sw_vers
        uname -m
        sysctl -n hw.model 2>/dev/null || printf '%s\n' 'Hardware model unavailable in build sandbox; runtime JSON records public Metal device name.'
        xcrun swiftc --version
        printf 'Source root: %s\nLabel: %s\n' "$source_root" "$label"
    } > "$output/build-environment.txt"
fi
if [ "$build_only" = true ]; then printf 'Built: %s\n' "$binary"; exit 0; fi
test -x "$binary"
result="$output/$scenario.json"
if [ "$cpu_particles" = true ]; then result="$output/$scenario-cpu-particles.json"; fi
if [ "$decorations" = all ]; then result="${result%.json}-decorations-all.json"; fi
if [ -e "$result" ]; then printf 'Result already exists; choose a fresh label to preserve evidence: %s\n' "$result" >&2; exit 2; fi
args=(--scenario "$scenario" --label "$label" --warmup "$warmup" --seconds "$seconds" --output "$result")
args+=(--decorations "$decorations")
if [ "$cpu_particles" = true ]; then args+=(--cpu-particles); fi
"$binary" "${args[@]}"
