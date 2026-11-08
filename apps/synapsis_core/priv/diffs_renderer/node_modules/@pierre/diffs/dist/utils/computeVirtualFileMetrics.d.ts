import { HunkSeparators, VirtualFileMetrics } from "../types.js";
//#region src/utils/computeVirtualFileMetrics.d.ts
declare function computeVirtualFileMetrics(metrics?: Partial<VirtualFileMetrics>): VirtualFileMetrics;
declare function getVirtualFileHeaderRegion(metrics: VirtualFileMetrics, disableFileHeader: boolean): number;
declare function getVirtualFileHeaderHeight(metrics: VirtualFileMetrics, disableFileHeader: boolean): number;
declare function getVirtualFilePaddingTop(metrics: VirtualFileMetrics, disableFileHeader: boolean): number;
declare function getVirtualFilePaddingBottom(metrics: VirtualFileMetrics): number;
declare function getDefaultHunkSeparatorHeight(type: HunkSeparators): number;
//#endregion
export { computeVirtualFileMetrics, getDefaultHunkSeparatorHeight, getVirtualFileHeaderHeight, getVirtualFileHeaderRegion, getVirtualFilePaddingBottom, getVirtualFilePaddingTop };
//# sourceMappingURL=computeVirtualFileMetrics.d.ts.map