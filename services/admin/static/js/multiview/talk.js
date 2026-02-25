/**
 * AVA Doorbell v4.0 — Push-to-Talk
 *
 * Captures microphone audio, resamples to 8kHz mono PCM16 LE,
 * and streams via WebSocket to /api/ws-talk. Reliability fixes:
 * - 3 connection retries (V3: 0)
 * - 2048 sample buffer (256ms latency, V3: 4096 = 512ms)
 * - Linear resampling (V3: nearest-neighbor)
 * - Heartbeat silence frames every 1s during pauses
 */

import { setTalkState } from './controls.js?v=4.10';

const TARGET_SAMPLE_RATE = 8000;
const BUFFER_SIZE = 2048;
const MAX_RETRIES = 3;
const HEARTBEAT_INTERVAL = 1000;

let ws = null;
let audioContext = null;
let mediaStream = null;
let scriptProcessor = null;
let heartbeatTimer = null;
let isRecording = false;

/**
 * Start push-to-talk: acquire mic, connect WebSocket, stream audio.
 *
 * @param {string} cameraId  Camera to talk to.
 * @param {Object} wsInfo  WebSocket info from /api/ws-info.
 */
export async function startTalk(cameraId, wsInfo) {
    if (isRecording) return;
    isRecording = true;
    setTalkState('connecting');

    try {
        // Acquire microphone
        mediaStream = await navigator.mediaDevices.getUserMedia({
            audio: {
                sampleRate: TARGET_SAMPLE_RATE,
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: true,
            },
        });

        // Connect WebSocket with retry
        ws = await connectWithRetry(cameraId);
        if (!ws) {
            throw new Error('Failed to connect talk WebSocket after retries');
        }

        // Set up audio processing
        audioContext = new (window.AudioContext || window.webkitAudioContext)({
            sampleRate: TARGET_SAMPLE_RATE,
        });

        const source = audioContext.createMediaStreamSource(mediaStream);

        // ScriptProcessor with 2048 buffer (256ms at 8kHz)
        scriptProcessor = audioContext.createScriptProcessor(BUFFER_SIZE, 1, 1);

        scriptProcessor.onaudioprocess = (e) => {
            if (!ws || ws.readyState !== WebSocket.OPEN) return;

            const inputData = e.inputBuffer.getChannelData(0);
            const browserRate = audioContext.sampleRate;
            let samples;

            if (browserRate !== TARGET_SAMPLE_RATE) {
                samples = linearResample(inputData, browserRate, TARGET_SAMPLE_RATE);
            } else {
                samples = inputData;
            }

            // Encode as PCM16 LE with format header
            const pcm16 = encodePCM16(samples);
            const frame = new Uint8Array(1 + pcm16.byteLength);
            frame[0] = 0x01; // Format: PCM16 LE
            frame.set(new Uint8Array(pcm16), 1);

            ws.send(frame.buffer);
        };

        source.connect(scriptProcessor);
        scriptProcessor.connect(audioContext.destination);

        // Start heartbeat — send silence during pauses to keep connection alive
        startHeartbeat();

        setTalkState('recording');
        console.log(`[talk] Started talk to ${cameraId}`);

    } catch (err) {
        console.error('[talk] Start failed:', err);
        stopTalk();
        setTalkState('idle');
    }
}

/**
 * Stop push-to-talk: close everything.
 */
export function stopTalk() {
    isRecording = false;
    stopHeartbeat();

    if (scriptProcessor) {
        scriptProcessor.disconnect();
        scriptProcessor = null;
    }
    if (audioContext) {
        audioContext.close().catch(() => {});
        audioContext = null;
    }
    if (mediaStream) {
        mediaStream.getTracks().forEach(t => t.stop());
        mediaStream = null;
    }
    if (ws && ws.readyState < 2) {
        ws.close();
    }
    ws = null;
    setTalkState('idle');
    console.log('[talk] Stopped');
}

/**
 * Connect WebSocket to talk relay with retry.
 */
async function connectWithRetry(cameraId) {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = `${proto}//${location.host}/api/ws-talk?camera=${cameraId}`;

    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
        try {
            const socket = await new Promise((resolve, reject) => {
                const s = new WebSocket(url);
                const timer = setTimeout(() => {
                    s.close();
                    reject(new Error('Connect timeout'));
                }, 10000);

                s.onopen = () => {
                    clearTimeout(timer);
                    resolve(s);
                };
                s.onerror = () => {
                    clearTimeout(timer);
                    reject(new Error('WebSocket error'));
                };
            });

            socket.onclose = () => {
                console.log('[talk] WebSocket closed');
                if (isRecording) {
                    stopTalk();
                }
            };

            console.log(`[talk] Connected on attempt ${attempt}`);
            return socket;
        } catch (err) {
            console.warn(`[talk] Attempt ${attempt}/${MAX_RETRIES} failed: ${err.message}`);
            if (attempt < MAX_RETRIES) {
                await new Promise(r => setTimeout(r, 1000));
            }
        }
    }
    return null;
}

/**
 * Linear resampling (better than nearest-neighbor — reduces aliasing).
 */
function linearResample(inputData, fromRate, toRate) {
    const ratio = fromRate / toRate;
    const outputLength = Math.floor(inputData.length / ratio);
    const output = new Float32Array(outputLength);

    for (let i = 0; i < outputLength; i++) {
        const srcIdx = i * ratio;
        const lo = Math.floor(srcIdx);
        const hi = Math.min(lo + 1, inputData.length - 1);
        const frac = srcIdx - lo;
        output[i] = inputData[lo] * (1 - frac) + inputData[hi] * frac;
    }

    return output;
}

/**
 * Encode Float32 samples to PCM16 LE ArrayBuffer.
 */
function encodePCM16(samples) {
    const buffer = new ArrayBuffer(samples.length * 2);
    const view = new DataView(buffer);
    for (let i = 0; i < samples.length; i++) {
        const s = Math.max(-1, Math.min(1, samples[i]));
        view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
    return buffer;
}

/**
 * Send silence frames periodically to keep the WebSocket alive.
 */
function startHeartbeat() {
    stopHeartbeat();
    heartbeatTimer = setInterval(() => {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        // Send a small silence frame (format byte + 320 bytes of silence = 40ms @ 8kHz)
        const silence = new Uint8Array(1 + 320);
        silence[0] = 0x01; // Format: PCM16 LE
        // Rest is zeros = silence
        ws.send(silence.buffer);
    }, HEARTBEAT_INTERVAL);
}

function stopHeartbeat() {
    if (heartbeatTimer) {
        clearInterval(heartbeatTimer);
        heartbeatTimer = null;
    }
}
