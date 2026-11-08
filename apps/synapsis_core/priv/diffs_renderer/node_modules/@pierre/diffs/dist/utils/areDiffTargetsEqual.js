//#region src/utils/areDiffTargetsEqual.ts
function areDiffTargetsEqual(diffA, diffB) {
	return diffA?.cacheKey != null || diffB?.cacheKey != null ? diffA?.cacheKey === diffB?.cacheKey : diffA === diffB;
}
//#endregion
export { areDiffTargetsEqual };

//# sourceMappingURL=areDiffTargetsEqual.js.map