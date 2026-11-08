import { AnnotationSide } from "../types.js";
//#region src/utils/lineAnnotationIdentity.d.ts
interface LineAnnotationPosition {
  lineNumber: number;
  side?: AnnotationSide;
}
/**
 * Resolve a possibly-remapped annotation back to the original object it
 * descends from. Annotations that were never cloned resolve to themselves.
 */
declare function getLineAnnotationSource<T extends LineAnnotationPosition>(annotation: T): T;
declare function recordLineAnnotationSource(moved: LineAnnotationPosition, annotation: LineAnnotationPosition): void;
//#endregion
export { LineAnnotationPosition, getLineAnnotationSource, recordLineAnnotationSource };
//# sourceMappingURL=lineAnnotationIdentity.d.ts.map