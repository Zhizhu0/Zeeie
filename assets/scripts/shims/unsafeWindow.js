const unsafeWindow = typeof window !== 'undefined'
    ? window
    : (typeof globalThis !== 'undefined'
        ? globalThis
        : (typeof self !== 'undefined' ? self : {}));
