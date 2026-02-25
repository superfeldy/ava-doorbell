/**
 * AVA Doorbell v4.0 — Layout Editor Module
 *
 * Drag-and-drop grid editor, click-to-assign, layout size tabs,
 * named preset management (save/load/delete).
 */

import { fetchAPI } from './api.js';
import { showToast } from '../shared/toast.js';
import { showConfirm } from '../shared/confirm.js';

const SIZES = ['single', '2up', '4up', '6up', '8up', '9up'];
const SLOT_COUNTS = { single: 1, '2up': 2, '4up': 4, '6up': 6, '8up': 8, '9up': 9 };

let cameras = [];
let layouts = {};
let presets = [];
let currentSize = '4up';

export function initLayouts() {
    loadLayoutData();

    // Size tabs
    document.querySelectorAll('.layout-size-tab').forEach(tab => {
        tab.addEventListener('click', () => {
            currentSize = tab.dataset.size;
            document.querySelectorAll('.layout-size-tab').forEach(t => t.classList.toggle('active', t === tab));
            renderGrid();
        });
    });

    // Save button
    const saveBtn = document.getElementById('saveLayoutsBtn');
    if (saveBtn) saveBtn.addEventListener('click', saveLayouts);

    // Save preset button
    const presetBtn = document.getElementById('savePresetBtn');
    if (presetBtn) presetBtn.addEventListener('click', saveAsPreset);
}

async function loadLayoutData() {
    try {
        const [camResp, configResp] = await Promise.all([
            fetchAPI('/api/cameras'),
            fetchAPI('/api/config/full'),
        ]);
        cameras = await camResp.json();
        const config = await configResp.json();
        layouts = config.layouts || {};
        presets = config.preset_layouts || [];
        renderGrid();
        renderCameraTiles();
        renderPresets();
    } catch (e) {
        console.error('Failed to load layout data:', e);
    }
}

function renderGrid() {
    const grid = document.getElementById('layoutGrid');
    if (!grid) return;

    const slotCount = SLOT_COUNTS[currentSize] || 1;
    const cameraList = layouts[currentSize] || [];

    grid.className = `layout-grid-preview layout-${currentSize}-grid`;
    grid.innerHTML = '';

    for (let i = 0; i < slotCount; i++) {
        const cameraId = cameraList[i] || null;
        const cam = cameraId ? cameras.find(c => c.id === cameraId) : null;

        const slot = document.createElement('div');
        slot.className = 'layout-slot' + (cameraId ? ' filled' : '');
        slot.dataset.slot = i;

        if (cam) {
            slot.innerHTML = `
                <span class="slot-label">${esc(cam.name)}</span>
                <button class="slot-clear" title="Clear">&times;</button>
            `;
            slot.querySelector('.slot-clear').addEventListener('click', (e) => {
                e.stopPropagation();
                clearSlot(i);
            });
        } else {
            slot.innerHTML = `<span class="slot-label" style="color:var(--text-dimmed)">Empty</span>`;
        }

        // Click-to-assign
        slot.addEventListener('click', () => showCameraSelector(i));

        // Drag-and-drop
        slot.addEventListener('dragover', (e) => {
            e.preventDefault();
            slot.classList.add('drag-over');
        });
        slot.addEventListener('dragleave', () => {
            slot.classList.remove('drag-over');
        });
        slot.addEventListener('drop', (e) => {
            e.preventDefault();
            slot.classList.remove('drag-over');
            const camId = e.dataTransfer.getData('text/plain');
            assignCamera(i, camId);
        });

        grid.appendChild(slot);
    }
}

function renderCameraTiles() {
    const container = document.getElementById('cameraTiles');
    if (!container) return;

    container.innerHTML = cameras.map(cam => `
        <div class="camera-tile" draggable="true" data-camera="${cam.id}">
            <span class="camera-tile-icon"></span>
            ${esc(cam.name)}
        </div>
    `).join('');

    container.querySelectorAll('.camera-tile').forEach(tile => {
        tile.addEventListener('dragstart', (e) => {
            e.dataTransfer.setData('text/plain', tile.dataset.camera);
            tile.classList.add('dragging');
        });
        tile.addEventListener('dragend', () => {
            tile.classList.remove('dragging');
        });
    });
}

function renderPresets() {
    const list = document.getElementById('presetList');
    if (!list) return;

    if (presets.length === 0) {
        list.innerHTML = '<p style="color:var(--text-dimmed);font-size:12px;">No saved presets</p>';
        return;
    }

    list.innerHTML = presets.map((p, idx) => `
        <div class="preset-item" data-idx="${idx}">
            <span>${esc(p.name)} (${p.size})</span>
            <div class="preset-item-actions">
                <button class="preset-item-btn load-preset" title="Load">Load</button>
                <button class="preset-item-btn delete preset-delete" title="Delete">&times;</button>
            </div>
        </div>
    `).join('');

    list.querySelectorAll('.load-preset').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const idx = parseInt(e.target.closest('.preset-item').dataset.idx);
            loadPreset(idx);
        });
    });

    list.querySelectorAll('.preset-delete').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            const idx = parseInt(e.target.closest('.preset-item').dataset.idx);
            if (await showConfirm('Delete Preset', `Delete "${presets[idx].name}"?`, { danger: true })) {
                deletePreset(idx);
            }
        });
    });
}

function assignCamera(slotIndex, cameraId) {
    if (!layouts[currentSize]) layouts[currentSize] = [];
    // Ensure array is large enough
    while (layouts[currentSize].length <= slotIndex) layouts[currentSize].push(null);
    layouts[currentSize][slotIndex] = cameraId;
    renderGrid();
}

function clearSlot(slotIndex) {
    if (layouts[currentSize]) {
        layouts[currentSize][slotIndex] = null;
        renderGrid();
    }
}

function showCameraSelector(slotIndex) {
    const backdrop = document.createElement('div');
    backdrop.className = 'modal-backdrop show';
    backdrop.innerHTML = `
        <div class="modal">
            <div class="modal-title">Assign Camera to Slot ${slotIndex + 1}</div>
            <div class="modal-body">
                ${cameras.map(cam => `
                    <div class="camera-tile" data-camera="${cam.id}" style="margin-bottom:6px;cursor:pointer;">
                        <span class="camera-tile-icon"></span>
                        ${esc(cam.name)}
                    </div>
                `).join('')}
                <div class="camera-tile" data-camera="" style="margin-bottom:6px;cursor:pointer;color:var(--text-dimmed);">
                    Clear slot
                </div>
            </div>
        </div>
    `;
    document.body.appendChild(backdrop);

    backdrop.addEventListener('click', (e) => {
        if (e.target === backdrop) backdrop.remove();
    });

    backdrop.querySelectorAll('.camera-tile').forEach(tile => {
        tile.addEventListener('click', () => {
            assignCamera(slotIndex, tile.dataset.camera || null);
            backdrop.remove();
        });
    });
}

async function saveLayouts() {
    try {
        const resp = await fetchAPI('/api/layouts', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(layouts),
        });
        if (resp.ok) {
            showToast('Layouts saved', 'success');
        } else {
            showToast('Failed to save layouts', 'error');
        }
    } catch (e) {
        showToast('Error saving layouts', 'error');
    }
}

function saveAsPreset() {
    const name = prompt('Preset name:');
    if (!name) return;

    presets.push({
        name: name.trim(),
        size: currentSize,
        cameras: [...(layouts[currentSize] || [])],
    });

    savePresetsToServer();
    renderPresets();
}

function loadPreset(idx) {
    const preset = presets[idx];
    if (!preset) return;

    currentSize = preset.size;
    layouts[currentSize] = [...preset.cameras];

    // Update size tab
    document.querySelectorAll('.layout-size-tab').forEach(t =>
        t.classList.toggle('active', t.dataset.size === currentSize)
    );

    renderGrid();
    showToast(`Loaded preset: ${preset.name}`, 'success');
}

function deletePreset(idx) {
    presets.splice(idx, 1);
    savePresetsToServer();
    renderPresets();
}

async function savePresetsToServer() {
    try {
        await fetchAPI('/api/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ preset_layouts: presets }),
        });
    } catch (e) {
        console.error('Failed to save presets:', e);
    }
}

function esc(str) {
    const d = document.createElement('div');
    d.textContent = str || '';
    return d.innerHTML;
}
