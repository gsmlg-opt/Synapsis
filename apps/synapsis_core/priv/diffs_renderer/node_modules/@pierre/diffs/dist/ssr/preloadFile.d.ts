import { FileContents, LineAnnotation } from "../types.js";
import { FileOptions } from "../components/File.js";
//#region src/ssr/preloadFile.d.ts
type PreloadFileOptions<LAnnotation, Caret> = {
  file: FileContents;
  options?: FileOptions<LAnnotation, Caret>;
  annotations?: LineAnnotation<LAnnotation>[];
};
interface PreloadedFileResult<LAnnotation, Caret> {
  file: FileContents;
  options?: FileOptions<LAnnotation, Caret>;
  annotations?: LineAnnotation<LAnnotation>[];
  prerenderedHTML: string;
}
declare function preloadFile<LAnnotation = undefined, Caret = undefined>({ file, options, annotations }: PreloadFileOptions<LAnnotation, Caret>): Promise<PreloadedFileResult<LAnnotation, Caret>>;
//#endregion
export { PreloadFileOptions, PreloadedFileResult, preloadFile };
//# sourceMappingURL=preloadFile.d.ts.map