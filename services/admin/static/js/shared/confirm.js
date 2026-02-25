/**
 * AVA Doorbell v4.0 — Confirmation Dialog
 *
 * Promise-based modal using CSS classes from common.css.
 */

/**
 * Show a confirmation dialog.
 *
 * @param {string} title  Dialog title.
 * @param {string} message  Dialog body text.
 * @param {Object} [options]  { confirmText, cancelText, danger }
 * @returns {Promise<boolean>}  true if confirmed, false if cancelled.
 */
export function showConfirm(title, message, options = {}) {
    return new Promise((resolve) => {
        const { confirmText = 'Confirm', cancelText = 'Cancel', danger = false } = options;

        const backdrop = document.createElement('div');
        backdrop.className = 'modal-backdrop show';

        const modal = document.createElement('div');
        modal.className = 'modal';
        modal.innerHTML = `
            <div class="modal-title">${esc(title)}</div>
            <div class="modal-body">${esc(message)}</div>
            <div class="modal-actions">
                <button class="btn btn-secondary cancel-btn">${esc(cancelText)}</button>
                <button class="btn ${danger ? 'btn-danger' : 'btn-primary'} confirm-btn">${esc(confirmText)}</button>
            </div>
        `;

        backdrop.appendChild(modal);
        document.body.appendChild(backdrop);

        function close(result) {
            backdrop.remove();
            document.removeEventListener('keydown', onKey);
            resolve(result);
        }

        function onKey(e) {
            if (e.key === 'Escape') close(false);
            if (e.key === 'Enter') close(true);
        }

        modal.querySelector('.confirm-btn').addEventListener('click', () => close(true));
        modal.querySelector('.cancel-btn').addEventListener('click', () => close(false));
        backdrop.addEventListener('click', (e) => { if (e.target === backdrop) close(false); });
        document.addEventListener('keydown', onKey);

        modal.querySelector('.confirm-btn').focus();
    });
}

function esc(str) {
    const d = document.createElement('div');
    d.textContent = str;
    return d.innerHTML;
}
