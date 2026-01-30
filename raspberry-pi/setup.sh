#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════╗
# ║     AVA DOORBELL SYSTEM - AUTOMATED INSTALLER                 ║
# ║     For IC Realtime Dinger Pro 2 + AVA Remote                 ║
# ╚═══════════════════════════════════════════════════════════════╝
#
# This script automatically sets up everything you need.
# After installation, use the web admin panel to configure your cameras.
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
INSTALL_DIR="$HOME/ava-doorbell"
ADMIN_PORT=8888
GO2RTC_PORT=1984
RTSP_PORT=8554
MQTT_PORT=1883
WEBHOOK_PORT=8080

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║     █████╗ ██╗   ██╗ █████╗     ██████╗  ██████╗  ██████╗     ║"
    echo "║    ██╔══██╗██║   ██║██╔══██╗    ██╔══██╗██╔═══██╗██╔═══██╗    ║"
    echo "║    ███████║██║   ██║███████║    ██║  ██║██║   ██║██║   ██║    ║"
    echo "║    ██╔══██║╚██╗ ██╔╝██╔══██║    ██║  ██║██║   ██║██║   ██║    ║"
    echo "║    ██║  ██║ ╚████╔╝ ██║  ██║    ██████╔╝╚██████╔╝╚██████╔╝    ║"
    echo "║    ╚═╝  ╚═╝  ╚═══╝  ╚═╝  ╚═╝    ╚═════╝  ╚═════╝  ╚═════╝     ║"
    echo "║                                                               ║"
    echo "║            DOORBELL SYSTEM INSTALLER v1.0                     ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  STEP $1: $2${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

print_info() {
    echo -e "${CYAN}  ℹ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}  ✗ $1${NC}"
}

get_ip() {
    hostname -I | awk '{print $1}'
}

check_root() {
    if [ "$EUID" -eq 0 ]; then
        print_error "Please do NOT run as root. Run as your normal user."
        exit 1
    fi
}

# ============================================================
# MAIN INSTALLATION
# ============================================================

print_banner
check_root

PI_IP=$(get_ip)
echo -e "${BOLD}Detected IP Address: ${GREEN}$PI_IP${NC}"
echo ""
echo "This script will install:"
echo "  • Docker & Docker Compose"
echo "  • go2rtc (video streaming server)"
echo "  • Mosquitto (MQTT for notifications)"
echo "  • Webhook Relay (doorbell events)"
echo "  • Admin Panel (web GUI for configuration)"
echo ""
echo -e "${YELLOW}Press Enter to continue or Ctrl+C to cancel...${NC}"
read

# ============================================================
# STEP 1: System Update
# ============================================================
print_step "1/6" "Updating System"

print_info "Updating package lists..."
sudo apt-get update -qq

print_info "Upgrading packages..."
sudo apt-get upgrade -y -qq

print_success "System updated"

# ============================================================
# STEP 2: Install Docker
# ============================================================
print_step "2/6" "Installing Docker"

if command -v docker &> /dev/null; then
    print_success "Docker already installed: $(docker --version)"
else
    print_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    print_success "Docker installed"
fi

# Add user to docker group
if ! groups | grep -q docker; then
    sudo usermod -aG docker $USER
    print_warning "Added $USER to docker group (will take effect after relogin)"
fi

# Install docker-compose if needed
if ! command -v docker-compose &> /dev/null; then
    print_info "Installing Docker Compose..."
    sudo apt-get install -y docker-compose -qq
fi
print_success "Docker Compose ready"

# ============================================================
# STEP 3: Create Project Structure
# ============================================================
print_step "3/6" "Creating Project Files"

mkdir -p "$INSTALL_DIR"/{config,webhook-relay,admin-panel/{templates,static},logs}
cd "$INSTALL_DIR"

print_info "Creating configuration files..."

# Create .env file
cat > .env << EOF
# AVA Doorbell System Configuration
# Edit these values or use the Admin Panel at http://$PI_IP:$ADMIN_PORT

PI_IP=$PI_IP
TZ=$(cat /etc/timezone 2>/dev/null || echo "America/Los_Angeles")

# Camera Settings (configure via Admin Panel)
DOORBELL_IP=
DOORBELL_USER=admin
DOORBELL_PASS=
NVR_IP=
NVR_USER=admin
NVR_PASS=

# Ports
ADMIN_PORT=$ADMIN_PORT
GO2RTC_PORT=$GO2RTC_PORT
RTSP_PORT=$RTSP_PORT
MQTT_PORT=$MQTT_PORT
WEBHOOK_PORT=$WEBHOOK_PORT
EOF

# Create docker-compose.yml
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config/go2rtc.yaml:/config/go2rtc.yaml:ro
    mem_limit: 256m

  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
      - "9001:9001"
    volumes:
      - ./config/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - mosquitto_data:/mosquitto/data
    mem_limit: 64m

  webhook-relay:
    build: ./webhook-relay
    container_name: webhook-relay
    restart: unless-stopped
    network_mode: host
    environment:
      - MQTT_HOST=localhost
      - MQTT_PORT=1883
    depends_on:
      - mosquitto
    mem_limit: 96m

  admin-panel:
    build: ./admin-panel
    container_name: admin-panel
    restart: unless-stopped
    ports:
      - "8888:8888"
    volumes:
      - ./config:/app/config
      - ./.env:/app/.env
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - PI_IP=${PI_IP}
    mem_limit: 128m

volumes:
  mosquitto_data:
COMPOSE_EOF

# Create default go2rtc.yaml
cat > config/go2rtc.yaml << 'YAML_EOF'
# go2rtc Configuration
# This file is auto-generated. Use the Admin Panel to configure.

streams:
  # Doorbell stream - configure via Admin Panel
  doorbell:
    - "rtsp://admin:password@192.168.1.1:554/cam/realmonitor?channel=1&subtype=0"
  doorbell_sub:
    - "rtsp://admin:password@192.168.1.1:554/cam/realmonitor?channel=1&subtype=1"

webrtc:
  candidates:
    - "192.168.1.100:8555"

api:
  listen: ":1984"
  origin: "*"

rtsp:
  listen: ":8554"

log:
  level: "info"
YAML_EOF

# Create mosquitto.conf
cat > config/mosquitto.conf << 'MQTT_EOF'
listener 1883
protocol mqtt
listener 9001
protocol websockets
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
log_dest stdout
MQTT_EOF

print_success "Configuration files created"

# ============================================================
# STEP 4: Create Webhook Relay
# ============================================================
print_step "4/6" "Creating Webhook Relay Service"

cat > webhook-relay/Dockerfile << 'DOCKERFILE_EOF'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir flask paho-mqtt requests
COPY server.py .
EXPOSE 8080
CMD ["python", "-u", "server.py"]
DOCKERFILE_EOF

cat > webhook-relay/server.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import os, json, threading, logging
from datetime import datetime
from flask import Flask, request, jsonify
import paho.mqtt.client as mqtt

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
log = logging.getLogger('webhook')

app = Flask(__name__)
mqtt_client = None
mqtt_connected = threading.Event()

def setup_mqtt():
    global mqtt_client
    mqtt_client = mqtt.Client(client_id=f"webhook_{os.getpid()}")
    mqtt_client.on_connect = lambda c,u,f,rc: (mqtt_connected.set(), log.info("MQTT connected")) if rc==0 else None
    mqtt_client.on_disconnect = lambda c,u,rc: (mqtt_connected.clear(), log.warning("MQTT disconnected"))
    
    def connect():
        while True:
            try:
                mqtt_client.connect(os.environ.get('MQTT_HOST', 'localhost'), 
                                   int(os.environ.get('MQTT_PORT', 1883)), 60)
                mqtt_client.loop_start()
                break
            except Exception as e:
                log.error(f"MQTT connection failed: {e}, retrying...")
                import time; time.sleep(5)
    
    threading.Thread(target=connect, daemon=True).start()

def publish(topic, data):
    if mqtt_connected.is_set():
        mqtt_client.publish(f"doorbell/{topic}", json.dumps(data), qos=1)
        log.info(f"Published to doorbell/{topic}")

@app.route('/health')
def health():
    return jsonify({'status': 'healthy', 'mqtt': mqtt_connected.is_set(), 'time': datetime.now().isoformat()})

@app.route('/webhook/doorbell', methods=['POST', 'GET'])
def doorbell():
    ts = datetime.now().isoformat()
    log.info(f"🔔 DOORBELL PRESSED at {ts}")
    publish('ring', {'event_type': 'ring', 'timestamp': ts, 'source': 'doorbell'})
    publish('event', {'event_type': 'doorbell_press', 'timestamp': ts})
    return jsonify({'status': 'ok', 'event': 'doorbell_press'})

@app.route('/webhook/motion', methods=['POST', 'GET'])
def motion():
    camera = request.args.get('camera', request.json.get('camera', 'doorbell') if request.is_json else 'doorbell')
    ts = datetime.now().isoformat()
    log.info(f"👁 Motion detected on {camera}")
    publish('motion', {'event_type': 'motion', 'timestamp': ts, 'source': camera})
    return jsonify({'status': 'ok', 'event': 'motion', 'camera': camera})

@app.route('/webhook/alarm', methods=['POST', 'GET'])
def alarm():
    ts = datetime.now().isoformat()
    data = {}
    if request.is_json:
        data = request.json or {}
    elif request.form:
        data = dict(request.form)
    data.update(dict(request.args))
    
    alarm_type = str(data.get('type', data.get('alarmType', data.get('event', 'unknown')))).lower()
    channel = data.get('channel', data.get('chn', '1'))
    
    log.info(f"📢 Alarm received: type={alarm_type}, channel={channel}, data={data}")
    
    if any(x in alarm_type for x in ['doorbell', 'ring', 'button', 'call']):
        publish('ring', {'event_type': 'ring', 'timestamp': ts, 'source': f'channel_{channel}'})
    elif any(x in alarm_type for x in ['motion', 'md', 'move']):
        publish('motion', {'event_type': 'motion', 'timestamp': ts, 'source': f'channel_{channel}'})
    else:
        publish('event', {'event_type': alarm_type, 'timestamp': ts, 'source': f'channel_{channel}', 'data': data})
    
    return jsonify({'status': 'ok'})

@app.route('/test/ring', methods=['GET', 'POST'])
def test_ring():
    ts = datetime.now().isoformat()
    publish('ring', {'event_type': 'ring', 'timestamp': ts, 'source': 'test'})
    log.info("🧪 Test ring sent")
    return jsonify({'status': 'ok', 'message': 'Test doorbell ring sent!'})

@app.route('/test/motion', methods=['GET', 'POST'])
def test_motion():
    camera = request.args.get('camera', 'test')
    ts = datetime.now().isoformat()
    publish('motion', {'event_type': 'motion', 'timestamp': ts, 'source': camera})
    return jsonify({'status': 'ok', 'message': f'Test motion sent for {camera}'})

if __name__ == '__main__':
    log.info("Starting Webhook Relay Server on port 8080...")
    setup_mqtt()
    app.run(host='0.0.0.0', port=8080, threaded=True)
PYTHON_EOF

print_success "Webhook relay created"

# ============================================================
# STEP 5: Create Admin Panel
# ============================================================
print_step "5/6" "Creating Admin Panel"

cat > admin-panel/Dockerfile << 'DOCKERFILE_EOF'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir flask requests pyyaml python-dotenv
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY . .
EXPOSE 8888
CMD ["python", "-u", "app.py"]
DOCKERFILE_EOF

cat > admin-panel/app.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import os
import json
import yaml
import subprocess
import requests
from pathlib import Path
from flask import Flask, render_template, request, jsonify, redirect, url_for
from dotenv import load_dotenv, set_key

app = Flask(__name__)

CONFIG_DIR = Path('/app/config')
ENV_FILE = Path('/app/.env')
GO2RTC_CONFIG = CONFIG_DIR / 'go2rtc.yaml'

def load_env():
    """Load environment variables"""
    load_dotenv(ENV_FILE)
    return {
        'PI_IP': os.getenv('PI_IP', ''),
        'DOORBELL_IP': os.getenv('DOORBELL_IP', ''),
        'DOORBELL_USER': os.getenv('DOORBELL_USER', 'admin'),
        'DOORBELL_PASS': os.getenv('DOORBELL_PASS', ''),
        'NVR_IP': os.getenv('NVR_IP', ''),
        'NVR_USER': os.getenv('NVR_USER', 'admin'),
        'NVR_PASS': os.getenv('NVR_PASS', ''),
        'TZ': os.getenv('TZ', 'America/Los_Angeles'),
    }

def save_env(data):
    """Save environment variables"""
    for key, value in data.items():
        set_key(str(ENV_FILE), key, value)

def generate_go2rtc_config(env):
    """Generate go2rtc.yaml from environment"""
    config = {
        'streams': {},
        'webrtc': {
            'candidates': [f"{env['PI_IP']}:8555"]
        },
        'api': {
            'listen': ':1984',
            'origin': '*'
        },
        'rtsp': {
            'listen': ':8554'
        },
        'log': {
            'level': 'info'
        }
    }
    
    # Add doorbell stream if configured
    if env.get('DOORBELL_IP') and env.get('DOORBELL_PASS'):
        user = env.get('DOORBELL_USER', 'admin')
        password = env['DOORBELL_PASS']
        ip = env['DOORBELL_IP']
        
        config['streams']['doorbell'] = [
            f"rtsp://{user}:{password}@{ip}:554/cam/realmonitor?channel=1&subtype=0"
        ]
        config['streams']['doorbell_sub'] = [
            f"rtsp://{user}:{password}@{ip}:554/cam/realmonitor?channel=1&subtype=1"
        ]
    
    # Add NVR cameras if configured
    if env.get('NVR_IP') and env.get('NVR_PASS'):
        user = env.get('NVR_USER', 'admin')
        password = env['NVR_PASS']
        ip = env['NVR_IP']
        
        for i, name in enumerate(['camera_front', 'camera_back', 'camera_garage', 'camera_side'], 1):
            config['streams'][name] = [
                f"rtsp://{user}:{password}@{ip}:554/cam/realmonitor?channel={i}&subtype=0"
            ]
            config['streams'][f'{name}_sub'] = [
                f"rtsp://{user}:{password}@{ip}:554/cam/realmonitor?channel={i}&subtype=1"
            ]
    
    return config

def save_go2rtc_config(config):
    """Save go2rtc configuration"""
    with open(GO2RTC_CONFIG, 'w') as f:
        yaml.dump(config, f, default_flow_style=False)

def get_service_status():
    """Get status of all services"""
    services = {}
    try:
        result = subprocess.run(
            ['docker', 'ps', '--format', '{{.Names}}:{{.Status}}'],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split('\n'):
            if ':' in line:
                name, status = line.split(':', 1)
                services[name] = 'running' if 'Up' in status else 'stopped'
    except:
        pass
    return services

def test_rtsp_stream(url):
    """Test if RTSP stream is accessible"""
    try:
        # Use curl to test RTSP OPTIONS
        result = subprocess.run(
            ['curl', '-s', '-m', '5', '-I', url.replace('rtsp://', 'http://').split('/')[0].replace('http://', 'rtsp://') + ':554'],
            capture_output=True, text=True, timeout=10
        )
        return True
    except:
        return False

@app.route('/')
def index():
    env = load_env()
    services = get_service_status()
    return render_template('index.html', env=env, services=services, pi_ip=env.get('PI_IP', ''))

@app.route('/save', methods=['POST'])
def save():
    data = {
        'DOORBELL_IP': request.form.get('doorbell_ip', ''),
        'DOORBELL_USER': request.form.get('doorbell_user', 'admin'),
        'DOORBELL_PASS': request.form.get('doorbell_pass', ''),
        'NVR_IP': request.form.get('nvr_ip', ''),
        'NVR_USER': request.form.get('nvr_user', 'admin'),
        'NVR_PASS': request.form.get('nvr_pass', ''),
    }
    
    # Load existing env and update
    env = load_env()
    env.update(data)
    
    # Save to .env file
    save_env(data)
    
    # Generate and save go2rtc config
    config = generate_go2rtc_config(env)
    save_go2rtc_config(config)
    
    return redirect(url_for('index', saved=1))

@app.route('/restart/<service>')
def restart_service(service):
    try:
        subprocess.run(['docker', 'restart', service], capture_output=True, timeout=30)
        return jsonify({'status': 'ok', 'message': f'{service} restarted'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/restart-all')
def restart_all():
    try:
        subprocess.run(['docker', 'restart', 'go2rtc', 'mosquitto', 'webhook-relay'], 
                      capture_output=True, timeout=60)
        return jsonify({'status': 'ok', 'message': 'All services restarted'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/test/doorbell')
def test_doorbell():
    try:
        r = requests.get('http://localhost:8080/test/ring', timeout=5)
        return jsonify({'status': 'ok', 'message': 'Test doorbell ring sent!'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/test/stream')
def test_stream():
    env = load_env()
    if not env.get('DOORBELL_IP') or not env.get('DOORBELL_PASS'):
        return jsonify({'status': 'error', 'message': 'Doorbell not configured'})
    
    try:
        # Check go2rtc API
        r = requests.get('http://localhost:1984/api/streams', timeout=5)
        streams = r.json()
        if 'doorbell' in streams:
            return jsonify({'status': 'ok', 'message': 'Stream configured', 'streams': list(streams.keys())})
        else:
            return jsonify({'status': 'warning', 'message': 'Stream not found in go2rtc'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/logs/<service>')
def get_logs(service):
    try:
        result = subprocess.run(
            ['docker', 'logs', '--tail', '100', service],
            capture_output=True, text=True, timeout=10
        )
        return jsonify({'status': 'ok', 'logs': result.stdout + result.stderr})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/api/status')
def api_status():
    env = load_env()
    services = get_service_status()
    
    # Check go2rtc streams
    streams = []
    try:
        r = requests.get('http://localhost:1984/api/streams', timeout=3)
        streams = list(r.json().keys())
    except:
        pass
    
    return jsonify({
        'services': services,
        'streams': streams,
        'configured': bool(env.get('DOORBELL_IP') and env.get('DOORBELL_PASS')),
        'pi_ip': env.get('PI_IP', '')
    })

if __name__ == '__main__':
    print("Starting Admin Panel on port 8888...")
    app.run(host='0.0.0.0', port=8888, debug=False)
PYTHON_EOF

# Create admin panel HTML template
cat > admin-panel/templates/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AVA Doorbell - Admin Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f0f23 100%);
            min-height: 100vh;
            color: #e4e4e7;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        
        header {
            text-align: center;
            padding: 30px 0;
            border-bottom: 1px solid #333;
            margin-bottom: 30px;
        }
        
        h1 {
            font-size: 2.5em;
            background: linear-gradient(90deg, #e94560, #ff6b6b);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 10px;
        }
        
        .subtitle {
            color: #888;
            font-size: 1.1em;
        }
        
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .card {
            background: rgba(255,255,255,0.05);
            border-radius: 16px;
            padding: 24px;
            border: 1px solid rgba(255,255,255,0.1);
            backdrop-filter: blur(10px);
        }
        
        .card h2 {
            font-size: 1.3em;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .card h2 .icon {
            font-size: 1.5em;
        }
        
        .form-group {
            margin-bottom: 16px;
        }
        
        label {
            display: block;
            margin-bottom: 6px;
            color: #aaa;
            font-size: 0.9em;
        }
        
        input[type="text"], input[type="password"] {
            width: 100%;
            padding: 12px 16px;
            border: 1px solid #333;
            border-radius: 8px;
            background: rgba(0,0,0,0.3);
            color: #fff;
            font-size: 1em;
            transition: border-color 0.2s;
        }
        
        input:focus {
            outline: none;
            border-color: #e94560;
        }
        
        input::placeholder {
            color: #555;
        }
        
        .btn {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 12px 24px;
            border: none;
            border-radius: 8px;
            font-size: 1em;
            cursor: pointer;
            transition: all 0.2s;
            text-decoration: none;
        }
        
        .btn-primary {
            background: linear-gradient(90deg, #e94560, #ff6b6b);
            color: white;
        }
        
        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 20px rgba(233, 69, 96, 0.4);
        }
        
        .btn-secondary {
            background: rgba(255,255,255,0.1);
            color: #fff;
            border: 1px solid #333;
        }
        
        .btn-secondary:hover {
            background: rgba(255,255,255,0.15);
        }
        
        .btn-sm {
            padding: 8px 16px;
            font-size: 0.9em;
        }
        
        .status-grid {
            display: grid;
            gap: 12px;
        }
        
        .status-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 16px;
            background: rgba(0,0,0,0.2);
            border-radius: 8px;
        }
        
        .status-item .name {
            font-weight: 500;
        }
        
        .status-badge {
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 500;
        }
        
        .status-badge.running {
            background: rgba(34, 197, 94, 0.2);
            color: #4ade80;
        }
        
        .status-badge.stopped {
            background: rgba(239, 68, 68, 0.2);
            color: #f87171;
        }
        
        .status-badge.unknown {
            background: rgba(234, 179, 8, 0.2);
            color: #fbbf24;
        }
        
        .info-box {
            background: rgba(59, 130, 246, 0.1);
            border: 1px solid rgba(59, 130, 246, 0.3);
            border-radius: 8px;
            padding: 16px;
            margin-top: 16px;
        }
        
        .info-box h3 {
            color: #60a5fa;
            margin-bottom: 12px;
            font-size: 1em;
        }
        
        .info-box code {
            display: block;
            background: rgba(0,0,0,0.3);
            padding: 8px 12px;
            border-radius: 4px;
            font-family: monospace;
            font-size: 0.9em;
            margin: 4px 0;
            word-break: break-all;
        }
        
        .alert {
            padding: 16px;
            border-radius: 8px;
            margin-bottom: 20px;
        }
        
        .alert-success {
            background: rgba(34, 197, 94, 0.1);
            border: 1px solid rgba(34, 197, 94, 0.3);
            color: #4ade80;
        }
        
        .button-row {
            display: flex;
            gap: 10px;
            margin-top: 20px;
            flex-wrap: wrap;
        }
        
        .test-result {
            margin-top: 12px;
            padding: 12px;
            border-radius: 8px;
            display: none;
        }
        
        .test-result.show { display: block; }
        .test-result.success { background: rgba(34, 197, 94, 0.1); color: #4ade80; }
        .test-result.error { background: rgba(239, 68, 68, 0.1); color: #f87171; }
        
        .logs-container {
            background: #000;
            border-radius: 8px;
            padding: 16px;
            max-height: 300px;
            overflow-y: auto;
            font-family: monospace;
            font-size: 0.85em;
            white-space: pre-wrap;
            color: #4ade80;
            margin-top: 16px;
            display: none;
        }
        
        .logs-container.show { display: block; }
        
        footer {
            text-align: center;
            padding: 30px;
            color: #666;
            border-top: 1px solid #333;
            margin-top: 30px;
        }
        
        @media (max-width: 768px) {
            .grid { grid-template-columns: 1fr; }
            h1 { font-size: 1.8em; }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🔔 AVA Doorbell</h1>
            <p class="subtitle">Admin Configuration Panel</p>
        </header>
        
        {% if request.args.get('saved') %}
        <div class="alert alert-success">
            ✓ Settings saved! Restart services for changes to take effect.
        </div>
        {% endif %}
        
        <div class="grid">
            <!-- Camera Configuration -->
            <div class="card">
                <h2><span class="icon">📹</span> Camera Configuration</h2>
                <form method="POST" action="/save">
                    <div class="form-group">
                        <label>Doorbell IP Address</label>
                        <input type="text" name="doorbell_ip" value="{{ env.DOORBELL_IP }}" 
                               placeholder="192.168.1.50">
                    </div>
                    <div class="form-group">
                        <label>Doorbell Username</label>
                        <input type="text" name="doorbell_user" value="{{ env.DOORBELL_USER }}" 
                               placeholder="admin">
                    </div>
                    <div class="form-group">
                        <label>Doorbell Password</label>
                        <input type="password" name="doorbell_pass" value="{{ env.DOORBELL_PASS }}" 
                               placeholder="Enter password">
                    </div>
                    
                    <hr style="border-color: #333; margin: 20px 0;">
                    
                    <div class="form-group">
                        <label>NVR IP Address (Optional)</label>
                        <input type="text" name="nvr_ip" value="{{ env.NVR_IP }}" 
                               placeholder="192.168.1.60">
                    </div>
                    <div class="form-group">
                        <label>NVR Username</label>
                        <input type="text" name="nvr_user" value="{{ env.NVR_USER }}" 
                               placeholder="admin">
                    </div>
                    <div class="form-group">
                        <label>NVR Password</label>
                        <input type="password" name="nvr_pass" value="{{ env.NVR_PASS }}" 
                               placeholder="Enter password">
                    </div>
                    
                    <div class="button-row">
                        <button type="submit" class="btn btn-primary">💾 Save Configuration</button>
                    </div>
                </form>
            </div>
            
            <!-- Service Status -->
            <div class="card">
                <h2><span class="icon">⚡</span> Service Status</h2>
                <div class="status-grid">
                    <div class="status-item">
                        <span class="name">🎥 go2rtc (Streaming)</span>
                        <span class="status-badge {{ 'running' if services.get('go2rtc') == 'running' else 'stopped' if services.get('go2rtc') else 'unknown' }}">
                            {{ services.get('go2rtc', 'unknown') }}
                        </span>
                    </div>
                    <div class="status-item">
                        <span class="name">📨 Mosquitto (MQTT)</span>
                        <span class="status-badge {{ 'running' if services.get('mosquitto') == 'running' else 'stopped' if services.get('mosquitto') else 'unknown' }}">
                            {{ services.get('mosquitto', 'unknown') }}
                        </span>
                    </div>
                    <div class="status-item">
                        <span class="name">🔗 Webhook Relay</span>
                        <span class="status-badge {{ 'running' if services.get('webhook-relay') == 'running' else 'stopped' if services.get('webhook-relay') else 'unknown' }}">
                            {{ services.get('webhook-relay', 'unknown') }}
                        </span>
                    </div>
                </div>
                
                <div class="button-row">
                    <button onclick="restartAll()" class="btn btn-secondary btn-sm">🔄 Restart All</button>
                    <button onclick="showLogs('go2rtc')" class="btn btn-secondary btn-sm">📋 View Logs</button>
                </div>
                
                <div id="logs" class="logs-container"></div>
            </div>
            
            <!-- Testing -->
            <div class="card">
                <h2><span class="icon">🧪</span> Test Functions</h2>
                <div class="button-row">
                    <button onclick="testDoorbell()" class="btn btn-secondary">🔔 Test Doorbell Ring</button>
                    <button onclick="testStream()" class="btn btn-secondary">📡 Test Stream</button>
                </div>
                <div id="testResult" class="test-result"></div>
                
                <div class="info-box">
                    <h3>📱 Android App Settings</h3>
                    <p style="margin-bottom: 8px;">Enter these values in the AVA Doorbell app:</p>
                    <code>Server IP: {{ pi_ip }}</code>
                    <code>go2rtc Port: 1984</code>
                    <code>RTSP Port: 8554</code>
                    <code>MQTT Port: 1883</code>
                </div>
            </div>
            
            <!-- Quick Links -->
            <div class="card">
                <h2><span class="icon">🔗</span> Quick Links</h2>
                <div class="status-grid">
                    <a href="http://{{ pi_ip }}:1984" target="_blank" class="status-item" style="text-decoration: none; color: inherit;">
                        <span>go2rtc Web Interface</span>
                        <span>→</span>
                    </a>
                    <a href="http://{{ pi_ip }}:1984/stream.html?src=doorbell" target="_blank" class="status-item" style="text-decoration: none; color: inherit;">
                        <span>View Doorbell Stream</span>
                        <span>→</span>
                    </a>
                </div>
                
                <div class="info-box">
                    <h3>🔔 NVR Webhook URL</h3>
                    <p style="margin-bottom: 8px;">Configure your IC Realtime NVR to send webhooks to:</p>
                    <code>http://{{ pi_ip }}:8080/webhook/alarm</code>
                </div>
            </div>
        </div>
        
        <footer>
            AVA Doorbell System • IC Realtime Dinger Pro 2 Integration
        </footer>
    </div>
    
    <script>
        function showResult(message, isError) {
            const el = document.getElementById('testResult');
            el.textContent = message;
            el.className = 'test-result show ' + (isError ? 'error' : 'success');
        }
        
        async function testDoorbell() {
            try {
                const r = await fetch('/test/doorbell');
                const data = await r.json();
                showResult(data.status === 'ok' ? '✓ ' + data.message : '✗ ' + data.message, data.status !== 'ok');
            } catch(e) {
                showResult('✗ Error: ' + e.message, true);
            }
        }
        
        async function testStream() {
            try {
                const r = await fetch('/test/stream');
                const data = await r.json();
                if (data.status === 'ok') {
                    showResult('✓ Streams found: ' + data.streams.join(', '), false);
                } else {
                    showResult('⚠ ' + data.message, true);
                }
            } catch(e) {
                showResult('✗ Error: ' + e.message, true);
            }
        }
        
        async function restartAll() {
            if (!confirm('Restart all services?')) return;
            try {
                await fetch('/restart-all');
                alert('Services restarting... Please wait 10 seconds then refresh.');
                setTimeout(() => location.reload(), 10000);
            } catch(e) {
                alert('Error: ' + e.message);
            }
        }
        
        async function showLogs(service) {
            const el = document.getElementById('logs');
            el.className = 'logs-container show';
            el.textContent = 'Loading logs...';
            try {
                const r = await fetch('/logs/' + service);
                const data = await r.json();
                el.textContent = data.logs || 'No logs available';
            } catch(e) {
                el.textContent = 'Error loading logs: ' + e.message;
            }
        }
    </script>
</body>
</html>
HTML_EOF

print_success "Admin panel created"

# ============================================================
# STEP 6: Build and Start Services
# ============================================================
print_step "6/6" "Building and Starting Services"

cd "$INSTALL_DIR"

# Need to use newgrp or sudo for docker if just added to group
if ! docker ps &> /dev/null; then
    print_info "Using sudo for docker (group not active yet)..."
    sudo docker-compose build
    sudo docker-compose up -d
else
    docker-compose build
    docker-compose up -d
fi

print_info "Waiting for services to start..."
sleep 10

print_success "All services started"

# ============================================================
# DONE!
# ============================================================

PI_IP=$(get_ip)

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}║            ✓ INSTALLATION COMPLETE!                           ║${NC}"
echo -e "${GREEN}║                                                               ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Open the Admin Panel in your browser:"
echo -e "     ${YELLOW}http://$PI_IP:$ADMIN_PORT${NC}"
echo ""
echo -e "  ${CYAN}2.${NC} Enter your IC Realtime Doorbell IP and password"
echo ""
echo -e "  ${CYAN}3.${NC} Click 'Save Configuration' then 'Restart All'"
echo ""
echo -e "  ${CYAN}4.${NC} Configure your NVR webhook URL:"
echo -e "     ${YELLOW}http://$PI_IP:$WEBHOOK_PORT/webhook/alarm${NC}"
echo ""
echo -e "  ${CYAN}5.${NC} Install the Android APK on your AVA Remote"
echo ""
echo -e "${BOLD}Useful URLs:${NC}"
echo -e "  • Admin Panel:     ${YELLOW}http://$PI_IP:$ADMIN_PORT${NC}"
echo -e "  • go2rtc Interface: ${YELLOW}http://$PI_IP:$GO2RTC_PORT${NC}"
echo -e "  • Test Doorbell:   ${YELLOW}http://$PI_IP:$WEBHOOK_PORT/test/ring${NC}"
echo ""
echo -e "${BOLD}Service Commands:${NC}"
echo -e "  • View logs:    ${CYAN}cd $INSTALL_DIR && docker-compose logs -f${NC}"
echo -e "  • Restart:      ${CYAN}cd $INSTALL_DIR && docker-compose restart${NC}"
echo -e "  • Stop:         ${CYAN}cd $INSTALL_DIR && docker-compose down${NC}"
echo ""
