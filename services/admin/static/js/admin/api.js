/**
 * AVA Doorbell v4.0 — API Module
 *
 * Centralised fetch wrapper with auth redirect, connection-state
 * tracking, automatic retry on 5xx with exponential backoff.
 */

import { showToast } from '../shared/toast.js';

let _serverReachable = true;
let _consecutiveFailures = 0;

function setServerReachable(reachable) {
    const banner = document.getElementById('connectionBanner');
    if (reachable && !_serverReachable) {
        if (banner) banner.classList.remove('show');
        _consecutiveFailures = 0;
        showToast('Server reconnected', 'success');
    } else if (!reachable && _serverReachable) {
        if (banner) banner.classList.add('show');
    }
    _serverReachable = reachable;
}

export function isServerReachable() { return _serverReachable; }
export function getConsecutiveFailures() { return _consecutiveFailures; }

/**
 * Fetch with auto-retry on 5xx errors (3 attempts, exponential backoff).
 * Auto-redirects on 401 (session expired).
 */
export async function fetchAPI(url, options = {}) {
    const maxRetries = options._noRetry ? 0 : 2;
    let lastError = null;

    // CSRF protection: add X-Requested-With header to all requests
    if (!options.headers) options.headers = {};
    if (typeof options.headers === 'object' && !options.headers['X-Requested-With']) {
        options.headers['X-Requested-With'] = 'XMLHttpRequest';
    }

    // Abort after 15s to prevent indefinite hangs
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 15000);
    if (!options.signal) options.signal = controller.signal;

    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            const resp = await fetch(url, options);

            if (resp.status === 401) {
                window.location.href = '/login';
                throw new Error('Session expired');
            }

            // Retry on 5xx server errors
            if (resp.status >= 500 && attempt < maxRetries) {
                console.warn(`[api] ${url} returned ${resp.status}, retrying (${attempt + 1}/${maxRetries})`);
                await sleep(1000 * Math.pow(2, attempt));
                continue;
            }

            clearTimeout(timeoutId);
            setServerReachable(true);
            return resp;
        } catch (err) {
            // Provide a clearer message for timeout aborts
            if (err.name === 'AbortError') {
                lastError = new Error('Request timed out — check your connection to the Pi');
            } else {
                lastError = err;
            }
            if (attempt < maxRetries) {
                console.warn(`[api] ${url} network error, retrying (${attempt + 1}/${maxRetries}):`, lastError.message);
                await sleep(1000 * Math.pow(2, attempt));
            }
        }
    }

    clearTimeout(timeoutId);
    // All retries exhausted
    _consecutiveFailures++;
    setServerReachable(false);
    throw lastError || new Error('Request failed');
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
