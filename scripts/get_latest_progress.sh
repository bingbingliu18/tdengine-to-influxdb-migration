#!/bin/bash

# Script to get the latest migration progress
# This script connects to the EMR cluster and retrieves the latest progress information

# Get the script directory absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print usage
function print_usage {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -c, --cluster-id ID       EMR cluster ID (required)"
    echo "  -f, --key-file FILE       SSH key file (required, place in the script directory)"
    echo "  -a, --app-id ID           Yarn application ID (required)"
    echo "  -r, --region REGION       AWS region (default: us-east-1)"
    echo "  -l, --lines NUM           Number of log lines to show (default: 100)"
    echo "  -h, --help                Show this help message"
    exit 1
}

# Parse command line arguments
EMR_CLUSTER_ID=""
KEY_FILE=""
APP_ID=""
REGION="us-east-1"
LOG_LINES=100

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -c|--cluster-id)
            EMR_CLUSTER_ID="$2"
            shift 2
            ;;
        -f|--key-file)
            KEY_FILE="$2"
            shift 2
            ;;
        -a|--app-id)
            APP_ID="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -l|--lines)
            LOG_LINES="$2"
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
if [ -z "$EMR_CLUSTER_ID" ] || [ -z "$KEY_FILE" ] || [ -z "$APP_ID" ]; then
    echo "Error: Missing required parameters."
    print_usage
fi

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

if [ -z "$EMR_MASTER_DNS" ] || [ "$EMR_MASTER_DNS" == "None" ]; then
    echo "Error: Could not retrieve master node hostname. Please check if the cluster is running."
    exit 1
fi

echo "Master node hostname: $EMR_MASTER_DNS"

# Make sure the key file has the right permissions
chmod 400 $SSH_KEY_PATH

echo "Fetching latest progress information (last $LOG_LINES lines)..."
ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no hadoop@$EMR_MASTER_DNS "yarn logs -applicationId $APP_ID -log_files taskmanager.err --size_limit_mb -1 | grep 'Processed' | tail -$LOG_LINES"

echo ""
echo "Fetching any recent errors or warnings..."
ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no hadoop@$EMR_MASTER_DNS "yarn logs -applicationId $APP_ID -log_files taskmanager.err --size_limit_mb -1 | grep -i 'error\|warn\|exception' | tail -20"
