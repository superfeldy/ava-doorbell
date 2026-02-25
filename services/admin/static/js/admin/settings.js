/**
 * AVA Doorbell v4.0 — Settings Module
 *
 * Doorbell/NVR/notification settings forms, password change,
 * SMB config, auto-cycle settings.
 */

import { fetchAPI } from './api.js';
import { showToast } from '../shared/toast.js';

export function initSettings() {
    const saveBtn = document.getElementById('saveSettingsBtn');
    if (saveBtn) saveBtn.addEventListener('click', saveSettings);

    const passBtn = document.getElementById('changePasswordBtn');
    if (passBtn) passBtn.addEventListener('click', changePassword);

    const rerunBtn = document.getElementById('rerunSetupBtn');
    if (rerunBtn) rerunBtn.addEventListener('click', rerunSetup);

    loadSettings();
}

async function loadSettings() {
    try {
        const resp = await fetchAPI('/api/config/full');
        const config = await resp.json();

        // Doorbell
        setVal('setting-doorbell-ip', config.doorbell?.ip);
        setVal('setting-doorbell-user', config.doorbell?.username);
        setVal('setting-doorbell-pass', config.doorbell?.password);

        // NVR
        setVal('setting-nvr-ip', config.nvr?.ip);
        setVal('setting-nvr-user', config.nvr?.username);
        setVal('setting-nvr-pass', config.nvr?.password);
        setVal('setting-nvr-port', config.nvr?.rtsp_port);

        // Notifications
        setVal('setting-mqtt-topic', config.notifications?.mqtt_topic_ring);

        // SMB
        setChecked('setting-smb-enabled', config.smb?.enabled);

        // Auto-cycle
        setChecked('setting-autocycle-enabled', config.auto_cycle?.enabled);
        setVal('setting-autocycle-interval', config.auto_cycle?.interval_seconds);

    } catch (e) {
        console.error('Failed to load settings:', e);
    }
}

async function saveSettings() {
    const settings = {
        doorbell_ip: getVal('setting-doorbell-ip'),
        doorbell_username: getVal('setting-doorbell-user'),
        doorbell_password: getVal('setting-doorbell-pass'),
        nvr_ip: getVal('setting-nvr-ip'),
        nvr_username: getVal('setting-nvr-user'),
        nvr_password: getVal('setting-nvr-pass'),
        nvr_rtsp_port: getVal('setting-nvr-port'),
        mqtt_topic: getVal('setting-mqtt-topic'),
        smb_enabled: getChecked('setting-smb-enabled'),
        auto_cycle_enabled: getChecked('setting-autocycle-enabled'),
        auto_cycle_interval: parseInt(getVal('setting-autocycle-interval')) || 30,
    };

    try {
        const resp = await fetchAPI('/api/settings', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(settings),
        });

        if (resp.ok) {
            showToast('Settings saved', 'success');
        } else {
            const data = await resp.json();
            showToast(data.detail || 'Failed to save settings', 'error');
        }
    } catch (e) {
        showToast('Error saving settings', 'error');
    }
}

async function changePassword() {
    const current = getVal('setting-current-pass');
    const newPass = getVal('setting-new-pass');
    const confirm = getVal('setting-confirm-pass');

    if (!newPass || newPass.length < 6) {
        showToast('Password must be at least 6 characters', 'error');
        return;
    }
    if (newPass !== confirm) {
        showToast('Passwords do not match', 'error');
        return;
    }

    try {
        const resp = await fetchAPI('/api/password', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ old_password: current, new_password: newPass }),
        });

        if (resp.ok) {
            showToast('Password changed', 'success');
            setVal('setting-current-pass', '');
            setVal('setting-new-pass', '');
            setVal('setting-confirm-pass', '');
        } else {
            const data = await resp.json();
            showToast(data.detail || 'Failed to change password', 'error');
        }
    } catch (e) {
        showToast('Error changing password', 'error');
    }
}

async function rerunSetup() {
    const password = getVal('rerun-setup-pass');
    if (!password) {
        showToast('Enter your current password to confirm', 'error');
        return;
    }

    try {
        const resp = await fetchAPI('/api/rerun-setup', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ password }),
        });

        if (resp.ok) {
            window.location.href = '/setup';
        } else {
            const data = await resp.json();
            showToast(data.detail || 'Failed to re-enable setup', 'error');
        }
    } catch (e) {
        showToast('Error re-enabling setup wizard', 'error');
    }
}

function getVal(id) { return document.getElementById(id)?.value || ''; }
function setVal(id, val) { const el = document.getElementById(id); if (el) el.value = val || ''; }
function getChecked(id) { return document.getElementById(id)?.checked || false; }
function setChecked(id, val) { const el = document.getElementById(id); if (el) el.checked = !!val; }
