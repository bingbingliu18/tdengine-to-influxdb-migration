#!/bin/bash

# Script to submit TDengine to InfluxDB migration job with native connector, direct connections and OFFSET pagination
# This script uses direct database connections instead of a shared connection pool
# and LIMIT/OFFSET pagination instead of cursor-based pagination to prevent data loss

# Exit on error
set -e

# Set working directory
cd "$(dirname "$0")"

# Default values - reduced for better stability
DEFAULT_PARALLELISM=8
DEFAULT_BATCH_SIZE=2000
DEFAULT_TASK_NODES=8

# Parse command line arguments
function print_usage {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -s, --source-jdbc-url URL       Source TDengine JDBC URL (required)"
    echo "  -u, --source-username USER      Source TDengine username (required)"
    echo "  -p, --source-password PASS      Source TDengine password (required)"
    echo "  -t, --source-table TABLE        Source TDengine table name (required)"
    echo "  -i, --target-influx-url URL     Target InfluxDB URL (required)"
    echo "  -k, --target-token TOKEN        Target InfluxDB token (required)"
    echo "  -o, --target-org ORG            Target InfluxDB organization (required)"
    echo "  -b, --target-bucket BUCKET      Target InfluxDB bucket (required)"
    echo "  -m, --target-measurement MEAS   Target InfluxDB measurement name (required)"
    echo "  -c, --cluster-id ID             EMR cluster ID (required)"
    echo "  -r, --region REGION             AWS region (required)"
    echo "  -f, --key-file FILE             SSH key file (required, place in the script directory)"
    echo "  -n, --parallelism NUM           Parallelism level (default: $DEFAULT_PARALLELISM)"
    echo "  -z, --batch-size SIZE           Batch size (default: $DEFAULT_BATCH_SIZE)"
    echo "  --task-nodes NUM                Number of task nodes (default: $DEFAULT_TASK_NODES)"
    echo "  --start-time TIME               Start time for data migration (optional, format: yyyy-MM-dd HH:mm:ss.SSS)"
    echo "  --end-time TIME                 End time for data migration (optional, format: yyyy-MM-dd HH:mm:ss.SSS)"
    echo "  -h, --help                      Show this help message"
    exit 1
}

# Set variables
JAR_NAME="flink-test-1.0-SNAPSHOT.jar"
MAIN_CLASS="com.example.migration.TDengineToInfluxDBNativeDirectMigration_OFFSET"
PARALLELISM=$DEFAULT_PARALLELISM
BATCH_SIZE=$DEFAULT_BATCH_SIZE
TASK_NODES=$DEFAULT_TASK_NODES
START_TIME=""
END_TIME=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -s|--source-jdbc-url)
            SOURCE_JDBC_URL="$2"
            shift 2
            ;;
        -u|--source-username)
            SOURCE_USERNAME="$2"
            shift 2
            ;;
        -p|--source-password)
            SOURCE_PASSWORD="$2"
            shift 2
            ;;
        -t|--source-table)
            SOURCE_TABLE="$2"
            shift 2
            ;;
        -i|--target-influx-url)
            TARGET_INFLUX_URL="$2"
            shift 2
            ;;
        -k|--target-token)
            TARGET_TOKEN="$2"
            shift 2
            ;;
        -o|--target-org)
            TARGET_ORG="$2"
            shift 2
            ;;
        -b|--target-bucket)
            TARGET_BUCKET="$2"
            shift 2
            ;;
        -m|--target-measurement)
            TARGET_MEASUREMENT="$2"
            shift 2
            ;;
        -c|--cluster-id)
            EMR_CLUSTER_ID="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -f|--key-file)
            KEY_FILE="$2"
            shift 2
            ;;
        -n|--parallelism)
            PARALLELISM="$2"
            shift 2
            ;;
        -z|--batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --task-nodes)
            TASK_NODES="$2"
            shift 2
            ;;
        --start-time)
            START_TIME="$2"
            shift 2
            ;;
        --end-time)
            END_TIME="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            ;;
    esac
done

# Check required parameters
echo "Checking required parameters..."
echo "SOURCE_JDBC_URL: ${SOURCE_JDBC_URL:-(not set)}"
echo "SOURCE_USERNAME: ${SOURCE_USERNAME:-(not set)}"
echo "SOURCE_PASSWORD: ${SOURCE_PASSWORD:-(not set)}"
echo "SOURCE_TABLE: ${SOURCE_TABLE:-(not set)}"
echo "TARGET_INFLUX_URL: ${TARGET_INFLUX_URL:-(not set)}"
echo "TARGET_TOKEN: ${TARGET_TOKEN:-(not set)}"
echo "TARGET_ORG: ${TARGET_ORG:-(not set)}"
echo "TARGET_BUCKET: ${TARGET_BUCKET:-(not set)}"
echo "TARGET_MEASUREMENT: ${TARGET_MEASUREMENT:-(not set)}"
echo "EMR_CLUSTER_ID: ${EMR_CLUSTER_ID:-(not set)}"
echo "REGION: ${REGION:-(not set)}"
echo "KEY_FILE: ${KEY_FILE:-(not set)}"

if [ -z "$SOURCE_JDBC_URL" ] || [ -z "$SOURCE_USERNAME" ] || [ -z "$SOURCE_PASSWORD" ] || [ -z "$SOURCE_TABLE" ] || \
   [ -z "$TARGET_INFLUX_URL" ] || [ -z "$TARGET_TOKEN" ] || [ -z "$TARGET_ORG" ] || [ -z "$TARGET_BUCKET" ] || \
   [ -z "$TARGET_MEASUREMENT" ] || [ -z "$EMR_CLUSTER_ID" ] || [ -z "$REGION" ] || [ -z "$KEY_FILE" ]; then
    echo "Error: Missing required parameters."
    print_usage
fi

echo "Building the Flink native direct connection migration application with OFFSET pagination for EMR cluster $EMR_CLUSTER_ID..."
cd ..  # Go to project root directory
mvn clean package

if [ $? -ne 0 ]; then
    echo "Build failed. Exiting."
    exit 1
fi

cd scripts  # Go back to scripts directory

# Get the script directory absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Assume the key file is in the same directory as the script
SSH_KEY_PATH="${SCRIPT_DIR}/${KEY_FILE}"
echo "Using SSH key: $SSH_KEY_PATH"

# Check if the key file exists
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Error: SSH key file $SSH_KEY_PATH does not exist!"
    echo "Please copy your key file to the script directory."
    exit 1
fi

# Get the EMR master node hostname
echo "Retrieving master node hostname for cluster $EMR_CLUSTER_ID in region $REGION..."
EMR_MASTER_DNS=$(aws emr describe-cluster --cluster-id $EMR_CLUSTER_ID --region $REGION --query 'Cluster.MasterPublicDnsName' --output text)

if [ -z "$EMR_MASTER_DNS" ]; then
    echo "Error: Could not retrieve master node hostname. Please check if the cluster is running."
    exit 1
fi

echo "Master node hostname: $EMR_MASTER_DNS"

# Make sure the SSH key file has the right permissions
chmod 400 $SSH_KEY_PATH

echo "Copying JAR to EMR master node..."
scp -i $SSH_KEY_PATH -o StrictHostKeyChecking=no ../target/$JAR_NAME hadoop@$EMR_MASTER_DNS:~/$JAR_NAME

if [ $? -ne 0 ]; then
    echo "Failed to copy JAR to EMR master node. Exiting."
    exit 1
fi

echo "Submitting Flink job to EMR cluster $EMR_CLUSTER_ID using YARN application mode..."
ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no hadoop@$EMR_MASTER_DNS << EOF
    # Set up environment
    export HADOOP_CLASSPATH=\$(hadoop classpath)
    
    # Set up TDengine native library path
    export LD_LIBRARY_PATH=/usr/local/taos/driver:/usr/lib:\$LD_LIBRARY_PATH
    
    # Create HDFS directory for checkpoints if it doesn't exist
    hadoop fs -mkdir -p /flink-checkpoints
    
    # Submit the Flink job using YARN application mode with optimized configuration
    # No explicit memory settings to let YARN handle resource allocation
    MASTER_HOSTNAME=\$(hostname -f)
    echo "Setting JobManager to run on master node: \$MASTER_HOSTNAME"
    
    # Calculate taskmanager.numberOfTaskSlots based on parallelism/task-nodes
    TASK_SLOTS=\$(( $PARALLELISM / $TASK_NODES ))
    # Ensure at least 1 slot per task manager
    if [ \$TASK_SLOTS -lt 1 ]; then
        TASK_SLOTS=1
    fi
    echo "Calculated task slots per task manager: \$TASK_SLOTS (Parallelism: $PARALLELISM, Task Nodes: $TASK_NODES)"
    
    flink run-application -t yarn-application \
        -c $MAIN_CLASS \
        -Dyarn.application.name="TDengine to InfluxDB Native Direct Connection Migration with OFFSET - $SOURCE_TABLE to $TARGET_MEASUREMENT" \
        -Dtaskmanager.numberOfTaskSlots=\$TASK_SLOTS \
        -Dparallelism.default=$PARALLELISM \
        -Dtaskmanager.memory.process.size=8192mb \
        -Djobmanager.memory.process.size=2048mb \
        -Dstate.backend.incremental=true \
        -Dstate.checkpoints.dir=hdfs:///flink-checkpoints \
        -Dexecution.checkpointing.interval=30000 \
        -Dexecution.checkpointing.mode=EXACTLY_ONCE \
        -Dexecution.checkpointing.timeout=120000 \
        ~/$JAR_NAME \
        "$SOURCE_JDBC_URL" \
        "$SOURCE_USERNAME" \
        "$SOURCE_PASSWORD" \
        "$SOURCE_TABLE" \
        "$TARGET_INFLUX_URL" \
        "$TARGET_TOKEN" \
        "$TARGET_ORG" \
        "$TARGET_BUCKET" \
        "$TARGET_MEASUREMENT" \
        "$PARALLELISM" \
        "$BATCH_SIZE" \
        "$START_TIME" \
        "$END_TIME"
EOF

if [ $? -ne 0 ]; then
    echo "Failed to submit job to EMR. Exiting."
    exit 1
fi

echo "Job submitted successfully to EMR cluster $EMR_CLUSTER_ID in region $REGION!"
echo "Migration details:"
echo "  Source: $SOURCE_TABLE"
echo "  Target: $TARGET_MEASUREMENT"
echo "  Parallelism: $PARALLELISM"
echo "  Batch Size: $BATCH_SIZE"
echo "  Task Nodes: $TASK_NODES"
echo "  Task Slots per Node: $(( $PARALLELISM / $TASK_NODES ))"
if [ ! -z "$START_TIME" ]; then
    echo "  Start Time: $START_TIME"
fi
if [ ! -z "$END_TIME" ]; then
    echo "  End Time: $END_TIME"
fi
echo ""
echo "Check EMR console for status or use the following command to check YARN applications:"
echo "ssh -i $SSH_KEY_PATH hadoop@$EMR_MASTER_DNS 'yarn application -list'"
echo ""
echo "To monitor the Flink job, create an SSH tunnel and access the Flink Web UI:"
echo "ssh -i $SSH_KEY_PATH -L 8081:localhost:8081 hadoop@$EMR_MASTER_DNS"
echo "Then open http://localhost:8081 in your browser"
