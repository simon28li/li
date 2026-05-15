#!/bin/bash
#
# TC-006-gVisor-throughput-v2: Max start/stop throughput test in 1 second
# Change: throughput = 1 / average total duration (seconds)
#

########## Configuration ##########
RUNTIME_BIN="runsc"
IMAGE="88c56bc3ebe1"
NUMA_NODE=3
TEST_DURATION=1
ITERATIONS=10
CORE_GRADIENTS=(1)
LIMIT_CPUS=1
LIMIT_MEMORY_MB=2048

WORK_DIR="/ssd2/data/runsc-bench-$$"
ROOTFS_DIR="${WORK_DIR}/rootfs"
OUTPUT_DIR="./gvisor_throughput_avg_$(date +%Y%m%d_%H%M%S)"

DEBUG=0
########## Configuration end ##########

check_prerequisites() {
    echo "[INFO] Checking dependencies..."
    for cmd in runsc docker numactl bc jq; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] $cmd required"; exit 1; }
    done
    [ "$(id -u)" -ne 0 ] && echo "[WARN] Root privileges recommended"
    echo "[INFO] Dependency check passed"
}

prepare_rootfs() {
    echo "[INFO] Preparing rootfs (image $IMAGE)..."
    mkdir -p "$WORK_DIR"

    local cid=$(docker create "$IMAGE" 2>/dev/null)
    mkdir -p "$ROOTFS_DIR"
    docker export "$cid" | tar -x -C "$ROOTFS_DIR"
    docker rm "$cid" >/dev/null

    # write test.py
    cat > "${ROOTFS_DIR}/test.py" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
import resource
import time

def main():
    start = time.perf_counter()

    try:
        resource.setrlimit(
            resource.RLIMIT_AS,
            (17179869184, 17179869184)
        )
    except Exception:
        pass

    with open('./test.txt') as f:
        lines = f.readlines()

    sep = lines.index('--------------------------------\n')

    houses = [
        i - sep
        for i, line in enumerate(lines)
        if 'H' in line
    ]

    elapsed_ms = (time.perf_counter() - start) * 1000

    print(houses)
    print(f"Elapsed: {elapsed_ms:.3f} ms")

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

    # write test.txt
    cat > "${ROOTFS_DIR}/test.txt" << 'EOF'
H H H
--------------------------------
H H H H
EOF

    runsc spec -bundle "$WORK_DIR" >/dev/null 2>&1
    if [ ! -f "$WORK_DIR/config.json" ]; then
        echo "[ERROR] Failed to generate config.json"
        exit 1
    fi

    local mem_limit=$((LIMIT_MEMORY_MB * 1024 * 1024))
    local cpu_quota=$((LIMIT_CPUS * 100000))

    jq --arg root "$ROOTFS_DIR" \
       --arg mem_limit "$mem_limit" \
       --arg cpu_quota "$cpu_quota" \
       '.root.path = $root |
        .root.readonly = true |
        .process.terminal = false |
        .process.args = ["/usr/bin/python3", "/test.py"] |
        .process.env = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","TERM=xterm"] |
        .linux.resources = {
            "memory": {"limit": ($mem_limit|tonumber)},
            "cpu": {"quota": ($cpu_quota|tonumber), "period": 100000}
        }' \
        "$WORK_DIR/config.json" > "$WORK_DIR/config.tmp" && \
        mv "$WORK_DIR/config.tmp" "$WORK_DIR/config.json"

    echo "[INFO] Rootfs preparation completed"
}

self_test() {
    echo "[INFO] Performing quick self-test..."
    local test_bundle="${WORK_DIR}/test-bundle"
    local test_state="${WORK_DIR}/test-state"
    local test_id="test-$$-$(date +%s%N)"
    mkdir -p "$test_bundle" "$test_state"
    cp "${WORK_DIR}/config.json" "$test_bundle/config.json"

    local log_file="${WORK_DIR}/test-runsc.log"
    timeout 2 "$RUNTIME_BIN" --root="$test_state" run --bundle="$test_bundle" "$test_id" >"$log_file" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "[ERROR] Self-test failed (exit $rc). Please check runsc run availability."
        echo "[ERROR] Log: $log_file"
        cat "$log_file"
        rm -rf "$test_bundle" "$test_state"
        exit 1
    fi
    rm -rf "$test_bundle" "$test_state" "$log_file"
    echo "[INFO] Self-test passed"
}

cleanup() {
    echo "[INFO] Cleaning up environment..."
    rm -rf "$WORK_DIR"
    pkill -9 -f "runsc-" 2>/dev/null || true
}

# Single core worker process (records total container time + Python internal time)
run_single_core_worker() {
    local core=$1
    local duration_limit=$2
    local source_config="${WORK_DIR}/config.json"
    local cycle_count=0
    local durations=()        # container total duration (seconds)
    local py_times=()         # Python internal duration (seconds)
    local start_ts=$(date +%s.%N)

    while true; do
        local cur_ts=$(date +%s.%N)
        if awk -v s="$start_ts" -v c="$cur_ts" -v d="$duration_limit" \
               'BEGIN { if (c - s >= d) exit 0; else exit 1 }'; then
            break
        fi

        local container_id="bench-${core}-${cycle_count}-$(date +%s%N)"
        local bundle_path="${WORK_DIR}/bundle-${core}-${cycle_count}"
        local state_dir="${WORK_DIR}/state-${core}-${cycle_count}"
        mkdir -p "$bundle_path" "$state_dir"
        cp "$source_config" "$bundle_path/config.json"

        local cycle_start=$(date +%s.%N)
        local output_log="${bundle_path}/output.log"

        local cmd=(
            timeout 2 "$RUNTIME_BIN"
                --root="$state_dir"
                run
                --bundle="$bundle_path"
                "$container_id"
        )

        if [ "${SKIP_PHYSCPUBIND:-0}" -eq 1 ]; then
            numactl --cpunodebind=$NUMA_NODE --membind=$NUMA_NODE \
                "${cmd[@]}" >"$output_log" 2>&1
        else
            numactl --cpunodebind=$NUMA_NODE --membind=$NUMA_NODE --physcpubind=$core \
                "${cmd[@]}" >"$output_log" 2>&1
        fi
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            local cycle_end=$(date +%s.%N)
            local dur=$(awk -v s="$cycle_start" -v e="$cycle_end" 'BEGIN{printf "%.6f", e-s}')
            durations+=("$dur")

            # Extract Elapsed time reported by Python (milliseconds)
            local py_elapsed=$(grep -oP 'Elapsed:\s+\K[\d.]+' "$output_log" 2>/dev/null || echo "0")
            local py_sec=$(awk -v ms="$py_elapsed" 'BEGIN{printf "%.6f", ms/1000}')
            py_times+=("$py_sec")

            cycle_count=$((cycle_count + 1))
        else
            [ "$DEBUG" -eq 1 ] && echo "[WARN] core $core cycle $cycle_count failed (exit $exit_code)" >&2
            sleep 0.01
        fi

        rm -rf "$bundle_path" "$state_dir"
    done

    # Output format: RESULT:core:count: pairs of (total_duration:python_duration)
    echo -n "RESULT:$core:$cycle_count"
    for ((i=0; i<cycle_count; i++)); do
        echo -n ":${durations[$i]}:${py_times[$i]}"
    done
    echo
}

run_benchmark_for_cores() {
    local core_list=("$@")
    local n_cores=${#core_list[@]}

    local tmp_dir=$(mktemp -d -p /ssd2/data gvisor-bench-XXXXX)
    local pids=()

    for core in "${core_list[@]}"; do
        run_single_core_worker "$core" "$TEST_DURATION" > "${tmp_dir}/core_${core}.out" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done

    local total_cycles=0
    local all_durations=()      # total durations
    local all_py_durations=()   # Python durations
    local core_details=""

    for core in "${core_list[@]}"; do
        local out_file="${tmp_dir}/core_${core}.out"
        [ ! -f "$out_file" ] && continue

        local line=$(grep "^RESULT:" "$out_file" | head -n1)
        [ -z "$line" ] && continue

        local cycles=$(echo "$line" | cut -d':' -f3)
        if [[ "$cycles" =~ ^[0-9]+$ ]]; then
            total_cycles=$((total_cycles + cycles))
            local data_fields=$(echo "$line" | cut -d':' -f4-)
            local idx=0
            local pair_total=""
            local pair_py=""
            for val in $(echo "$data_fields" | tr ':' ' '); do
                if [ $((idx % 2)) -eq 0 ]; then
                    all_durations+=("$val")
                    pair_total="$val"
                else
                    all_py_durations+=("$val")
                    pair_py="$val"
                    core_details="${core_details}Core${core}_cycle$((idx/2)):total=${pair_total}s,py=${pair_py}s;"
                fi
                idx=$((idx+1))
            done
        fi
    done

    # Calculate average total duration (seconds)
    local avg_dur="0"
    [ ${#all_durations[@]} -gt 0 ] && \
        avg_dur=$(printf '%s\n' "${all_durations[@]}" | awk '{sum+=$1} END{printf "%.6f", sum/NR}')
    local avg_py_dur="0"
    [ ${#all_py_durations[@]} -gt 0 ] && \
        avg_py_dur=$(printf '%s\n' "${all_py_durations[@]}" | awk '{sum+=$1} END{printf "%.6f", sum/NR}')

    # throughput = 1 / average total duration (seconds)
    local throughput="0.00"
    if [ "$avg_dur" != "0" ] && [ "$avg_dur" != "0.000000" ]; then
        throughput=$(awk -v d="$avg_dur" 'BEGIN{printf "%.2f", 1.0/d}')
    fi

    echo "$n_cores,$throughput,$avg_dur,$avg_py_dur|$core_details"
    rm -rf "$tmp_dir"
}

get_numa_cores() {
    local node=$1
    lscpu -p=cpu,node 2>/dev/null | awk -F, -v node="$node" '$2 == node && $1 !~ /^#/ {print $1}' | sort -n
}

main() {
    check_prerequisites
    prepare_rootfs
    mkdir -p "$OUTPUT_DIR"

    self_test

    echo "Cores,Avg_Throughput,StdDev_Throughput,Avg_Total_ms,Avg_Python_ms" > "$OUTPUT_DIR/summary.csv"

    local all_cores=$(get_numa_cores $NUMA_NODE)
    if [ -z "$all_cores" ]; then
        echo "[ERROR] No cores available on NUMA Node $NUMA_NODE"
        cleanup; exit 1
    fi
    local total_available_cores=$(echo "$all_cores" | wc -l)

    for ((iter=1; iter<=ITERATIONS; iter++)); do
        echo ""
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "===== Round $iter / $ITERATIONS ($timestamp) ====="

        local iter_file="$OUTPUT_DIR/iter_${iter}_result.tmp"
        > "$iter_file"

        for n_cores in "${CORE_GRADIENTS[@]}"; do
            [ "$n_cores" -gt "$total_available_cores" ] && continue
            local selected_cores=($(echo "$all_cores" | head -n "$n_cores"))

            local full_result=$(run_benchmark_for_cores "${selected_cores[@]}")
            local result=$(echo "$full_result" | cut -d'|' -f1)
            local details=$(echo "$full_result" | cut -d'|' -f2)

            echo "$result" >> "$iter_file"

            local throughput=$(echo "$result" | cut -d',' -f2)
            local avg_total=$(echo "$result" | cut -d',' -f3)
            local avg_py=$(echo "$result" | cut -d',' -f4)
            echo "[INFO] $n_cores core(s): throughput $throughput cycles/s, avg total ${avg_total}s, avg Python ${avg_py}s"

            if [ -n "$details" ]; then
                echo "----- [DETAIL] Round $iter per-cycle duration details -----"
                echo "$details" | tr ';' '\n' | while read -r item; do
                    [ -n "$item" ] && echo "  -> $item"
                done
                echo "--------------------------------------------"
            fi
        done
    done

    echo ""
    echo "===== Computing average results ====="
    for n_cores in "${CORE_GRADIENTS[@]}"; do
        [ "$n_cores" -gt "$total_available_cores" ] && continue

        local lines=$(cat "$OUTPUT_DIR"/iter_*_result.tmp | grep "^$n_cores,")
        local throughputs=$(echo "$lines" | cut -d',' -f2)
        local total_durs=$(echo "$lines" | cut -d',' -f3)
        local py_durs=$(echo "$lines" | cut -d',' -f4)

        [ -z "$throughputs" ] && { echo "[WARN] No data for $n_cores core(s)"; continue; }

        # Throughput statistics (average of per-round throughputs)
        local avg_tp=$(echo "$throughputs" | awk '{sum+=$1} END{printf "%.2f", sum/NR}')
        local std_tp=$(echo "$throughputs" | awk -v avg="$avg_tp" '{sum+=($1-avg)^2} END{printf "%.2f", sqrt(sum/NR)}')

        # Total duration (seconds) converted to milliseconds
        local avg_total_ms=$(echo "$total_durs" | awk '{sum+=$1} END{printf "%.3f", sum/NR * 1000}')
        local std_total_ms=$(echo "$total_durs" | awk -v avg="$avg_total_ms" 'BEGIN{avg/=1000}{sum+=($1-avg)^2} END{printf "%.3f", sqrt(sum/NR)*1000}')

        # Python duration (seconds) converted to milliseconds
        local avg_py_ms=$(echo "$py_durs" | awk '{sum+=$1} END{printf "%.3f", sum/NR * 1000}')
        local std_py_ms=$(echo "$py_durs" | awk -v avg="$avg_py_ms" 'BEGIN{avg/=1000}{sum+=($1-avg)^2} END{printf "%.3f", sqrt(sum/NR)*1000}')

        echo "Cores: $n_cores"
        echo "  Avg Throughput: $avg_tp ± $std_tp cycles/s"
        echo "  Avg Total Duration: $avg_total_ms ± $std_total_ms ms"
        echo "  Avg Python Duration: $avg_py_ms ± $std_py_ms ms"

        echo "$n_cores,$avg_tp,$std_tp,$avg_total_ms,$avg_py_ms" >> "$OUTPUT_DIR/summary.csv"
    done

    rm -f "$OUTPUT_DIR"/iter_*_result.tmp
    echo "===== Done, results see $OUTPUT_DIR ====="
    cleanup
}

main
