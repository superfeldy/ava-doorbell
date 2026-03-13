/**
 * AVA Doorbell v4.0 — Per-Cell Fullscreen Toggle
 *
 * Tap or click a camera cell to toggle fullscreen.
 * Press Escape or tap again to exit.
 *
 * Uses a small movement threshold to avoid triggering on swipes.
 */

let fullscreenCell = null;
let touchStartX = 0;
let touchStartY = 0;
let lastToggleTime = 0;
let initialized = false;
const TAP_MOVE_THRESHOLD = 20; // px — ignore taps that moved too far (swipes)
const TOGGLE_DEBOUNCE_MS = 300; // ignore rapid double-taps

/**
 * Initialize fullscreen handling on camera cells.
 *
 * @param {HTMLElement} viewport  The #viewport container.
 */
export function initFullscreen(viewport) {
    if (!viewport) return;
    if (initialized) return;
    initialized = true;

    // Track touch start position to distinguish taps from swipes
    viewport.addEventListener('touchstart', (e) => {
        if (e.touches.length === 1) {
            touchStartX = e.touches[0].clientX;
            touchStartY = e.touches[0].clientY;
        }
    }, { passive: true });

    viewport.addEventListener('touchend', (e) => {
        if (e.changedTouches.length === 1) {
            const dx = e.changedTouches[0].clientX - touchStartX;
            const dy = e.changedTouches[0].clientY - touchStartY;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < TAP_MOVE_THRESHOLD) {
                const cell = e.target.closest('.camera-cell');
                if (cell && !cell.classList.contains('empty')
                    && !cell.querySelector('.loading-overlay, .reconnect-overlay')) {
                    toggleFullscreen(cell);
                }
            }
        }
    });

    // Mouse click fallback (non-touch devices)
    viewport.addEventListener('click', (e) => {
        // Skip if this was a touch event (touchend already handled it)
        if (e.sourceCapabilities && e.sourceCapabilities.firesTouchEvents) return;
        const cell = e.target.closest('.camera-cell');
        if (!cell || cell.classList.contains('empty')) return;
        if (cell.querySelector('.loading-overlay, .reconnect-overlay')) return;
        toggleFullscreen(cell);
    });

    // Escape key to exit fullscreen
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && fullscreenCell) {
            exitFullscreen();
        }
    });
}

/**
 * Toggle fullscreen on a camera cell.
 */
function toggleFullscreen(cell) {
    const now = Date.now();
    if (now - lastToggleTime < TOGGLE_DEBOUNCE_MS) return;
    lastToggleTime = now;

    if (fullscreenCell === cell) {
        exitFullscreen();
    } else {
        // Exit any existing fullscreen first
        if (fullscreenCell) exitFullscreen();
        cell.classList.add('fullscreen');
        fullscreenCell = cell;
    }
}

/**
 * Exit fullscreen mode.
 */
export function exitFullscreen() {
    if (fullscreenCell) {
        fullscreenCell.classList.remove('fullscreen');
        fullscreenCell = null;
    }
}

/**
 * Check if any cell is currently fullscreen.
 */
export function isFullscreen() {
    return fullscreenCell !== null;
}
