/**
 * AVA Doorbell v4.0 — Toast Notifications
 *
 * Lightweight, auto-dismissing toast notifications.
 * Creates DOM elements dynamically; no container required.
 */

/**
 * Display a toast notification at the bottom of the viewport.
 *
 * @param {string} message  Text to display.
 * @param {'info'|'success'|'error'|'warning'} type  Visual style (default 'info').
 * @param {number} duration  Milliseconds before auto-dismiss (default 3000).
 */
export function showToast(message, type = 'info', duration = 3000) {
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    toast.textContent = message;
    document.body.appendChild(toast);

    setTimeout(() => {
        toast.style.opacity = '0';
        setTimeout(() => toast.remove(), 300);
    }, duration);
}
