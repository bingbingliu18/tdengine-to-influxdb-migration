# TDengine to InfluxDB Parallel Data Migration Tool

A high-performance data migration solution from TDengine to InfluxDB using Apache Flink as the distributed processing framework.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Java](https://img.shields.io/badge/Java-11+-blue.svg)](https://www.oracle.com/java/)
[![Flink](https://img.shields.io/badge/Apache%20Flink-1.20.0-orange.svg)](https://flink.apache.org/)
[![TDengine](https://img.shields.io/badge/TDengine-3.0.5+-green.svg)](https://www.taosdata.com/)

## 🚀 Features

- **Parallel Processing**: Support multiple parallel tasks reading from TDengine simultaneously
- **Data Partitioning**: Time-based data partitioning with each parallel task handling specific time ranges
- **Optimized Batch Processing**: Tuned batch sizes and buffer settings for maximum throughput
- **Enhanced Retry Logic**: Robust retry mechanisms for connections and query operations
- **Resource Balancing**: Ensures balanced workload between read and write operations
- **Fault Recovery**: Built-in checkpointing and state management for job recovery
- **Native Connectivity**: Uses TDengine native connector for optimal performance

## 📁 Project Structure

```
tdengine-to-influxdb-migration/
├── scripts/                                    # Script files
│   ├── setup_environment.sh                   # Environment setup script
│   ├── install_tdengine_client.sh             # TDengine client installation
│   ├── submit_native_direct_migration_offset.sh # Main migration script
│   ├── get_latest_progress.sh                 # Progress monitoring script
│   └── tail_emr_logs.sh                       # Log monitoring script
├── src/                                        # Source code
│   └── main/java/com/example/migration/
│       ├── TDengineToInfluxDBNativeDirectMigration_OFFSET.java
│       └── ParallelTDengineNativeSourceFunctionWithDirectConnection_OFFSET.java
├── packages/                                   # Installation packages
│   └── TDengine-server-3.0.5.0-Linux-x64.tar.gz
├── docs/                                       # Documentation
│   ├── INSTALL.md                             # Installation guide
│   └── CONFIGURATION.md                       # Configuration parameters
├── pom.xml                                     # Maven project configuration
├── .gitignore                                  # Git ignore rules
└── README.md                                   # This file
```

## 🛠️ System Requirements

- **Java**: 11 or higher
- **Apache Maven**: 3.6 or higher
- **AWS EMR Cluster**: EMR 6.x or higher (recommended)
- **AWS CLI**: Properly configured
- **SSH Key**: For EMR cluster connection
- **TDengine**: 3.0.5 or higher
- **InfluxDB**: 2.x with token authentication

## 🚀 Quick Start

### 1. Environment Setup

First, set up your environment with all necessary tools:

```bash
cd scripts
chmod +x setup_environment.sh
./setup_environment.sh
```

This script will automatically:
- Check and install AWS CLI
- Check and install Java 11+
- Check and install Maven
- Verify AWS CLI configuration

### 2. Install TDengine Client

Install TDengine client on all EMR cluster nodes:

```bash
chmod +x install_tdengine_client.sh
./install_tdengine_client.sh <EMR_CLUSTER_ID> <SSH_KEY_FILE>
```

**Example:**
```bash
./install_tdengine_client.sh j-27CZGXO7U8NC3 us-east-1.pem
```

### 3. Build the Project

```bash
cd ..  # Go to project root
mvn clean package
```

### 4. Run Data Migration

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

## 📋 Script Reference

### 🔧 setup_environment.sh
**Purpose**: Automated environment setup and dependency installation

**Features**:
- Checks for AWS CLI, Java, and Maven
- Installs missing dependencies automatically
- Verifies AWS CLI configuration
- Cross-platform support (Ubuntu, CentOS, macOS)

**Usage**:
```bash
./setup_environment.sh
```

### 📦 install_tdengine_client.sh
**Purpose**: One-click TDengine client installation across EMR cluster

**Features**:
- Installs TDengine client on all cluster nodes
- Handles JDBC driver deployment
- Sets up environment variables
- Includes comprehensive error handling

**Usage**:
```bash
./install_tdengine_client.sh <EMR_CLUSTER_ID> <SSH_KEY_FILE>
```

### 🚀 submit_native_direct_migration_offset.sh
**Purpose**: Main migration job submission script

**Required Parameters**:
| Parameter | Description | Example |
|-----------|-------------|---------|
| `--source-jdbc-url` | TDengine JDBC URL | `jdbc:TAOS://host:6030/db` |
| `--source-username` | TDengine username | `root` |
| `--source-password` | TDengine password | `taosdata` |
| `--source-table` | Source table name | `sensor_data` |
| `--target-influx-url` | InfluxDB URL | `http://host:8086` |
| `--target-token` | InfluxDB token | `your-token` |
| `--target-org` | InfluxDB organization | `your-org` |
| `--target-bucket` | InfluxDB bucket | `your-bucket` |
| `--target-measurement` | Target measurement | `sensors` |
| `--cluster-id` | EMR cluster ID | `j-XXXXXXXXXX` |
| `--region` | AWS region | `us-east-1` |
| `--key-file` | SSH key file | `your-key.pem` |

### 📊 get_latest_progress.sh
**Purpose**: Monitor migration progress and retrieve latest status

**Usage**:
```bash
./get_latest_progress.sh \
  --cluster-id j-XXXXXXXXXX \
  --key-file your-key.pem \
  --app-id application_XXXXXXXXXX_XXXX
```

### 📝 tail_emr_logs.sh
**Purpose**: Continuous log monitoring and local file streaming

**Usage**:
```bash
./tail_emr_logs.sh \
  --cluster-id j-XXXXXXXXXX \
  --key-file your-key.pem \
  --app-id application_XXXXXXXXXX_XXXX \
  --output migration_logs.txt
```

## ⚡ Performance Optimization

### Parallelism Settings
- **Small datasets** (< 10M records): `--parallelism 4`
- **Medium datasets** (10M - 100M records): `--parallelism 8`
- **Large datasets** (> 100M records): `--parallelism 16`

### Batch Size Tuning
- **Complex data** (many columns): `--batch-size 1000`
- **Simple data** (few columns): `--batch-size 5000`

## 📊 Monitoring

### Real-time Monitoring
```bash
# Monitor progress
./get_latest_progress.sh -c j-CLUSTER-ID -f key.pem -a app-id

# Stream logs to file
./tail_emr_logs.sh -c j-CLUSTER-ID -f key.pem -a app-id -o logs.txt
```

### Flink Web UI
```bash
# Create SSH tunnel
ssh -i your-key.pem -L 8081:localhost:8081 hadoop@emr-master-dns

# Access UI at http://localhost:8081
```

## 🚨 Important Notes

1. **SSH Key Placement**: Place SSH key files in the `scripts` directory
2. **TDengine Capacity**: Ensure TDengine server can handle parallel connections
3. **Network Bandwidth**: Monitor network usage during migration
4. **Memory Configuration**: Adjust based on actual data volume

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

**Built with ❤️ for high-performance data migration**

> 📖 **中文文档**: [README_CN.md](README_CN.md)
