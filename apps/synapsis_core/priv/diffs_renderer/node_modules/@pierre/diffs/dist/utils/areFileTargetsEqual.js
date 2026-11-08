//#region src/utils/areFileTargetsEqual.ts
function areFileTargetsEqual(fileA, fileB) {
	return fileA?.cacheKey != null || fileB?.cacheKey != null ? fileA?.cacheKey === fileB?.cacheKey : fileA?.contents === fileB?.contents && fileA?.name === fileB?.name && fileA?.lang === fileB?.lang;
}
//#endregion
export { areFileTargetsEqual };

//# sourceMappingURL=areFileTargetsEqual.js.map