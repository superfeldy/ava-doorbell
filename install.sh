#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                                                                           ║
# ║       █████╗ ██╗   ██╗ █████╗     ██████╗  ██████╗  ██████╗ ██████╗       ║
# ║      ██╔══██╗██║   ██║██╔══██╗    ██╔══██╗██╔═══██╗██╔═══██╗██╔══██╗      ║
# ║      ███████║██║   ██║███████║    ██║  ██║██║   ██║██║   ██║██████╔╝      ║
# ║      ██╔══██║╚██╗ ██╔╝██╔══██║    ██║  ██║██║   ██║██║   ██║██╔══██╗      ║
# ║      ██║  ██║ ╚████╔╝ ██║  ██║    ██████╔╝╚██████╔╝╚██████╔╝██║  ██║      ║
# ║      ╚═╝  ╚═╝  ╚═══╝  ╚═╝  ╚═╝    ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝      ║
# ║                                                                           ║
# ║              ONE-CLICK INSTALLER FOR IC REALTIME + AVA REMOTE             ║
# ║                                                                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# This script sets up everything automatically. After running it, just open
# the Admin Panel in your browser to configure your cameras.
#

set -e

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════
INSTALL_DIR="$HOME/ava-doorbell"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' C='\033[0;36m' W='\033[1;37m' N='\033[0m'

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
banner() {
    clear
    echo -e "${C}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                      AVA DOORBELL SYSTEM INSTALLER                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${N}"
}

step() { echo -e "\n${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n${W}  $1${N}\n${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"; }
ok() { echo -e "${G}  ✓ $1${N}"; }
info() { echo -e "${C}  → $1${N}"; }
warn() { echo -e "${Y}  ⚠ $1${N}"; }
err() { echo -e "${R}  ✗ $1${N}"; }

get_ip() { hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"; }

# ═══════════════════════════════════════════════════════════════════════════
# MAIN INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════
banner

PI_IP=$(get_ip)
echo -e "  ${W}Raspberry Pi IP:${N} ${G}$PI_IP${N}"
echo ""
echo "  This will install:"
echo "    • Docker & Docker Compose"
echo "    • go2rtc (video streaming)"
echo "    • Mosquitto (notifications)"  
echo "    • Admin Panel (web configuration)"
echo ""
echo -e "  ${Y}Press Enter to start installation...${N}"
read

# ═══════════════════════════════════════════════════════════════════════════
step "STEP 1/5: System Update"
# ═══════════════════════════════════════════════════════════════════════════
info "Updating packages..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
ok "System updated"

# ═══════════════════════════════════════════════════════════════════════════
step "STEP 2/5: Installing Docker"
# ═══════════════════════════════════════════════════════════════════════════
if command -v docker &>/dev/null; then
    ok "Docker already installed"
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh >/dev/null 2>&1
    rm /tmp/get-docker.sh
    ok "Docker installed"
fi

if ! groups | grep -q docker; then
    sudo usermod -aG docker $USER
    warn "Added to docker group - will need re-login"
fi

if ! command -v docker-compose &>/dev/null; then
    sudo apt-get install -y docker-compose -qq
fi
ok "Docker Compose ready"

# ═══════════════════════════════════════════════════════════════════════════
step "STEP 3/5: Creating Project Files"
# ═══════════════════════════════════════════════════════════════════════════
mkdir -p "$INSTALL_DIR"/{config,webhook,admin/templates}
cd "$INSTALL_DIR"

PI_IP=$(get_ip)

# --- docker-compose.yml ---
cat > docker-compose.yml << 'DCOMPOSE'
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
    mem_limit: 64m

  webhook:
    build: ./webhook
    container_name: webhook
    restart: unless-stopped
    network_mode: host
    depends_on:
      - mosquitto
    mem_limit: 64m

  admin:
    build: ./admin
    container_name: admin
    restart: unless-stopped
    ports:
      - "8888:8888"
    volumes:
      - ./config:/config
      - /var/run/docker.sock:/var/run/docker.sock
    mem_limit: 64m
DCOMPOSE

# --- go2rtc.yaml (default) ---
cat > config/go2rtc.yaml << GORTC
# AVA Doorbell - go2rtc configuration
# Configure via Admin Panel at http://$PI_IP:8888

streams:
  doorbell:
    - "rtsp://admin:admin@192.168.1.1:554/cam/realmonitor?channel=1&subtype=0"
  doorbell_sub:
    - "rtsp://admin:admin@192.168.1.1:554/cam/realmonitor?channel=1&subtype=1"

webrtc:
  candidates:
    - "$PI_IP:8555"
  
api:
  listen: ":1984"
  origin: "*"

rtsp:
  listen: ":8554"

log:
  level: info
GORTC

# --- mosquitto.conf ---
cat > config/mosquitto.conf << 'MQTT'
listener 1883
protocol mqtt
listener 9001
protocol websockets
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
MQTT

# --- webhook/Dockerfile ---
cat > webhook/Dockerfile << 'WHDOCKER'
FROM python:3.11-alpine
RUN pip install --no-cache-dir flask paho-mqtt
WORKDIR /app
COPY server.py .
EXPOSE 8080
CMD ["python", "-u", "server.py"]
WHDOCKER

# --- webhook/server.py ---
cat > webhook/server.py << 'WHSERVER'
from flask import Flask, request, jsonify
import paho.mqtt.client as mqtt
import json, threading, time

app = Flask(__name__)
mqtt_client = mqtt.Client()
connected = threading.Event()

def mqtt_connect():
    while True:
        try:
            mqtt_client.connect("localhost", 1883, 60)
            mqtt_client.loop_start()
            connected.set()
            print("MQTT connected")
            break
        except: time.sleep(3)

threading.Thread(target=mqtt_connect, daemon=True).start()

def publish(topic, data):
    if connected.is_set():
        mqtt_client.publish(f"doorbell/{topic}", json.dumps(data), qos=1)

@app.route('/health')
def health():
    return jsonify({"status": "ok", "mqtt": connected.is_set()})

@app.route('/webhook/doorbell', methods=['GET','POST'])
def doorbell():
    print("🔔 DOORBELL RING!")
    publish('ring', {'event': 'ring', 'time': time.time()})
    return jsonify({"status": "ok"})

@app.route('/webhook/motion', methods=['GET','POST'])
def motion():
    publish('motion', {'event': 'motion', 'time': time.time()})
    return jsonify({"status": "ok"})

@app.route('/webhook/alarm', methods=['GET','POST'])
def alarm():
    data = request.json or dict(request.args) or {}
    atype = str(data.get('type', data.get('alarmType', ''))).lower()
    if any(x in atype for x in ['ring', 'doorbell', 'button', 'call']):
        print("🔔 DOORBELL via alarm!")
        publish('ring', {'event': 'ring', 'time': time.time()})
    elif 'motion' in atype:
        publish('motion', {'event': 'motion', 'time': time.time()})
    return jsonify({"status": "ok"})

@app.route('/test/ring')
def test_ring():
    publish('ring', {'event': 'ring', 'time': time.time(), 'test': True})
    print("🧪 Test ring sent")
    return jsonify({"status": "ok", "message": "Test ring sent!"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
WHSERVER

ok "Core files created"

# ═══════════════════════════════════════════════════════════════════════════
step "STEP 4/5: Creating Admin Panel"
# ═══════════════════════════════════════════════════════════════════════════

# --- admin/Dockerfile ---
cat > admin/Dockerfile << 'ADOCKER'
FROM python:3.11-alpine
RUN apk add --no-cache docker-cli curl && pip install --no-cache-dir flask pyyaml
WORKDIR /app
COPY . .
EXPOSE 8888
CMD ["python", "-u", "app.py"]
ADOCKER

# --- admin/app.py ---
cat > admin/app.py << 'ADMINPY'
#!/usr/bin/env python3
import os, yaml, subprocess
from flask import Flask, render_template, request, jsonify, redirect

app = Flask(__name__)
CONFIG_FILE = '/config/go2rtc.yaml'

def get_ip():
    try: return subprocess.check_output(['hostname', '-I']).decode().split()[0]
    except: return 'localhost'

def load_config():
    try:
        with open(CONFIG_FILE) as f: return yaml.safe_load(f)
    except: return {'streams': {}}

def save_config(cfg):
    with open(CONFIG_FILE, 'w') as f: yaml.dump(cfg, f, default_flow_style=False)

def parse_rtsp(url):
    """Extract user, pass, ip from rtsp://user:pass@ip:port/..."""
    try:
        url = url.replace('rtsp://', '')
        auth, rest = url.split('@')
        user, pwd = auth.split(':')
        ip = rest.split(':')[0]
        return user, pwd, ip
    except: return 'admin', '', ''

def make_rtsp(user, pwd, ip, channel=1, sub=0):
    return f"rtsp://{user}:{pwd}@{ip}:554/cam/realmonitor?channel={channel}&subtype={sub}"

def get_services():
    try:
        out = subprocess.check_output(['docker', 'ps', '--format', '{{.Names}}:{{.Status}}'], timeout=5).decode()
        return {l.split(':')[0]: 'running' if 'Up' in l else 'stopped' for l in out.strip().split('\n') if ':' in l}
    except: return {}

@app.route('/')
def index():
    cfg = load_config()
    streams = cfg.get('streams', {})
    
    # Parse doorbell settings
    doorbell_url = streams.get('doorbell', [''])[0] if isinstance(streams.get('doorbell'), list) else ''
    user, pwd, ip = parse_rtsp(doorbell_url) if doorbell_url else ('admin', '', '')
    
    pi_ip = get_ip()
    services = get_services()
    saved = request.args.get('saved')
    
    return render_template('index.html', 
        doorbell_ip=ip, doorbell_user=user, doorbell_pass=pwd,
        pi_ip=pi_ip, services=services, saved=saved,
        streams=list(streams.keys()))

@app.route('/save', methods=['POST'])
def save():
    ip = request.form.get('doorbell_ip', '').strip()
    user = request.form.get('doorbell_user', 'admin').strip()
    pwd = request.form.get('doorbell_pass', '').strip()
    nvr_ip = request.form.get('nvr_ip', '').strip()
    nvr_user = request.form.get('nvr_user', 'admin').strip()
    nvr_pwd = request.form.get('nvr_pass', '').strip()
    
    pi_ip = get_ip()
    
    cfg = {
        'streams': {},
        'webrtc': {'candidates': [f'{pi_ip}:8555']},
        'api': {'listen': ':1984', 'origin': '*'},
        'rtsp': {'listen': ':8554'},
        'log': {'level': 'info'}
    }
    
    if ip and pwd:
        cfg['streams']['doorbell'] = [make_rtsp(user, pwd, ip, 1, 0)]
        cfg['streams']['doorbell_sub'] = [make_rtsp(user, pwd, ip, 1, 1)]
    
    if nvr_ip and nvr_pwd:
        for i, name in enumerate(['front', 'back', 'garage', 'side'], 1):
            cfg['streams'][f'camera_{name}'] = [make_rtsp(nvr_user, nvr_pwd, nvr_ip, i, 0)]
            cfg['streams'][f'camera_{name}_sub'] = [make_rtsp(nvr_user, nvr_pwd, nvr_ip, i, 1)]
    
    save_config(cfg)
    return redirect('/?saved=1')

@app.route('/restart')
def restart():
    try:
        subprocess.run(['docker', 'restart', 'go2rtc'], timeout=30)
        return jsonify({'status': 'ok'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/restart-all')
def restart_all():
    try:
        subprocess.run(['docker', 'restart', 'go2rtc', 'mosquitto', 'webhook'], timeout=60)
        return jsonify({'status': 'ok'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/test/ring')
def test_ring():
    try:
        import urllib.request
        urllib.request.urlopen('http://localhost:8080/test/ring', timeout=5)
        return jsonify({'status': 'ok', 'message': 'Test ring sent!'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/test/stream')
def test_stream():
    try:
        import urllib.request
        resp = urllib.request.urlopen('http://localhost:1984/api/streams', timeout=5)
        data = resp.read().decode()
        return jsonify({'status': 'ok', 'streams': list(eval(data).keys())})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

@app.route('/logs/<service>')
def logs(service):
    try:
        out = subprocess.check_output(['docker', 'logs', '--tail', '50', service], 
                                     stderr=subprocess.STDOUT, timeout=10).decode()
        return jsonify({'status': 'ok', 'logs': out})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8888)
ADMINPY

# --- admin/templates/index.html ---
cat > admin/templates/index.html << 'ADMINHTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AVA Doorbell - Admin</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
    min-height: 100vh;
    color: #e4e4e7;
    padding: 20px;
}
.container { max-width: 900px; margin: 0 auto; }
header {
    text-align: center;
    padding: 30px 0;
    border-bottom: 1px solid #333;
    margin-bottom: 30px;
}
h1 {
    font-size: 2.2em;
    background: linear-gradient(90deg, #e94560, #ff6b6b);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
}
.subtitle { color: #888; margin-top: 8px; }
.grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(380px, 1fr));
    gap: 20px;
}
.card {
    background: rgba(255,255,255,0.05);
    border-radius: 16px;
    padding: 24px;
    border: 1px solid rgba(255,255,255,0.1);
}
.card h2 {
    font-size: 1.2em;
    margin-bottom: 20px;
    display: flex;
    align-items: center;
    gap: 10px;
}
.form-group { margin-bottom: 16px; }
label {
    display: block;
    margin-bottom: 6px;
    color: #aaa;
    font-size: 0.9em;
}
input {
    width: 100%;
    padding: 12px 16px;
    border: 1px solid #333;
    border-radius: 8px;
    background: rgba(0,0,0,0.3);
    color: #fff;
    font-size: 1em;
}
input:focus {
    outline: none;
    border-color: #e94560;
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
.btn-sm { padding: 8px 16px; font-size: 0.9em; }
.status-grid { display: grid; gap: 10px; }
.status-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    background: rgba(0,0,0,0.2);
    border-radius: 8px;
}
.badge {
    padding: 4px 12px;
    border-radius: 20px;
    font-size: 0.85em;
}
.badge.running { background: rgba(34, 197, 94, 0.2); color: #4ade80; }
.badge.stopped { background: rgba(239, 68, 68, 0.2); color: #f87171; }
.info-box {
    background: rgba(59, 130, 246, 0.1);
    border: 1px solid rgba(59, 130, 246, 0.3);
    border-radius: 8px;
    padding: 16px;
    margin-top: 16px;
}
.info-box h3 { color: #60a5fa; margin-bottom: 10px; font-size: 0.95em; }
.info-box code {
    display: block;
    background: rgba(0,0,0,0.3);
    padding: 8px 12px;
    border-radius: 4px;
    font-family: monospace;
    margin: 4px 0;
    word-break: break-all;
}
.alert {
    padding: 16px;
    border-radius: 8px;
    margin-bottom: 20px;
    background: rgba(34, 197, 94, 0.1);
    border: 1px solid rgba(34, 197, 94, 0.3);
    color: #4ade80;
}
.btn-row { display: flex; gap: 10px; margin-top: 20px; flex-wrap: wrap; }
#result {
    margin-top: 12px;
    padding: 12px;
    border-radius: 8px;
    display: none;
}
#result.show { display: block; }
#result.ok { background: rgba(34, 197, 94, 0.1); color: #4ade80; }
#result.err { background: rgba(239, 68, 68, 0.1); color: #f87171; }
#logs {
    background: #000;
    border-radius: 8px;
    padding: 12px;
    max-height: 200px;
    overflow-y: auto;
    font-family: monospace;
    font-size: 0.8em;
    white-space: pre-wrap;
    color: #4ade80;
    margin-top: 12px;
    display: none;
}
hr { border-color: #333; margin: 20px 0; }
a.link {
    color: inherit;
    text-decoration: none;
    display: flex;
    justify-content: space-between;
    align-items: center;
}
footer {
    text-align: center;
    padding: 30px;
    color: #666;
    margin-top: 30px;
}
</style>
</head>
<body>
<div class="container">
<header>
<h1>🔔 AVA Doorbell</h1>
<p class="subtitle">Admin Configuration Panel</p>
</header>

{% if saved %}
<div class="alert">✓ Settings saved! Click "Restart Services" to apply changes.</div>
{% endif %}

<div class="grid">
<!-- Camera Config -->
<div class="card">
<h2>📹 Camera Configuration</h2>
<form method="POST" action="/save">
<div class="form-group">
<label>Doorbell IP Address</label>
<input type="text" name="doorbell_ip" value="{{ doorbell_ip }}" placeholder="192.168.1.50">
</div>
<div class="form-group">
<label>Doorbell Username</label>
<input type="text" name="doorbell_user" value="{{ doorbell_user }}" placeholder="admin">
</div>
<div class="form-group">
<label>Doorbell Password</label>
<input type="password" name="doorbell_pass" value="{{ doorbell_pass }}" placeholder="Enter password">
</div>

<hr>

<div class="form-group">
<label>NVR IP Address (Optional)</label>
<input type="text" name="nvr_ip" placeholder="192.168.1.60">
</div>
<div class="form-group">
<label>NVR Username</label>
<input type="text" name="nvr_user" value="admin" placeholder="admin">
</div>
<div class="form-group">
<label>NVR Password</label>
<input type="password" name="nvr_pass" placeholder="Enter password">
</div>

<div class="btn-row">
<button type="submit" class="btn btn-primary">💾 Save Configuration</button>
</div>
</form>
</div>

<!-- Status -->
<div class="card">
<h2>⚡ Service Status</h2>
<div class="status-grid">
<div class="status-item">
<span>🎥 go2rtc (Streaming)</span>
<span class="badge {{ 'running' if services.get('go2rtc')=='running' else 'stopped' }}">
{{ services.get('go2rtc', 'unknown') }}
</span>
</div>
<div class="status-item">
<span>📨 Mosquitto (MQTT)</span>
<span class="badge {{ 'running' if services.get('mosquitto')=='running' else 'stopped' }}">
{{ services.get('mosquitto', 'unknown') }}
</span>
</div>
<div class="status-item">
<span>🔗 Webhook Relay</span>
<span class="badge {{ 'running' if services.get('webhook')=='running' else 'stopped' }}">
{{ services.get('webhook', 'unknown') }}
</span>
</div>
</div>
<div class="btn-row">
<button onclick="restartAll()" class="btn btn-secondary btn-sm">🔄 Restart Services</button>
<button onclick="showLogs()" class="btn btn-secondary btn-sm">📋 View Logs</button>
</div>
<div id="logs"></div>
</div>

<!-- Testing -->
<div class="card">
<h2>🧪 Test & Links</h2>
<div class="btn-row">
<button onclick="testRing()" class="btn btn-secondary">🔔 Test Doorbell</button>
<button onclick="testStream()" class="btn btn-secondary">📡 Test Streams</button>
</div>
<div id="result"></div>

<div class="info-box">
<h3>📱 Android App Settings</h3>
<code>Server IP: {{ pi_ip }}</code>
<code>RTSP Port: 8554</code>
<code>MQTT Port: 1883</code>
</div>

<div class="info-box">
<h3>🔗 Quick Links</h3>
<div class="status-grid" style="margin-top:10px">
<a href="http://{{ pi_ip }}:1984" target="_blank" class="status-item link">
<span>go2rtc Web Interface</span><span>→</span>
</a>
<a href="http://{{ pi_ip }}:1984/stream.html?src=doorbell" target="_blank" class="status-item link">
<span>View Doorbell Stream</span><span>→</span>
</a>
</div>
</div>

<div class="info-box">
<h3>🔔 NVR Webhook URL</h3>
<p style="margin-bottom:8px;font-size:0.9em">Configure your IC Realtime NVR to send webhooks to:</p>
<code>http://{{ pi_ip }}:8080/webhook/alarm</code>
</div>
</div>

<!-- Streams -->
<div class="card">
<h2>📺 Configured Streams</h2>
{% if streams %}
<div class="status-grid">
{% for s in streams %}
<div class="status-item">
<span>{{ s }}</span>
<a href="http://{{ pi_ip }}:1984/stream.html?src={{ s }}" target="_blank" class="btn btn-secondary btn-sm">View</a>
</div>
{% endfor %}
</div>
{% else %}
<p style="color:#888">No streams configured. Enter camera details above.</p>
{% endif %}
</div>
</div>

<footer>AVA Doorbell System • IC Realtime Dinger Pro 2</footer>
</div>

<script>
function showResult(msg, ok) {
    const el = document.getElementById('result');
    el.textContent = msg;
    el.className = 'show ' + (ok ? 'ok' : 'err');
}

async function testRing() {
    try {
        const r = await fetch('/test/ring');
        const d = await r.json();
        showResult(d.status=='ok' ? '✓ '+d.message : '✗ '+d.message, d.status=='ok');
    } catch(e) { showResult('✗ '+e.message, false); }
}

async function testStream() {
    try {
        const r = await fetch('/test/stream');
        const d = await r.json();
        showResult(d.status=='ok' ? '✓ Streams: '+d.streams.join(', ') : '✗ '+d.message, d.status=='ok');
    } catch(e) { showResult('✗ '+e.message, false); }
}

async function restartAll() {
    if (!confirm('Restart all services?')) return;
    showResult('Restarting...', true);
    await fetch('/restart-all');
    setTimeout(() => location.reload(), 5000);
}

async function showLogs() {
    const el = document.getElementById('logs');
    el.style.display = el.style.display === 'none' ? 'block' : 'none';
    if (el.style.display === 'block') {
        el.textContent = 'Loading...';
        try {
            const r = await fetch('/logs/go2rtc');
            const d = await r.json();
            el.textContent = d.logs || 'No logs';
        } catch(e) { el.textContent = 'Error: '+e.message; }
    }
}
</script>
</body>
</html>
ADMINHTML

ok "Admin Panel created"

# ═══════════════════════════════════════════════════════════════════════════
step "STEP 5/5: Building & Starting Services"
# ═══════════════════════════════════════════════════════════════════════════
cd "$INSTALL_DIR"

info "Building containers (this may take a few minutes)..."
if sudo docker-compose build --quiet 2>/dev/null; then
    ok "Containers built"
else
    warn "Build needs sudo, using sudo..."
    sudo docker-compose build --quiet
    ok "Containers built"
fi

info "Starting services..."
sudo docker-compose up -d

info "Waiting for services to start..."
sleep 8

ok "All services started!"

# ═══════════════════════════════════════════════════════════════════════════
# COMPLETE!
# ═══════════════════════════════════════════════════════════════════════════
PI_IP=$(get_ip)

echo ""
echo -e "${G}╔═══════════════════════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║                                                                           ║${N}"
echo -e "${G}║                    ✓ INSTALLATION COMPLETE!                               ║${N}"
echo -e "${G}║                                                                           ║${N}"
echo -e "${G}╚═══════════════════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "${W}NEXT STEPS:${N}"
echo ""
echo -e "  ${C}1.${N} Open the Admin Panel in your browser:"
echo ""
echo -e "         ${Y}http://$PI_IP:8888${N}"
echo ""
echo -e "  ${C}2.${N} Enter your IC Realtime doorbell IP and password"
echo ""
echo -e "  ${C}3.${N} Click ${W}Save Configuration${N} then ${W}Restart Services${N}"
echo ""
echo -e "  ${C}4.${N} Configure your NVR to send webhooks to:"
echo ""
echo -e "         ${Y}http://$PI_IP:8080/webhook/alarm${N}"
echo ""
echo -e "  ${C}5.${N} Install the Android app on your AVA Remote"
echo ""
echo -e "${W}QUICK LINKS:${N}"
echo -e "  • Admin Panel:    ${C}http://$PI_IP:8888${N}"
echo -e "  • go2rtc:         ${C}http://$PI_IP:1984${N}"
echo -e "  • Test Doorbell:  ${C}http://$PI_IP:8080/test/ring${N}"
echo ""
echo -e "${W}COMMANDS:${N}"
echo -e "  • View logs:    ${C}cd $INSTALL_DIR && sudo docker-compose logs -f${N}"
echo -e "  • Restart:      ${C}cd $INSTALL_DIR && sudo docker-compose restart${N}"
echo ""
