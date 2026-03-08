// ==UserScript==
// @name         Zeeie WebView Wheel Tamer
// @namespace    https://zeeie.local/
// @version      1.0.0
// @description  Normalize wheel scrolling inside the Windows WebView host.
// @author       Zeeie
// @match        *://*/*
// @run-at       document-start
// ==/UserScript==

(function () {
    'use strict';

    const MIN_WHEEL_FACTOR = 0.16;
    const MAX_WHEEL_FACTOR = 0.52;
    const LINE_HEIGHT_PX = 32;
    let listenerAttached = false;
    let activeTarget = null;
    let queuedDeltaX = 0;
    let queuedDeltaY = 0;
    let animationFrameId = 0;

    function isInternalPage() {
        return location.hostname === 'localhost' &&
            location.pathname.startsWith('/assets/web/');
    }

    if (isInternalPage() || window.self !== window.top) {
        return;
    }

    function getPixelDelta(event) {
        const pageHeight = window.innerHeight || document.documentElement.clientHeight || 800;
        const unit = event.deltaMode === 1
            ? LINE_HEIGHT_PX
            : event.deltaMode === 2
                ? pageHeight
                : 1;
        return {
            x: event.deltaX * unit,
            y: event.deltaY * unit,
        };
    }

    function getAdaptiveFactor(dx, dy) {
        const magnitude = Math.max(Math.abs(dx), Math.abs(dy));
        if (magnitude <= 0) {
            return MIN_WHEEL_FACTOR;
        }

        // Small wheel notches are aggressively tamed, while larger flicks keep
        // more travel distance so fast scrolling still works.
        const normalized = Math.min(1, magnitude / 720);
        return MIN_WHEEL_FACTOR + (MAX_WHEEL_FACTOR - MIN_WHEEL_FACTOR) * normalized;
    }

    function isScrollableAxis(overflowValue) {
        return overflowValue === 'auto' ||
            overflowValue === 'scroll' ||
            overflowValue === 'overlay';
    }

    function getRootScroller() {
        return document.scrollingElement || document.documentElement || document.body;
    }

    function canScrollElement(el, dx, dy) {
        if (!el) {
            return false;
        }

        const maxX = el.scrollWidth - el.clientWidth;
        const maxY = el.scrollHeight - el.clientHeight;
        if (maxX <= 0 && maxY <= 0) {
            return false;
        }

        if (el === getRootScroller()) {
            const canScrollX = dx < 0 ? el.scrollLeft > 0 : dx > 0 ? el.scrollLeft < maxX : false;
            const canScrollY = dy < 0 ? el.scrollTop > 0 : dy > 0 ? el.scrollTop < maxY : false;
            return canScrollX || canScrollY;
        }

        const style = getComputedStyle(el);
        const canScrollX = isScrollableAxis(style.overflowX) &&
            maxX > 0 &&
            (dx < 0 ? el.scrollLeft > 0 : dx > 0 ? el.scrollLeft < maxX : false);
        const canScrollY = isScrollableAxis(style.overflowY) &&
            maxY > 0 &&
            (dy < 0 ? el.scrollTop > 0 : dy > 0 ? el.scrollTop < maxY : false);
        return canScrollX || canScrollY;
    }

    function findScrollTarget(start, dx, dy) {
        let node = start instanceof Element ? start : null;
        while (node) {
            if (canScrollElement(node, dx, dy)) {
                return node;
            }
            node = node.parentElement;
        }

        const root = getRootScroller();
        return canScrollElement(root, dx, dy) ? root : null;
    }

    function shouldSkip(event) {
        if (event.defaultPrevented || event.ctrlKey) {
            return true;
        }

        const target = event.target;
        if (!(target instanceof Element)) {
            return false;
        }

        const tagName = target.tagName;
        if (tagName === 'IFRAME' || tagName === 'EMBED' || tagName === 'OBJECT') {
            return true;
        }

        return !!target.closest('[data-zeeie-wheel-ignore]');


    }

    function applyScroll(target, dx, dy) {
        if (!target) {
            return;
        }

        if (dx !== 0) {
            target.scrollLeft += dx;
        }
        if (dy !== 0) {
            target.scrollTop += dy;
        }
    }

    function takeStep(value) {
        if (value === 0) {
            return 0;
        }

        const sign = value > 0 ? 1 : -1;
        const absValue = Math.abs(value);
        const eased = absValue * 0.35;
        const step = Math.min(absValue, Math.max(0.75, eased));
        return sign * step;
    }

    function pumpScroll() {
        animationFrameId = 0;

        if (!activeTarget) {
            queuedDeltaX = 0;
            queuedDeltaY = 0;
            return;
        }

        const stepX = takeStep(queuedDeltaX);
        const stepY = takeStep(queuedDeltaY);

        if (stepX === 0 && stepY === 0) {
            queuedDeltaX = 0;
            queuedDeltaY = 0;
            return;
        }

        applyScroll(activeTarget, stepX, stepY);
        queuedDeltaX -= stepX;
        queuedDeltaY -= stepY;

        if (Math.abs(queuedDeltaX) < 0.5) {
            queuedDeltaX = 0;
        }
        if (Math.abs(queuedDeltaY) < 0.5) {
            queuedDeltaY = 0;
        }

        if (queuedDeltaX !== 0 || queuedDeltaY !== 0) {
            animationFrameId = requestAnimationFrame(pumpScroll);
        }
    }

    function enqueueScroll(target, dx, dy) {
        if (!target) {
            return;
        }

        if (activeTarget !== target) {
            activeTarget = target;
            queuedDeltaX = 0;
            queuedDeltaY = 0;
        }

        queuedDeltaX += dx;
        queuedDeltaY += dy;

        if (!animationFrameId) {
            animationFrameId = requestAnimationFrame(pumpScroll);
        }
    }

    function onWheel(event) {
        if (shouldSkip(event)) {
            return;
        }

        const delta = getPixelDelta(event);
        if (delta.x === 0 && delta.y === 0) {
            return;
        }

        const target = findScrollTarget(event.target, delta.x, delta.y);
        if (!target) {
            return;
        }

        event.preventDefault();
        const factor = getAdaptiveFactor(delta.x, delta.y);
        enqueueScroll(target, delta.x * factor, delta.y * factor);
    }

    function attachListener() {
        if (listenerAttached) {
            return;
        }
        listenerAttached = true;
        window.addEventListener('wheel', onWheel, { passive: false, capture: true });
    }

    attachListener();
})();
