import { ChangeContent, FileDiffMetadata, Hunk } from "../types.js";
//#region src/utils/realignChangeContent.d.ts
/**
 * Re-split count-mismatched change blocks in every hunk so paired lines are
 * chosen by content similarity instead of position. Mutates `hunks` in place
 * without moving changes across context lines; rendered row counts are
 * unchanged (a split block covers the same split/unified rows as the original).
 */
declare function realignChangeContentBySimilarity(diff: Pick<FileDiffMetadata, 'hunks' | 'additionLines' | 'deletionLines'>): void;
/**
 * During editing, slide pure insert/delete blocks made entirely of blank lines
 * to the top of the blank run they sit in. Adding or removing a blank line next to
 * existing blanks is ambiguous, and the diff library reports the change at
 * the run's bottom — so pressing Enter at the end of a line marks a blank
 * *below* the caret as inserted while the caret's own new line renders as
 * context. Sliding up anchors the change to the content above it (the caret
 * line after an Enter) instead.
 *
 * `resolveSlide` receives each block that qualifies along with the full
 * distance to the run's top and returns how far to actually move it; 0 keeps
 * the parsed position. Without it, every qualifying block slides to the top.
 *
 * The slide only applies when the block comes to rest directly beneath
 * remaining in-hunk content. A slide that would consume the
 * hunk's entire leading context was stopped by the hunk's edge — a context
 * window cut, not the top of the blank run — and that landing spot is
 * arbitrary, so the block keeps the library's bottom-of-run anchor (which
 * sits against the content below the run). Non-blank blocks never slide, so
 * code that merely ends like its neighbor (an added function before an
 * identical `}`) keeps the library's canonical position.
 */
declare function slideBlankBoundaryBlocksUp(hunk: Hunk, diff: Pick<FileDiffMetadata, 'additionLines' | 'deletionLines'>, resolveSlide?: (block: ChangeContent, maxSlide: number) => number): void;
//#endregion
export { realignChangeContentBySimilarity, slideBlankBoundaryBlocksUp };
//# sourceMappingURL=realignChangeContent.d.ts.map