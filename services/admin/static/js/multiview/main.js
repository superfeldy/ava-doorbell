/**
 * AVA Doorbell v4.0 — Multiview Entry Point
 *
 * Fetches config, builds the camera grid, connects cameras,
 * manages layout switching, auto-cycle, preset selection,
 * and exposes WebView bridge APIs for Android.
 */

import { connectCamera, cleanupConnection, disconnectAll, resetBackoff } from './connect.js?v=4.10';
import { stopAllMjpeg } from './mjpeg.js?v=4.10';
import { initControls, setTalkVisible, getLayoutSizes } from './controls.js?v=4.10';
import { startTalk, stopTalk } from './talk.js?v=4.10';
import { initFullscreen, exitFullscreen } from './fullscreen.js?v=4.10';

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
    cells: {},     // cameraId → cell element
};

let autoCycleTimer = null;
let autoCycleIdx = 0;
let cycleStartTime = 0;
let cycleProgressTimer = null;
const viewport = document.getElementById('viewport');

// ============================================================================
// Grid Building
// ============================================================================

/**
 * Build the camera grid for a given layout size.
 *
 * @param {string} layoutName  e.g., 'single', '4up', '9up'
 */
function buildGrid(layoutName) {
    if (!viewport) return;

    // Clean up existing connections
    disconnectAll(state.cells);
    stopAllMjpeg();
    exitFullscreen();

    // Get camera list for this layout
    const layoutCameras = state.layouts[layoutName] || [];
    const sizeMap = { single: 1, '2up': 2, '4up': 4, '6up': 6, '8up': 8, '9up': 9 };
    const slotCount = sizeMap[layoutName] || 1;

    // Set grid class
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

            cell.innerHTML = `
                <video autoplay playsinline muted class="waiting"></video>
                <img class="mjpeg-preview" style="position:absolute;inset:0;width:100%;height:100%;object-fit:contain;display:none;z-index:0;">
                <span class="camera-label">${escapeHtml(label)}</span>
                <span class="camera-status connecting"></span>
            `;
            cell.dataset.cameraId = cameraId;
            state.cells[cameraId] = cell;

            // Apply rotation to video and MJPEG preview
            if (rotation) {
                cell.classList.add(`rotate-${rotation}`);
            }

            // Check if this camera supports talk
            if (cam && cam.talk_enabled) {
                state.talkCamera = cameraId;
            }
        } else {
            cell.textContent = 'No camera';
        }

        viewport.appendChild(cell);
    }

    // Show/hide talk button
    setTalkVisible(!!state.talkCamera);

    // Connect all assigned cameras
    for (const [cameraId, cell] of Object.entries(state.cells)) {
        resetBackoff(cameraId);
        connectCamera(cameraId, cell, state);
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

    // Apply preset cameras to the layout
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

    // Progress bar
    updateCycleIndicator(true, interval);
}

function stopAutoCycle() {
    if (autoCycleTimer) {
        clearInterval(autoCycleTimer);
        autoCycleTimer = null;
    }
    if (cycleProgressTimer) {
        clearInterval(cycleProgressTimer);
        cycleProgressTimer = null;
    }
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
        const pct = Math.min(100, (elapsed / interval) * 100);
        progressBar.style.width = pct + '%';
    }, 200);
}

// ============================================================================
// Initialization
// ============================================================================

async function init() {
    try {
        // Fetch config and ws-info in parallel
        const [configResp, wsResp] = await Promise.all([
            fetch('/api/config'),
            fetch('/api/ws-info'),
        ]);

        const config = await configResp.json();
        const wsInfo = await wsResp.json();

        state.cameras = config.cameras || [];
        state.layouts = config.layouts || {};
        state.presets = config.preset_layouts || [];
        state.autoCycle = config.auto_cycle || state.autoCycle;
        state.wsInfo = wsInfo;

        // Determine initial layout from URL params or config
        const params = new URLSearchParams(location.search);
        const requestedLayout = params.get('layout');
        const requestedCamera = params.get('camera');

        if (requestedCamera) {
            // Single camera mode
            state.layouts.single = [requestedCamera];
            buildGrid('single');
        } else if (requestedLayout && state.layouts[requestedLayout]) {
            buildGrid(requestedLayout);
        } else {
            // Find the largest layout that has cameras assigned
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
                // No layouts configured — show single with first camera
                if (state.cameras.length > 0) {
                    state.layouts.single = [state.cameras[0].id];
                }
                buildGrid('single');
            }
        }

        // Initialize controls
        initControls(state, {
            onLayoutChange: switchLayout,
            onRefresh: () => buildGrid(state.currentLayout),
            onMuteToggle: (muted) => {
                document.querySelectorAll('.camera-cell video').forEach(v => {
                    v.muted = muted;
                });
            },
            onTalkToggle: (pressed) => {
                if (pressed && state.talkCamera) {
                    startTalk(state.talkCamera, state.wsInfo);
                } else {
                    stopTalk();
                }
            },
        });

        // Initialize fullscreen
        initFullscreen(viewport);

        // Start auto-cycle if enabled
        if (state.autoCycle.enabled) {
            startAutoCycle();
        }

    } catch (err) {
        console.error('Multiview init failed:', err);
    }
}

// ============================================================================
// WebView Bridge (Android postMessage API)
// ============================================================================

window.switchCamera = (cameraId) => {
    state.layouts.single = [cameraId];
    buildGrid('single');
};

window.onRingEvent = (cameraId) => {
    // Highlight the doorbell camera and show talk button attention pulse
    const talkBtn = document.getElementById('btn-talk');
    if (talkBtn) {
        talkBtn.classList.add('visible', 'ring-attention');
        setTimeout(() => talkBtn.classList.remove('ring-attention'), 10000);
    }
    // Switch to doorbell if in single view
    if (state.currentLayout === 'single') {
        state.layouts.single = [cameraId];
        buildGrid('single');
    }
};

window.answerDoorbell = (cameraId) => {
    // Switch to doorbell camera view. Talk is handled natively by Android
    // (NativeTalkManager) — the WebView no longer needs to capture mic audio.
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
    } catch (e) {
        // Ignore malformed messages
    }
});

// ============================================================================
// Start
// ============================================================================

document.addEventListener('DOMContentLoaded', init);

// Helpers
function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}
