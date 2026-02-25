/**
 * AVA Doorbell v4.0 — Dashboard Module
 *
 * Service status cards, restart buttons, auto-refresh with backoff,
 * and system-info display (IP, uptime, version).
 */

import { fetchAPI, isServerReachable, getConsecutiveFailures } from './api.js';
import { showToast } from '../shared/toast.js';
import { showConfirm } from '../shared/confirm.js';

/**
 * Fetch /api/status and update every status card and system-info field.
 */
const SERVICE_LABELS = {
    go2rtc: 'go2rtc',
    alarm_scanner: 'Alarm Scanner',
    ava_talk: 'Talk Relay',
    mosquitto: 'MQTT',
    smbd: 'Samba',
};

export async function refreshStatus() {
    try {
        const response = await fetchAPI('/api/status');
        const data = await response.json();

        // Render service status cards into the grid
        const grid = document.getElementById('statusGrid');
        if (grid) {
            grid.innerHTML = Object.entries(SERVICE_LABELS).map(([key, label]) => {
                const online = !!data[key];
                return `<div class="status-card">
                    <div class="status-dot ${online ? 'online' : 'offline'}"></div>
                    <div class="status-info">
                        <h3>${label}</h3>
                        <p>${online ? 'Online' : 'Offline'}</p>
                    </div>
                </div>`;
            }).join('');
        }

        const piIp = document.getElementById('pi-ip');
        const uptime = document.getElementById('system-uptime');
        const updated = document.getElementById('last-updated');
        if (piIp) piIp.textContent = data.pi_ip || 'Unknown';
        if (uptime) uptime.textContent = data.uptime || '--';
        if (updated) updated.textContent = new Date().toLocaleTimeString();
    } catch (error) {
        console.error('Status fetch error:', error);
    }
}

/**
 * Recursive scheduler — backs off when the server is unreachable.
 * Normal interval: 10 s.  Unreachable: 10 s -> 20 s -> 30 s (capped).
 */
function scheduleStatusRefresh() {
    const delay = isServerReachable()
        ? 10000
        : Math.min(10000 * (getConsecutiveFailures() + 1), 30000);

    const countdown = document.getElementById('retryCountdown');
    if (!isServerReachable() && countdown) {
        countdown.textContent = `(retry in ${(delay / 1000).toFixed(0)}s)`;
    }

    setTimeout(async () => {
        await refreshStatus();
        scheduleStatusRefresh();
    }, delay);
}

/**
 * Wire up dashboard buttons and kick off the first status fetch + polling.
 */
export function initDashboard() {
    document.getElementById('refreshStatusBtn').addEventListener('click', refreshStatus);

    document.getElementById('restartAllBtn').addEventListener('click', async () => {
        if (await showConfirm('Restart Services', 'Are you sure you want to restart all services? This will temporarily disconnect cameras.')) {
            try {
                const response = await fetchAPI('/api/restart-all', { method: 'POST' });
                if (response.ok) {
                    showToast('Services restarting...', 'success');
                    setTimeout(refreshStatus, 3000);
                }
            } catch (error) {
                showToast('Error restarting services', 'error');
            }
        }
    });

    // Initial fetch + start polling loop
    refreshStatus();
    scheduleStatusRefresh();
}
