/**
 * AVA Doorbell v4.0 — Logs Module
 *
 * Service log viewer with filtering and auto-refresh.
 */

import { fetchAPI } from './api.js';

let autoRefreshTimer = null;

async function refreshLogs() {
    const service = document.getElementById('logServiceFilter')?.value || 'all';
    const lines = document.getElementById('logLinesFilter')?.value || '100';
    const output = document.getElementById('logOutput');
    if (!output) return;

    try {
        const resp = await fetchAPI(`/api/logs?service=${service}&lines=${lines}`);
        const data = await resp.json();

        if (data.error) {
            output.textContent = `Error: ${data.error}`;
            return;
        }

        if (data.lines && data.lines.length > 0) {
            // Color-code log lines by severity
            output.innerHTML = '';
            for (const line of data.lines) {
                const span = document.createElement('span');
                span.textContent = line;
                if (/\b(error|fatal|exception|traceback|panic)\b/i.test(line)) {
                    span.className = 'log-error';
                } else if (/\b(warn|warning)\b/i.test(line)) {
                    span.className = 'log-warn';
                }
                output.appendChild(span);
                output.appendChild(document.createTextNode('\n'));
            }
            const viewer = document.getElementById('logViewer');
            if (viewer) viewer.scrollTop = viewer.scrollHeight;
        } else {
            output.textContent = 'No log entries found.';
        }
    } catch (e) {
        output.textContent = `Failed to fetch logs: ${e.message}`;
    }
}

function toggleAutoRefresh(enabled) {
    if (autoRefreshTimer) {
        clearInterval(autoRefreshTimer);
        autoRefreshTimer = null;
    }
    if (enabled) {
        autoRefreshTimer = setInterval(refreshLogs, 5000);
    }
}

export function initLogs() {
    const refreshBtn = document.getElementById('refreshLogsBtn');
    const serviceFilter = document.getElementById('logServiceFilter');
    const linesFilter = document.getElementById('logLinesFilter');
    const autoRefreshCb = document.getElementById('logAutoRefresh');

    if (refreshBtn) refreshBtn.addEventListener('click', refreshLogs);
    if (serviceFilter) serviceFilter.addEventListener('change', refreshLogs);
    if (linesFilter) linesFilter.addEventListener('change', refreshLogs);
    if (autoRefreshCb) {
        autoRefreshCb.addEventListener('change', () => {
            toggleAutoRefresh(autoRefreshCb.checked);
            if (autoRefreshCb.checked) refreshLogs();
        });
    }
}
