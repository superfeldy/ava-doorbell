/**
 * AVA Doorbell v4.0 — Camera Management Module
 *
 * Camera card grid, add/edit/delete, stream testing, NVR import.
 */

import { fetchAPI } from './api.js';
import { showToast } from '../shared/toast.js';
import { showConfirm } from '../shared/confirm.js';
import { maskPassword } from '../shared/utils.js';

let cameras = [];

export function initCameras() {
    const addBtn = document.getElementById('addCameraBtn');
    if (addBtn) addBtn.addEventListener('click', showAddCameraForm);

    const addNvrBtn = document.getElementById('addFromNvrBtn');
    if (addNvrBtn) addNvrBtn.addEventListener('click', addFromNvr);

    loadCameras();
}

async function loadCameras() {
    try {
        const resp = await fetchAPI('/api/cameras');
        cameras = await resp.json();
        renderCameras();
    } catch (e) {
        console.error('Failed to load cameras:', e);
    }
}

function renderCameras() {
    const grid = document.getElementById('cameraGrid');
    if (!grid) return;

    if (cameras.length === 0) {
        grid.innerHTML = '<p style="color:var(--text-muted);font-size:14px;">No cameras configured. Add one manually or scan your NVR.</p>';
        return;
    }

    grid.innerHTML = cameras.map(cam => `
        <div class="camera-card" data-id="${cam.id}">
            <img class="camera-thumb" src="/api/frame.jpeg?src=${cam.id}&t=${Date.now()}"
                 alt="${esc(cam.name)}" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">
            <div class="camera-thumb-placeholder" style="display:none">No preview</div>
            <div class="camera-header">
                <span class="camera-name">${esc(cam.name)}</span>
                <span class="camera-badge">${cam.type || 'rtsp'}</span>
            </div>
            <div class="camera-info">ID: ${esc(cam.id)}</div>
            <div class="camera-url">${maskPassword(cam.url || '')}</div>
            <div class="camera-actions">
                <button class="btn btn-sm btn-secondary" onclick="window._editCamera('${cam.id}')">Edit</button>
                <button class="btn btn-sm btn-secondary" onclick="window._testCamera('${cam.id}')">Test</button>
                <button class="btn btn-sm btn-danger" onclick="window._deleteCamera('${cam.id}')">Delete</button>
            </div>
        </div>
    `).join('');
}

function showAddCameraForm() {
    const backdrop = document.createElement('div');
    backdrop.className = 'modal-backdrop show';
    backdrop.innerHTML = `
        <div class="modal" style="max-width:500px;">
            <div class="modal-title">Add Camera</div>
            <div class="modal-body">
                <div class="form-group">
                    <label>Camera Name</label>
                    <input type="text" id="new-cam-name" placeholder="e.g. Front Door">
                </div>
                <div class="form-group">
                    <label>Stream URL (sub-stream)</label>
                    <input type="text" id="new-cam-url" placeholder="rtsp://user:pass@ip:554/...">
                </div>
                <div class="form-group">
                    <label>Main Stream URL (optional)</label>
                    <input type="text" id="new-cam-main" placeholder="rtsp://user:pass@ip:554/...">
                </div>
                <div class="form-checkbox">
                    <input type="checkbox" id="new-cam-talk">
                    <label for="new-cam-talk">Enable two-way talk</label>
                </div>
            </div>
            <div class="modal-actions">
                <button class="btn btn-secondary cancel-btn">Cancel</button>
                <button class="btn btn-primary save-btn">Add Camera</button>
            </div>
        </div>
    `;
    document.body.appendChild(backdrop);

    backdrop.querySelector('.cancel-btn').addEventListener('click', () => backdrop.remove());
    backdrop.addEventListener('click', (e) => { if (e.target === backdrop) backdrop.remove(); });

    backdrop.querySelector('.save-btn').addEventListener('click', async () => {
        const name = backdrop.querySelector('#new-cam-name').value.trim();
        const url = backdrop.querySelector('#new-cam-url').value.trim();
        const mainUrl = backdrop.querySelector('#new-cam-main').value.trim();
        const talkEnabled = backdrop.querySelector('#new-cam-talk').checked;

        if (!name || !url) {
            showToast('Name and URL are required', 'error');
            return;
        }

        try {
            const resp = await fetchAPI('/api/cameras', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    name,
                    url,
                    main_url: mainUrl || undefined,
                    talk_enabled: talkEnabled,
                }),
            });

            if (resp.ok) {
                showToast('Camera added', 'success');
                backdrop.remove();
                loadCameras();
            } else {
                const data = await resp.json();
                showToast(data.detail || 'Failed to add camera', 'error');
            }
        } catch (e) {
            showToast('Error adding camera', 'error');
        }
    });
}

window._editCamera = async (id) => {
    const cam = cameras.find(c => c.id === id);
    if (!cam) return;

    const backdrop = document.createElement('div');
    backdrop.className = 'modal-backdrop show';
    backdrop.innerHTML = `
        <div class="modal" style="max-width:500px;">
            <div class="modal-title">Edit Camera: ${esc(cam.name)}</div>
            <div class="modal-body">
                <div class="form-group">
                    <label>Camera Name</label>
                    <input type="text" id="edit-cam-name" value="${esc(cam.name)}">
                </div>
                <div class="form-group">
                    <label>Stream URL</label>
                    <input type="text" id="edit-cam-url" value="${esc(cam.url || '')}">
                </div>
                <div class="form-group">
                    <label>Main Stream URL</label>
                    <input type="text" id="edit-cam-main" value="${esc(cam.main_url || '')}">
                </div>
                <div class="form-checkbox">
                    <input type="checkbox" id="edit-cam-talk" ${cam.talk_enabled ? 'checked' : ''}>
                    <label for="edit-cam-talk">Enable two-way talk</label>
                </div>
            </div>
            <div class="modal-actions">
                <button class="btn btn-secondary cancel-btn">Cancel</button>
                <button class="btn btn-primary save-btn">Save</button>
            </div>
        </div>
    `;
    document.body.appendChild(backdrop);

    backdrop.querySelector('.cancel-btn').addEventListener('click', () => backdrop.remove());
    backdrop.addEventListener('click', (e) => { if (e.target === backdrop) backdrop.remove(); });

    backdrop.querySelector('.save-btn').addEventListener('click', async () => {
        try {
            const resp = await fetchAPI(`/api/cameras/${id}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    name: backdrop.querySelector('#edit-cam-name').value.trim(),
                    url: backdrop.querySelector('#edit-cam-url').value.trim(),
                    main_url: backdrop.querySelector('#edit-cam-main').value.trim() || undefined,
                    talk_enabled: backdrop.querySelector('#edit-cam-talk').checked,
                }),
            });

            if (resp.ok) {
                showToast('Camera updated', 'success');
                backdrop.remove();
                loadCameras();
            } else {
                showToast('Failed to update camera', 'error');
            }
        } catch (e) {
            showToast('Error updating camera', 'error');
        }
    });
};

window._deleteCamera = async (id) => {
    const cam = cameras.find(c => c.id === id);
    if (!cam) return;
    if (await showConfirm('Delete Camera', `Delete "${cam.name}"? This cannot be undone.`, { danger: true })) {
        try {
            const resp = await fetchAPI(`/api/cameras/${id}`, { method: 'DELETE' });
            if (resp.ok) {
                showToast('Camera deleted', 'success');
                loadCameras();
            }
        } catch (e) {
            showToast('Error deleting camera', 'error');
        }
    }
};

window._testCamera = async (id) => {
    showToast('Testing stream...', 'info');
    try {
        const resp = await fetchAPI(`/api/cameras/${id}/test`, { method: 'POST' });
        const data = await resp.json();
        if (data.reachable) {
            showToast(`Stream OK: ${data.message}`, 'success');
            // Reload thumbnail
            const img = document.querySelector(`.camera-card[data-id="${id}"] .camera-thumb`);
            if (img) img.src = `/api/frame.jpeg?src=${id}&t=${Date.now()}`;
        } else {
            showToast(data.message || 'Stream unreachable', 'error');
        }
    } catch (e) {
        showToast('Stream test error', 'error');
    }
};

async function addFromNvr() {
    showToast('Scanning NVR...', 'info');
    try {
        const resp = await fetchAPI('/api/scan-nvr', { method: 'POST' });
        const data = await resp.json();
        if (data.cameras && data.cameras.length > 0) {
            showToast(`Found ${data.cameras.length} NVR cameras`, 'success');
            loadCameras();
        } else {
            showToast('No NVR cameras found', 'warning');
        }
    } catch (e) {
        showToast('NVR scan failed', 'error');
    }
}

function esc(str) {
    const d = document.createElement('div');
    d.textContent = str || '';
    return d.innerHTML;
}
