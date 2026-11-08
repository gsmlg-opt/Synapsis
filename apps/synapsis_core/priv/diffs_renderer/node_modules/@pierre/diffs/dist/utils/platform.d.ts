//#region src/utils/platform.d.ts
/**
 * Clears the cached platform/browser detection. Detection is memoized on first
 * call, so a test process that swaps `navigator` (e.g. to exercise Linux or
 * Safari behavior) must reset it; otherwise the value cached by an earlier test
 * leaks across tests and no longer matches the active navigator.
 */
declare function resetPlatformDetection(): void;
declare function isMacLike(): boolean;
declare function isLinux(): boolean;
declare function isSafari(): boolean;
declare function isFirefox(): boolean;
//#endregion
export { isFirefox, isLinux, isMacLike, isSafari, resetPlatformDetection };
//# sourceMappingURL=platform.d.ts.map