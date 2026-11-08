import { FileDiffOptions } from "../components/FileDiff.js";
import { PreloadFileDiffResult } from "./preloadDiffs.js";
//#region src/ssr/preloadPatchFile.d.ts
type PreloadPatchFileOptions<LAnnotation, Caret> = {
  patch: string;
  options?: FileDiffOptions<LAnnotation, Caret>;
};
declare function preloadPatchFile<LAnnotation = undefined, Caret = undefined>({ patch, options }: PreloadPatchFileOptions<LAnnotation, Caret>): Promise<PreloadFileDiffResult<LAnnotation, Caret>[]>;
//#endregion
export { PreloadPatchFileOptions, preloadPatchFile };
//# sourceMappingURL=preloadPatchFile.d.ts.map