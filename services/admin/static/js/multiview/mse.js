/**
 * AVA Doorbell v4.0 — MSE (Media Source Extensions) Strategy
 *
 * Connects to go2rtc via WebSocket, negotiates codecs via JSON messages,
 * pipes video into MediaSource with SourceBuffer queue management,
 * buffer trimming (2s interval), stale detection (10s), and live-edge sync.
 *
 * go2rtc protocol:
 *   1. Client opens WebSocket to /api/ws?src=<camera>
 *   2. On sourceopen, client sends: {type: 'mse', value: 'codec1,codec2,...'}
 *   3. Server replies with: {type: 'mse', value: 'video/mp4; codecs="..."'}
 *   4. Server sends binary MP4 segments
 */

/**
 * Codecs to advertise to go2rtc (matches go2rtc's video-rtc.js CODECS list).
 * go2rtc uses these to select the best codec for the stream.
 */
const CODECS = [
    'avc1.640029',      // H.264 high 4.1
    'avc1.64002A',      // H.264 high 4.2
    'avc1.640033',      // H.264 high 5.1
    'hvc1.1.6.L153.B0', // H.265 main 5.1
    'mp4a.40.2',        // AAC LC
    'mp4a.40.5',        // AAC HE
    'flac',             // FLAC
    'opus',             // OPUS
];

/**
 * Build a comma-separated codec string of supported codecs.
 */
function getSupportedCodecs() {
    return CODECS
        .filter(codec => MediaSource.isTypeSupported(`video/mp4; codecs="${codec}"`))
        .join();
}

/**
 * Attempt MSE connection for a camera.
 *
 * @param {string} cameraId  Camera identifier.
 * @param {HTMLVideoElement} videoEl  Target video element.
 * @param {Object} wsInfo  WebSocket connection info from /api/ws-info.
 * @param {Object} config  Callbacks: onConnected, onFailed, muted.
 * @returns {Promise<{ ws: WebSocket, mediaSource: MediaSource, trimTimer: number }>}
 */
export function tryMSE(cameraId, videoEl, wsInfo, config) {
    return new Promise((resolve, reject) => {
        let resolved = false;
        let ws = null;
        let mediaSource = null;
        let sourceBuffer = null;
        let bufferQueue = [];
        let lastDataTime = 0;
        let trimTimer = null;
        let staleTimer = null;
        let codecSent = false;  // guard: only send codec request once

        // 15s connection timeout — go2rtc starts RTSP pull on-demand,
        // first connection can take 5-10s for RTSP negotiation.
        const timeout = setTimeout(() => {
            if (!resolved) {
                resolved = true;
                console.warn(`[${cameraId}] MSE timeout after 15s`);
                cleanup();
                reject(new Error('MSE timeout'));
            }
        }, 15000);

        function cleanup() {
            if (staleTimer) clearInterval(staleTimer);
            if (trimTimer) clearInterval(trimTimer);
            if (ws && ws.readyState < 2) ws.close();
        }

        try {
            // Connect directly to go2rtc's WebSocket.
            const wsBase = wsInfo?.ws_base || '';
            const wsUrl = wsBase
                ? `${wsBase}/api/ws?src=${cameraId}`
                : `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/api/ws-proxy?src=${cameraId}`;

            console.log(`[${cameraId}] MSE: connecting to ${wsUrl}`);
            ws = new WebSocket(wsUrl);
            ws.binaryType = 'arraybuffer';

            mediaSource = new MediaSource();
            videoEl.src = URL.createObjectURL(mediaSource);

            // Send codec request once both MediaSource and WebSocket are ready.
            // Race: sourceopen and ws.onopen fire in unpredictable order.
            function sendCodecRequestIfReady() {
                if (codecSent) return;
                if (ws.readyState !== WebSocket.OPEN) return;
                if (mediaSource.readyState !== 'open') return;
                codecSent = true;
                const codecs = getSupportedCodecs();
                console.log(`[${cameraId}] MSE: sending codec request: ${codecs}`);
                ws.send(JSON.stringify({ type: 'mse', value: codecs }));
            }

            mediaSource.addEventListener('sourceopen', () => {
                console.log(`[${cameraId}] MSE: MediaSource open`);
                sendCodecRequestIfReady();
            });

            ws.onopen = () => {
                console.log(`[${cameraId}] MSE: WebSocket connected`);
                lastDataTime = Date.now();
                sendCodecRequestIfReady();
            };

            ws.onmessage = (event) => {
                lastDataTime = Date.now();

                if (typeof event.data === 'string') {
                    // JSON message from go2rtc
                    let msg;
                    try {
                        msg = JSON.parse(event.data);
                    } catch (e) {
                        // Legacy: raw codec string (shouldn't happen with go2rtc 1.9+)
                        console.warn(`[${cameraId}] MSE: non-JSON string: ${event.data}`);
                        return;
                    }

                    if (msg.type === 'mse') {
                        // go2rtc responds with the actual codec to use
                        const mimeType = msg.value;
                        console.log(`[${cameraId}] MSE: server codec: ${mimeType}`);

                        // Guard: ignore duplicate mse responses
                        if (sourceBuffer) {
                            console.log(`[${cameraId}] MSE: SourceBuffer already created, ignoring duplicate`);
                            return;
                        }

                        if (!MediaSource.isTypeSupported(mimeType)) {
                            console.error(`[${cameraId}] MSE: unsupported codec: ${mimeType}`);
                            clearTimeout(timeout);
                            resolved = true;
                            cleanup();
                            reject(new Error(`Unsupported codec: ${mimeType}`));
                            return;
                        }

                        try {
                            sourceBuffer = mediaSource.addSourceBuffer(mimeType);
                            sourceBuffer.mode = 'segments';
                            sourceBuffer.addEventListener('updateend', flushQueue);
                        } catch (e) {
                            console.error(`[${cameraId}] MSE: addSourceBuffer failed:`, e);
                            clearTimeout(timeout);
                            resolved = true;
                            cleanup();
                            reject(e);
                            return;
                        }

                        // Start buffer trimming every 15s (longer interval reduces
                        // MediaCodec flush storms on MediaTek devices)
                        trimTimer = setInterval(() => trimBuffer(), 15000);

                        // Start stale detection — check every 5s for 30s timeout
                        // Skip checks when page is hidden (Android WebView pause)
                        staleTimer = setInterval(() => {
                            if (document.hidden) {
                                lastDataTime = Date.now(); // reset while hidden
                                return;
                            }
                            if (Date.now() - lastDataTime > 30000) {
                                console.warn(`[${cameraId}] MSE: no data for 30s — stale`);
                                clearInterval(staleTimer);
                                staleTimer = null;
                                if (typeof config.onFailed === 'function') {
                                    config.onFailed('stale');
                                }
                            }
                        }, 5000);
                    } else if (msg.type === 'error') {
                        console.error(`[${cameraId}] MSE: server error: ${msg.value}`);
                    }

                    return;
                }

                // Binary data — video segment
                if (!sourceBuffer) return;

                // First data received = connection success
                if (!resolved) {
                    resolved = true;
                    clearTimeout(timeout);
                    console.log(`[${cameraId}] MSE: receiving video data`);
                    videoEl.classList.remove('waiting');
                    videoEl.muted = config.muted;
                    videoEl.play().catch(() => {
                        videoEl.muted = true;
                        videoEl.play().catch(() => {});
                    });
                    if (typeof config.onConnected === 'function') {
                        config.onConnected();
                    }
                    resolve({ ws, mediaSource, trimTimer, staleTimer });
                }

                bufferQueue.push(event.data);
                flushQueue();
            };

            ws.onerror = (err) => {
                console.error(`[${cameraId}] MSE: WebSocket error`);
                if (!resolved) {
                    resolved = true;
                    clearTimeout(timeout);
                    cleanup();
                    reject(new Error('MSE WebSocket error'));
                }
            };

            ws.onclose = () => {
                console.log(`[${cameraId}] MSE: WebSocket closed`);
                if (!resolved) {
                    resolved = true;
                    clearTimeout(timeout);
                    cleanup();
                    reject(new Error('MSE WebSocket closed'));
                } else {
                    if (typeof config.onFailed === 'function') {
                        config.onFailed('ws_closed');
                    }
                }
            };

        } catch (err) {
            clearTimeout(timeout);
            if (!resolved) {
                resolved = true;
                cleanup();
                reject(err);
            }
        }

        function flushQueue() {
            if (!sourceBuffer || sourceBuffer.updating || bufferQueue.length === 0) return;

            // Drop old queued segments if queue backs up (reduces decoder pressure
            // on weak MediaTek SoCs that crash on rapid appendBuffer calls)
            if (bufferQueue.length > 10) {
                const dropped = bufferQueue.length - 3;
                bufferQueue.splice(0, dropped);
                console.warn(`[${cameraId}] MSE: dropped ${dropped} queued segments`);
            }

            try {
                const data = bufferQueue.shift();
                sourceBuffer.appendBuffer(data);
            } catch (e) {
                console.warn(`[${cameraId}] MSE: appendBuffer error:`, e.name);
                if (e.name === 'QuotaExceededError') {
                    bufferQueue.length = 0;
                    trimBuffer(true);
                }
            }
        }

        let lastSeekTime = 0;

        function trimBuffer(aggressive = false) {
            if (!sourceBuffer || sourceBuffer.updating) return;
            try {
                const buffered = sourceBuffer.buffered;
                if (buffered.length === 0) return;

                const end = buffered.end(buffered.length - 1);
                const start = buffered.start(0);
                const keepSeconds = aggressive ? 5 : 30;

                // Only trim if buffer is significantly over the keep threshold
                // to minimize sourceBuffer.remove() calls which trigger
                // MediaCodec decoder flushes on MediaTek hardware
                if (end - start > keepSeconds + 5) {
                    sourceBuffer.remove(start, end - keepSeconds);
                }

                // Live-edge sync: only seek if very far behind (>15s) and
                // not more often than every 60s to avoid Android MediaCodec
                // decoder flush storms from frequent seeks
                const now = Date.now();
                if (videoEl.currentTime > 0 && end - videoEl.currentTime > 15 && now - lastSeekTime > 60000) {
                    lastSeekTime = now;
                    videoEl.currentTime = end - 1;
                }
            } catch (e) {
                // Ignore trim errors
            }
        }
    });
}

/**
 * Clean up an MSE connection.
 *
 * @param {Object} mseObj  { ws, mediaSource, trimTimer, staleTimer }
 * @param {HTMLVideoElement} [videoEl]
 */
export function cleanupMSE(mseObj, videoEl) {
    if (!mseObj) return;
    try {
        if (mseObj.trimTimer) clearInterval(mseObj.trimTimer);
        if (mseObj.staleTimer) clearInterval(mseObj.staleTimer);
        if (mseObj.ws && mseObj.ws.readyState < 2) mseObj.ws.close();
        if (mseObj.mediaSource && mseObj.mediaSource.readyState === 'open') {
            mseObj.mediaSource.endOfStream();
        }
        if (videoEl) {
            videoEl.pause();
            videoEl.removeAttribute('src');
            videoEl.load();
        }
    } catch (e) {
        console.error('cleanupMSE error:', e);
    }
}
