/**
 * AVA Doorbell v4.0 — MJPEG Snapshot Polling Display
 *
 * Polls /api/frame.jpeg (same-origin admin proxy to go2rtc) for JPEG
 * snapshots. Uses adaptive polling: fast (250ms) when frames arrive,
 * progressive backoff on errors.
 *
 * Direct go2rtc stream.mjpeg was removed because cross-origin requests
 * (port 1984 vs 5000) fail in Android WebView, and go2rtc requires the
 * RTSP source to already be connected before stream.mjpeg works.
 *
 * The native Android MJPEG overlay (CinemaActivity.startMjpegPreview)
 * provides the primary video feed; this web MJPEG is secondary for
 * multi-camera layout slots.
 */

/** Track active MJPEG streams per camera. */
const activeStreams = {};

/** Polling timers per camera. */
const pollingTimers = {};

/**
 * Start MJPEG preview for a camera via snapshot polling.
 *
 * @param {string} cameraId  Camera identifier.
 * @param {HTMLImageElement} imgEl  Target image element.
 */
export function startMjpegPreview(cameraId, imgEl) {
    stopMjpegPreview(cameraId, imgEl);

    console.log(`[${cameraId}] MJPEG: starting snapshot polling`);
    imgEl.style.display = 'block';
    activeStreams[cameraId] = imgEl;
    startSnapshotPolling(cameraId, imgEl);
}

/**
 * Poll /api/frame.jpeg snapshots with adaptive timing.
 *
 * Fast (250ms) when frames are arriving, progressive backoff on errors.
 * Initial retries are aggressive (500ms) because go2rtc may need a few
 * seconds to reconnect to an RTSP source after all consumers disconnect.
 */
function startSnapshotPolling(cameraId, imgEl) {
    let consecutiveErrors = 0;
    let gotFirstFrame = false;
    let pollTimer = null;

    function fetchFrame() {
        if (!imgEl.isConnected) {
            stopMjpegPreview(cameraId, imgEl);
            return;
        }
        const url = `/api/frame.jpeg?src=${cameraId}&t=${Date.now()}`;
        const img = new Image();
        img.onload = () => {
            imgEl.src = img.src;
            imgEl.style.display = 'block';
            consecutiveErrors = 0;
            gotFirstFrame = true;
            scheduleNext(250); // Fast polling when healthy
        };
        img.onerror = () => {
            consecutiveErrors++;
            if (!gotFirstFrame) {
                // Still waiting for initial connection — retry aggressively.
                // go2rtc may need 3-8s to reconnect RTSP to a slow camera.
                if (consecutiveErrors >= 30) {
                    console.warn(`[${cameraId}] MJPEG: ${consecutiveErrors} errors on initial connect, pausing 15s`);
                    scheduleNext(15000);
                    consecutiveErrors = 0;
                } else {
                    scheduleNext(500); // Fast retry during initial connect
                }
            } else {
                // Had frames before — camera may have gone offline
                if (consecutiveErrors >= 20) {
                    console.warn(`[${cameraId}] MJPEG polling: ${consecutiveErrors} errors, pausing 30s`);
                    scheduleNext(30000);
                    consecutiveErrors = 0;
                } else if (consecutiveErrors >= 8) {
                    scheduleNext(3000); // Moderate backoff
                } else {
                    scheduleNext(1000); // Quick retry
                }
            }
        };
        img.src = url;
    }

    function scheduleNext(delayMs) {
        if (pollTimer) clearTimeout(pollTimer);
        pollTimer = setTimeout(fetchFrame, delayMs);
        pollingTimers[cameraId] = pollTimer;
    }

    fetchFrame();
}

/**
 * Stop MJPEG preview for a camera.
 *
 * @param {string} cameraId
 * @param {HTMLImageElement} [imgEl]
 */
export function stopMjpegPreview(cameraId, imgEl) {
    if (activeStreams[cameraId]) {
        activeStreams[cameraId].src = '';
        activeStreams[cameraId].onerror = null;
        activeStreams[cameraId].onload = null;
        delete activeStreams[cameraId];
    }
    if (pollingTimers[cameraId]) {
        clearTimeout(pollingTimers[cameraId]);
        delete pollingTimers[cameraId];
    }
}

/**
 * Stop all MJPEG streams and polling.
 */
export function stopAllMjpeg() {
    for (const id of Object.keys(activeStreams)) {
        activeStreams[id].src = '';
        activeStreams[id].onerror = null;
        activeStreams[id].onload = null;
    }
    for (const id of Object.keys(pollingTimers)) {
        clearTimeout(pollingTimers[id]);
    }
    Object.keys(activeStreams).forEach(k => delete activeStreams[k]);
    Object.keys(pollingTimers).forEach(k => delete pollingTimers[k]);
}
