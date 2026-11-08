import { DiffFileInput, DiffLineAnnotation, FileContents, FileDiffMetadata, MaybeDiffFileInput } from "../types.js";
import { FileDiffOptions } from "../components/FileDiff.js";
import { UnresolvedFileOptions } from "../components/UnresolvedFile.js";
//#region src/ssr/preloadDiffs.d.ts
interface PreloadDiffBaseOptions<LAnnotation, Caret> {
  options?: FileDiffOptions<LAnnotation, Caret>;
  annotations?: DiffLineAnnotation<LAnnotation>[];
}
type PreloadDiffOptions<LAnnotation, Caret> = PreloadDiffBaseOptions<LAnnotation, Caret> & (({
  fileDiff: FileDiffMetadata;
} & MaybeDiffFileInput) | ({
  fileDiff?: undefined;
} & DiffFileInput));
declare function preloadDiffHTML<LAnnotation = undefined, Caret = undefined>({ fileDiff, oldFile, newFile, options, annotations }: PreloadDiffOptions<LAnnotation, Caret>): Promise<string>;
declare function preloadUnresolvedFileHTML<LAnnotation = undefined>({ file, options, annotations }: PreloadUnresolvedFileOptions<LAnnotation>): Promise<string>;
interface PreloadMultiFileDiffBaseOptions<LAnnotation, Caret> {
  options?: FileDiffOptions<LAnnotation, Caret>;
  annotations?: DiffLineAnnotation<LAnnotation>[];
}
type PreloadMultiFileDiffOptions<LAnnotation, Caret> = PreloadMultiFileDiffBaseOptions<LAnnotation, Caret> & DiffFileInput;
type PreloadMultiFileDiffResult<LAnnotation, Caret> = PreloadMultiFileDiffOptions<LAnnotation, Caret> & {
  prerenderedHTML: string;
};
declare function preloadMultiFileDiff<LAnnotation = undefined, Caret = undefined>({ oldFile, newFile, options, annotations }: PreloadMultiFileDiffOptions<LAnnotation, Caret>): Promise<PreloadMultiFileDiffResult<LAnnotation, Caret>>;
interface PreloadFileDiffOptions<LAnnotation, Caret> {
  fileDiff: FileDiffMetadata;
  options?: FileDiffOptions<LAnnotation, Caret>;
  annotations?: DiffLineAnnotation<LAnnotation>[];
}
interface PreloadFileDiffResult<LAnnotation, Caret> extends PreloadFileDiffOptions<LAnnotation, Caret> {
  prerenderedHTML: string;
}
declare function preloadFileDiff<LAnnotation = undefined, Caret = undefined>({ fileDiff, options, annotations }: PreloadFileDiffOptions<LAnnotation, Caret>): Promise<PreloadFileDiffResult<LAnnotation, Caret>>;
interface PreloadUnresolvedFileOptions<LAnnotation> {
  file: FileContents;
  options?: Omit<UnresolvedFileOptions<LAnnotation>, 'onMergeConflictAction' | 'onMergeConflictResolve' | 'onPostRender'>;
  annotations?: DiffLineAnnotation<LAnnotation>[];
}
interface PreloadUnresolvedFileResult<LAnnotation> extends PreloadUnresolvedFileOptions<LAnnotation> {
  prerenderedHTML: string;
}
declare function preloadUnresolvedFile<LAnnotation = undefined>({ file, options, annotations }: PreloadUnresolvedFileOptions<LAnnotation>): Promise<PreloadUnresolvedFileResult<LAnnotation>>;
interface PreloadPatchDiffOptions<LAnnotation, Caret> {
  patch: string;
  options?: FileDiffOptions<LAnnotation, Caret>;
  annotations?: DiffLineAnnotation<LAnnotation>[];
}
interface PreloadPatchDiffResult<LAnnotation, Caret> extends PreloadPatchDiffOptions<LAnnotation, Caret> {
  prerenderedHTML: string;
}
declare function preloadPatchDiff<LAnnotation = undefined, Caret = undefined>({ patch, options, annotations }: PreloadPatchDiffOptions<LAnnotation, Caret>): Promise<PreloadPatchDiffResult<LAnnotation, Caret>>;
//#endregion
export { PreloadDiffOptions, PreloadFileDiffOptions, PreloadFileDiffResult, PreloadMultiFileDiffOptions, PreloadMultiFileDiffResult, PreloadPatchDiffOptions, PreloadPatchDiffResult, PreloadUnresolvedFileOptions, PreloadUnresolvedFileResult, preloadDiffHTML, preloadFileDiff, preloadMultiFileDiff, preloadPatchDiff, preloadUnresolvedFile, preloadUnresolvedFileHTML };
//# sourceMappingURL=preloadDiffs.d.ts.map