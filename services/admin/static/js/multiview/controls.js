/**
 * AVA Doorbell v4.0 — Controls Bar
 *
 * Auto-hide after 3s of inactivity, layout cycling (1→2→4→6→8→9→1),
 * preset dropdown, auto-cycle toggle, mute, refresh.
 */

const LAYOUT_SIZES = ['single', '2up', '4up', '6up', '8up', '9up'];
const HIDE_DELAY = 3000;

let hideTimer = null;
let controlsEl = null;

/**
 * Initialize controls bar.
 *
 * @param {Object} state  Global multiview state.
 * @param {Object} callbacks  { onLayoutChange, onRefresh, onMuteToggle, onTalkToggle, onPresetChange, onAutoCycleToggle }
 */
export function initControls(state, callbacks) {
    controlsEl = document.getElementById('controls');
    if (!controlsEl) return;

    // Show controls initially, then auto-hide
    showControls();

    // Auto-hide on inactivity
    document.addEventListener('mousemove', showControls);
    document.addEventListener('touchstart', showControls, { passive: true });
    document.addEventListener('click', showControls);

    // Layout cycle button
    const layoutBtn = document.getElementById('btn-layout');
    if (layoutBtn) {
        layoutBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            const currentIdx = LAYOUT_SIZES.indexOf(state.currentLayout);
            const nextIdx = (currentIdx + 1) % LAYOUT_SIZES.length;
            const nextLayout = LAYOUT_SIZES[nextIdx];
            if (typeof callbacks.onLayoutChange === 'function') {
                callbacks.onLayoutChange(nextLayout);
            }
        });
    }

    // Mute button
    const muteBtn = document.getElementById('btn-mute');
    if (muteBtn) {
        muteBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            state.muted = !state.muted;
            muteBtn.classList.toggle('muted', state.muted);
            if (typeof callbacks.onMuteToggle === 'function') {
                callbacks.onMuteToggle(state.muted);
            }
        });
        // Set initial state
        muteBtn.classList.toggle('muted', state.muted);
    }

    // Talk button
    const talkBtn = document.getElementById('btn-talk');
    if (talkBtn) {
        talkBtn.addEventListener('mousedown', (e) => {
            e.stopPropagation();
            if (typeof callbacks.onTalkToggle === 'function') {
                callbacks.onTalkToggle(true);
            }
        });
        talkBtn.addEventListener('mouseup', () => {
            if (typeof callbacks.onTalkToggle === 'function') {
                callbacks.onTalkToggle(false);
            }
        });
        talkBtn.addEventListener('touchstart', (e) => {
            e.preventDefault();
            e.stopPropagation();
            if (typeof callbacks.onTalkToggle === 'function') {
                callbacks.onTalkToggle(true);
            }
        }, { passive: false });
        talkBtn.addEventListener('touchend', (e) => {
            e.preventDefault();
            if (typeof callbacks.onTalkToggle === 'function') {
                callbacks.onTalkToggle(false);
            }
        }, { passive: false });
    }

    // Refresh button
    const refreshBtn = document.getElementById('btn-refresh');
    if (refreshBtn) {
        refreshBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            if (typeof callbacks.onRefresh === 'function') {
                callbacks.onRefresh();
            }
        });
    }
}

/**
 * Show controls and restart auto-hide timer.
 */
function showControls() {
    if (!controlsEl) return;
    controlsEl.classList.remove('hidden');
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
        controlsEl.classList.add('hidden');
    }, HIDE_DELAY);
}

/**
 * Show or hide the talk button based on whether any camera has talk enabled.
 */
export function setTalkVisible(visible) {
    const talkBtn = document.getElementById('btn-talk');
    if (talkBtn) {
        talkBtn.classList.toggle('visible', visible);
    }
}

/**
 * Update talk button visual state.
 *
 * @param {'idle'|'connecting'|'recording'|'ring-attention'} state
 */
export function setTalkState(talkState) {
    const btn = document.getElementById('btn-talk');
    if (!btn) return;
    btn.classList.remove('connecting', 'recording', 'ring-attention');
    if (talkState !== 'idle') {
        btn.classList.add(talkState);
    }
}

/**
 * Get the list of available layout sizes.
 */
export function getLayoutSizes() {
    return [...LAYOUT_SIZES];
}
