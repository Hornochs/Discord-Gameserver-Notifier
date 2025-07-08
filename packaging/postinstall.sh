#!/bin/bash
#
# Post-installation script for Discord Gameserver Notifier
# This script is executed after package installation (.deb/.rpm)
#

set -e

# Configuration directory and file paths (can be overridden for testing)
CONFIG_DIR="${CONFIG_DIR:-/etc/dgn}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.yaml}"
EXAMPLE_CONFIG="${EXAMPLE_CONFIG:-/usr/lib/python3/dist-packages/config/config.yaml.example}"

# Alternative paths for different Python installations
EXAMPLE_CONFIG_ALT1="/usr/local/lib/python3.*/dist-packages/config/config.yaml.example"
EXAMPLE_CONFIG_ALT2="/usr/lib/python*/dist-packages/config/config.yaml.example"
SERVICE_EXAMPLE_CONFIG="/usr/lib/python3/dist-packages/config/config.yaml.service-example"

# Virtual environment setup
VENV_DIR="/opt/discord-gameserver-notifier"
WHEEL_DIR="/usr/lib/python3/dist-packages"

echo "Discord Gameserver Notifier: Post-installation setup..."

# Ensure configuration directory exists (should be created by preinstall.sh)
if [ ! -d "$CONFIG_DIR" ]; then
    echo "Warning: Configuration directory $CONFIG_DIR does not exist (should be created by preinstall.sh)"
    mkdir -p "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
else
    echo "Configuration directory found: $CONFIG_DIR"
fi

# Create virtual environment
echo "Creating virtual environment at $VENV_DIR..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    chown -R root:root "$VENV_DIR"
    chmod -R 755 "$VENV_DIR"
    echo "Virtual environment created successfully"
else
    echo "Virtual environment already exists"
fi

# Install wheel package into venv
echo "Installing Discord Gameserver Notifier into virtual environment..."
if [ -d "$WHEEL_DIR/discord_gameserver_notifier" ]; then
    # Install the package from the copied wheel contents
    "$VENV_DIR/bin/pip" install --no-deps "$WHEEL_DIR"/../discord_gameserver_notifier*.whl 2>/dev/null || {
        # Fallback: Create a local installable package
        echo "Creating local package installation..."
        TEMP_PKG_DIR=$(mktemp -d)
        cp -r "$WHEEL_DIR/discord_gameserver_notifier" "$TEMP_PKG_DIR/"
        
        # Detect version from wheel filename
        WHEEL_VERSION=$(ls "$WHEEL_DIR"/../discord_gameserver_notifier*.whl 2>/dev/null | head -1 | sed -n 's/.*discord_gameserver_notifier-\([0-9.]*\)-.*/\1/p')
        if [ -z "$WHEEL_VERSION" ]; then
            WHEEL_VERSION="0.0.6"  # fallback
        fi
        
        # Create a minimal setup.py for local installation
        cat > "$TEMP_PKG_DIR/setup.py" << EOF
from setuptools import setup, find_packages

setup(
    name="Discord-Gameserver-Notifier",
    version="$WHEEL_VERSION",
    packages=find_packages(),
    install_requires=[
        "pyyaml>=6.0",
        "discord-webhook>=1.3.0", 
        "opengsq>=3.4.0"
    ],
    entry_points={
        'console_scripts': [
            'discord-gameserver-notifier-pkg=discord_gameserver_notifier.main:main',
        ],
    }
)
EOF
        
        # Install the package and its dependencies
        "$VENV_DIR/bin/pip" install "$TEMP_PKG_DIR"
        
        # Cleanup
        rm -rf "$TEMP_PKG_DIR"
    }
    echo "Package installed successfully into virtual environment"
else
    echo "Warning: Package files not found in expected location"
fi

# Verify installation
echo "Verifying installation..."
if "$VENV_DIR/bin/python" -c "import discord_gameserver_notifier.main" >/dev/null 2>&1; then
    echo "✅ Package verification successful"
else
    echo "❌ Package verification failed - trying to install dependencies manually"
    "$VENV_DIR/bin/pip" install pyyaml>=6.0 discord-webhook>=1.3.0 opengsq>=3.4.0
fi

# Copy example configuration if no config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No configuration file found at $CONFIG_FILE"
    
    # Try to find the example config in various locations
    FOUND_EXAMPLE=""
    
    # Prefer service-specific config for systemd deployments
    if [ -f "$SERVICE_EXAMPLE_CONFIG" ]; then
        FOUND_EXAMPLE="$SERVICE_EXAMPLE_CONFIG"
    elif [ -f "$EXAMPLE_CONFIG" ]; then
        FOUND_EXAMPLE="$EXAMPLE_CONFIG"
    else
        # Try alternative paths with globbing
        for pattern in $EXAMPLE_CONFIG_ALT1 $EXAMPLE_CONFIG_ALT2; do
            for file in $pattern; do
                if [ -f "$file" ]; then
                    FOUND_EXAMPLE="$file"
                    break 2
                fi
            done
        done
    fi
    
    if [ -n "$FOUND_EXAMPLE" ]; then
        echo "Copying example configuration from: $FOUND_EXAMPLE"
        cp "$FOUND_EXAMPLE" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        echo "Configuration file created: $CONFIG_FILE"
        echo ""
        echo "⚠️  IMPORTANT: Please edit $CONFIG_FILE to configure:"
        echo "   - Network scan ranges"
        echo "   - Discord webhook URL"
        echo "   - Game types to monitor"
        echo ""
    else
        echo "⚠️  Warning: Could not find example configuration file."
        echo "   Please create $CONFIG_FILE manually."
        echo "   You can find an example at:"
        echo "   https://github.com/lan-dot-party/Discord-Gameserver-Notifier/blob/main/config/config.yaml.example"
        echo ""
    fi
else
    echo "Configuration file already exists: $CONFIG_FILE"
    echo "Skipping configuration setup."
fi

# Set appropriate ownership (try to use a reasonable default)
if command -v chown >/dev/null 2>&1; then
    # Make config readable by all, writable by root
    chown root:root "$CONFIG_DIR" 2>/dev/null || true
    if [ -f "$CONFIG_FILE" ]; then
        chown root:root "$CONFIG_FILE" 2>/dev/null || true
    fi
fi

# Enable and start systemd service if systemctl is available
if command -v systemctl >/dev/null 2>&1; then
    echo "Configuring systemd service..."
    
    # Reload systemd daemon to pick up new service file
    systemctl daemon-reload 2>/dev/null || true
    
    # Enable the service to start on boot
    systemctl enable discord-gameserver-notifier.service 2>/dev/null || true
    
    echo "Service enabled to start on boot."
    echo "Note: Please configure $CONFIG_FILE before starting the service."
    echo ""
    echo "🚀 Quick Start:"
    echo "   1. Edit configuration: sudo nano $CONFIG_FILE"
    echo "   2. Start the service: sudo systemctl start discord-gameserver-notifier"
    echo "   3. Check status: sudo systemctl status discord-gameserver-notifier"
    echo "   4. View logs: sudo journalctl -u discord-gameserver-notifier -f"
    echo ""
    echo "📋 Service Management:"
    echo "   • Start:   sudo systemctl start discord-gameserver-notifier"
    echo "   • Stop:    sudo systemctl stop discord-gameserver-notifier"
    echo "   • Restart: sudo systemctl restart discord-gameserver-notifier"
    echo "   • Disable: sudo systemctl disable discord-gameserver-notifier"
    echo ""
else
    echo "Systemctl not available - manual execution required."
    echo ""
    echo "🚀 Quick Start:"
    echo "   1. Edit configuration: sudo nano $CONFIG_FILE"
    echo "   2. Run manually: discord-gameserver-notifier"
    echo "   3. For help: discord-gameserver-notifier --help"
    echo ""
fi

echo "Discord Gameserver Notifier installation completed!"
echo "📖 Documentation: https://github.com/lan-dot-party/Discord-Gameserver-Notifier"
echo ""

exit 0 