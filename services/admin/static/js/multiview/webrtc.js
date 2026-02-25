/**
 * AVA Doorbell v4.0 — WebRTC Connection Strategy
 *
 * Creates an RTCPeerConnection (LAN-only, no STUN), performs SDP
 * exchange via go2rtc's WebSocket signaling protocol, and monitors
 * stream health by checking framesDecoded every 3 seconds.
 *
 * go2rtc WebRTC signaling protocol (via WebSocket):
 *   1. Client opens WebSocket to /api/ws?src=<camera>
 *   2. Client sends: { type: 'webrtc', value: offer_sdp }
 *   3. Server replies: { type: 'webrtc', value: answer_sdp }
 *   4. ICE candidates exchanged via: { type: 'webrtc/candidate', value: candidate_json }
 *
 * Note: go2rtc's HTTP POST /api/webrtc endpoint connects ICE but
 * doesn't deliver media tracks. WebSocket signaling is required.
 */

/**
 * Attempt a WebRTC connection for a camera.
 *
 * @param {string} cameraId  Camera identifier.
 * @param {HTMLVideoElement} videoEl  Target video element.
 * @param {Object} wsInfo  WebSocket/HTTP info from /api/ws-info.
 * @param {Object} config  Configuration bag:
 *   @param {boolean} config.muted        Initial mute state.
 *   @param {Function} config.onTrack     Called when a media track arrives.
 *   @param {Function} config.onConnected Called on successful connection.
 *   @param {Function} config.onFailed    Called on connection failure/close after success.
 *   @param {Function} config.onDisconnected Called on transient disconnect after success.
 *   @param {Function} config.updateStatus  (cameraId, state) => void.
 * @returns {Promise<{ peer: RTCPeerConnection, ws: WebSocket, healthTimer: number }>}
 *          Resolves when the stream is flowing, rejects on timeout/failure.
 */
export function tryWebRTC(cameraId, videoEl, wsInfo, config) {
    return new Promise(async (resolve, reject) => {
        let resolved = false;
        let peer = null;
        let ws = null;
        let healthTimer = null;

        // 15s timeout: go2rtc starts the RTSP pull on-demand, so the first
        // connection to a camera can take 5-10s while go2rtc negotiates RTSP.
        const timeout = setTimeout(() => {
            if (!resolved) {
                resolved = true;
                console.warn(`[${cameraId}] WebRTC timeout after 15s`);
                cleanup();
                reject(new Error('WebRTC timeout'));
            }
        }, 15000);

        function cleanup() {
            if (ws && ws.readyState < 2) ws.close();
            if (peer) {
                try { peer.close(); } catch (e) { /* ignore */ }
            }
        }

        try {
            // Connect to go2rtc's WebSocket for signaling
            const wsBase = wsInfo?.ws_base || '';
            const wsUrl = wsBase
                ? `${wsBase}/api/ws?src=${cameraId}`
                : `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/api/ws-proxy?src=${cameraId}`;

            console.log(`[${cameraId}] WebRTC: connecting signaling WS to ${wsUrl}`);
            ws = new WebSocket(wsUrl);

            // No STUN/TURN — LAN-only. Removing STUN avoids external DNS
            // lookup and speeds up ICE gathering.
            peer = new RTCPeerConnection({ iceServers: [] });

            peer.addTransceiver('video', { direction: 'recvonly' });
            peer.addTransceiver('audio', { direction: 'recvonly' });

            // Track received = video is flowing
            let gotTrack = false;
            peer.ontrack = (event) => {
                if (resolved && !gotTrack) return; // Don't touch video if timed out before any track
                console.log(`[${cameraId}] WebRTC: received ${event.track.kind} track`);
                gotTrack = true;

                if (typeof config.onTrack === 'function') {
                    config.onTrack(event);
                }

                if (videoEl.srcObject !== event.streams[0]) {
                    videoEl.srcObject = event.streams[0];
                }
                videoEl.classList.remove('waiting');
                videoEl.muted = config.muted;
                videoEl.play().catch(() => {
                    videoEl.muted = true;
                    videoEl.play().catch(() => {});
                });

                // Resolve once we have a track and connection is up
                if (!resolved) {
                    resolved = true;
                    clearTimeout(timeout);
                    console.log(`[${cameraId}] WebRTC: stream active`);
                    if (typeof config.onConnected === 'function') {
                        config.onConnected();
                    }
                    resolve({ peer, ws, healthTimer });
                }
            };

            // Send trickle ICE candidates to go2rtc via WebSocket
            peer.onicecandidate = (event) => {
                if (event.candidate && ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({
                        type: 'webrtc/candidate',
                        value: event.candidate.candidate,
                    }));
                }
            };

            peer.onconnectionstatechange = () => {
                console.log(`[${cameraId}] WebRTC state: ${peer.connectionState}`);
                if (typeof config.updateStatus === 'function') {
                    config.updateStatus(cameraId, peer.connectionState);
                }

                if (peer.connectionState === 'connected' && gotTrack && !resolved) {
                    resolved = true;
                    clearTimeout(timeout);
                    console.log(`[${cameraId}] WebRTC: connected with tracks`);
                    if (typeof config.onConnected === 'function') {
                        config.onConnected();
                    }
                    resolve({ peer, ws, healthTimer });
                }

                if (peer.connectionState === 'failed' || peer.connectionState === 'closed') {
                    clearTimeout(timeout);
                    if (!resolved) {
                        resolved = true;
                        cleanup();
                        reject(new Error(`WebRTC ${peer.connectionState}`));
                    } else {
                        if (typeof config.onFailed === 'function') {
                            config.onFailed(peer.connectionState);
                        }
                    }
                }

                // 'disconnected' is often transient on LAN. Give 5s to recover.
                if (peer.connectionState === 'disconnected' && resolved) {
                    setTimeout(() => {
                        if (peer.connectionState === 'disconnected') {
                            console.warn(`[${cameraId}] WebRTC: still disconnected after 5s`);
                            if (typeof config.onDisconnected === 'function') {
                                config.onDisconnected();
                            }
                        }
                    }, 5000);
                }
            };

            // WebSocket message handler — processes go2rtc signaling
            ws.onmessage = async (event) => {
                if (typeof event.data !== 'string') return;

                let msg;
                try {
                    msg = JSON.parse(event.data);
                } catch (e) {
                    return;
                }

                if (msg.type === 'webrtc') {
                    // SDP answer from go2rtc
                    console.log(`[${cameraId}] WebRTC: received SDP answer (${msg.value.length} bytes)`);
                    try {
                        await peer.setRemoteDescription(
                            new RTCSessionDescription({ type: 'answer', sdp: msg.value })
                        );
                    } catch (e) {
                        console.error(`[${cameraId}] WebRTC: setRemoteDescription failed:`, e);
                        if (!resolved) {
                            resolved = true;
                            clearTimeout(timeout);
                            cleanup();
                            reject(e);
                        }
                    }
                } else if (msg.type === 'webrtc/candidate') {
                    // ICE candidate from go2rtc
                    try {
                        const candidate = new RTCIceCandidate({
                            candidate: msg.value,
                            sdpMid: '0',
                        });
                        await peer.addIceCandidate(candidate);
                    } catch (e) {
                        // Ignore candidate errors — some are expected
                    }
                } else if (msg.type === 'error') {
                    console.error(`[${cameraId}] WebRTC: server error: ${msg.value}`);
                }
            };

            // When WebSocket is open, create and send the SDP offer
            ws.onopen = async () => {
                console.log(`[${cameraId}] WebRTC: signaling WS connected`);

                try {
                    const offer = await peer.createOffer();
                    await peer.setLocalDescription(offer);

                    // Send the offer immediately — don't wait for ICE gathering.
                    // go2rtc handles trickle ICE via webrtc/candidate messages.
                    console.log(`[${cameraId}] WebRTC: sending SDP offer`);
                    ws.send(JSON.stringify({
                        type: 'webrtc',
                        value: peer.localDescription.sdp,
                    }));
                } catch (e) {
                    console.error(`[${cameraId}] WebRTC: offer creation failed:`, e);
                    if (!resolved) {
                        resolved = true;
                        clearTimeout(timeout);
                        cleanup();
                        reject(e);
                    }
                }
            };

            ws.onerror = () => {
                console.error(`[${cameraId}] WebRTC: signaling WS error`);
                if (!resolved) {
                    resolved = true;
                    clearTimeout(timeout);
                    cleanup();
                    reject(new Error('WebRTC signaling WebSocket error'));
                }
            };

            ws.onclose = () => {
                console.log(`[${cameraId}] WebRTC: signaling WS closed`);
                if (!resolved) {
                    resolved = true;
                    clearTimeout(timeout);
                    cleanup();
                    reject(new Error('WebRTC signaling WebSocket closed'));
                }
                // After connection is established, signaling WS closing is fine —
                // the peer connection stays up independently.
            };

            // --- WEBRTC HEALTH MONITOR ---
            // Check that video frames are arriving every 3s.
            // Detect stalls in 6s (2 consecutive failures).
            let lastFrameCount = 0;
            let healthCheckFails = 0;
            healthTimer = setInterval(async () => {
                try {
                    if (!peer || peer.connectionState === 'closed' || peer.connectionState === 'failed') {
                        clearInterval(healthTimer);
                        return;
                    }
                    const stats = await peer.getStats();
                    let currentFrames = 0;
                    stats.forEach(report => {
                        if (report.type === 'inbound-rtp' && report.kind === 'video') {
                            currentFrames = report.framesDecoded || 0;
                        }
                    });
                    if (currentFrames === lastFrameCount && lastFrameCount > 0) {
                        healthCheckFails++;
                        if (healthCheckFails >= 2) {
                            console.warn(`[${cameraId}] WebRTC: no new frames for ${healthCheckFails * 3}s`);
                            clearInterval(healthTimer);
                            if (typeof config.onFailed === 'function') {
                                config.onFailed('stalled');
                            }
                        }
                    } else {
                        healthCheckFails = 0;
                    }
                    lastFrameCount = currentFrames;
                } catch (e) {
                    clearInterval(healthTimer);
                }
            }, 3000);

        } catch (err) {
            clearTimeout(timeout);
            if (!resolved) {
                resolved = true;
                cleanup();
                reject(err);
            }
        }
    });
}

/**
 * Clean up a WebRTC connection (peer + signaling WebSocket).
 *
 * @param {{ peer: RTCPeerConnection, ws?: WebSocket, healthTimer?: number }} peerObj
 * @param {HTMLVideoElement} [videoEl]  If provided, detach srcObject.
 */
export function cleanupWebRTC(peerObj, videoEl) {
    if (!peerObj) return;
    if (peerObj.healthTimer) {
        clearInterval(peerObj.healthTimer);
        peerObj.healthTimer = null;
    }
    try {
        if (peerObj.ws && peerObj.ws.readyState < 2) {
            peerObj.ws.close();
        }
        if (peerObj.peer) {
            peerObj.peer.close();
        }
        if (videoEl && videoEl.srcObject) {
            videoEl.srcObject.getTracks().forEach(t => t.stop());
            videoEl.srcObject = null;
        }
    } catch (e) {
        console.error('cleanupWebRTC error:', e);
    }
}
