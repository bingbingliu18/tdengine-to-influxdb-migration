# TDengine 到 InfluxDB 并行数据迁移工具

基于 Apache Flink 的高性能 TDengine 到 InfluxDB 数据迁移解决方案。

## ✨ 主要特性

- **并行处理**：支持多个并行任务同时从 TDengine 读取数据
- **数据分区**：基于时间范围对数据进行分区处理
- **批处理优化**：优化的批处理大小和缓冲区设置
- **重试机制**：健壮的连接和查询重试逻辑
- **故障恢复**：内置检查点和状态管理
- **原生连接**：使用 TDengine 原生连接器获得最佳性能

## 🚀 快速开始

### 1. 环境准备
```bash
cd scripts
./setup_environment.sh
```

### 2. 安装 TDengine 客户端
```bash
./install_tdengine_client.sh <EMR集群ID> <SSH密钥文件>
```

### 3. 编译项目
```bash
mvn clean package
```

### 4. 运行迁移
```bash
./submit_native_direct_migration_offset.sh \
  --source-jdbc-url "jdbc:TAOS://tdengine-host:6030/database" \
  --source-username "root" \
  --source-password "taosdata" \
  --source-table "your_table" \
  --target-influx-url "http://influxdb-host:8086" \
  --target-token "your-token" \
  --target-org "your-org" \
  --target-bucket "your-bucket" \
  --target-measurement "your_measurement" \
  --cluster-id "j-XXXXXXXXXX" \
  --region "us-east-1" \
  --key-file "your-key.pem"
```

## 📋 脚本说明

| 脚本 | 功能 | 用途 |
|------|------|------|
| `setup_environment.sh` | 环境设置 | 自动安装和配置所需工具 |
| `install_tdengine_client.sh` | 客户端安装 | 在EMR集群安装TDengine客户端 |
| `submit_native_direct_migration_offset.sh` | 任务提交 | 提交数据迁移作业 |
| `get_latest_progress.sh` | 进度监控 | 获取迁移进度信息 |
| `tail_emr_logs.sh` | 日志监控 | 实时监控和保存日志 |

## ⚡ 性能调优

### 并行度设置
- 小数据集（< 1000万条）：`--parallelism 4`
- 中等数据集（1000万 - 1亿条）：`--parallelism 8`
- 大数据集（> 1亿条）：`--parallelism 16`

### 批处理大小
- 复杂数据（多列）：`--batch-size 1000`
- 简单数据（少列）：`--batch-size 5000`

## 📊 监控

### 实时监控
```bash
# 查看进度
./get_latest_progress.sh -c 集群ID -f 密钥文件 -a 应用ID

# 监控日志
./tail_emr_logs.sh -c 集群ID -f 密钥文件 -a 应用ID
```

### Flink Web UI
```bash
# 创建SSH隧道
ssh -i your-key.pem -L 8081:localhost:8081 hadoop@emr-master-dns

# 访问 http://localhost:8081
```

## 🔧 系统要求

- Java 11+
- Apache Maven 3.6+
- AWS EMR 6.x+
- AWS CLI（已配置）
- TDengine 3.0.5+
- InfluxDB 2.x

## 📁 项目结构

```
tdengine-to-influxdb-migration/
├── scripts/          # 脚本文件
├── src/             # 源代码
├── packages/        # 安装包
├── docs/           # 文档
└── pom.xml         # Maven配置
```

## 🚨 注意事项

1. SSH密钥文件需放在 `scripts` 目录中
2. 确保TDengine服务器能处理并行连接
3. 监控网络带宽使用情况
4. 根据数据量调整内存配置

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

---

**为高性能数据迁移而构建** ❤️
