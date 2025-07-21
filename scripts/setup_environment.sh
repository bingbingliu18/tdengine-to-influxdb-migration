#!/bin/bash

# TDengine to InfluxDB Migration - Environment Setup Script
# This script checks and installs all necessary tools for the migration process

# Set strict error handling
set -e

# Display header
echo "=================================================="
echo "  TDengine to InfluxDB Migration - Environment Setup"
echo "=================================================="
echo "This script will check and install all necessary tools:"
echo "- AWS CLI"
echo "- Java"
echo "- Maven"
echo "=================================================="

# Function to check if a command exists
check_command() {
    if command -v $1 &> /dev/null; then
        echo "✅ $1 is already installed: $(command -v $1)"
        return 0
    else
        echo "❌ $1 is not installed"
        return 1
    fi
}

# Function to check AWS CLI configuration
check_aws_config() {
    echo "Checking AWS CLI configuration..."
    if aws sts get-caller-identity &> /dev/null; then
        echo "✅ AWS CLI is properly configured"
        aws sts get-caller-identity | grep "Account"
        return 0
    else
        echo "❌ AWS CLI is not properly configured"
        return 1
    fi
}

# Function to check Java version
check_java_version() {
    if check_command java; then
        JAVA_VERSION=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | sed 's/^1\.//' | cut -d'.' -f1)
        if [[ "$JAVA_VERSION" -lt 8 ]]; then
            echo "❌ Java 8 or higher is required. Current version: $JAVA_VERSION"
            return 1
        else
            echo "✅ Java version $JAVA_VERSION is compatible"
            return 0
        fi
    else
        return 1
    fi
}

# Function to install AWS CLI
install_aws_cli() {
    echo "Installing AWS CLI..."
    
    # Check if pip is installed
    if ! check_command pip && ! check_command pip3; then
        echo "Installing pip..."
        curl -s "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
        python3 get-pip.py --user
        rm get-pip.py
    fi
    
    # Install AWS CLI
    if command -v pip &> /dev/null; then
        pip install --user awscli
    else
        pip3 install --user awscli
    fi
    
    # Add to PATH if needed
    if ! command -v aws &> /dev/null; then
        echo 'export PATH=$PATH:$HOME/.local/bin' >> ~/.bashrc
        export PATH=$PATH:$HOME/.local/bin
    fi
    
    echo "AWS CLI installed. Please configure it with your credentials:"
    echo "aws configure"
}

# Function to install Java
install_java() {
    echo "Installing Java..."
    
    # Check the OS
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        sudo apt-get update
        sudo apt-get install -y openjdk-11-jdk
    elif [ -f /etc/redhat-release ]; then
        # RHEL/CentOS/Fedora
        sudo yum install -y java-11-openjdk-devel
    elif [ -f /etc/arch-release ]; then
        # Arch Linux
        sudo pacman -S jdk11-openjdk
    elif [ -f /etc/alpine-release ]; then
        # Alpine
        sudo apk add openjdk11
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        brew install openjdk@11
        echo "You may need to add Java to your PATH:"
        echo 'export PATH="/usr/local/opt/openjdk@11/bin:$PATH"'
    else
        echo "Unsupported OS. Please install Java 11 manually."
        return 1
    fi
    
    echo "Java installed successfully."
}

# Function to install Maven
install_maven() {
    echo "Installing Maven..."
    
    # Check the OS
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        sudo apt-get update
        sudo apt-get install -y maven
    elif [ -f /etc/redhat-release ]; then
        # RHEL/CentOS/Fedora
        sudo yum install -y maven
    elif [ -f /etc/arch-release ]; then
        # Arch Linux
        sudo pacman -S maven
    elif [ -f /etc/alpine-release ]; then
        # Alpine
        sudo apk add maven
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        brew install maven
    else
        echo "Unsupported OS. Please install Maven manually."
        return 1
    fi
    
    echo "Maven installed successfully."
}

# Main execution starts here

# Check AWS CLI
echo -e "\nChecking for AWS CLI..."
if ! check_command aws; then
    echo "Installing AWS CLI..."
    install_aws_cli
    if ! check_command aws; then
        echo "Failed to install AWS CLI. Please install manually."
        exit 1
    fi
fi

# Check AWS CLI configuration
if ! check_aws_config; then
    echo "Please configure AWS CLI with your credentials:"
    echo "aws configure"
    echo "Then run this script again."
    exit 1
fi

# Check Java
echo -e "\nChecking for Java..."
if ! check_java_version; then
    echo "Installing Java..."
    install_java
    if ! check_java_version; then
        echo "Failed to install Java. Please install Java 8 or higher manually."
        exit 1
    fi
fi

# Check Maven
echo -e "\nChecking for Maven..."
if ! check_command mvn; then
    echo "Installing Maven..."
    install_maven
    if ! check_command mvn; then
        echo "Failed to install Maven. Please install manually."
        exit 1
    fi
fi

# Final check
echo -e "\nFinal environment check:"
check_command aws
check_aws_config
check_java_version
check_command mvn

echo -e "\n=================================================="
echo "  Environment setup completed successfully!"
echo "=================================================="
echo "You can now run the following scripts:"
echo "1. install_tdengine_client_improved.sh - to install TDengine client"
echo "2. submit_native_direct_migration_offset.sh - to run the migration"
echo "=================================================="
