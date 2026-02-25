/**
 * AVA Doorbell v4.0 — Multiview MJPEG-Only Entry Point
 *
 * Lightweight version for Android WebView on MediaTek devices where
 * MSE/WebRTC triggers MediaCodec decoder flush storms and crashes.
 *
 * This file does NOT import webrtc.js, mse.js, or connect.js —
 * no MediaCodec, no GPU compositing, no WebSocket video streams.
 * Just MJPEG <img> elements pointed at go2rtc's stream endpoint.
 */

import { startMjpegPreview, stopAllMjpeg } from './mjpeg.js?v=4.10';
import { initControls, setTalkVisible, getLayoutSizes } from './controls.js?v=4.10';
import { initFullscreen, exitFullscreen } from './fullscreen.js?v=4.10';

console.log('MJPEG-only mode: MSE/WebRTC disabled (server-side template)');

// ============================================================================
// Global State
// ============================================================================

const state = {
    cameras: [],
    layouts: {},
    presets: [],
    autoCycle: { enabled: false, interval: 30, presets: [] },
    currentLayout: 'single',
    muted: true,
    wsInfo: null,
    talkCamera: null,
    cells: {},
};

let autoCycleTimer = null;
let autoCycleIdx = 0;
let cycleStartTime = 0;
let cycleProgressTimer = null;
const viewport = document.getElementById('viewport');

// ============================================================================
// Grid Building (MJPEG-only — no <video>, just <img>)
// ============================================================================

function buildGrid(layoutName) {
    if (!viewport) return;

    stopAllMjpeg();
    exitFullscreen();

    const layoutCameras = state.layouts[layoutName] || [];
    const sizeMap = { single: 1, '2up': 2, '4up': 4, '6up': 6, '8up': 8, '9up': 9 };
    const slotCount = sizeMap[layoutName] || 1;

    viewport.className = `layout-${layoutName}`;
    viewport.innerHTML = '';
    state.cells = {};
    state.currentLayout = layoutName;

    for (let i = 0; i < slotCount; i++) {
        const cameraId = layoutCameras[i] || null;
        const cell = document.createElement('div');
        cell.className = 'camera-cell' + (cameraId ? '' : ' empty');
        cell.dataset.slot = i;

        if (cameraId) {
            const cam = state.cameras.find(c => c.id === cameraId);
            const label = cam ? cam.name : cameraId;
            const rotation = cam?.rotation || 0;

            // MJPEG-only: no <video> element at all — just <img>
            cell.innerHTML = `
                <img class="mjpeg-preview" style="position:absolute;inset:0;width:100%;height:100%;object-fit:contain;display:block;z-index:0;background:#000;">
                <span class="camera-label">${escapeHtml(label)}</span>
                <span class="camera-status connecting"></span>
            `;
            cell.dataset.cameraId = cameraId;
            state.cells[cameraId] = cell;

            if (rotation) {
                cell.classList.add(`rotate-${rotation}`);
            }

            if (cam && cam.talk_enabled) {
                state.talkCamera = cameraId;
            }
        } else {
            cell.textContent = 'No camera';
        }

        viewport.appendChild(cell);
    }

    setTalkVisible(false); // Talk is handled natively by Android

    // Start MJPEG for all cameras
    for (const [cameraId, cell] of Object.entries(state.cells)) {
        const imgEl = cell.querySelector('.mjpeg-preview');
        if (imgEl) {
            startMjpegPreview(cameraId, imgEl);
            // Update status dot when image loads
            imgEl.addEventListener('load', () => {
                const dot = cell.querySelector('.camera-status');
                if (dot) dot.className = 'camera-status live';
            }, { once: true });
        }
    }
}

// ============================================================================
// Layout & Preset Switching
// ============================================================================

function switchLayout(layoutName) {
    console.log(`Switching to layout: ${layoutName}`);
    buildGrid(layoutName);
}

function switchPreset(presetName) {
    const preset = state.presets.find(p => p.name === presetName);
    if (!preset) return;
    state.layouts[preset.size] = [...preset.cameras];
    switchLayout(preset.size);
}

// ============================================================================
// Auto-Cycle
// ============================================================================

function startAutoCycle() {
    stopAutoCycle();
    if (!state.autoCycle.enabled || state.autoCycle.presets.length === 0) return;

    const interval = (state.autoCycle.interval || 30) * 1000;
    autoCycleIdx = 0;

    function cycle() {
        const presetName = state.autoCycle.presets[autoCycleIdx % state.autoCycle.presets.length];
        switchPreset(presetName);
        autoCycleIdx++;
        cycleStartTime = Date.now();
    }

    cycle();
    autoCycleTimer = setInterval(cycle, interval);
    updateCycleIndicator(true, interval);
}

function stopAutoCycle() {
    if (autoCycleTimer) { clearInterval(autoCycleTimer); autoCycleTimer = null; }
    if (cycleProgressTimer) { clearInterval(cycleProgressTimer); cycleProgressTimer = null; }
    updateCycleIndicator(false, 0);
}

function updateCycleIndicator(active, interval) {
    const indicator = document.getElementById('cycle-indicator');
    const progressBar = document.getElementById('cycle-progress');
    if (!indicator || !progressBar) return;
    indicator.classList.toggle('active', active);
    if (!active) return;
    if (cycleProgressTimer) clearInterval(cycleProgressTimer);
    cycleProgressTimer = setInterval(() => {
        const elapsed = Date.now() - cycleStartTime;
        progressBar.style.width = Math.min(100, (elapsed / interval) * 100) + '%';
    }, 200);
}

// ============================================================================
// Initialization
// ============================================================================

async function init() {
    try {
        const configResp = await fetch('/api/config');
        const config = await configResp.json();

        state.cameras = config.cameras || [];
        state.layouts = config.layouts || {};
        state.presets = config.preset_layouts || [];
        state.autoCycle = config.auto_cycle || state.autoCycle;

        const params = new URLSearchParams(location.search);
        const requestedLayout = params.get('layout');
        const requestedCamera = params.get('camera');

        if (requestedCamera && (!requestedLayout || requestedLayout === 'single')) {
            // camera= param only forces single view when layout is single or unset
            state.layouts.single = [requestedCamera];
            buildGrid('single');
        } else if (requestedLayout && state.layouts[requestedLayout]) {
            buildGrid(requestedLayout);
        } else {
            const sizes = getLayoutSizes().reverse();
            let found = false;
            for (const size of sizes) {
                if (state.layouts[size] && state.layouts[size].filter(Boolean).length > 0) {
                    buildGrid(size);
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (state.cameras.length > 0) {
                    state.layouts.single = [state.cameras[0].id];
                }
                buildGrid('single');
            }
        }

        initControls(state, {
            onLayoutChange: switchLayout,
            onRefresh: () => buildGrid(state.currentLayout),
            onMuteToggle: () => {}, // No video elements to mute
            onTalkToggle: () => {}, // Talk handled natively by Android
        });

        initFullscreen(viewport);

        if (state.autoCycle.enabled) {
            startAutoCycle();
        }

    } catch (err) {
        console.error('Multiview MJPEG init failed:', err);
    }
}

// ============================================================================
// WebView Bridge (Android postMessage API)
// ============================================================================

window.switchCamera = (cameraId) => {
    state.layouts.single = [cameraId];
    buildGrid('single');
};

window.switchLayout = switchLayout;

window.onRingEvent = (cameraId) => {
    if (state.currentLayout === 'single') {
        state.layouts.single = [cameraId];
        buildGrid('single');
    }
};

window.answerDoorbell = (cameraId) => {
    state.layouts.single = [cameraId];
    buildGrid('single');
};

window.addEventListener('message', (event) => {
    try {
        const msg = typeof event.data === 'string' ? JSON.parse(event.data) : event.data;
        if (msg.action === 'switchCamera') window.switchCamera(msg.cameraId);
        if (msg.action === 'ringEvent') window.onRingEvent(msg.cameraId);
        if (msg.action === 'answerDoorbell') window.answerDoorbell(msg.cameraId);
        if (msg.action === 'switchLayout') switchLayout(msg.layout);
        if (msg.action === 'switchPreset') switchPreset(msg.preset);
    } catch (e) {}
});

// ============================================================================
// Start
// ============================================================================

document.addEventListener('DOMContentLoaded', init);

function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}
