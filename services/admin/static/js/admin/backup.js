/**
 * AVA Doorbell v4.0 — Backup & Restore Module
 *
 * Download config backup, upload restore with confirmation.
 */

import { fetchAPI } from './api.js';
import { showToast } from '../shared/toast.js';
import { showConfirm } from '../shared/confirm.js';

export function initBackup() {
    const downloadBtn = document.getElementById('downloadBackupBtn');
    if (downloadBtn) downloadBtn.addEventListener('click', downloadBackup);

    const restoreInput = document.getElementById('restoreFileInput');
    if (restoreInput) restoreInput.addEventListener('change', handleRestore);

    const restoreBtn = document.getElementById('restoreBackupBtn');
    if (restoreBtn) {
        restoreBtn.addEventListener('click', () => restoreInput?.click());
    }
}

async function downloadBackup() {
    try {
        const resp = await fetchAPI('/api/backup');
        const blob = await resp.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `ava-backup-${new Date().toISOString().slice(0, 10)}.json`;
        document.body.appendChild(a);
        a.click();
        a.remove();
        URL.revokeObjectURL(url);
        showToast('Backup downloaded', 'success');
    } catch (e) {
        showToast('Backup download failed', 'error');
    }
}

async function handleRestore(e) {
    const file = e.target.files[0];
    if (!file) return;

    if (!await showConfirm(
        'Restore Configuration',
        'This will replace your current configuration. Services will restart. Continue?',
        { danger: true, confirmText: 'Restore' }
    )) {
        e.target.value = '';
        return;
    }

    try {
        const text = await file.text();
        JSON.parse(text); // Validate JSON

        const formData = new FormData();
        formData.append('file', file);

        const resp = await fetchAPI('/api/restore', {
            method: 'POST',
            body: formData,
        });

        if (resp.ok) {
            showToast('Configuration restored. Reloading...', 'success');
            setTimeout(() => location.reload(), 2000);
        } else {
            showToast('Restore failed', 'error');
        }
    } catch (err) {
        showToast('Invalid backup file', 'error');
    }

    e.target.value = '';
}
