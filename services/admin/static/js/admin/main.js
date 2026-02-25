/**
 * AVA Doorbell v4.0 — Admin Dashboard Entry Point
 *
 * Section navigation, mobile sidebar, module initialization.
 */

import { initDashboard } from './dashboard.js';
import { initCameras } from './cameras.js';
import { initLayouts } from './layouts.js';
import { initSettings } from './settings.js';
import { initDiscovery } from './discovery.js';
import { initLogs } from './logs.js';
import { initBackup } from './backup.js';

const SECTIONS = ['dashboard', 'cameras', 'layouts', 'settings', 'discovery', 'logs', 'backup'];

function init() {
    // Section navigation
    document.querySelectorAll('.sidebar-link').forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            const section = link.dataset.section;
            if (section) showSection(section);
            // Close mobile sidebar
            document.querySelector('.sidebar')?.classList.remove('show');
        });
    });

    // Mobile hamburger
    const hamburger = document.getElementById('hamburgerBtn');
    if (hamburger) {
        hamburger.addEventListener('click', () => {
            document.querySelector('.sidebar')?.classList.toggle('show');
        });
    }

    // Initialize all modules
    initDashboard();
    initCameras();
    initLayouts();
    initSettings();
    initDiscovery();
    initLogs();
    initBackup();

    // Show initial section from URL hash or default to dashboard
    const hash = location.hash.replace('#', '');
    showSection(SECTIONS.includes(hash) ? hash : 'dashboard');
}

function showSection(name) {
    SECTIONS.forEach(s => {
        const el = document.getElementById(`section-${s}`);
        if (el) el.classList.toggle('active', s === name);
    });

    document.querySelectorAll('.sidebar-link').forEach(link => {
        link.classList.toggle('active', link.dataset.section === name);
    });

    location.hash = name;
}

document.addEventListener('DOMContentLoaded', init);
