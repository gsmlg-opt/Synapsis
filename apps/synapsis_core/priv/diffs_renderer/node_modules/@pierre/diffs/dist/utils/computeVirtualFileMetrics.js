import { DEFAULT_VIRTUAL_FILE_METRICS } from "../constants.js";
//#region src/utils/computeVirtualFileMetrics.ts
function computeVirtualFileMetrics(metrics) {
	return {
		...DEFAULT_VIRTUAL_FILE_METRICS,
		...metrics
	};
}
function getVirtualFileHeaderRegion(metrics, disableFileHeader) {
	return getVirtualFileHeaderHeight(metrics, disableFileHeader) + getVirtualFilePaddingTop(metrics, disableFileHeader);
}
function getVirtualFileHeaderHeight(metrics, disableFileHeader) {
	return disableFileHeader ? 0 : metrics.diffHeaderHeight;
}
function getVirtualFilePaddingTop(metrics, disableFileHeader) {
	return metrics.paddingTop ?? (disableFileHeader ? metrics.spacing : 0);
}
function getVirtualFilePaddingBottom(metrics) {
	return metrics.paddingBottom ?? metrics.spacing;
}
function getDefaultHunkSeparatorHeight(type) {
	switch (type) {
		case "simple": return 4;
		case "metadata":
		case "line-info":
		case "line-info-basic":
		case "custom": return 32;
	}
}
//#endregion
export { computeVirtualFileMetrics, getDefaultHunkSeparatorHeight, getVirtualFileHeaderHeight, getVirtualFileHeaderRegion, getVirtualFilePaddingBottom, getVirtualFilePaddingTop };

//# sourceMappingURL=computeVirtualFileMetrics.js.map