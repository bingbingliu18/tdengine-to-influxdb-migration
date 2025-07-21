#!/bin/bash

# Script to continuously tail EMR job logs to a local file
# This script connects to the EMR cluster and streams logs to a local file

# Get the script directory absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print usage
function print_usage {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -c, --cluster-id ID       EMR cluster ID (required)"
    echo "  -f, --key-file FILE       SSH key file (required, place in the script directory)"
    echo "  -a, --app-id ID           Yarn application ID (required)"
    echo "  -o, --output FILE         Local output log file (default: emr_migration_logs.txt)"
    echo "  -i, --interval SEC        Polling interval in seconds (default: 10)"
    echo "  -r, --region REGION       AWS region (default: us-east-1)"
    echo "  -p, --pattern STRING      Log pattern to filter (default: 'Processed')"
    echo "  -h, --help                Show this help message"
    exit 1
}

# Parse command line arguments
EMR_CLUSTER_ID=""
KEY_FILE=""
APP_ID=""
OUTPUT_FILE="emr_migration_logs.txt"
INTERVAL=10
REGION="us-east-1"
PATTERN="Processed"

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
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -p|--pattern)
            PATTERN="$2"
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

# Initialize the log file with a header
echo "=== TDengine to InfluxDB Migration Logs ===" > "$OUTPUT_FILE"
echo "EMR Cluster: $EMR_CLUSTER_ID" >> "$OUTPUT_FILE"
echo "Application: $APP_ID" >> "$OUTPUT_FILE"
echo "Started at: $(date)" >> "$OUTPUT_FILE"
echo "Filtering for: '$PATTERN'" >> "$OUTPUT_FILE"
echo "=======================================" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Function to get the latest logs
function get_latest_logs {
    # Get the latest logs from EMR
    ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no hadoop@$EMR_MASTER_DNS "yarn logs -applicationId $APP_ID -log_files taskmanager.err --size_limit_mb -1 | grep '$PATTERN' | tail -100"
}

# Get initial logs
echo "Fetching initial logs..."
get_latest_logs >> "$OUTPUT_FILE"

# Track the last line number to avoid duplicates
LAST_LINE_COUNT=$(wc -l < "$OUTPUT_FILE")

echo "Starting continuous log monitoring. Press Ctrl+C to stop."
echo "Logs are being saved to: $OUTPUT_FILE"
echo "Polling every $INTERVAL seconds..."

# Continuously poll for new logs
while true; do
    # Wait for the specified interval
    sleep $INTERVAL
    
    # Get the latest logs
    get_latest_logs > temp_logs.txt
    
    # Check if there are new logs
    if [ -s temp_logs.txt ]; then
        # Append timestamp
        echo -e "\n--- Update at $(date) ---" >> "$OUTPUT_FILE"
        
        # Append new logs
        cat temp_logs.txt >> "$OUTPUT_FILE"
        
        # Print the last few lines to the console
        echo "New logs received at $(date):"
        tail -5 temp_logs.txt
    fi
    
    # Clean up
    rm -f temp_logs.txt
    
    # Check if the application is still running
    APP_STATUS=$(ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no hadoop@$EMR_MASTER_DNS "yarn application -status $APP_ID 2>/dev/null | grep 'State :' | awk '{print \$3}'")
    
    if [ "$APP_STATUS" != "RUNNING" ] && [ -n "$APP_STATUS" ]; then
        echo "Application is no longer running. Final state: $APP_STATUS"
        echo -e "\n--- Application finished at $(date) with state: $APP_STATUS ---" >> "$OUTPUT_FILE"
        break
    fi
done

echo "Log monitoring completed. All logs saved to: $OUTPUT_FILE"
