# 安装指南

## 前提条件

1. 已创建并运行的 AWS EMR 集群
2. 可以访问 TDengine 和 InfluxDB 服务器
3. 已配置 AWS CLI
4. 有用于连接 EMR 集群的 SSH 密钥

## 安装步骤

### 1. 解压安装包

```bash
tar -xzvf tdengine-to-influxdb-migration.tar.gz
cd tdengine-to-influxdb-migration
```

### 2. 安装 TDengine 客户端

在 EMR 集群的所有节点上安装 TDengine 客户端：

```bash
cd scripts
chmod +x install_tdengine_client_improved.sh
./install_tdengine_client_improved.sh <EMR_CLUSTER_ID> <SSH_KEY_PATH>
```

参数说明：
- `<EMR_CLUSTER_ID>`: EMR 集群 ID，例如 "j-2AXXXXXXGAPLF"
- `<SSH_KEY_PATH>`: SSH 密钥文件路径，例如 "us-east-1.pem"

### 3. 编译项目

如果需要重新编译项目：

```bash
cd ..  # 回到项目根目录
mvn clean package
```

### 4. 运行数据迁移

使用 `submit_native_direct_migration_offset.sh` 脚本提交迁移作业：

```bash
cd scripts
chmod +x submit_native_direct_migration_offset.sh
./submit_native_direct_migration_offset.sh \
  --source-jdbc-url "jdbc:TAOS://your-tdengine-host:6030/your-database" \
  --source-username "root" \
  --source-password "taosdata" \
  --source-table "your_table" \
  --target-influx-url "http://your-influxdb-host:8086" \
  --target-token "your-influxdb-token" \
  --target-org "your-org" \
  --target-bucket "your-bucket" \
  --target-measurement "your_measurement" \
  --cluster-id "j-XXXXXXXXXX" \
  --region "us-east-1" \
  --key-file "your-key.pem" \
  --parallelism 8 \
  --batch-size 2000
```

注意：将 SSH 密钥文件放在 `keys` 目录中，或者提供完整路径。

## 参数说明

### TDengine 客户端安装脚本参数

- `<EMR_CLUSTER_ID>`: EMR 集群 ID
- `<SSH_KEY_PATH>`: SSH 密钥文件路径

### 数据迁移脚本参数

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
| `--parallelism` | 并行度 | 8 |
| `--batch-size` | 批处理大小 | 2000 |
| `--task-nodes` | 任务节点数量 | 8 |
| `--start-time` | 数据迁移开始时间（可选） | 2023-01-01 00:00:00.000 |
| `--end-time` | 数据迁移结束时间（可选） | 2023-12-31 23:59:59.999 |

## 验证安装

安装完成后，可以通过以下方式验证：

1. 检查 TDengine 客户端是否正确安装：
   ```bash
   ssh -i <SSH_KEY_PATH> hadoop@<EMR_MASTER_DNS> "ls -la /usr/local/taos/driver/"
   ```

2. 检查 Flink 作业是否正在运行：
   ```bash
   ssh -i <SSH_KEY_PATH> hadoop@<EMR_MASTER_DNS> "yarn application -list"
   ```

3. 访问 Flink Web UI 监控作业执行情况：
   ```bash
   ssh -i <SSH_KEY_PATH> -L 8081:localhost:8081 hadoop@<EMR_MASTER_DNS>
   ```
   然后在浏览器中访问 http://localhost:8081
