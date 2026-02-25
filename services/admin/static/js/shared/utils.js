/**
 * AVA Doorbell v4.0 — Shared Utilities
 *
 * Common helper functions used across the application.
 */

/**
 * Mask the password portion of an RTSP URL for safe logging/display.
 *
 * Given "rtsp://admin:secret@192.168.1.1/stream" returns
 * "rtsp://admin:****@192.168.1.1/stream".
 *
 * @param {string} url  URL that may contain embedded credentials.
 * @returns {string}  URL with password replaced by "****".
 */
export function maskPassword(url) {
    if (!url) return url;
    try {
        // Match rtsp://user:password@host... or http(s)://user:password@host...
        return url.replace(/:\/\/([^:]+):([^@]+)@/, '://$1:****@');
    } catch (e) {
        return url;
    }
}

/**
 * Convert a layout value to an array.
 * Handles both array and object ({"0": "cam1", "1": "cam2"}) formats
 * that may come from the config API.
 *
 * @param {Array|Object|null} layout  Layout value from config.
 * @param {number} size  Expected number of slots.
 * @returns {Array|null}
 */
export function toLayoutArray(layout, size) {
    if (Array.isArray(layout)) return layout;
    if (layout && typeof layout === 'object') {
        const arr = [];
        for (let i = 0; i < size; i++) {
            arr.push(layout[String(i)] || null);
        }
        return arr;
    }
    return null;
}
