# AIGC Training Tools

AIGC 训练工具集，包含 NUMA 绑核、GPU 优化、分布式训练辅助脚本。

## 工具列表

### 🔧 NUMA Auto-Bind (`numa_auto_bind.sh`)

自动配置 NUMA 绑核，优化 AI 训练任务的 CPU 亲和性和内存分配。

#### 功能特性

- **GPU 感知**：根据 GPU ID 自动推断对应 NUMA 节点
- **灵活模式**：支持 GPU 模式、全节点模式、手动指定模式
- **环境变量**：生成可 source 的环境变量，方便集成到训练脚本
- **拓扑展示**：一键查看服务器 NUMA 拓扑结构
- **启动包装**：生成可直接使用的任务启动脚本

#### 快速开始

```bash
# 查看帮助
./numa_auto_bind.sh --help

# 查看 NUMA 拓扑
./numa_auto_bind.sh --show

# 绑定 GPU 0,1 对应的 NUMA 节点 CPU
./numa_auto_bind.sh --gpus 0,1

# 绑定 GPU 0-3
./numa_auto_bind.sh --gpus 0,1,2,3

# 手动指定 CPU 范围和节点
./numa_auto_bind.sh --mode manual --cpus 0-31 --node 0
```

#### 输出示例

```
[ OK ] ===== 绑定配置结果 =====

export NUMA_CPUS="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31"
export NUMA_NODE="0"
export NUMA_GPUS="0,1"

export LAUNCH_CMD="numactl --physcpubind=0-31 --membind=0"

快速使用:
  source /tmp/numa_env_$USER.sh

启动训练示例:
  numactl --physcpubind=0-31 --membind=0 python train.py
```

#### AI 训练建议

| 场景 | 推荐用法 |
|------|----------|
| 单 GPU | `./numa_auto_bind.sh --gpus 0` |
| 多 GPU 同节点 | `./numa_auto_bind.sh --gpus 0,1,2,3` |
| 多 GPU 跨节点 | 配合 MPI/NCCL 通信，使用 `--mode full` |
| 性能关键任务 | 同时设置 `CUDA_VISIBLE_DEVICES` |

#### 环境变量

| 变量 | 说明 |
|------|------|
| `NUMA_CPUS` | 绑定的 CPU 核心列表 |
| `NUMA_NODE` | 绑定的 NUMA 节点编号 |
| `NUMA_GPUS` | 对应的 GPU ID 列表 |
| `LAUNCH_CMD` | 推荐的任务启动命令前缀 |

#### 依赖

- `numactl`
- `lscpu`
- Linux 操作系统

安装依赖：
```bash
# Ubuntu/Debian
sudo apt install numactl util-linux

# CentOS/RHEL
sudo yum install numactl util-linux
```

---

## 📈 后续计划

- [ ] `gpu_topology_detect.sh` - 自动检测 GPU 之间的拓扑关系（NVLINK/Pcie）
- [ ] `distributed_launch.sh` - 分布式训练一键启动脚本
- [ ] `memory_monitor.sh` - 显存和内存实时监控
- [ ] `checkpoint_manager.sh` - 训练checkpoint自动管理

---

## 贡献

欢迎提交 Issue 和 PR！

## License

MIT
