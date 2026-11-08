//#region src/utils/composeCacheKey.ts
const CACHE_KEY_VERSION = 1;
/** Encodes caller-controlled segments without delimiter ambiguity. */
function composeCacheKey(scope, ...segments) {
	return `ck${CACHE_KEY_VERSION}:${JSON.stringify([scope, ...segments])}`;
}
//#endregion
export { composeCacheKey };

//# sourceMappingURL=composeCacheKey.js.map