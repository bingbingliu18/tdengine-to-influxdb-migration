#!/bin/bash

# TDengine Client One-Click Installation Script (Fixed Version 3)
# This script will install the TDengine client on all nodes of an EMR cluster
# Modified to use local JDBC driver from packages directory
# Added improved error handling and permission fixes for JDBC driver transfer

# Check if required parameters are provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 <EMR_CLUSTER_ID> <KEY_FILE>"
    echo "Example: $0 j-27CZGXO7U8NC3 us-east-1.pem"
    echo "Note: KEY_FILE should be placed in the scripts directory"
    exit 1
fi

# Get parameters from command line arguments
EMR_CLUSTER_ID="$1"
KEY_FILE="$2"

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

# Define package directory relative to script directory
PACKAGES_DIR="../packages"
if [ ! -d "$PACKAGES_DIR" ]; then
    echo "Warning: Packages directory $PACKAGES_DIR does not exist!"
    echo "Creating packages directory..."
    mkdir -p "$PACKAGES_DIR"
fi

TDENGINE_PACKAGE="${PACKAGES_DIR}/TDengine-server-3.0.5.0-Linux-x64.tar.gz"
JDBC_DRIVER="${PACKAGES_DIR}/taos-jdbcdriver-3.0.0-dist.jar"

# Check if JDBC driver exists
if [ ! -f "$JDBC_DRIVER" ]; then
    echo "Warning: JDBC driver not found at $JDBC_DRIVER"
    echo "Please place the JDBC driver in the packages directory."
    echo "Continuing installation without JDBC driver..."
else
    echo "Found JDBC driver at $JDBC_DRIVER"
fi

# Get EMR master node hostname using AWS CLI
echo "Retrieving EMR master node hostname using AWS CLI..."
EMR_MASTER=$(aws emr describe-cluster --cluster-id "$EMR_CLUSTER_ID" --query 'Cluster.MasterPublicDnsName' --output text)

# Fix for the test condition
if [ -z "$EMR_MASTER" ] || [ "$EMR_MASTER" = "None" ]; then
    echo "Error: Could not retrieve EMR master node hostname for cluster ID: $EMR_CLUSTER_ID"
    echo "Please check if the cluster ID is correct and if you have proper AWS CLI configuration."
    exit 1
fi

echo "EMR master node hostname: $EMR_MASTER"

# Display header
echo "=================================================="
echo "  TDengine Client One-Click Installation to EMR Cluster (Fixed Version 3)"
echo "=================================================="
echo "EMR Cluster ID: $EMR_CLUSTER_ID"
echo "Master Node: $EMR_MASTER"
echo "SSH Key: $SSH_KEY_PATH"
echo "TDengine Package: $TDENGINE_PACKAGE"
echo "JDBC Driver: $JDBC_DRIVER"
echo "=================================================="

# Check if TDengine package exists
if [ ! -f "$TDENGINE_PACKAGE" ]; then
    echo "Error: TDengine package $TDENGINE_PACKAGE does not exist!"
    echo "Checking if package exists in current directory..."
    
    if [ -f "TDengine-server-3.0.5.0-Linux-x64.tar.gz" ]; then
        echo "Found TDengine package in current directory, using it."
        TDENGINE_PACKAGE="TDengine-server-3.0.5.0-Linux-x64.tar.gz"
    else
        echo "Downloading TDengine package..."
        wget -O TDengine-server-3.0.5.0-Linux-x64.tar.gz https://www.taosdata.com/assets-download/3.0/TDengine-server-3.0.5.0-Linux-x64.tar.gz
        if [ $? -ne 0 ]; then
            echo "Failed to download TDengine package!"
            exit 1
        fi
        TDENGINE_PACKAGE="TDengine-server-3.0.5.0-Linux-x64.tar.gz"
    fi
fi

# Create installation script
echo "Creating TDengine client installation script..."
cat > install_tdengine_client.sh << 'EOF'
#!/bin/bash

# Set up logging
exec > >(tee /tmp/tdengine_install.log) 2>&1
echo "Starting TDengine client installation..."

# Check Java environment
if ! command -v java &> /dev/null; then
    echo "Warning: Java not found. JDBC connections may not work."
else
    echo "Java found: $(java -version 2>&1 | head -1)"
fi

# Extract TDengine package
echo "Extracting TDengine package..."
cd /tmp
tar -zxf TDengine-server-3.0.5.0-Linux-x64.tar.gz
cd TDengine-server-3.0.5.0

# Try to install client only
echo "Attempting standard client installation..."
./install.sh -v client -e no || echo "Standard client installation failed, proceeding with manual installation"

# Manual installation regardless of previous step result
echo "Performing manual installation of client libraries..."

# Create directories if they don't exist
sudo mkdir -p /usr/local/taos/driver
sudo mkdir -p /usr/local/taos/include
sudo mkdir -p /usr/local/taos/connector

# Copy driver files
echo "Copying driver files..."
sudo cp -f driver/libtaos.* /usr/local/taos/driver/ || echo "Warning: Could not copy driver files to /usr/local/taos/driver/"
sudo cp -f driver/libtaos.* /usr/lib/ || echo "Warning: Could not copy driver files to /usr/lib/"

# Check if we have a local JDBC driver in home directory
if [ -f "$HOME/taos-jdbcdriver.jar" ]; then
    echo "Using provided JDBC driver from home directory"
    sudo cp -f "$HOME/taos-jdbcdriver.jar" /usr/local/taos/connector/
# Check if we have a local JDBC driver in /tmp
elif [ -f "/tmp/taos-jdbcdriver.jar" ]; then
    echo "Using provided JDBC driver from /tmp"
    sudo cp -f /tmp/taos-jdbcdriver.jar /usr/local/taos/connector/
else
    # Extract JDBC driver from the package if available
    echo "Looking for JDBC driver in the package..."
    JDBC_DRIVER_PATH=$(find . -name "taos-jdbcdriver*.jar" | head -1)

    if [ -n "$JDBC_DRIVER_PATH" ]; then
        echo "Found JDBC driver in package: $JDBC_DRIVER_PATH"
        sudo cp -f "$JDBC_DRIVER_PATH" /usr/local/taos/connector/
    else
        echo "JDBC driver not found in package, trying to download from Maven Central..."
        # Try to download from Maven Central as an alternative - using version 3.2.4 which is available
        cd /tmp
        wget -O taos-jdbcdriver.jar https://repo1.maven.org/maven2/com/taosdata/jdbc/taos-jdbcdriver/3.2.4/taos-jdbcdriver-3.2.4.jar
        
        if [ $? -ne 0 ]; then
            echo "Failed to download JDBC driver from Maven Central, trying GitHub..."
            # Try GitHub as another alternative
            wget -O taos-jdbcdriver.jar https://github.com/taosdata/taos-connector-jdbc/releases/download/v3.2.4/taos-jdbcdriver-3.2.4-dist.jar
            
            if [ $? -ne 0 ]; then
                echo "Failed to download from GitHub, trying another Maven path..."
                wget -O taos-jdbcdriver.jar https://repo1.maven.org/maven2/com/taosdata/jdbc/taos-jdbcdriver/3.0.0/taos-jdbcdriver-3.0.0-dist.jar
                
                if [ $? -ne 0 ]; then
                    echo "Warning: Could not download JDBC driver from any source!"
                else
                    echo "Successfully downloaded JDBC driver from Maven Central"
                    sudo cp -f /tmp/taos-jdbcdriver.jar /usr/local/taos/connector/
                fi
            else
                echo "Successfully downloaded JDBC driver from GitHub"
                sudo cp -f /tmp/taos-jdbcdriver.jar /usr/local/taos/connector/
            fi
        else
            echo "Successfully downloaded JDBC driver from Maven Central"
            sudo cp -f /tmp/taos-jdbcdriver.jar /usr/local/taos/connector/
        fi
    fi
fi

# Download FastJSON
echo "Downloading FastJSON..."
cd /tmp
wget -O fastjson-1.2.83.jar https://repo1.maven.org/maven2/com/alibaba/fastjson/1.2.83/fastjson-1.2.83.jar

if [ $? -ne 0 ]; then
    echo "Warning: Could not download FastJSON, trying alternative version..."
    wget -O fastjson-1.2.83.jar https://repo1.maven.org/maven2/com/alibaba/fastjson/1.2.80/fastjson-1.2.80.jar
    
    if [ $? -ne 0 ]; then
        echo "Warning: Could not download FastJSON from any source!"
    else
        echo "Successfully downloaded alternative FastJSON version"
        sudo cp -f /tmp/fastjson-1.2.83.jar /usr/local/taos/connector/
    fi
else
    echo "Successfully downloaded FastJSON"
    sudo cp -f /tmp/fastjson-1.2.83.jar /usr/local/taos/connector/
fi

# Set up environment variables
echo "Setting up environment variables..."
sudo bash -c 'cat > /etc/profile.d/taos.sh << EOL
export LD_LIBRARY_PATH=/usr/local/taos/driver:/usr/lib:\$LD_LIBRARY_PATH
export CLASSPATH=/usr/local/taos/connector/*:\$CLASSPATH
EOL'
sudo chmod +x /etc/profile.d/taos.sh
source /etc/profile.d/taos.sh

# Update library cache
echo "Updating library cache..."
sudo ldconfig

# Verify installation
echo "Verifying installation..."
if [ -f "/usr/local/taos/driver/libtaos.so.3.0.5.0" ] || [ -f "/usr/lib/libtaos.so.3.0.5.0" ]; then
    echo "TDengine client libraries installed successfully!"
    echo "Library locations:"
    ls -la /usr/local/taos/driver/libtaos.so* 2>/dev/null || echo "Not found in /usr/local/taos/driver/"
    ls -la /usr/lib/libtaos.so* 2>/dev/null || echo "Not found in /usr/lib/"
    
    echo "JDBC driver location:"
    ls -la /usr/local/taos/connector/taos-jdbcdriver*.jar 2>/dev/null || echo "JDBC driver not found!"
    
    echo "FastJSON location:"
    ls -la /usr/local/taos/connector/fastjson*.jar 2>/dev/null || echo "FastJSON not found!"
    
    echo "Environment variables:"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    echo "CLASSPATH=$CLASSPATH"
    
    echo "Installation completed successfully."
    exit 0
else
    echo "TDengine client installation failed! Libraries not found."
    echo "Checking if libraries exist in the package:"
    find . -name "libtaos*"
    exit 1
fi
EOF

chmod +x install_tdengine_client.sh

# Step 1: Copy TDengine package and installation script to EMR master node
echo "Step 1: Copying TDengine package and installation script to EMR master node..."
scp -i "$SSH_KEY_PATH" "$TDENGINE_PACKAGE" hadoop@"$EMR_MASTER":/tmp/

# Copy JDBC driver if it exists - using home directory to avoid permission issues
if [ -f "$JDBC_DRIVER" ]; then
    echo "Copying JDBC driver to EMR master node..."
    # First try to copy to user's home directory which should have proper permissions
    scp -i "$SSH_KEY_PATH" "$JDBC_DRIVER" hadoop@"$EMR_MASTER":~/taos-jdbcdriver.jar
    
    if [ $? -eq 0 ]; then
        echo "JDBC driver successfully copied to EMR master node home directory"
        # Also try to copy to /tmp with proper permissions if needed by installation script
        ssh -i "$SSH_KEY_PATH" hadoop@"$EMR_MASTER" "sudo rm -f /tmp/taos-jdbcdriver.jar 2>/dev/null; sudo cp ~/taos-jdbcdriver.jar /tmp/ 2>/dev/null; sudo chmod 644 /tmp/taos-jdbcdriver.jar 2>/dev/null || echo 'Note: Could not copy to /tmp, will use home directory version'"
    else
        echo "Warning: Failed to copy JDBC driver to EMR master node"
        echo "Installation will attempt to download JDBC driver from alternative sources"
    fi
fi

scp -i "$SSH_KEY_PATH" install_tdengine_client.sh hadoop@"$EMR_MASTER":/tmp/
ssh -i "$SSH_KEY_PATH" hadoop@"$EMR_MASTER" "chmod +x /tmp/install_tdengine_client.sh"

# Step 2: Install TDengine client on master node
echo "Step 2: Installing TDengine client on master node..."
ssh -i "$SSH_KEY_PATH" hadoop@"$EMR_MASTER" "sudo /tmp/install_tdengine_client.sh"

# Step 3: Copy SSH key to master node if it doesn't exist there
echo "Step 3: Ensuring SSH key is available on master node..."
ssh -i "$SSH_KEY_PATH" hadoop@"$EMR_MASTER" "mkdir -p ~/.ssh"
scp -i "$SSH_KEY_PATH" "$SSH_KEY_PATH" hadoop@"$EMR_MASTER":~/.ssh/
ssh -i "$SSH_KEY_PATH" hadoop@"$EMR_MASTER" "chmod 600 ~/.ssh/$(basename "$SSH_KEY_PATH")"

# Step 4: Install TDengine client on all worker nodes
echo "Step 4: Installing TDengine client on all worker nodes..."
ssh -i "$SSH_KEY_PATH" hadoop@"$EMR_MASTER" << EOF
#!/bin/bash
# Get all worker nodes
echo "Getting worker node list..."
NODES=\$(yarn node -list | grep RUNNING | awk '{print \$1}' | cut -d ":" -f1)
NODE_COUNT=\$(echo "\$NODES" | wc -l)
echo "Found \$NODE_COUNT worker nodes"

# Install on all worker nodes
echo "Installing TDengine client on worker nodes..."
COUNTER=0
for node in \$NODES; do
  COUNTER=\$((COUNTER+1))
  echo "[\$COUNTER/\$NODE_COUNT] Installing on node \$node..."
  
  # Add host key to known_hosts to avoid verification prompt
  ssh-keyscan -H \$node >> ~/.ssh/known_hosts 2>/dev/null
  
  # Copy files to worker node
  scp -i ~/.ssh/$(basename "$SSH_KEY_PATH") -o StrictHostKeyChecking=no /tmp/TDengine-server-3.0.5.0-Linux-x64.tar.gz hadoop@\$node:/tmp/
  
  # Copy JDBC driver if it exists - first to home directory to avoid permission issues
  if [ -f "\$HOME/taos-jdbcdriver.jar" ]; then
    echo "Copying JDBC driver to worker node \$node..."
    scp -i ~/.ssh/$(basename "$SSH_KEY_PATH") -o StrictHostKeyChecking=no \$HOME/taos-jdbcdriver.jar hadoop@\$node:\$HOME/
    
    # Also try to copy to /tmp with proper permissions
    ssh -i ~/.ssh/$(basename "$SSH_KEY_PATH") -o StrictHostKeyChecking=no hadoop@\$node "sudo rm -f /tmp/taos-jdbcdriver.jar 2>/dev/null; sudo cp \$HOME/taos-jdbcdriver.jar /tmp/ 2>/dev/null; sudo chmod 644 /tmp/taos-jdbcdriver.jar 2>/dev/null || echo 'Note: Could not copy to /tmp, will use home directory version'"
  fi
  
  scp -i ~/.ssh/$(basename "$SSH_KEY_PATH") -o StrictHostKeyChecking=no /tmp/install_tdengine_client.sh hadoop@\$node:/tmp/
  
  # Execute installation script on worker node
  ssh -i ~/.ssh/$(basename "$SSH_KEY_PATH") -o StrictHostKeyChecking=no hadoop@\$node "chmod +x /tmp/install_tdengine_client.sh && sudo /tmp/install_tdengine_client.sh"
done

echo "TDengine client installation completed on all nodes!"
EOF

# Clean up temporary files
rm -f install_tdengine_client.sh

echo "=================================================="
echo "  TDengine Client Installation Completed!"
echo "=================================================="
echo "You can now run the submit_parallel_migration.sh script to start the data migration job."
echo "=================================================="
