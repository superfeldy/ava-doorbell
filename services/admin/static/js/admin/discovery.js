/**
 * AVA Doorbell v4.0 — Network Discovery Module
 *
 * Trigger network scan, display results, add discovered devices.
 */

import { fetchAPI } from './api.js';
import { showToast } from '../shared/toast.js';

export function initDiscovery() {
    const scanBtn = document.getElementById('scanNetworkBtn');
    if (scanBtn) scanBtn.addEventListener('click', runDiscovery);

    // Event delegation for dynamically-created Add buttons (avoids inline onclick XSS)
    const grid = document.getElementById('discoveryResults');
    if (grid) {
        grid.addEventListener('click', (e) => {
            const btn = e.target.closest('[data-action="add"]');
            if (!btn) return;
            const ip = btn.dataset.ip;
            if (ip) addDiscovered(ip, btn);
        });
    }
}

async function runDiscovery() {
    const btn = document.getElementById('scanNetworkBtn');
    const grid = document.getElementById('discoveryResults');
    if (!grid) return;

    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Scanning...';
    }

    try {
        const resp = await fetchAPI('/api/discover', { method: 'POST' });
        const data = await resp.json();

        if (data.devices && data.devices.length > 0) {
            grid.innerHTML = data.devices.map(dev => `
                <div class="discovery-card">
                    <div class="discovery-info">
                        <h4>${esc(dev.name || dev.ip)}</h4>
                        <p>${esc(dev.ip)}${dev.ports ? ' — ports: ' + dev.ports.join(', ') : ''}</p>
                    </div>
                    <button class="btn btn-sm btn-primary" data-action="add" data-ip="${esc(dev.ip)}">Add</button>
                </div>
            `).join('');
            showToast(`Found ${data.devices.length} devices`, 'success');
        } else {
            grid.innerHTML = '<p style="color:var(--text-muted);">No devices found on the network.</p>';
            showToast('No devices found', 'warning');
        }
    } catch (e) {
        showToast('Discovery failed', 'error');
    } finally {
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Scan Network';
        }
    }
}

async function addDiscovered(ip, btn) {
    if (btn) { btn.disabled = true; btn.textContent = 'Adding...'; }

    try {
        const resp = await fetchAPI('/api/discover-and-add', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ip }),
        });

        if (resp.ok) {
            const data = await resp.json();
            showToast(`Added ${data.cameras_added || 0} camera(s)`, 'success');
            if (btn) { btn.textContent = 'Added'; }
        } else {
            showToast('Failed to add device', 'error');
            if (btn) { btn.disabled = false; btn.textContent = 'Add'; }
        }
    } catch (e) {
        showToast('Error adding device', 'error');
        if (btn) { btn.disabled = false; btn.textContent = 'Add'; }
    }
}

function esc(str) {
    const d = document.createElement('div');
    d.textContent = str || '';
    return d.innerHTML;
}
