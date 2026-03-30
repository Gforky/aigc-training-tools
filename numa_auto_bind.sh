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
FORCE=0

#==============================================================================
# 辅助函数
#==============================================================================
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR ]${NC} $1" >&2; }

version() {
    echo "numa_auto_bind.sh v1.1.0"
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

    local missing=()
    local found=0

    if command -v numactl &>/dev/null; then
        # 测试 numactl 是否真正可用（可能安装了但无权限）
        if numactl --show &>/dev/null; then
            found=1
        fi
    fi

    if command -v lscpu &>/dev/null; then
        if lscpu --parseable &>/dev/null || lscpu -p &>/dev/null; then
            found=1
        fi
    fi

    # 检查 /sys 文件系统（最基础的 NUMA 检测）
    if [[ -d /sys/devices/system/node ]]; then
        found=1
    fi

    if [[ "$found" == "0" ]]; then
        missing+=("numactl (apt install numactl)")
        missing+=("lscpu (apt install util-linux)")
        missing+=("/sys/devices/system/node (NUMA sysfs)")

        log_err "缺少 NUMA 支持，请安装上述依赖之一，或使用 --force 强制运行"
        log_info "提示: 使用 --force 会尝试从 /sys 读取 NUMA 信息"
        exit 1
    fi

    [[ "$VERBOSE" == "1" ]] && log_info "NUMA 信息源检测正常"
}

#==============================================================================
# 获取 NUMA 信息（多层 fallback）
#==============================================================================

# 方法1: numactl --hardware
get_numa_info_numactl() {
    numactl --hardware 2>/dev/null || numactl -H 2>/dev/null
}

# 方法2: lscpu
get_numa_info_lscpu() {
    lscpu 2>/dev/null
}

# 方法3: 从 /sys 读取
get_numa_info_sys() {
    local node_path="/sys/devices/system/node"
    if [[ ! -d "$node_path" ]]; then
        return 1
    fi

    echo "NUMA topology from /sys:"
    for node_dir in "$node_path"/node*; do
        if [[ -d "$node_dir" ]]; then
            local node_name
            node_name=$(basename "$node_dir")
            local cpu_list
            cpu_list=$(cat "$node_dir"/cpumap 2>/dev/null | tr -d '\n' || echo "unknown")
            # cpumap 是 bitmask，需要转换
            local cpu_count
            cpu_count=$(ls -d "$node_dir"/cpu[0-9]* 2>/dev/null | wc -l || echo "?")
            echo "$node_name: cpus=$cpu_count (cpumap=$cpu_list)"
        fi
    done
}

# 获取所有 NUMA 节点列表
get_numa_nodes() {
    local nodes=""

    # 尝试 numactl
    if command -v numactl &>/dev/null; then
        nodes=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}')
        if [[ -n "$nodes" ]]; then
            echo "$nodes"
            return 0
        fi
    fi

    # 尝试 lscpu -p
    if command -v lscpu &>/dev/null; then
        nodes=$(lscpu -p 2>/dev/null | grep -v "^#" | awk -F',' '{print $2}' | sort -u | tr '\n' ' ')
        if [[ -n "$nodes" ]]; then
            echo "$nodes" | sed 's/ $//'
            return 0
        fi
    fi

    # 尝试 /sys
    for node_dir in /sys/devices/system/node/node*; do
        if [[ -d "$node_dir" ]]; then
            local node_id
            node_id=$(basename "$node_dir" | sed 's/node//')
            nodes="$nodes $node_id"
        fi
    done

    if [[ -n "$nodes" ]]; then
        echo "$nodes" | sed 's/^ //' | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//'
        return 0
    fi

    return 1
}

# 获取指定 NUMA 节点的 CPU 列表（核心编号）
get_cpus_per_node() {
    local target_node=$1
    local cpus=""

    # 尝试 numactl
    if command -v numactl &>/dev/null; then
        cpus=$(numactl --hardware 2>/dev/null | grep "^node $target_node cpus:" | cut -d: -f2- | sed 's/^ *//')
        if [[ -n "$cpus" ]]; then
            echo "$cpus"
            return 0
        fi
    fi

    # 尝试 lscpu -p（格式: thread,core,socket,node）
    if command -v lscpu &>/dev/null; then
        cpus=$(lscpu -p 2>/dev/null | grep ",$target_node$" | awk -F',' '{print $2}' | sort -n | uniq | tr '\n' ' ' | sed 's/ $//')
        if [[ -n "$cpus" ]]; then
            echo "$cpus"
            return 0
        fi
    fi

    # 尝试 /sys
    local node_path="/sys/devices/system/node/node$target_node"
    if [[ -d "$node_path" ]]; then
        # 读取 cpu list (有些系统有 cpulist 文件)
        if [[ -f "$node_path/cpulist" ]]; then
            cat "$node_path/cpulist" 2>/dev/null && return 0
        fi
        # 从 cpumap bitmask 转换
        if [[ -f "$node_path/cpumap" ]]; then
            local bitmask
            bitmask=$(cat "$node_path/cpumap" 2>/dev/null | tr -d '\n ')
            # 解析 bitmask 为 CPU 列表
            local cpu_idx=0
            local cpu_list=""
            for byte in $(echo "$bitmask" | fold -w2); do
                local val=$((16#$byte))
                local bit=0
                while [[ $bit -lt 8 ]]; do
                    if (( (val >> bit) & 1 )); then
                        cpu_list="$cpu_list $cpu_idx"
                    fi
                    ((bit++))
                done
                ((cpu_idx+=8))
            done
            echo "$cpu_list" | sed 's/^ //' | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ' | sed 's/ $//'
            return 0
        fi
    fi

    return 1
}

# 获取 CPU 总数和节点数
get_system_info() {
    local cpu_count
    local node_count

    cpu_count=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "?")
    node_count=$(echo "$(get_numa_nodes)" | wc -w 2>/dev/null || echo "?")

    echo "CPU 总数: $cpu_count"
    echo "NUMA 节点数: $node_count"
}

#==============================================================================
# 根据 GPU ID 推断 NUMA 节点
#==============================================================================
gpu_to_numa_node() {
    local gpu_id=$1

    # 尝试 nvidia-smi + PCI 总线
    if command -v nvidia-smi &>/dev/null; then
        # 方法1: 通过 nvidia-smi 查询 PCI 总线，然后查 sysfs
        local pci_bus
        pci_bus=$(nvidia-smi -i "$gpu_id" -q 2>/dev/null | grep -i "Bus Id" | grep -oP '0000:\K[0-9a-fA-F]+\.[0-9a-fA-F]+' | head -1)
        if [[ -n "$pci_bus" ]]; then
            local sys_path="/sys/bus/pci/devices/0000:$pci_bus/numa_node"
            if [[ -f "$sys_path" ]]; then
                local node
                node=$(cat "$sys_path" 2>/dev/null)
                if [[ -n "$node" && "$node" != "-1" ]]; then
                    [[ "$VERBOSE" == "1" ]] && log_info "GPU $gpu_id -> PCI $pci_bus -> NUMA $node"
                    echo "$node"
                    return 0
                fi
            fi
        fi

        # 方法2: 直接从 nvidia-smi 解析（较新版本）
        local numa
        numa=$(nvidia-smi -i "$gpu_id" -q 2>/dev/null | grep -i "numa id" | grep -oP '\d+' | head -1)
        if [[ -n "$numa" ]]; then
            [[ "$VERBOSE" == "1" ]] && log_info "GPU $gpu_id -> NUMA $numa (from nvidia-smi)"
            echo "$numa"
            return 0
        fi
    fi

    # 回退: 通过 GPU 数量启发式分配（同节点 = 前半 GPU）
    # 仅当没有其他信息时使用
    log_warn "无法确定 GPU $gpu_id 的 NUMA 节点，使用启发式分配"
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
        log_warn "检测到操作系统: $os，NUMA 主要为 Linux 设计"
    fi

    echo ""

    # 尝试 lscpu（格式最好）
    if command -v lscpu &>/dev/null; then
        echo "--- lscpu 输出 ---"
        lscpu 2>/dev/null | grep -E "Architecture|Socket|Core|Thread|NUMA|CPU\(s\)|^#"
        echo ""
    fi

    # 尝试 numactl
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
                local cpulist
                cpulist=$(cat "$node_dir/cpulist" 2>/dev/null || echo "N/A")
                local meminfo
                meminfo=$(cat "$node_dir/meminfo" 2>/dev/null | head -2 || echo "N/A")
                echo "$node_name: cpulist=$cpulist"
                echo "  $meminfo"
            fi
        done
        echo ""
    fi

    # GPU 信息
    if command -v nvidia-smi &>/dev/null; then
        echo "--- NVIDIA GPU ---"
        nvidia-smi -L 2>/dev/null || true
        echo ""
        echo "GPU -> NUMA 映射:"
        local gpu_count
        gpu_count=$(nvidia-smi --list-gpus 2>/dev/null | grep -c "GPU" || echo "0")
        for ((i=0; i<gpu_count; i++)); do
            local node
            node=$(gpu_to_numa_node "$i")
            echo "  GPU $i -> NUMA Node $node"
        done
        echo ""
    fi

    # CPU 分布表
    log_info "CPU 分布详情:"
    local nodes
    nodes=$(get_numa_nodes)
    if [[ -n "$nodes" ]]; then
        for node in $nodes; do
            local cpus
            cpus=$(get_cpus_per_node "$node")
            if [[ -n "$cpus" ]]; then
                local cpu_count
                cpu_count=$(echo "$cpus" | wc -w)
                log_info "  节点 $node: $cpu_count 个 CPU核心"
                if [[ "$VERBOSE" == "1" ]]; then
                    log_info "    $cpus"
                fi
            fi
        done
    else
        log_warn "无法获取 CPU 分布信息"
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
            # 收集所有节点的 CPU
            local all_cpus=""
            for node in $(get_numa_nodes); do
                local node_cpus
                node_cpus=$(get_cpus_per_node "$node")
                if [[ -n "$node_cpus" ]]; then
                    all_cpus="$all_cpus $node_cpus"
                fi
            done
            # 去重并排序
            target_cpus=$(echo "$all_cpus" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            ;;

        strict)
            log_info "模式: strict（每个节点严格绑定自身 CPU）"
            target_node="all"
            # strict 模式: 每个节点分别绑定
            local all_cpus=""
            for node in $(get_numa_nodes); do
                local node_cpus
                node_cpus=$(get_cpus_per_node "$node")
                if [[ -n "$node_cpus" ]]; then
                    all_cpus="$all_cpus $node_cpus"
                fi
            done
            target_cpus=$(echo "$all_cpus" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            ;;

        gpu)
            log_info "GPU 模式: 绑定 GPU [$gpu_ids] 对应的 NUMA 节点 CPU"

            # 去重收集每个 GPU 对应的 NUMA 节点
            declare -A node_cpus
            local unique_nodes=()

            IFS=',' read -ra GPU_ARRAY <<< "$gpu_ids"
            for gpu in "${GPU_ARRAY[@]}"; do
                gpu=$(echo "$gpu" | tr -d ' ')
                [[ -z "$gpu" ]] && continue

                local numa_node
                numa_node=$(gpu_to_numa_node "$gpu")
                gpu_numa_nodes+=("$gpu:$numa_node")

                # 避免重复收集同一节点
                if [[ ! " ${unique_nodes[*]} " =~ " ${numa_node} " ]]; then
                    unique_nodes+=("$numa_node")
                    local node_cpu_list
                    node_cpu_list=$(get_cpus_per_node "$numa_node")
                    if [[ -n "$node_cpu_list" ]]; then
                        node_cpus[$numa_node]="$node_cpu_list"
                    fi
                fi
            done

            if [[ ${#node_cpus[@]} -eq 0 ]]; then
                log_err "无法获取 NUMA 节点 CPU 信息，请检查 numactl 或 /sys 是否可用"
                log_info "可尝试 --force 参数强制运行"
                exit 1
            fi

            # 合并所有节点的 CPU
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
        log_info "请确认: (1) numactl 已安装且可用, (2) /sys/devices/system/node 存在"
        log_info "或使用 --force 强制运行"
        exit 1
    fi

    # 输出结果
    echo ""
    log_ok "===== 绑定配置结果 ====="
    echo ""

    # 如果节点是多个，用逗号分隔显示
    local node_display
    node_display=$(echo "$target_node" | tr '\n' ',' | sed 's/,$//')
    local cpu_count
    cpu_count=$(echo "$target_cpus" | tr ',' '\n' | wc -l)

    echo "${GREEN}绑定的 NUMA 节点:${NC} $node_display"
    echo "${GREEN}绑定的 CPU 数量:${NC} $cpu_count"
    echo "${GREEN}CPU 列表:${NC} $target_cpus"
    echo ""

    # 生成环境变量
    echo "${GREEN}可 source 的环境变量:${NC}"
    echo "  export NUMA_CPUS=\"$target_cpus\""
    echo "  export NUMA_NODE=\"$target_node\""
    echo "  export NUMA_GPUS=\"$gpu_ids\""
    echo ""

    # 生成绑定参数
    if [[ "$mode" == "gpu" || "$mode" == "manual" ]]; then
        bind_args="--physcpubind=$target_cpus --membind=$target_node"
    else
        bind_args="--cpunodebind=$target_node --membind=$target_node"
    fi

    echo "${GREEN}推荐启动命令:${NC}"
    echo "  numactl $bind_args python train.py"
    echo ""

    # GPU -> NUMA 映射详情
    if [[ ${#gpu_numa_nodes[@]} -gt 0 ]]; then
        echo "${GREEN}GPU -> NUMA 映射:${NC}"
        for mapping in "${gpu_numa_nodes[@]}"; do
            echo "  GPU $mapping"
        done
        echo ""
    fi

    # 保存到临时文件
    local env_file="/tmp/numa_env_$(whoami 2>/dev/null || echo 'default').sh"
    cat > "$env_file" << EOF
# NUMA Auto-Bind 环境变量
# 生成时间: $(date)
# 模式: $mode

export NUMA_CPUS="$target_cpus"
export NUMA_NODE="$target_node"
export NUMA_GPUS="$gpu_ids"

# 推荐启动命令
export LAUNCH_CMD="numactl $bind_args"

# 使用方式:
#   source $env_file
#   \$LAUNCH_CMD python train.py
EOF

    log_info "环境变量已保存到: $env_file"
    echo ""

    # 生成可直接使用的包装脚本
    local wrapper="/tmp/numa_launch_$(whoami 2>/dev/null || echo 'default').sh"
    cat > "$wrapper" << EOF
#!/bin/bash
# NUMA Auto-Bind 启动包装脚本
# 使用: $wrapper <command> [args...]
#
# NUMA 绑定: node=$node_display, cpus=$target_cpus

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

    # 验证参数
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

    if [[ "$MODE" == "gpu" ]] && [[ ! "$GPU_IDS" =~ ^[0-9,\ ]+$ ]]; then
        log_err "--gpus 参数格式错误，请使用逗号分隔的数字，如: 0,1,2,3"
        exit 1
    fi
}

#==============================================================================
# 主流程
#==============================================================================
main() {
    parse_args "$@"

    # Linux 检查
    if [[ "$(uname -s)" != "Linux" ]]; then
        if [[ "$FORCE" != "1" && "$MODE" != "show" ]]; then
            log_warn "NUMA 是 Linux 特性，当前系统: $(uname -s)"
            log_info "使用 --force 可强制运行（可能无法获取完整信息）"
        fi
    fi

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
