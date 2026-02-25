#!/bin/bash
################################################################################
# AVA Doorbell v4.0 - Installation Script
#
# Comprehensive installer for Raspberry Pi 3B+ running 64-bit Bookworm
# This script is idempotent and safe to run multiple times
#
# V4 changes from V3:
#   - FastAPI + uvicorn instead of Flask
#   - No nmap dependency (socket-based network scan)
#   - ava-admin.service → uvicorn with SSL
#   - SSL cert deferred to app startup (dynamic SAN)
#   - No default password in config (setup wizard handles it)
#
# Usage: ./install.sh
################################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="${HOME}/ava-doorbell"
VENV_DIR="${INSTALL_DIR}/venv"
BIN_DIR="${INSTALL_DIR}/bin"
CONFIG_DIR="${INSTALL_DIR}/config"
SERVICES_DIR="${INSTALL_DIR}/services"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP_NUM=0
TOTAL_STEPS=11

################################################################################
# Utility Functions
################################################################################

print_step() {
    STEP_NUM=$((STEP_NUM + 1))
    local title="$1"
    echo -e "\n${BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${NC} ${title}"
    echo -e "${BLUE}$(printf '=%.0s' {1..70})${NC}"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ ERROR: $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ WARNING: $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ INFO: $1${NC}"; }

confirm() {
    local prompt="$1"
    local response
    while true; do
        read -p "$(echo -e ${BLUE})${prompt}${NC} (y/n) " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]) return 1 ;;
            *) echo "Please answer y or n" ;;
        esac
    done
}

fail_exit() {
    print_error "$1"
    exit 1
}

################################################################################
# Pre-flight Checks
################################################################################

preflight_checks() {
    print_step "Running pre-flight checks"

    if [[ $EUID -eq 0 ]]; then
        fail_exit "This script must NOT be run as root. Please run as a regular user."
    fi
    print_success "Running as regular user"

    if ! command -v sudo &> /dev/null; then
        fail_exit "sudo is not installed."
    fi
    print_success "sudo is available"

    if ! sudo -n true 2>/dev/null; then
        print_info "Setting up sudo..."
        if ! sudo -v; then
            fail_exit "Could not obtain sudo privileges"
        fi
    fi
    print_success "sudo privileges available"

    if ! grep -qi "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
        print_warning "This does not appear to be a Raspberry Pi"
    else
        print_success "Detected: $(cat /proc/device-tree/model 2>/dev/null || echo 'Unknown')"
    fi

    if ! timeout 5 ping -c 1 8.8.8.8 &> /dev/null; then
        fail_exit "No internet connectivity detected."
    fi
    print_success "Internet connectivity confirmed"
}

################################################################################
# Display Installation Summary
################################################################################

show_summary() {
    print_step "Installation Summary"

    cat << EOF

This script will install AVA Doorbell v4.0 with the following components:

SYSTEM PACKAGES:
  • mosquitto (MQTT broker)
  • ffmpeg (video processing)
  • samba (SMB file sharing)
  • python3-pip & python3-venv

PYTHON PACKAGES (in virtual environment):
  • FastAPI + uvicorn (web framework — replaces Flask from V3)
  • PyYAML (configuration)
  • websockets (WebSocket support)
  • aiohttp (async HTTP)
  • httpx (HTTP client)
  • paho-mqtt (MQTT client)
  • jinja2 (templating)

APPLICATIONS:
  • go2rtc (camera streaming server)
  • alarm-scanner.py (motion detection)
  • talk_relay.py (two-way audio)
  • admin/ (FastAPI web dashboard)

INSTALL LOCATION: ${INSTALL_DIR}
PYTHON VENV: ${VENV_DIR}

SYSTEMD SERVICES (auto-starting):
  • go2rtc.service
  • alarm-scanner.service
  • ava-talk.service
  • ava-admin.service (uvicorn with SSL)
  • mosquitto.service
  • smbd.service

EOF

    if ! confirm "Continue with installation?"; then
        print_warning "Installation cancelled by user"
        exit 0
    fi
}

################################################################################
# System Packages
################################################################################

install_system_packages() {
    print_step "Installing system packages"

    print_info "Running apt update..."
    sudo apt-get update || fail_exit "apt update failed"
    print_success "apt update completed"

    # V4: No nmap (socket-based network scan replaces it)
    local packages=(
        "mosquitto"
        "mosquitto-clients"
        "ffmpeg"
        "samba"
        "python3-pip"
        "python3-venv"
    )

    sudo apt-get install -y "${packages[@]}" || fail_exit "Package installation failed"
    print_success "System packages installed"
}

################################################################################
# Python Virtual Environment
################################################################################

setup_python_venv() {
    print_step "Setting up Python virtual environment"

    mkdir -p "${INSTALL_DIR}" "${BIN_DIR}" "${CONFIG_DIR}" "${SERVICES_DIR}"
    print_info "Created directory structure"

    if [[ -d "${VENV_DIR}" ]]; then
        print_info "Virtual environment already exists at ${VENV_DIR}"
    else
        print_info "Creating virtual environment..."
        python3 -m venv "${VENV_DIR}" || fail_exit "Failed to create virtual environment"
        print_success "Virtual environment created"
    fi

    source "${VENV_DIR}/bin/activate"
    print_info "Upgrading pip..."
    pip install --upgrade pip setuptools wheel &> /dev/null || fail_exit "Failed to upgrade pip"
    print_success "pip upgraded"

    # V4: Install from requirements.txt
    if [[ -f "${SCRIPT_DIR}/services/requirements.txt" ]]; then
        print_info "Installing Python packages from requirements.txt..."
        pip install -r "${SCRIPT_DIR}/services/requirements.txt" &> /dev/null || fail_exit "Failed to install requirements"
    else
        # Fallback: install individually
        print_info "Installing Python packages..."
        local packages=(
            "fastapi>=0.115"
            "uvicorn[standard]>=0.34"
            "python-multipart>=0.0.12"
            "pyyaml>=6.0.1"
            "httpx>=0.27"
            "aiohttp>=3.9"
            "paho-mqtt>=1.6"
            "websockets>=12.0"
            "jinja2>=3.1"
        )
        for pkg in "${packages[@]}"; do
            pip install "$pkg" &> /dev/null || fail_exit "Failed to install $pkg"
        done
    fi
    print_success "Python packages installed"

    deactivate
}

################################################################################
# Download go2rtc Binary
################################################################################

install_go2rtc() {
    print_step "Installing go2rtc binary"

    local arch
    arch=$(uname -m)

    local go2rtc_arch
    case "$arch" in
        aarch64) go2rtc_arch="arm64" ;;
        armv7l) go2rtc_arch="armv7" ;;
        *)
            print_warning "Unsupported architecture: $arch"
            print_info "Skipping go2rtc installation"
            return
            ;;
    esac

    print_info "Detected architecture: $arch ($go2rtc_arch)"

    if [[ -f "${BIN_DIR}/go2rtc" ]]; then
        print_info "go2rtc already installed at ${BIN_DIR}/go2rtc"
        return
    fi

    print_info "Fetching latest go2rtc release..."
    local latest_release
    latest_release=$(curl -s "https://api.github.com/repos/AlexxIT/go2rtc/releases/latest" | grep "tag_name" | cut -d'"' -f4)

    if [[ -z "$latest_release" ]]; then
        print_warning "Could not determine latest go2rtc version"
        return
    fi

    print_info "Latest version: $latest_release"

    local download_url="https://github.com/AlexxIT/go2rtc/releases/download/${latest_release}/go2rtc_linux_${go2rtc_arch}"
    local temp_file="/tmp/go2rtc_linux_${go2rtc_arch}"

    print_info "Downloading go2rtc..."
    if ! curl -fsSL -o "$temp_file" "$download_url"; then
        print_warning "Failed to download go2rtc"
        return
    fi

    mkdir -p "${BIN_DIR}"
    mv "$temp_file" "${BIN_DIR}/go2rtc"
    chmod +x "${BIN_DIR}/go2rtc"

    print_success "go2rtc installed: ${BIN_DIR}/go2rtc"
}

################################################################################
# Deploy Configuration Files
################################################################################

deploy_files() {
    print_step "Deploying files"

    if [[ ! -d "${SCRIPT_DIR}/services" ]]; then
        print_warning "services/ directory not found in ${SCRIPT_DIR}"
        return
    fi

    if [[ -d "${SCRIPT_DIR}/services" ]]; then
        print_info "Copying services directory..."
        if cp -r "${SCRIPT_DIR}/services" "${INSTALL_DIR}/"; then
            print_success "Services copied"
        else
            print_warning "Some files failed to copy — check permissions"
        fi
    fi

    if [[ -d "${SCRIPT_DIR}/config" ]]; then
        print_info "Copying config directory..."
        mkdir -p "${CONFIG_DIR}"

        for file in "${SCRIPT_DIR}/config"/*; do
            if [[ -f "$file" ]]; then
                filename=$(basename "$file")
                if [[ "$filename" == "config.json" ]] && [[ -f "${CONFIG_DIR}/config.json" ]]; then
                    print_info "Preserving existing config.json"
                else
                    cp "$file" "${CONFIG_DIR}/$filename"
                fi
            fi
        done

        print_success "Config files copied"
    fi

    # V4: Create config.json from default if not exists (no hardcoded password)
    if [[ ! -f "${CONFIG_DIR}/config.json" ]]; then
        print_info "Creating config.json from defaults..."
        if [[ -f "${CONFIG_DIR}/config.default.json" ]]; then
            cp "${CONFIG_DIR}/config.default.json" "${CONFIG_DIR}/config.json"
            print_success "config.json created from template (setup wizard will configure on first login)"
        else
            print_warning "config.default.json not found — setup wizard will create config on first run"
        fi
    else
        print_info "config.json already exists, preserving"
    fi

    # Deploy Android APK for sideloading
    if [[ -d "${SCRIPT_DIR}/apk" ]]; then
        mkdir -p "${INSTALL_DIR}/apk"
        if ls "${SCRIPT_DIR}/apk"/*.apk &>/dev/null; then
            cp "${SCRIPT_DIR}/apk"/*.apk "${INSTALL_DIR}/apk/"
            print_success "Android APK deployed (available at /app/download)"
        else
            print_warning "No .apk files found in apk/ directory"
        fi
    fi
}

################################################################################
# Generate Initial Configurations
################################################################################

generate_configs() {
    print_step "Generating initial configurations"

    if [[ ! -f "${CONFIG_DIR}/go2rtc.yaml" ]]; then
        print_info "Creating default go2rtc.yaml..."
        cat > "${CONFIG_DIR}/go2rtc.yaml" << 'EOFGO2RTC'
api:
  listen: ":1984"

webrtc:
  listen: ":8555"

rtsp:
  listen: ":8554"

streams:
  # Streams are auto-generated by ava-admin from config.json

log:
  format: text
  level: info
EOFGO2RTC
        print_success "go2rtc.yaml created"
    fi

    print_info "Configuring mosquitto..."
    sudo tee /etc/mosquitto/mosquitto.conf > /dev/null << 'EOFMOSQ'
# Mosquitto MQTT Broker - AVA Doorbell v4.0
listener 1883 0.0.0.0
allow_anonymous true

persistence true
persistence_location /var/lib/mosquitto/

max_connections 50
max_queued_messages 1000

log_dest file /var/log/mosquitto/mosquitto.log
log_type error
log_type warning
log_type notice
EOFMOSQ

    sudo rm -f /etc/mosquitto/conf.d/ava.conf /etc/mosquitto/conf.d/ava-doorbell.conf
    print_success "mosquitto configured"
}

################################################################################
# Configure Samba
################################################################################

configure_samba() {
    print_step "Configuring Samba file sharing"

    local current_user="$(whoami)"
    mkdir -p "${INSTALL_DIR}/recordings"

    if [[ -f "${SCRIPT_DIR}/config/smb.conf" ]]; then
        local smb_conf="/tmp/ava-smb.conf"
        sed -e "s|%INSTALL_DIR%|${INSTALL_DIR}|g" \
            -e "s|%USER%|${current_user}|g" \
            "${SCRIPT_DIR}/config/smb.conf" > "$smb_conf"

        if ! grep -q "include = /etc/samba/ava-smb.conf" /etc/samba/smb.conf 2>/dev/null; then
            sudo cp "$smb_conf" /etc/samba/ava-smb.conf
            echo "" | sudo tee -a /etc/samba/smb.conf > /dev/null
            echo "include = /etc/samba/ava-smb.conf" | sudo tee -a /etc/samba/smb.conf > /dev/null
        else
            sudo cp "$smb_conf" /etc/samba/ava-smb.conf
        fi
        rm -f "$smb_conf"
        print_success "Samba configuration deployed"
    else
        print_warning "smb.conf template not found, skipping"
    fi

    # Generate a random Samba password (never hardcode credentials)
    local smb_pass
    smb_pass="$(openssl rand -base64 12)"
    (echo "$smb_pass"; echo "$smb_pass") | sudo smbpasswd -s -a "${current_user}" 2>/dev/null || true
    print_success "Samba user configured (password: $smb_pass — save this!)"
}

################################################################################
# Create Systemd Services
################################################################################

create_systemd_services() {
    print_step "Creating systemd service units"

    local current_user="$(whoami)"

    # go2rtc.service
    sudo tee /etc/systemd/system/go2rtc.service > /dev/null << EOFSERVICE1
[Unit]
Description=go2rtc - Camera Streaming Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${current_user}
ExecStart=${INSTALL_DIR}/bin/go2rtc -config ${INSTALL_DIR}/config/go2rtc.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFSERVICE1
    print_success "go2rtc.service created"

    # alarm-scanner.service
    sudo tee /etc/systemd/system/alarm-scanner.service > /dev/null << EOFSERVICE2
[Unit]
Description=AVA Doorbell Alarm Scanner
After=network-online.target mosquitto.service
Wants=network-online.target

[Service]
Type=simple
User=${current_user}
Environment="AVA_CONFIG=${INSTALL_DIR}/config/config.json"
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/services/alarm_scanner.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFSERVICE2
    print_success "alarm-scanner.service created"

    # ava-talk.service
    sudo tee /etc/systemd/system/ava-talk.service > /dev/null << EOFSERVICE3
[Unit]
Description=AVA Doorbell Talk Relay
After=network-online.target mosquitto.service
Wants=network-online.target

[Service]
Type=simple
User=${current_user}
Environment="AVA_CONFIG=${INSTALL_DIR}/config/config.json"
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/services/talk_relay.py
Restart=always
RestartSec=5
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFSERVICE3
    print_success "ava-talk.service created"

    # V4: ava-admin.service uses uvicorn with SSL (cert generated at app startup)
    sudo tee /etc/systemd/system/ava-admin.service > /dev/null << EOFSERVICE4
[Unit]
Description=AVA Doorbell Admin Dashboard (FastAPI)
After=network-online.target mosquitto.service go2rtc.service
Wants=network-online.target

[Service]
Type=simple
User=${current_user}
Environment="AVA_CONFIG=${INSTALL_DIR}/config/config.json"
WorkingDirectory=${INSTALL_DIR}/services
ExecStart=${INSTALL_DIR}/venv/bin/python3 -m admin.main
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFSERVICE4
    print_success "ava-admin.service created (FastAPI + uvicorn)"
}

################################################################################
# Enable and Start Services
################################################################################

enable_start_services() {
    print_step "Enabling and starting services"

    sudo systemctl daemon-reload
    print_success "Daemon reloaded"

    local services=(
        "mosquitto"
        "go2rtc"
        "alarm-scanner"
        "ava-talk"
        "ava-admin"
        "smbd"
    )

    for service in "${services[@]}"; do
        print_info "Enabling ${service}.service..."
        sudo systemctl enable "${service}.service" || print_warning "Failed to enable ${service}"

        print_info "Starting ${service}.service..."
        sudo systemctl start "${service}.service" || print_warning "Failed to start ${service}"
    done

    print_success "Services enabled and started"
}

################################################################################
# Print Summary
################################################################################

print_installation_summary() {
    print_step "Installation Summary"

    cat << EOF

${GREEN}Installation completed successfully!${NC}

INSTALLED COMPONENTS:
  • System packages (mosquitto, ffmpeg, python3)
  • Python virtual environment with FastAPI stack
  • go2rtc camera streaming server
  • AVA Doorbell services (alarm-scanner, talk-relay, admin)
  • Systemd service units for auto-start

SERVICE STATUS:
EOF

    echo
    for service in mosquitto go2rtc alarm-scanner ava-talk ava-admin smbd; do
        if sudo systemctl is-active --quiet "${service}.service"; then
            echo -e "  ${GREEN}✓${NC} ${service}.service is ${GREEN}running${NC}"
        else
            echo -e "  ${YELLOW}✗${NC} ${service}.service is ${YELLOW}not running${NC}"
        fi
    done

    cat << EOF

ACCESS POINTS:
  • Admin Dashboard:  ${BLUE}https://localhost:5000${NC}
  • Setup Wizard:     ${BLUE}https://localhost:5000/setup${NC}  (first run)
  • Live View:        ${BLUE}https://localhost:5000/view${NC}
  • go2rtc API:       ${BLUE}http://localhost:1984${NC}
  • MQTT Broker:      ${BLUE}localhost:1883${NC}

INSTALLATION PATHS:
  • Install Dir:      ${INSTALL_DIR}
  • Config Dir:       ${CONFIG_DIR}
  • Services Dir:     ${SERVICES_DIR}
  • Python Venv:      ${VENV_DIR}

CONFIGURATION:
  • No default password — setup wizard runs on first access
  • SSL certificate auto-generated on first admin startup
  • Config File:      ${CONFIG_DIR}/config.json

USEFUL COMMANDS:
  • View service logs:    sudo journalctl -u ava-admin -f
  • Check service status: systemctl status ava-*
  • Restart services:     sudo systemctl restart ava-admin
  • Stop all services:    sudo systemctl stop mosquitto go2rtc alarm-scanner ava-talk ava-admin

NEXT STEPS:
  1. Open ${BLUE}https://$(hostname -I | awk '{print $1}'):5000${NC} in your browser
  2. Complete the setup wizard (set password, discover cameras)
  3. Configure cameras and layouts in the admin dashboard
  4. Set up the Android app with your server IP

EOF

    print_success "Installation script completed"
}

################################################################################
# Main Execution Flow
################################################################################

main() {
    echo -e "${BLUE}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║            AVA Doorbell v4.0 - Installation Script                       ║
║                                                                           ║
║       FastAPI + Glassmorphism + Cinema Remote                            ║
║       Comprehensive installer for Raspberry Pi 64-bit Bookworm           ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    preflight_checks
    show_summary
    install_system_packages
    setup_python_venv
    install_go2rtc
    deploy_files
    generate_configs
    configure_samba
    create_systemd_services
    enable_start_services
    print_installation_summary
}

main "$@"
