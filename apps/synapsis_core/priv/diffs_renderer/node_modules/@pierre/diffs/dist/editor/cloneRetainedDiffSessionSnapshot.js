import { cloneHunks } from "../utils/cloneFileDiffMetadata.js";
//#region src/editor/cloneRetainedDiffSessionSnapshot.ts
function cloneRetainedDiffSessionSnapshot(snapshot) {
	return {
		...snapshot,
		oldFile: snapshot.oldFile != null ? {
			...snapshot.oldFile,
			lines: [...snapshot.oldFile.lines]
		} : null,
		hunks: cloneHunks(snapshot.hunks)
	};
}
//#endregion
export { cloneRetainedDiffSessionSnapshot };

//# sourceMappingURL=cloneRetainedDiffSessionSnapshot.js.map