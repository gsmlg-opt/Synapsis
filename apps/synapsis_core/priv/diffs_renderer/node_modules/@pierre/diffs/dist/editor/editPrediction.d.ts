import { Position, TextEdit } from "./types.js";
import { TextDocumentChangeTransaction } from "./textDocumentChangeTransaction.js";
//#region src/editor/editPrediction.d.ts
interface EditPredictRequest {
  /** Current file name/path as supplied to the File or FileDiff component. */
  readonly path: string;
  /** Document version. */
  readonly version: number;
  /** Document end-of-line sequence. */
  readonly eol: '\n' | '\r\n' | '\r';
  /** Bounded slice of the file around the cursor (not the whole file). */
  readonly excerptText: string;
  /** Zero-based document line where the excerpt starts. */
  readonly excerptStartLine: number;
  /** UTF-16 cursor offset relative to `excerptText`. */
  readonly cursorOffsetInExcerpt: number;
  /** Half-open UTF-16 range within `excerptText` that may be edited. */
  readonly editableRange: {
    readonly start: number;
    readonly end: number;
  };
  /** Chronological, bounded edit history for this document. */
  readonly editHistory: ReadonlyArray<{
    /** Edit in unified-diff format. */
    readonly diff: string;
    /** Edit source. */
    readonly source: 'user' | 'prediction';
  }>;
}
interface EditPredictContext {
  /** Aborted when the document or cursor changes. */
  readonly signal: AbortSignal;
}
interface EditPredictResponse {
  /** Non-overlapping edits using absolute document positions. */
  readonly edits: readonly TextEdit[];
  /** Absolute post-edit cursor position. */
  readonly newCursor: Position;
}
interface EditPredictProvider {
  /** Predicts the next edit for the given request. */
  predict: (request: EditPredictRequest, context: EditPredictContext) => Promise<EditPredictResponse>;
}
interface EditPredictionHistoryRecord {
  readonly path: string;
  readonly hunk: string;
  readonly start: number;
  readonly end: number;
  readonly at: number;
  readonly source: 'user' | 'prediction';
  readonly fragment?: EditPredictionHistoryFragment;
}
interface EditPredictionDocument {
  readonly version: number;
  readonly eol: '\n' | '\r\n' | '\r';
  readonly lineCount: number;
  positionAt(offset: number): Position;
  positionsAt(offsets: readonly number[]): Position[];
  offsetAt(position: Position): number;
  getLineText(line: number): string;
  getLineLength(line: number): number;
  getTextSlice(start: number, end: number): string;
  charAt(offset: number): string;
}
interface EditPredictionHistoryFragment {
  readonly baseText: string;
  readonly currentText: string;
  readonly currentStart: number;
  readonly currentEnd: number;
  readonly startLine: number;
}
declare function recordEditPrediction(history: readonly EditPredictionHistoryRecord[], path: string, document: EditPredictionDocument, transaction: TextDocumentChangeTransaction, source: 'user' | 'prediction', at?: number): EditPredictionHistoryRecord[];
declare function buildEditPredictionRequest(path: string, document: EditPredictionDocument, cursorOffset: number, history: readonly EditPredictionHistoryRecord[], isLineEditable: (line: number) => boolean): EditPredictRequest | undefined;
declare function matchesEditPredictionPattern(path: string, pattern: string | RegExp): boolean;
//#endregion
export { EditPredictContext, EditPredictProvider, EditPredictRequest, EditPredictResponse, EditPredictionHistoryRecord, buildEditPredictionRequest, matchesEditPredictionPattern, recordEditPrediction };
//# sourceMappingURL=editPrediction.d.ts.map