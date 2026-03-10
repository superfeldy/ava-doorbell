/**
 * AVA Doorbell v4.0 — Connection Orchestrator
 *
 * Manages per-camera connection cascade: WebRTC → MSE → MJPEG.
 * Tracks protocol preferences with 10-minute expiry and prevents
 * concurrent cascade attempts via connectionInProgress flags.
 */

import { tryWebRTC, cleanupWebRTC } from './webrtc.js?v=4.11';
import { tryMSE, cleanupMSE } from './mse.js?v=4.11';
import { startMjpegPreview, stopMjpegPreview } from './mjpeg.js?v=4.11';
import {
    createBackoffState, recordFailure, recordSuccess,
    getDelay, isMaxedOut,
    freezeFrame, removeFrozenFrame,
    showReconnectOverlay, removeReconnectOverlay,
    showLoadingOverlay, removeLoadingOverlay,
} from './reconnect.js?v=4.11';

/** Check URL for forced MJPEG mode (Android WebView on devices with broken MSE). */
const forceMjpeg = new URLSearchParams(location.search).get('mode') === 'mjpeg';
if (forceMjpeg) console.log('MJPEG-only mode forced via URL parameter');

/** Protocol preference cache with timestamps. */
const protocolCache = {};

/** Expiry for protocol preferences (10 minutes). */
const PROTOCOL_CACHE_EXPIRY = 10 * 60 * 1000;

/** Prevent concurrent cascade attempts per camera. */
const connectionInProgress = {};

/** Active connections per camera. */
const activeConnections = {};

/** Backoff state per camera. */
const backoffStates = {};

/** Pending reconnect timers per camera (to cancel on layout switch). */
const reconnectTimers = {};

/**
 * Get the preferred protocol for a camera, respecting expiry.
 */
function getPreferredProtocol(cameraId) {
    const entry = protocolCache[cameraId];
    if (!entry) return null;
    if (Date.now() - entry.timestamp > PROTOCOL_CACHE_EXPIRY) {
        delete protocolCache[cameraId];
        return null;
    }
    return entry.protocol;
}

/**
 * Record a successful protocol for a camera.
 */
function setPreferredProtocol(cameraId, protocol) {
    protocolCache[cameraId] = { protocol, timestamp: Date.now() };
}

/**
 * Connect a camera with the WebRTC → MSE → MJPEG cascade.
 *
 * @param {string} cameraId  Camera identifier (matches go2rtc source name).
 * @param {HTMLElement} cell  The .camera-cell container element.
 * @param {Object} state  Global multiview state (muted, wsInfo, etc).
 * @returns {Promise<void>}
 */
export async function connectCamera(cameraId, cell, state) {
    // Prevent concurrent cascades
    if (connectionInProgress[cameraId]) {
        console.log(`[${cameraId}] Connection already in progress, skipping`);
        return;
    }
    connectionInProgress[cameraId] = true;

    // Ensure backoff state exists
    if (!backoffStates[cameraId]) {
        backoffStates[cameraId] = createBackoffState(cameraId);
    }

    const videoEl = cell.querySelector('video');
    const imgEl = cell.querySelector('.mjpeg-preview');

    // Clean up any existing connection
    cleanupConnection(cameraId, cell);
    removeReconnectOverlay(cell);

    // Start MJPEG preview immediately for fast first-frame
    if (imgEl) {
        startMjpegPreview(cameraId, imgEl);
    }

    // If MJPEG-only mode is forced (e.g. Android WebView on MediaTek with
    // broken hardware video decoding), skip MSE/WebRTC entirely.
    if (forceMjpeg) {
        console.log(`[${cameraId}] MJPEG-only mode — skipping MSE/WebRTC`);
        if (imgEl) {
            imgEl.style.display = 'block';
            if (videoEl) videoEl.style.display = 'none';
            // Show spinner until first MJPEG frame arrives (unless frozen frame is showing)
            if (!cell.querySelector('.frozen-frame')) {
                showLoadingOverlay(cell, 'Connecting\u2026');
            }
            imgEl.addEventListener('load', () => {
                removeLoadingOverlay(cell);
                removeFrozenFrame(cell);
                updateCameraStatus(cell, 'live');
            }, { once: true });
        } else {
            removeLoadingOverlay(cell);
            updateCameraStatus(cell, 'live');
        }
        connectionInProgress[cameraId] = false;
        return;
    }

    showLoadingOverlay(cell, 'Connecting\u2026');

    const preferred = getPreferredProtocol(cameraId);
    const protocols = buildProtocolOrder(preferred);

    let connected = false;

    for (const protocol of protocols) {
        if (connected) break;

        try {
            if (protocol === 'webrtc') {
                const result = await tryWebRTC(cameraId, videoEl, state.wsInfo, {
                    muted: state.muted,
                    onConnected: () => {
                        removeLoadingOverlay(cell);
                        if (imgEl) stopMjpegPreview(cameraId, imgEl);
                        setPreferredProtocol(cameraId, 'webrtc');
                        recordSuccess(backoffStates[cameraId]);
                        updateCameraStatus(cell, 'live');
                        // Defer frozen frame removal until video has a painted frame
                        deferFrozenFrameRemoval(cell, videoEl);
                    },
                    onFailed: (reason) => {
                        console.warn(`[${cameraId}] WebRTC failed after connection: ${reason}`);
                        scheduleReconnect(cameraId, cell, state);
                    },
                    onDisconnected: () => {
                        scheduleReconnect(cameraId, cell, state);
                    },
                    updateStatus: (id, s) => {
                        if (s === 'connecting' || s === 'checking') {
                            updateCameraStatus(cell, 'connecting');
                        }
                    },
                });
                activeConnections[cameraId] = { type: 'webrtc', ...result };
                connected = true;
            } else if (protocol === 'mse') {
                const result = await tryMSE(cameraId, videoEl, state.wsInfo, {
                    muted: state.muted,
                    onConnected: () => {
                        removeLoadingOverlay(cell);
                        if (imgEl) stopMjpegPreview(cameraId, imgEl);
                        setPreferredProtocol(cameraId, 'mse');
                        recordSuccess(backoffStates[cameraId]);
                        updateCameraStatus(cell, 'live');
                        // Defer frozen frame removal until video has a painted frame
                        deferFrozenFrameRemoval(cell, videoEl);
                    },
                    onFailed: (reason) => {
                        console.warn(`[${cameraId}] MSE failed: ${reason}`);
                        scheduleReconnect(cameraId, cell, state);
                    },
                });
                activeConnections[cameraId] = { type: 'mse', ...result };
                connected = true;
            }
        } catch (err) {
            console.warn(`[${cameraId}] ${protocol} failed: ${err.message}`);
        }
    }

    if (!connected) {
        // All protocols failed — fall back to MJPEG-only
        console.warn(`[${cameraId}] All protocols failed, using MJPEG fallback`);
        removeLoadingOverlay(cell);
        if (imgEl) {
            startMjpegPreview(cameraId, imgEl);
            imgEl.style.display = 'block';
            if (videoEl) videoEl.style.display = 'none';
        }
        updateCameraStatus(cell, 'error');
        scheduleReconnect(cameraId, cell, state);
    }

    connectionInProgress[cameraId] = false;
}

/**
 * Build the protocol attempt order based on preference.
 */
function buildProtocolOrder(preferred) {
    if (preferred === 'mse') return ['mse', 'webrtc'];
    if (preferred === 'webrtc') return ['webrtc', 'mse'];
    return ['mse', 'webrtc']; // default: MSE first (reliable), WebRTC as fallback
}

/**
 * Schedule a reconnect attempt with backoff.
 */
function scheduleReconnect(cameraId, cell, state) {
    const bs = backoffStates[cameraId];
    if (!bs) return;

    // Capture frozen frame before cleanup
    const videoEl = cell.querySelector('video');
    if (videoEl) freezeFrame(cell, videoEl);

    // Immediately clean up the old connection to free MediaCodec decoders
    cleanupConnection(cameraId, cell);

    recordFailure(bs);

    if (isMaxedOut(bs)) {
        console.error(`[${cameraId}] Max reconnect attempts reached`);
        removeLoadingOverlay(cell);
        updateCameraStatus(cell, 'error');
        showReconnectOverlay(cell, () => {
            bs.attempts = 0;
            connectCamera(cameraId, cell, state);
        });
        return;
    }

    const delay = getDelay(bs);
    showLoadingOverlay(cell, `Reconnecting in ${Math.round(delay / 1000)}s\u2026`);

    // Cancel any existing reconnect timer for this camera
    if (reconnectTimers[cameraId]) clearTimeout(reconnectTimers[cameraId]);

    reconnectTimers[cameraId] = setTimeout(() => {
        delete reconnectTimers[cameraId];
        if (!connectionInProgress[cameraId]) {
            connectCamera(cameraId, cell, state);
        }
    }, delay);
}

/**
 * Clean up the active connection for a camera.
 */
export function cleanupConnection(cameraId, cell) {
    const conn = activeConnections[cameraId];
    if (!conn) return;

    const videoEl = cell.querySelector('video');

    if (conn.type === 'webrtc') {
        cleanupWebRTC(conn, videoEl);
    } else if (conn.type === 'mse') {
        cleanupMSE(conn, videoEl);
    }

    delete activeConnections[cameraId];
}

/**
 * Disconnect all cameras.
 */
export function disconnectAll(cells) {
    for (const [cameraId, conn] of Object.entries(activeConnections)) {
        const cell = cells[cameraId];
        if (cell) cleanupConnection(cameraId, cell);
    }
}

/**
 * Reset backoff state for a camera (used on manual refresh).
 */
export function resetBackoff(cameraId) {
    if (backoffStates[cameraId]) {
        backoffStates[cameraId].attempts = 0;
        if (backoffStates[cameraId].resetTimer) {
            clearTimeout(backoffStates[cameraId].resetTimer);
            backoffStates[cameraId].resetTimer = null;
        }
    }
    connectionInProgress[cameraId] = false;
    // Cancel pending reconnect timer to prevent ghost connections to destroyed DOM
    if (reconnectTimers[cameraId]) {
        clearTimeout(reconnectTimers[cameraId]);
        delete reconnectTimers[cameraId];
    }
}

/**
 * Defer frozen frame removal until the video element has a decoded frame,
 * preventing a black flash between frozen frame and live video.
 */
function deferFrozenFrameRemoval(cell, videoEl) {
    if (!cell.querySelector('.frozen-frame')) return;
    if (videoEl && videoEl.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
        removeFrozenFrame(cell);
    } else if (videoEl) {
        const onReady = () => {
            removeFrozenFrame(cell);
            videoEl.removeEventListener('canplay', onReady);
        };
        videoEl.addEventListener('canplay', onReady);
        // Safety timeout: remove after 3s regardless
        setTimeout(() => {
            videoEl.removeEventListener('canplay', onReady);
            removeFrozenFrame(cell);
        }, 3000);
    } else {
        removeFrozenFrame(cell);
    }
}

/**
 * Update the status indicator dot on a camera cell.
 */
function updateCameraStatus(cell, status) {
    const dot = cell.querySelector('.camera-status');
    if (!dot) return;
    dot.className = 'camera-status ' + status;
}
