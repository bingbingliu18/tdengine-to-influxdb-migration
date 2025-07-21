# 配置参数说明

## 迁移脚本参数

`submit_native_direct_migration_offset.sh` 脚本支持以下参数：

### 必需参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `--source-jdbc-url` | TDengine JDBC URL | jdbc:TAOS://hostname:6030/database |
| `--source-username` | TDengine 用户名 | root |
| `--source-password` | TDengine 密码 | taosdata |
| `--source-table` | TDengine 表名 | your_table |
| `--target-influx-url` | InfluxDB URL | http://hostname:8086 |
| `--target-token` | InfluxDB 访问令牌 | your-token |
| `--target-org` | InfluxDB 组织名称 | your-org |
| `--target-bucket` | InfluxDB 存储桶名称 | your-bucket |
| `--target-measurement` | InfluxDB 测量名称 | your_measurement |
| `--cluster-id` | EMR 集群 ID | j-XXXXXXXXXX |
| `--region` | AWS 区域 | us-east-1 |
| `--key-file` | SSH 密钥文件 | your-key.pem |

### 可选参数

| 参数 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `--parallelism` | 并行度 | 8 | 16 |
| `--batch-size` | 批处理大小 | 2000 | 5000 |
| `--task-nodes` | 任务节点数量 | 8 | 4 |
| `--start-time` | 数据迁移开始时间 | - | 2023-01-01 00:00:00.000 |
| `--end-time` | 数据迁移结束时间 | - | 2023-12-31 23:59:59.999 |

## Flink 作业配置

迁移脚本中包含了以下 Flink 作业配置：

### 资源配置

| 参数 | 值 | 说明 |
|------|------|------|
| `taskmanager.memory.process.size` | 8192mb | 每个任务管理器的内存大小 |
| `jobmanager.memory.process.size` | 2048mb | 作业管理器的内存大小 |
| `taskmanager.numberOfTaskSlots` | 动态计算 | 每个任务管理器的槽位数，根据并行度和任务节点数计算 |

### 检查点配置

| 参数 | 值 | 说明 |
|------|------|------|
| `state.backend.incremental` | true | 启用增量检查点 |
| `state.checkpoints.dir` | hdfs:///flink-checkpoints | 检查点存储目录 |
| `execution.checkpointing.interval` | 30000 | 检查点间隔（毫秒） |
| `execution.checkpointing.mode` | EXACTLY_ONCE | 检查点模式 |
| `execution.checkpointing.timeout` | 120000 | 检查点超时（毫秒） |

## TDengine 连接配置

TDengine 连接支持两种 JDBC URL 格式：

1. **原生连接**：`jdbc:TAOS://hostname:6030/database`
2. **REST API 连接**：`jdbc:TAOS-RS://hostname:6041/database`

脚本会自动将 REST API 格式转换为原生格式以提高性能。

## InfluxDB 写入配置

InfluxDB 写入使用以下配置：

| 参数 | 值 | 说明 |
|------|------|------|
| `batchSize` | 与命令行参数相同 | 批量写入的点数 |
| `flushInterval` | 1000 | 刷新间隔（毫秒） |
| `bufferLimit` | batchSize * 2 | 缓冲区限制 |
| `retryInterval` | 5000 | 重试间隔（毫秒） |
| `maxRetries` | 5 | 最大重试次数 |

## 调优建议

### 并行度设置

- 对于小型数据集（< 1000万行）：设置 `--parallelism 4`
- 对于中型数据集（1000万 - 1亿行）：设置 `--parallelism 8`
- 对于大型数据集（> 1亿行）：设置 `--parallelism 16`

### 批处理大小

- 对于复杂数据（多列）：设置 `--batch-size 1000`
- 对于简单数据（少量列）：设置 `--batch-size 5000`

### 任务节点数量

任务节点数量应根据 EMR 集群的大小进行调整。一般建议：

- 任务节点数量 = EMR 集群中的核心节点数
- 每个节点的任务槽数 = 并行度 / 任务节点数量
