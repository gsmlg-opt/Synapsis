import { ResolvedTextEdit } from "./types.js";
import { TextDocumentChange } from "./textDocument.js";
//#region src/editor/textDocumentChangeTransaction.d.ts
interface TextDocumentChangeTransaction {
  /** Edits applied to the document state before this change. */
  readonly appliedEdits: readonly ResolvedTextEdit[];
  /** Edits that restore the document state before this change. */
  readonly inverseEdits: readonly ResolvedTextEdit[];
}
declare function getTextDocumentChangeTransaction(change: TextDocumentChange): TextDocumentChangeTransaction | undefined;
declare function setTextDocumentChangeTransaction(change: TextDocumentChange, transaction: TextDocumentChangeTransaction): void;
//#endregion
export { TextDocumentChangeTransaction, getTextDocumentChangeTransaction, setTextDocumentChangeTransaction };
//# sourceMappingURL=textDocumentChangeTransaction.d.ts.map