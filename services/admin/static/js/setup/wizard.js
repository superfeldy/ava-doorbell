/**
 * AVA Doorbell v4.0 — Setup Wizard
 *
 * 8-step first-run setup: password, network, cameras, verify,
 * service health, Android app, complete.
 */

const steps = ['welcome', 'password', 'network', 'cameras', 'verify', 'services', 'app', 'complete'];
let currentStep = 0;
let piIp = '';  // Detected in network step, reused by later steps

/** Escape HTML to prevent XSS from server-provided data (camera names, IPs, etc). */
function esc(str) {
    const d = document.createElement('div');
    d.textContent = String(str ?? '');
    return d.innerHTML;
}

// ============================================================================
// Step Navigation
// ============================================================================

function showStep(index) {
    steps.forEach((id, i) => {
        const el = document.getElementById(`step-${id}`);
        if (el) el.classList.toggle('active', i === index);
    });

    document.querySelectorAll('.progress-dot').forEach((dot, i) => {
        dot.classList.toggle('active', i === index);
        dot.classList.toggle('completed', i < index);
    });

    const prevBtn = document.getElementById('prev-btn');
    const nextBtn = document.getElementById('next-btn');
    if (prevBtn) prevBtn.style.display = index === 0 ? 'none' : '';
    if (nextBtn) {
        nextBtn.textContent = index === steps.length - 1 ? 'Go to Dashboard' : 'Next';
    }

    currentStep = index;

    // Auto-run on-enter logic for certain steps
    if (steps[index] === 'services') checkServices();
    if (steps[index] === 'app') populateAppStep();
}

function nextStep() {
    if (currentStep === steps.length - 1) {
        window.location.href = '/login';
        return;
    }

    const stepId = steps[currentStep];
    const handler = stepHandlers[stepId];

    if (handler) {
        handler().then(ok => {
            if (ok) showStep(currentStep + 1);
        }).catch(err => {
            showError(err.message || 'An error occurred');
        });
    } else {
        showStep(currentStep + 1);
    }
}

function prevStep() {
    if (currentStep > 0) {
        showStep(currentStep - 1);
    }
}

// ============================================================================
// Step Handlers
// ============================================================================

const stepHandlers = {
    welcome: async () => true,

    password: async () => {
        const password = document.getElementById('setup-password').value;
        const confirm = document.getElementById('setup-password-confirm').value;

        if (!password || password.length < 6) {
            showError('Password must be at least 6 characters');
            return false;
        }
        if (password !== confirm) {
            showError('Passwords do not match');
            return false;
        }

        const resp = await fetch('/api/setup/password', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ password }),
        });

        if (!resp.ok) {
            const data = await resp.json();
            showError(data.detail || 'Failed to set password');
            return false;
        }

        return true;
    },

    network: async () => {
        showLoading('Detecting network...');

        const resp = await fetch('/api/setup/network', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({}),
        });

        hideLoading();

        if (!resp.ok) {
            showError('Network configuration failed');
            return false;
        }

        const data = await resp.json();
        piIp = data.pi_ip || '';

        const infoEl = document.getElementById('network-info');
        if (infoEl) {
            infoEl.innerHTML = `
                <p>Pi IP Address: <strong>${esc(data.pi_ip)}</strong></p>
                <p>SSL Certificate: <strong>${data.ssl_ready ? 'Ready' : 'Not available'}</strong></p>
            `;
        }

        const verifyIp = document.getElementById('verify-ip');
        if (verifyIp) verifyIp.textContent = data.pi_ip;

        return true;
    },

    cameras: async () => {
        const doorbellIp = document.getElementById('setup-doorbell-ip').value;
        const doorbellUser = document.getElementById('setup-doorbell-user').value || 'admin';
        const doorbellPass = document.getElementById('setup-doorbell-pass').value;
        const nvrIp = document.getElementById('setup-nvr-ip').value;
        const nvrUser = document.getElementById('setup-nvr-user').value || 'admin';
        const nvrPass = document.getElementById('setup-nvr-pass').value;

        const body = {};
        if (doorbellIp) {
            body.doorbell_ip = doorbellIp;
            body.doorbell_username = doorbellUser;
            body.doorbell_password = doorbellPass;
        }
        if (nvrIp) {
            body.nvr_ip = nvrIp;
            body.nvr_username = nvrUser;
            body.nvr_password = nvrPass;
        }

        if (!doorbellIp && !nvrIp) return true;

        showLoading('Connecting...');

        try {
            const resp = await fetch('/api/setup/cameras/scan', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
            });

            if (!resp.ok) {
                hideLoading();
                showError('Camera scan failed');
                return false;
            }

            const reader = resp.body.getReader();
            const decoder = new TextDecoder();
            let cameras = [];

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                const text = decoder.decode(value, { stream: true });
                for (const line of text.split('\n')) {
                    if (!line.startsWith('data: ')) continue;
                    try {
                        const event = JSON.parse(line.slice(6));

                        if (event.stage === 'complete') {
                            cameras = event.cameras || [];
                        } else if (event.stage === 'error' || event.stage === 'timeout') {
                            hideLoading();
                            showError(event.detail || 'Scan failed');
                            return false;
                        } else {
                            const pct = event.total > 0
                                ? ` (${event.current}/${event.total})`
                                : '';
                            updateLoading(`${event.detail}${pct}`);
                        }
                    } catch (e) { /* skip malformed lines */ }
                }
            }

            hideLoading();

            const resultEl = document.getElementById('camera-results');
            if (resultEl && cameras.length) {
                resultEl.innerHTML = cameras.map(cam =>
                    `<div class="camera-result">
                        <span class="camera-name">${esc(cam.name)}</span>
                        <span class="camera-type">${esc(cam.type)}</span>
                    </div>`
                ).join('');
            }

            loadVerifyPreviews(cameras);
            return true;

        } catch (err) {
            hideLoading();
            showError(err.message || 'Camera scan failed');
            return false;
        }
    },

    verify: async () => {
        showLoading('Saving configuration...');

        const resp = await fetch('/api/setup/complete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({}),
        });

        hideLoading();

        if (!resp.ok) {
            showError('Failed to complete setup');
            return false;
        }

        // Populate completion info
        const completeInfo = document.getElementById('complete-info');
        if (completeInfo) {
            const ip = esc(piIp || document.getElementById('verify-ip')?.textContent || 'your Pi IP');
            completeInfo.innerHTML = `
                <p>Dashboard: <a href="http://${ip}:5000">http://${ip}:5000</a></p>
                <p>Live View: <a href="http://${ip}:5000/view">http://${ip}:5000/view</a></p>
                <p>Login with the password you just set.</p>
            `;
        }

        return true;
    },

    // Services and app steps always allow advancing
    services: async () => true,
    app: async () => true,
};

// ============================================================================
// Device Test
// ============================================================================

async function testDevice(ip, username, password, statusEl) {
    if (!ip) {
        statusEl.textContent = '';
        return;
    }

    statusEl.className = 'device-status testing';
    statusEl.textContent = 'Testing...';

    try {
        const resp = await fetch('/api/setup/test-device', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ip, username, password }),
        });

        if (!resp.ok) {
            statusEl.className = 'device-status status-fail';
            statusEl.textContent = 'Error';
            return;
        }

        const result = await resp.json();

        if (!result.reachable) {
            statusEl.className = 'device-status status-fail';
            statusEl.textContent = `\u2717 Unreachable`;
        } else if (result.auth_ok === true) {
            statusEl.className = 'device-status status-ok';
            const dtype = result.device_type ? ` (${result.device_type})` : '';
            statusEl.textContent = `\u2713 Connected${dtype}`;  // textContent is safe
        } else if (result.auth_ok === false) {
            statusEl.className = 'device-status status-warn';
            statusEl.textContent = '\u26a0 Reachable, wrong credentials';
        } else {
            statusEl.className = 'device-status status-ok';
            statusEl.textContent = '\u2713 Reachable';
        }
    } catch (e) {
        statusEl.className = 'device-status status-fail';
        statusEl.textContent = 'Test failed';
    }
}

// ============================================================================
// Service Health Check
// ============================================================================

async function checkServices() {
    const listEl = document.getElementById('service-list');
    const actionsEl = document.getElementById('services-actions');
    const hintEl = document.getElementById('services-hint');
    if (!listEl) return;

    listEl.innerHTML = '<div class="status-row"><span>Checking services...</span></div>';

    try {
        const resp = await fetch('/api/health');
        const data = await resp.json();
        const services = data.services || {};

        let allOk = true;
        listEl.innerHTML = '';

        for (const [name, status] of Object.entries(services)) {
            const ok = status === 'active';
            if (!ok) allOk = false;
            const row = document.createElement('div');
            row.className = 'status-row';
            row.innerHTML = `
                <span class="status-name">${esc(name)}</span>
                <span class="${ok ? 'status-ok' : 'status-fail'}">${ok ? '\u2713 Running' : '\u2717 ' + esc(status)}</span>
            `;
            listEl.appendChild(row);
        }

        if (actionsEl) actionsEl.style.display = allOk ? 'none' : 'block';
        if (hintEl) hintEl.style.display = allOk ? 'none' : 'block';

    } catch (e) {
        listEl.innerHTML = '<div class="status-row"><span class="status-fail">Could not check services</span></div>';
        if (actionsEl) actionsEl.style.display = 'block';
        if (hintEl) hintEl.style.display = 'block';
    }
}

// ============================================================================
// App Step
// ============================================================================

function populateAppStep() {
    const ip = piIp || 'YOUR_PI_IP';
    const linkEl = document.getElementById('apk-link');
    if (linkEl) {
        const url = `http://${ip}:5000/app/download`;
        linkEl.href = url;
        linkEl.textContent = url;
    }
    const ipCell = document.getElementById('app-server-ip');
    if (ipCell) ipCell.textContent = ip;
}

// ============================================================================
// Camera Previews
// ============================================================================

function loadVerifyPreviews(cameras) {
    const container = document.getElementById('verify-previews');
    if (!container) return;

    container.innerHTML = '';
    cameras.forEach(cam => {
        const div = document.createElement('div');
        div.className = 'preview-card';
        div.innerHTML = `
            <img src="/api/frame.jpeg?src=${encodeURIComponent(cam.id)}" alt="${esc(cam.name)}" onerror="this.style.display='none'">
            <span>${esc(cam.name)}</span>
        `;
        container.appendChild(div);
    });
}

// ============================================================================
// UI Helpers
// ============================================================================

function showError(message) {
    const el = document.getElementById('setup-error');
    if (el) {
        el.textContent = message;
        el.style.display = 'block';
        setTimeout(() => { el.style.display = 'none'; }, 5000);
    }
}

function showLoading(text) {
    const el = document.getElementById('setup-loading');
    if (el) {
        el.querySelector('.loading-text').textContent = text || 'Loading...';
        el.style.display = 'flex';
    }
}

function updateLoading(text) {
    const el = document.getElementById('setup-loading');
    if (el) {
        const textEl = el.querySelector('.loading-text');
        if (textEl) textEl.textContent = text;
    }
}

function hideLoading() {
    const el = document.getElementById('setup-loading');
    if (el) el.style.display = 'none';
}

// ============================================================================
// Init
// ============================================================================

async function init() {
    try {
        const resp = await fetch('/api/setup/status');
        const status = await resp.json();

        if (status.setup_complete) {
            window.location.href = '/login';
            return;
        }

        if (status.has_password) {
            showStep(2); // network
        } else {
            showStep(0); // welcome
        }
    } catch (e) {
        showStep(0);
    }

    // Navigation buttons
    document.getElementById('next-btn')?.addEventListener('click', nextStep);
    document.getElementById('prev-btn')?.addEventListener('click', prevStep);

    // Skip camera setup
    document.getElementById('skip-cameras')?.addEventListener('click', () => {
        showStep(currentStep + 1);
    });

    // Device test buttons
    document.getElementById('test-doorbell')?.addEventListener('click', () => {
        testDevice(
            document.getElementById('setup-doorbell-ip').value,
            document.getElementById('setup-doorbell-user').value || 'admin',
            document.getElementById('setup-doorbell-pass').value,
            document.getElementById('doorbell-status'),
        );
    });

    document.getElementById('test-nvr')?.addEventListener('click', () => {
        testDevice(
            document.getElementById('setup-nvr-ip').value,
            document.getElementById('setup-nvr-user').value || 'admin',
            document.getElementById('setup-nvr-pass').value,
            document.getElementById('nvr-status'),
        );
    });

    // Retry services check
    document.getElementById('retry-services')?.addEventListener('click', checkServices);
}

document.addEventListener('DOMContentLoaded', init);
