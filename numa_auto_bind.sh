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
#   ./numa_auto_bind.sh --help
#
# 作者: Zero (AI Assistant)
# 需求: numactl, lscpu, /proc/cpuinfo
#==============================================================================

set -euo pipefail

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

#==============================================================================
# 辅助函数
#==============================================================================
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR ]${NC} $1" >&2; }

version() {
    echo "numa_auto_bind.sh v1.0.0"
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
    local missing=()

    if ! command -v numactl &>/dev/null; then
        missing+=("numactl (apt install numactl / yum install numactl)")
    fi

    if ! command -v lscpu &>/dev/null; then
        missing+=("lscpu (apt install util-linux / yum install util-linux)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_err "缺少必要依赖:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

#==============================================================================
# 获取 NUMA 拓扑信息
#==============================================================================
get_numa_info() {
    numactl --hardware 2>/dev/null || numactl -H 2>/dev/null
}

get_numa_nodes() {
    numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}'
}

get_cpus_per_node() {
    local node=$1
    numactl --hardware 2>/dev/null | grep "node $node cpus:" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i}'
}

get_phys_cpu_list() {
    local node=$1
    # 获取节点的 CPU 列表（物理核心）
    numactl --physcpubind=$node 2>/dev/null || \
        lscpu -p | grep ",$node," | awk -F',' '{print $2}' | sort -n | uniq
}

#==============================================================================
# 根据 GPU ID 推断 NUMA 节点（通过 PCI 总线位置）
#==============================================================================
gpu_to_numa_node() {
    local gpu_id=$1

    # 尝试通过 nvidia-smi 获取 GPU PCI 总线信息
    if command -v nvidia-smi &>/dev/null; then
        local pci_bus
        pci_bus=$(nvidia-smi -i "$gpu_id" -q -x 2>/dev/null | \
                   grep -oP 'BusLocation.*?\K([0-9a-fA-F]+)' | head -1)

        if [[ -n "$pci_bus" ]]; then
            # 读取 NUMA 节点（从 /sys 或 lspci）
            local sys_path="/sys/bus/pci/devices/0000:$pci_bus/numa_node"
            if [[ -f "$sys_path" ]]; then
                cat "$sys_path" 2>/dev/null
                return
            fi
        fi
    fi

    # 回退方案：通过 GPU 数量猜测（同节点 = 前半部分 GPU）
    # 注意：这是启发式方法，不保证准确
    echo "0"  # 默认返回节点 0
}

#==============================================================================
# 显示 NUMA 拓扑
#==============================================================================
show_numa_topology() {
    log_info "===== NUMA 拓扑信息 ====="

    if command -v lscpu &>/dev/null; then
        echo ""
        lscpu | grep -E "Architecture|Socket|Core|Thread|NUMA|CPU\(s\)"
        echo ""
    fi

    echo ""
    log_info "NUMA 节点详情:"
    numactl --hardware 2>/dev/null

    echo ""
    log_info "CPU 分布:"
    local nodes
    nodes=$(get_numa_nodes)
    for node in $nodes; do
        local cpus
        cpus=$(get_phys_cpu_list $node)
        log_info "  节点 $node: $cpus"
    done

    echo ""
    log_info "内存分布:"
    numactl -s 2>/dev/null | grep -E "node|size" || numactl --show

    # 检查 NVIDIA GPU 和 NUMA 关联
    if command -v nvidia-smi &>/dev/null; then
        echo ""
        log_info "GPU-NUMA 映射:"
        nvidia-smi -L 2>/dev/null || true
        for gpu in $(nvidia-smi --list-gpus 2>/dev/null | grep "GPU [0-9]" | grep -oP 'GPU [0-9]'); do
            local gpu_id
            gpu_id=$(echo "$gpu" | grep -oP '[0-9]+')
            local numa_node
            numa_node=$(gpu_to_numa_node "$gpu_id")
            echo "  GPU $gpu_id -> NUMA Node $numa_node"
        done
    fi

    echo ""
}

#==============================================================================
# 生成绑核命令
#==============================================================================
generate_bind_command() {
    local mode=$1
    shift
    local gpu_ids=$1
    shift
    local manual_cpus=$1
    shift
    local manual_node=$1

    local target_cpus=""
    local target_node=""
    local gpu_numa_nodes=()

    case "$mode" in
        full|strict)
            log_info "使用 --mode $mode"
            # 获取所有 NUMA 节点上的 CPU
            local all_cpus=""
            for node in $(get_numa_nodes); do
                local node_cpus
                node_cpus=$(get_phys_cpu_list $node)
                all_cpus="$all_cpus $node_cpus"
            done
            target_cpus=$(echo "$all_cpus" | tr ' ' '\n' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            target_node="all"
            ;;

        gpu)
            log_info "GPU 模式: $gpu_ids"
            # 收集所有 GPU 对应的 NUMA 节点
            local node_cpu_map=()  # associative-like array: node -> cpus
            declare -A node_cpus

            IFS=',' read -ra GPU_ARRAY <<< "$gpu_ids"
            for gpu in "${GPU_ARRAY[@]}"; do
                gpu=$(echo "$gpu" | tr -d ' ')
                local numa_node
                numa_node=$(gpu_to_numa_node "$gpu")
                gpu_numa_nodes+=("$gpu:$numa_node")

                local node_cpus_list
                node_cpus_list=$(get_phys_cpu_list "$numa_node")

                if [[ -z "${node_cpus[$numa_node]:-}" ]]; then
                    node_cpus[$numa_node]="$node_cpus_list"
                fi
            done

            # 合并同一节点的 CPU
            local first_node=""
            target_cpus=""
            for node in $(echo "${!node_cpus[@]}" | tr ' ' '\n' | sort -n); do
                [[ -z "$first_node" ]] && first_node=$node
                target_cpus="$target_cpus $(echo "${node_cpus[$node]}" | tr ' ' '\n' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')"
            done
            target_cpus=$(echo "$target_cpus" | tr ' ' '\n' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            target_node=$first_node
            ;;

        manual)
            if [[ -z "$manual_cpus" || -z "$manual_node" ]]; then
                log_err "--mode manual 需要配合 --cpus 和 --node 参数"
                exit 1
            fi
            target_cpus="$manual_cpus"
            target_node="$manual_node"
            ;;

        *)
            log_err "未知模式: $mode"
            usage
            ;;
    esac

    # 输出结果
    echo ""
    log_ok "===== 绑定配置结果 ====="
    echo ""
    echo "export NUMA_CPUS=\"$target_cpus\""
    echo "export NUMA_NODE=\"$target_node\""
    echo "export NUMA_GPUS=\"$gpu_ids\""
    echo ""

    # 生成推荐命令
    local bind_args=""
    if [[ "$mode" == "gpu" ]]; then
        bind_args="--physcpubind=$target_cpus --membind=$target_node"
    else
        bind_args="--cpunodebind=$target_node --membind=$target_node"
    fi

    echo "export LAUNCH_CMD=\"numactl $bind_args\""
    echo ""
    echo "${GREEN}快速使用:${NC}"
    echo "  source /tmp/numa_env_\$(whoami).sh  # 加载环境变量"
    echo ""
    echo "${GREEN}启动训练示例:${NC}"
    echo "  numactl $bind_args python train.py"
    echo ""

    # 保存到临时文件供 source
    local env_file="/tmp/numa_env_$(whoami 2>/dev/null || echo "default").sh"
    cat > "$env_file" << EOF
# NUMA Auto-Bind 环境变量
# 生成时间: $(date)
# 模式: $mode

export NUMA_CPUS="$target_cpus"
export NUMA_NODE="$target_node"
export NUMA_GPUS="$gpu_ids"

# GPU -> NUMA 映射详情
EOF

    for mapping in "${gpu_numa_nodes[@]:-}"; do
        echo "# $mapping" >> "$env_file"
    done

    cat >> "$env_file" << EOF

# 推荐启动命令
export LAUNCH_CMD="numactl $bind_args"

# 使用方式:
#   source $env_file
#   \$LAUNCH_CMD python train.py
EOF

    log_info "环境变量已保存到: $env_file"
    echo ""

    # 直接生成可直接使用的脚本
    local wrapper_script="/tmp/numa_launch_\$(whoami 2>/dev/null || echo "default").sh"
    cat > "$wrapper_script" << EOF
#!/bin/bash
# NUMA Auto-Bind 启动包装脚本
# 使用: numa_launch.sh <your_command>
# 例: numa_launch.sh python train.py --args ...

source "$env_file"

if [[ \$# -eq 0 ]]; then
    echo "用法: \$0 <command> [args...]"
    echo "例: \$0 python train.py"
    exit 1
fi

echo "启动命令 (NUMA 绑定: node=$target_node, cpus=$target_cpus):"
echo "  \$@"
echo ""

exec numactl $bind_args "\$@"
EOF

    chmod +x "$wrapper_script" 2>/dev/null || true
    log_info "启动包装脚本: $wrapper_script"
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

    # 验证参数
    if [[ "$MODE" == "show" ]]; then
        return
    fi

    if [[ -z "$MODE" ]]; then
        log_err "请指定运行模式 (--gpus, --mode, 或 --show)"
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

    # 检查是否为 Linux
    if [[ "$(uname)" != "Linux" ]]; then
        log_warn "此脚本设计用于 Linux 系统，当前运行在 $(uname)，部分功能可能受限"
    fi

    case "$MODE" in
        show)
            check_dependencies
            show_numa_topology
            ;;
        full|strict|gpu|manual)
            check_dependencies
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
