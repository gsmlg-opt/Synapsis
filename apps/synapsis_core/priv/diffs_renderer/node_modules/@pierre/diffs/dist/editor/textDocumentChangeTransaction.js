//#region src/editor/textDocumentChangeTransaction.ts
const transactions = /* @__PURE__ */ new WeakMap();
function getTextDocumentChangeTransaction(change) {
	return transactions.get(change);
}
function setTextDocumentChangeTransaction(change, transaction) {
	transactions.set(change, transaction);
}
//#endregion
export { getTextDocumentChangeTransaction, setTextDocumentChangeTransaction };

//# sourceMappingURL=textDocumentChangeTransaction.js.map