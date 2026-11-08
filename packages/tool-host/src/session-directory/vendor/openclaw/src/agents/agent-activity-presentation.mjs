import { asOptionalObjectRecord as asRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { normalizeLowercaseStringOrEmpty } from "../../packages/normalization-core/src/string-coerce.mjs";
import { groupToolCalls } from "../chat/tool-call-grouping.mjs";
import { isAgentPlanProgressToolName } from "../session-cards/progress-card-input.mjs";
export function resolveCompletedActivityWrappers 
                                   
                
                      
                                        
                                        
      
    
 (calls                 )            {
  const wrappers = new Set      ();
  const parentsFirst                        = [];
  const pending = groupToolCalls(calls);
  while (pending.length > 0) {
    const group = pending.pop() ;
    parentsFirst.push(group);
    for (const child of group.children) {
      pending.push(child);
    }
  }
  // Children settle before their parent: a nested wrapper kept for its own routine
  // calls stands for the wrapper above it, and so does a visible call under a hidden one.
  const shown = new Set                     ();
  for (const group of parentsFirst.toReversed()) {
    const { activity } = group.card;
    const childShown = group.children.some((child) => shown.has(child));
    if (childShown && activity?.status === "completed") {
      wrappers.add(group.card);
    }
    // A call still active at settlement has no recorded outcome, so on its own it does
    // not stand for its wrapper; a visible call beneath it still does.
    if (
      childShown ||
      (activity && !activity.hideFromChannelProgress && !activity.suppressChannelProgress)
    ) {
      shown.add(group);
    }
  }
  return wrappers;
}
export function projectAgentActivityItem 
                
                  
                  
                    
                   
                                      
    
 (
  item      ,
  facts                                                                                  = {},
)                                               {
  if (item.kind === "analysis") {
    return { ...item, hideFromChannelProgress: true };
  }
  const name = normalizeLowercaseStringOrEmpty(item.name);
  const details = asRecord(asRecord(facts.result)?.details);
  // Tool completion is not command success. Preserve the execution contract and
  // expose a normal nonzero exit only in the prepared activity outcome.
  if (
    item.phase === "end" &&
    item.status === "completed" &&
    (name === "exec" || name === "bash" || name === "process") &&
    details?.status === "completed" &&
    details.exitReason !== "manual-cancel" &&
    typeof details.exitCode === "number" &&
    Number.isFinite(details.exitCode) &&
    details.exitCode !== 0
  ) {
    return { ...item, status: "failed" };
  }
  const routine =
    facts.nativeOperation === "wait" ||
    facts.nativeOperation === "process.poll" ||
    isAgentPlanProgressToolName(name) ||
    name === "sessions_yield" ||
    (name === "process" && asRecord(facts.args)?.action === "poll") ||
    (name === "message" && asRecord(facts.args)?.action === "react");
  return routine && (item.status === "running" || item.status === "completed")
    ? { ...item, hideFromChannelProgress: true }
    : item;
}