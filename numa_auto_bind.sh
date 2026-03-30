#!/bin/bash
#==============================================================================
# NUMA Auto-Bind: 自动配置 NUMA 绑核脚本
# 适用于 AI 训练任务，优化多插槽服务器的 CPU 亲和性和内存分配
#
# 用法:
#   ./numa_auto_bind.sh --gpus 0,1,2,3           绑定 GPU 0-3 对应的 NUMA 节点 CPU
#   ./numa_auto_bind.sh --mode full              所有 CPU 绑定到各自 NUMA 节点
#   ./numa_auto_bind.sh --mode manual --cpus 0-31 --node 0
#   ./numa_auto_bind.sh --show                    显示当前 NUMA 拓扑
#   ./numa_auto_bind.sh --force                   强制运行（跳过依赖检查）
#   ./numa_auto_bind.sh --help
#
# 作者: Zero (AI Assistant)
# 需求: numactl 或 lscpu（至少有一个）
#==============================================================================

# 注意：不使用 set -e，因为 grep 等命令返回 1 是正常的
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认值
MODE=""
GPU_IDS=""
MANUAL_CPUS=""
MANUAL_NODE=""
VERBOSE=0
FORCE=0

#==============================================================================
# 辅助函数
#==============================================================================
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR ]${NC} $1" >&2; }

version() {
    echo "numa_auto_bind.sh v1.2.0"
}

usage() {
    cat << EOF
${GREEN}NUMA Auto-Bind${NC} - 自动配置 NUMA 绑核，优化 AI 训练性能

${YELLOW}用法:${NC}
    $0 [选项]

${YELLOW}选项:${NC}
    --gpus <ids>      GPU ID 列表，脚本会自动找到对应 NUMA 节点的 CPU
                      例: --gpus 0,1,2,3 或 --gpus 0,1

    --mode <mode>     绑定模式:
                      full    - 所有 CPU 绑定到各自 NUMA 节点（宽松模式）
                      strict  - 每个 NUMA 节点严格绑定自身 CPU
                      manual  - 手动指定 CPU 范围和节点（需配合 --cpus --node）

    --cpus <range>    手动指定的 CPU 范围（配合 --mode manual）
                      例: 0-31 或 0,1,2,3 或 0-15,32-47

    --node <n>        手动指定的 NUMA 节点编号（配合 --mode manual）

    --show            显示当前 NUMA 拓扑信息

    --force           强制运行，跳过依赖检查（使用 /proc 或 /sys 读取 NUMA 信息）

    --verbose         显示详细调试信息

    --help            显示本帮助信息

${YELLOW}示例:${NC}
    # 绑定 GPU 0,1 对应的 NUMA 节点 CPU
    $0 --gpus 0,1

    # 绑定 GPU 0-3（跨节点）
    $0 --gpus 0,1,2,3

    # 显示 NUMA 拓扑
    $0 --show

    # 手动绑定 CPU 0-31 到节点 0
    $0 --mode manual --cpus 0-31 --node 0

${YELLOW}AI 训练建议:${NC}
    • 单 GPU: 使用 --gpus 0（或对应 GPU ID）
    • 多 GPU 同节点: 使用 --gpus 0,1,2,3
    • 多 GPU 跨节点: 需要配合 MPI/ NCCL 的跨节点通信
    • 性能关键任务: 建议同时设置 CUDA_VISIBLE_DEVICES

${YELLOW}输出环境变量:${NC}
    脚本成功后会输出可 source 的环境变量:
    • NUMA_CPUS       - 绑定的 CPU 核心列表
    • NUMA_NODE       - 绑定的 NUMA 节点编号
    • NUMA_GPUS       - 对应的 GPU ID 列表
    • LAUNCH_CMD      - 推荐的任务启动命令前缀

EOF
    exit 0
}

#==============================================================================
# 检查依赖
#==============================================================================
check_dependencies() {
    if [[ "$FORCE" == "1" ]]; then
        return 0
    fi

    local found=0

    if command -v numactl &>/dev/null; then
        if numactl --show &>/dev/null; then
            found=1
        fi
    fi

    if command -v lscpu &>/dev/null; then
        if lscpu -p &>/dev/null; then
            found=1
        fi
    fi

    if [[ -d /sys/devices/system/node ]]; then
        found=1
    fi

    if [[ -f /proc/cpuinfo ]]; then
        found=1
    fi

    if [[ "$found" == "0" ]]; then
        log_err "缺少 NUMA 支持，请安装 numactl 或使用 --force 强制运行"
        log_info "提示: apt install numactl"
        exit 1
    fi

    [[ "$VERBOSE" == "1" ]] && log_info "NUMA 信息源检测正常"
}

#==============================================================================
# 获取 NUMA 信息
#==============================================================================

# 获取所有 NUMA 节点列表
get_numa_nodes() {
    local nodes=""

    # 尝试 numactl
    if command -v numactl &>/dev/null; then
        nodes=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}' || true)
        if [[ -n "$nodes" ]]; then
            echo "$nodes"
            return 0
        fi
    fi

    # 尝试 lscpu -p (格式: thread,core,socket,node)
    if command -v lscpu &>/dev/null; then
        nodes=$(lscpu -p 2>/dev/null | grep -v "^#" | awk -F',' '{print $2}' | sort -u | tr '\n' ' ' || true)
        if [[ -n "$nodes" ]]; then
            echo "$nodes" | sed 's/ $//'
            return 0
        fi
    fi

    # 尝试 /sys
    for node_dir in /sys/devices/system/node/node*; do
        if [[ -d "$node_dir" ]]; then
            local node_id
            node_id=$(basename "$node_dir" | sed 's/node//' || true)
            nodes="$nodes $node_id"
        fi
    done

    if [[ -n "$nodes" ]]; then
        echo "$nodes" | sed 's/^ //' | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ' | sed 's/ $//'
        return 0
    fi

    # 回退：检查 /proc/cpuinfo
    if [[ -f /proc/cpuinfo ]]; then
        local node_count
        node_count=$(grep -c "physical id" /proc/cpuinfo 2>/dev/null || echo "0")
        if [[ "$node_count" -gt 0 ]] 2>/dev/null; then
            echo "0"
            return 0
        fi
    fi

    return 1
}

# 获取指定 NUMA 节点的 CPU 列表（核心编号）
get_cpus_per_node() {
    local target_node=$1
    local cpus=""

    # 尝试 numactl
    if command -v numactl &>/dev/null; then
        cpus=$(numactl --hardware 2>/dev/null | grep "^node $target_node cpus:" | cut -d: -f2- | sed 's/^ *//' || true)
        if [[ -n "$cpus" ]]; then
            echo "$cpus"
            return 0
        fi
    fi

    # 尝试 lscpu -p (格式: thread,core,socket,node)
    if command -v lscpu &>/dev/null; then
        cpus=$(lscpu -p 2>/dev/null | grep ",$target_node$" | awk -F',' '{print $2}' | sort -n | uniq | tr '\n' ' ' || true)
        if [[ -n "$cpus" ]]; then
            echo "$cpus" | sed 's/ $//'
            return 0
        fi
    fi

    # 尝试 /sys
    local node_path="/sys/devices/system/node/node$target_node"
    if [[ -d "$node_path" ]]; then
        if [[ -f "$node_path/cpulist" ]]; then
            cat "$node_path/cpulist" 2>/dev/null && return 0
        fi
    fi

    return 1
}

#==============================================================================
# 根据 GPU ID 推断 NUMA 节点
#==============================================================================
gpu_to_numa_node() {
    local gpu_id=$1

    # 尝试 nvidia-smi + PCI 总线
    if command -v nvidia-smi &>/dev/null; then
        local pci_bus
        pci_bus=$(nvidia-smi -i "$gpu_id" -q 2>/dev/null | grep -i "Bus Id" | grep -oP '0000:\K[0-9a-fA-F]+\.[0-9a-fA-F]+' | head -1 || true)
        if [[ -n "$pci_bus" ]]; then
            local sys_path="/sys/bus/pci/devices/0000:$pci_bus/numa_node"
            if [[ -f "$sys_path" ]]; then
                local node
                node=$(cat "$sys_path" 2>/dev/null || true)
                if [[ -n "$node" && "$node" != "-1" ]]; then
                    [[ "$VERBOSE" == "1" ]] && log_info "GPU $gpu_id -> PCI $pci_bus -> NUMA $node"
                    echo "$node"
                    return 0
                fi
            fi
        fi

        # 方法2: 直接从 nvidia-smi 解析（较新版本）
        local numa
        numa=$(nvidia-smi -i "$gpu_id" -q 2>/dev/null | grep -i "numa id" | grep -oP '\d+' | head -1 || true)
        if [[ -n "$numa" ]]; then
            [[ "$VERBOSE" == "1" ]] && log_info "GPU $gpu_id -> NUMA $numa (from nvidia-smi)"
            echo "$numa"
            return 0
        fi
    fi

    log_warn "无法确定 GPU $gpu_id 的 NUMA 节点，使用启发式分配（默认节点 0）"
    echo "0"
}

#==============================================================================
# 显示 NUMA 拓扑
#==============================================================================
show_numa_topology() {
    log_info "===== NUMA 拓扑信息 ====="

    local os
    os=$(uname -s)
    if [[ "$os" != "Linux" ]]; then
        log_warn "检测到操作系统: $os，NUMA 主要为 Linux 设计，部分信息可能不准确"
    fi

    echo ""

    # lscpu 输出
    if command -v lscpu &>/dev/null; then
        echo "--- lscpu ---"
        lscpu 2>/dev/null | grep -E "Architecture|Socket|Core|Thread|NUMA|CPU\(s\)|^#" || true
        echo ""
    fi

    # numactl 输出
    if command -v numactl &>/dev/null; then
        if numactl --show &>/dev/null; then
            echo "--- numactl --show ---"
            numactl --show 2>/dev/null
            echo ""
        fi
        if numactl --hardware &>/dev/null; then
            echo "--- numactl --hardware ---"
            numactl --hardware 2>/dev/null
            echo ""
        fi
    fi

    # /sys 方式
    if [[ -d /sys/devices/system/node ]]; then
        echo "--- /sys/devices/system/node ---"
        for node_dir in /sys/devices/system/node/node*; do
            if [[ -d "$node_dir" ]]; then
                local node_name
                node_name=$(basename "$node_dir")
                local cpulist="N/A"
                cpulist=$(cat "$node_dir/cpulist" 2>/dev/null || echo "N/A")
                echo "$node_name: cpulist=$cpulist"
            fi
        done
        echo ""
    fi

    # GPU 信息
    if command -v nvidia-smi &>/dev/null; then
        echo "--- NVIDIA GPU ---"
        nvidia-smi -L 2>/dev/null || log_warn "nvidia-smi 可用但无法列出 GPU"
        echo ""
        echo "GPU -> NUMA 映射:"
        local gpu_count
        gpu_count=$(nvidia-smi --list-gpus 2>/dev/null | grep -c "GPU" || echo "0")
        if [[ "$gpu_count" == "0" ]]; then
            log_info "  未检测到 NVIDIA GPU"
        else
            for ((i=0; i<gpu_count; i++)); do
                local node
                node=$(gpu_to_numa_node "$i")
                echo "  GPU $i -> NUMA Node $node"
            done
        fi
        echo ""
    fi

    # CPU 分布表
    log_info "CPU 分布详情:"
    local nodes
    nodes=$(get_numa_nodes || true)
    if [[ -n "$nodes" ]]; then
        for node in $nodes; do
            local cpus
            cpus=$(get_cpus_per_node "$node" || true)
            if [[ -n "$cpus" ]]; then
                local cpu_count
                cpu_count=$(echo "$cpus" | wc -w)
                log_info "  节点 $node: $cpu_count 个 CPU 核心"
                [[ "$VERBOSE" == "1" ]] && log_info "    $cpus"
            fi
        done
    else
        log_warn "无法获取 CPU 分布信息，请尝试 --force"
    fi

    echo ""
}

#==============================================================================
# 生成绑核命令
#==============================================================================
generate_bind_command() {
    local mode=$1
    local gpu_ids=$2
    local manual_cpus=$3
    local manual_node=$4

    local target_cpus=""
    local target_node=""
    local gpu_numa_nodes=()
    local bind_args=""

    case "$mode" in
        full)
            log_info "模式: full（所有 CPU 绑定到各自 NUMA 节点）"
            target_node="all"
            local all_cpus=""
            for node in $(get_numa_nodes || echo ""); do
                [[ -z "$node" ]] && continue
                local node_cpus
                node_cpus=$(get_cpus_per_node "$node" || true)
                if [[ -n "$node_cpus" ]]; then
                    all_cpus="$all_cpus $node_cpus"
                fi
            done
            target_cpus=$(echo "$all_cpus" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            ;;

        strict)
            log_info "模式: strict（每个节点严格绑定自身 CPU）"
            target_node="all"
            local all_cpus=""
            for node in $(get_numa_nodes || echo ""); do
                [[ -z "$node" ]] && continue
                local node_cpus
                node_cpus=$(get_cpus_per_node "$node" || true)
                if [[ -n "$node_cpus" ]]; then
                    all_cpus="$all_cpus $node_cpus"
                fi
            done
            target_cpus=$(echo "$all_cpus" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            ;;

        gpu)
            log_info "GPU 模式: 绑定 GPU [$gpu_ids] 对应的 NUMA 节点 CPU"

            declare -A node_cpus
            local unique_nodes=()

            IFS=',' read -ra GPU_ARRAY <<< "$gpu_ids"
            for gpu in "${GPU_ARRAY[@]}"; do
                gpu=$(echo "$gpu" | tr -d ' ')
                [[ -z "$gpu" ]] && continue

                local numa_node
                numa_node=$(gpu_to_numa_node "$gpu")
                gpu_numa_nodes+=("$gpu:$numa_node")

                if [[ ! " ${unique_nodes[*]} " =~ " ${numa_node} " ]]; then
                    unique_nodes+=("$numa_node")
                    local node_cpu_list
                    node_cpu_list=$(get_cpus_per_node "$numa_node" || true)
                    if [[ -n "$node_cpu_list" ]]; then
                        node_cpus[$numa_node]="$node_cpu_list"
                    fi
                fi
            done

            if [[ ${#node_cpus[@]} -eq 0 ]]; then
                log_err "无法获取 NUMA 节点 CPU 信息"
                log_info "请确认 numactl 已安装或使用 --force"
                exit 1
            fi

            local combined_cpus=""
            for node in "${!node_cpus[@]}"; do
                combined_cpus="$combined_cpus ${node_cpus[$node]}"
            done
            target_cpus=$(echo "$combined_cpus" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            target_node=$(IFS=,; echo "${unique_nodes[*]}")
            ;;

        manual)
            log_info "手动模式: CPU [$manual_cpus] -> NUMA Node $manual_node"
            target_cpus="$manual_cpus"
            target_node="$manual_node"
            ;;

        *)
            log_err "未知模式: $mode"
            usage
            ;;
    esac

    if [[ -z "$target_cpus" ]]; then
        log_err "未能获取任何 CPU 信息，绑定失败"
        log_info "请确认系统支持 NUMA 或使用 --force"
        exit 1
    fi

    echo ""
    log_ok "===== 绑定配置结果 ====="
    echo ""

    local node_display
    node_display=$(echo "$target_node" | tr '\n' ',' | sed 's/,$//')
    local cpu_count
    cpu_count=$(echo "$target_cpus" | tr ',' '\n' | wc -l)

    echo "${GREEN}绑定的 NUMA 节点:${NC} $node_display"
    echo "${GREEN}绑定的 CPU 数量:${NC} $cpu_count"
    echo "${GREEN}CPU 列表:${NC} $target_cpus"
    echo ""

    echo "${GREEN}可 source 的环境变量:${NC}"
    echo "  export NUMA_CPUS=\"$target_cpus\""
    echo "  export NUMA_NODE=\"$target_node\""
    echo "  export NUMA_GPUS=\"$gpu_ids\""
    echo ""

    if [[ "$mode" == "gpu" || "$mode" == "manual" ]]; then
        bind_args="--physcpubind=$target_cpus --membind=$target_node"
    else
        bind_args="--cpunodebind=$target_node --membind=$target_node"
    fi

    echo "${GREEN}推荐启动命令:${NC}"
    echo "  numactl $bind_args python train.py"
    echo ""

    if [[ ${#gpu_numa_nodes[@]} -gt 0 ]]; then
        echo "${GREEN}GPU -> NUMA 映射:${NC}"
        for mapping in "${gpu_numa_nodes[@]}"; do
            echo "  GPU $mapping"
        done
        echo ""
    fi

    local env_file="/tmp/numa_env_$(whoami 2>/dev/null || echo 'default').sh"
    cat > "$env_file" << EOF
# NUMA Auto-Bind 环境变量
# 生成时间: $(date)
# 模式: $mode

export NUMA_CPUS="$target_cpus"
export NUMA_NODE="$target_node"
export NUMA_GPUS="$gpu_ids"

export LAUNCH_CMD="numactl $bind_args"

# 使用方式:
#   source $env_file
#   \$LAUNCH_CMD python train.py
EOF

    log_info "环境变量已保存到: $env_file"
    echo ""

    local wrapper="/tmp/numa_launch_$(whoami 2>/dev/null || echo 'default').sh"
    cat > "$wrapper" << EOF
#!/bin/bash
# NUMA Auto-Bind 启动包装脚本
# 使用: $wrapper <command> [args...]

source "$env_file"

if [[ \$# -eq 0 ]]; then
    echo "用法: \$0 <command> [args...]"
    echo "例: \$0 python train.py --config config.yaml"
    echo ""
    echo "当前绑定: NUMA node=$node_display, CPU=$target_cpus"
    exit 1
fi

echo "==> NUMA 绑核启动"
echo "    节点: $node_display"
echo "    CPU:  $target_cpus"
echo "    命令: \$@"
echo ""

exec numactl $bind_args "\$@"
EOF

    chmod +x "$wrapper" 2>/dev/null || true
    log_info "启动包装脚本: $wrapper"
    echo ""
    echo "用法示例:"
    echo "  source $env_file"
    echo "  $wrapper python train.py"
    echo ""
}

#==============================================================================
# 解析命令行参数
#==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gpus)
                GPU_IDS="$2"
                MODE="gpu"
                shift 2
                ;;
            --mode)
                MODE="$2"
                shift 2
                ;;
            --cpus)
                MANUAL_CPUS="$2"
                shift 2
                ;;
            --node)
                MANUAL_NODE="$2"
                shift 2
                ;;
            --show)
                MODE="show"
                shift
                ;;
            --force|-f)
                FORCE=1
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --help|-h)
                usage
                ;;
            --version)
                version
                exit 0
                ;;
            *)
                log_err "未知参数: $1"
                usage
                ;;
        esac
    done

    if [[ "$MODE" == "show" ]]; then
        return
    fi

    if [[ -z "$MODE" ]]; then
        log_err "请指定运行模式 (--gpus, --mode, 或 --show)"
        echo ""
        usage
    fi

    if [[ "$MODE" == "manual" ]] && [[ -z "$MANUAL_CPUS" || -z "$MANUAL_NODE" ]]; then
        log_err "--mode manual 需要同时指定 --cpus 和 --node"
        exit 1
    fi

    if [[ "$MODE" == "gpu" ]] && [[ -z "$GPU_IDS" ]]; then
        log_err "--gpus 需要指定 GPU ID 列表"
        exit 1
    fi
}

#==============================================================================
# 主流程
#==============================================================================
main() {
    parse_args "$@"

    check_dependencies

    case "$MODE" in
        show)
            show_numa_topology
            ;;
        full|strict|gpu|manual)
            show_numa_topology
            generate_bind_command "$MODE" "$GPU_IDS" "$MANUAL_CPUS" "$MANUAL_NODE"
            ;;
        *)
            log_err "无效模式: $MODE"
            usage
            ;;
    esac
}

main "$@"
