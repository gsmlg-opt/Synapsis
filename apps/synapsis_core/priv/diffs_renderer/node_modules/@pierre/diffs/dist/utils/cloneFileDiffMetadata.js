//#region src/utils/cloneFileDiffMetadata.ts
function cloneHunks(hunks) {
	return hunks.map((hunk) => ({
		...hunk,
		hunkContent: hunk.hunkContent.map((content) => ({ ...content }))
	}));
}
function cloneFileDiffMetadata(fileDiff) {
	return {
		...fileDiff,
		hunks: cloneHunks(fileDiff.hunks),
		deletionLines: [...fileDiff.deletionLines],
		additionLines: [...fileDiff.additionLines]
	};
}
//#endregion
export { cloneFileDiffMetadata, cloneHunks };

//# sourceMappingURL=cloneFileDiffMetadata.js.map