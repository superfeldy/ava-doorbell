/**
 * AVA Doorbell v4.0 — Reconnection & Visual Overlays
 *
 * Exponential backoff per camera, frozen-frame capture, and
 * loading / reconnect overlay management.
 */

// ------------------------------------------------------------------
// CONSTANTS
// ------------------------------------------------------------------

/** Backoff delays in milliseconds (attempt 1 → 5). Fast initial retry for doorbell use. */
export const BACKOFF_DELAYS = [2000, 5000, 10000, 20000, 30000];

/** Maximum reconnect attempts before showing "tap to reconnect". */
export const MAX_ATTEMPTS = 12;

/** Connection must be stable for this long (ms) before backoff resets. */
export const STABILITY_THRESHOLD = 15000;

// ------------------------------------------------------------------
// BACKOFF STATE
// ------------------------------------------------------------------

/**
 * Create a fresh backoff state object for a camera.
 *
 * @param {string} cameraId
 * @returns {{ cameraId: string, attempts: number, lastAttempt: number, resetTimer: number|null }}
 */
export function createBackoffState(cameraId) {
    return { cameraId, attempts: 0, lastAttempt: 0, resetTimer: null };
}

/**
 * Record a connection failure.  Increments the attempt counter,
 * cancels any pending stability-reset timer, and returns the
 * updated state.
 *
 * @param {Object} state  Backoff state from createBackoffState.
 * @returns {Object}  The same state object (mutated).
 */
export function recordFailure(state) {
    if (state.resetTimer) {
        clearTimeout(state.resetTimer);
        state.resetTimer = null;
    }
    state.attempts++;
    state.lastAttempt = Date.now();
    return state;
}

/**
 * Record a successful connection.  Starts a delayed reset — the
 * connection must stay up for STABILITY_THRESHOLD ms before the
 * backoff counter actually resets.  This prevents short-lived
 * connect-then-die cycles from resetting the counter.
 *
 * @param {Object} state  Backoff state.
 * @returns {Object}  The same state object.
 */
export function recordSuccess(state) {
    if (state.resetTimer) clearTimeout(state.resetTimer);
    state.resetTimer = setTimeout(() => {
        state.attempts = 0;
        state.resetTimer = null;
        console.log(`[${state.cameraId}] Connection stable for ${STABILITY_THRESHOLD / 1000}s — backoff reset`);
    }, STABILITY_THRESHOLD);
    return state;
}

/**
 * Get the delay in milliseconds for the next reconnect attempt.
 *
 * @param {Object} state  Backoff state.
 * @returns {number}  Delay in ms, computed from BACKOFF_DELAYS with
 *                    exponential progression: 15s, 30s, 60s, 120s max.
 */
export function getDelay(state) {
    const idx = Math.min(state.attempts - 1, BACKOFF_DELAYS.length - 1);
    const delay = BACKOFF_DELAYS[Math.max(0, idx)];
    console.warn(
        `[${state.cameraId}] Reconnect attempt #${state.attempts}/${MAX_ATTEMPTS} — waiting ${(delay / 1000).toFixed(0)}s`
    );
    return delay;
}

/**
 * Check whether the camera has exhausted all reconnect attempts.
 *
 * @param {Object} state  Backoff state.
 * @returns {boolean}
 */
export function isMaxedOut(state) {
    return state.attempts > MAX_ATTEMPTS;
}

// ------------------------------------------------------------------
// VIDEO FRAME CAPTURE
// ------------------------------------------------------------------

/**
 * Capture the current video frame as a JPEG data-URL.
 *
 * @param {HTMLVideoElement} video
 * @returns {string|null}  data:image/jpeg URL, or null on failure.
 */
export function captureVideoFrame(video) {
    try {
        if (!video || video.videoWidth === 0 || video.videoHeight === 0) return null;
        const canvas = document.createElement('canvas');
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(video, 0, 0);
        return canvas.toDataURL('image/jpeg', 0.85);
    } catch (e) {
        return null; // Security / cross-origin — ignore
    }
}

// ------------------------------------------------------------------
// FROZEN FRAME (seamless reconnect)
// ------------------------------------------------------------------

/**
 * Place a frozen-frame <img> over a camera cell so the user never
 * sees a black flash between stream connections.
 *
 * @param {HTMLElement} cell   The .camera-cell container.
 * @param {HTMLVideoElement} video  The video element to snapshot.
 */
export function freezeFrame(cell, video) {
    // Try capturing from the video element first
    let src = captureVideoFrame(video);
    // If video had nothing, check if there's an MJPEG preview we can use
    if (!src) {
        const mjpegImg = cell.querySelector('.mjpeg-preview');
        if (mjpegImg && mjpegImg.src && mjpegImg.src.startsWith('blob:')) {
            // Can't toDataURL a blob img, but we can leave the MJPEG img in place
            return;
        }
    }
    if (src) {
        const existing = cell.querySelector('.frozen-frame');
        if (existing) existing.remove();
        const img = document.createElement('img');
        img.className = 'frozen-frame';
        img.src = src;
        cell.appendChild(img);
    }
}

/**
 * Remove the frozen-frame overlay once a live stream is playing.
 *
 * @param {HTMLElement} cell  The .camera-cell container.
 */
export function removeFrozenFrame(cell) {
    const img = cell.querySelector('.frozen-frame');
    if (img) img.remove();
}

// ------------------------------------------------------------------
// RECONNECT OVERLAY  ("Tap to reconnect")
// ------------------------------------------------------------------

/**
 * Show a "Tap to reconnect" overlay when auto-reconnect is exhausted.
 *
 * @param {HTMLElement} cell  The .camera-cell container.
 * @param {Function} onReconnect  Callback invoked when user taps.
 */
export function showReconnectOverlay(cell, onReconnect) {
    let overlay = cell.querySelector('.reconnect-overlay');
    if (overlay) return; // already showing
    overlay = document.createElement('div');
    overlay.className = 'reconnect-overlay';
    overlay.innerHTML = `
        <div class="reconnect-icon">&#x21bb;</div>
        <span class="reconnect-text">Tap to reconnect</span>`;
    overlay.addEventListener('click', (e) => {
        e.stopPropagation();
        overlay.remove();
        if (typeof onReconnect === 'function') onReconnect();
    });
    cell.appendChild(overlay);
}

/**
 * Remove the reconnect overlay if present.
 *
 * @param {HTMLElement} cell  The .camera-cell container.
 */
export function removeReconnectOverlay(cell) {
    const overlay = cell.querySelector('.reconnect-overlay');
    if (overlay) overlay.remove();
}

// ------------------------------------------------------------------
// LOADING OVERLAY  (spinner + text)
// ------------------------------------------------------------------

/**
 * Show a loading overlay with a spinner on a camera cell.
 *
 * @param {HTMLElement} cell  The .camera-cell container.
 * @param {string} text  Status text (default "Connecting...").
 * @returns {HTMLElement}  The overlay element.
 */
export function showLoadingOverlay(cell, text = 'Connecting\u2026') {
    let overlay = cell.querySelector('.loading-overlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.className = 'loading-overlay';
        overlay.innerHTML = `
            <div class="spinner-lg"></div>
            <span class="loading-text">${text}</span>`;
        cell.appendChild(overlay);
    } else {
        const el = overlay.querySelector('.loading-text');
        if (el) el.textContent = text;
    }
    return overlay;
}

/**
 * Remove the loading overlay from a camera cell.
 *
 * @param {HTMLElement} cell  The .camera-cell container.
 */
export function removeLoadingOverlay(cell) {
    const overlay = cell.querySelector('.loading-overlay');
    if (overlay) overlay.remove();
}
