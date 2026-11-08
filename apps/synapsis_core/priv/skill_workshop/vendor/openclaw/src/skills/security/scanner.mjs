import { expectDefined } from "../../../packages/normalization-core/src/expect.mjs";
import { truncateUtf16Safe } from "../../../packages/normalization-core/src/utf16-slice.mjs";
import { escapeRegExp } from "../../shared/regexp.mjs";
import { formatScanEvidence, LITERAL_SECRET_SKILL_CONTENT_RULE } from "./scan-evidence.mjs";
                                                      

                                
                 
                              
               
               
                  
                   
  

const MAX_LINE_RULE_FINDINGS_PER_RULE = 32;
                 
                 
                              
                  
                  
                                                                                      
                           
  

                              
                                                                                       
                                      
  

const LINE_RULES             = [
  {
    ruleId: "dangerous-exec",
    severity: "critical",
    message: "Shell command execution detected (child_process)",
    // Capture the method in group 1 for direct calls and group 2 for computed calls.
    pattern:
      /\b(exec|execSync|spawn|spawnSync|execFile|execFileSync)\s*\(|["'](exec|execSync|spawn|spawnSync|execFile|execFileSync)["']\s*\]\s*\(/,
    requiresContext: /child_process/,
  },
  {
    ruleId: "dynamic-code-execution",
    severity: "critical",
    message: "Dynamic code execution detected",
    pattern: /\beval\s*\(|new\s+Function\s*\(/,
  },
  {
    ruleId: "crypto-mining",
    severity: "critical",
    message: "Possible crypto-mining reference detected",
    pattern: /stratum\+tcp|stratum\+ssl|coinhive|cryptonight|xmrig/i,
  },
  {
    ruleId: "suspicious-network",
    severity: "warn",
    message: "WebSocket connection to non-standard port",
    pattern: /new\s+WebSocket\s*\(\s*["']wss?:\/\/[^"']*:(\d+)/,
  },
];

const STANDARD_PORTS = new Set([80, 443, 8080, 8443, 3000]);
const NETWORK_SEND_CONTEXT_PATTERN = /\bfetch\s*\(|\bpost\s*\(|\.\s*post\s*\(|http\.request\s*\(/i;

const SOURCE_RULES               = [
  {
    ruleId: "potential-exfiltration",
    severity: "warn",
    message: "File read combined with network send — possible data exfiltration",
    pattern: /readFileSync|readFile/,
    requiresContext: NETWORK_SEND_CONTEXT_PATTERN,
  },
  {
    ruleId: "obfuscated-code",
    severity: "warn",
    message: "Hex-encoded string sequence detected (possible obfuscation)",
    pattern: /(\\x[0-9a-fA-F]{2}){6,}/,
  },
  {
    ruleId: "obfuscated-code",
    severity: "warn",
    message: "Large base64 payload with decode call detected (possible obfuscation)",
    pattern: /(?:atob|Buffer\.from)\s*\(\s*["'][A-Za-z0-9+/=]{200,}["']/,
  },
  {
    ruleId: "env-harvesting",
    severity: "critical",
    message:
      "Environment variable access combined with network send — possible credential harvesting",
    pattern: /process\.env/,
    requiresContext: NETWORK_SEND_CONTEXT_PATTERN,
    requiresContextWindowLines: 8,
  },
];

const SKILL_CONTENT_RULES               = [
  LITERAL_SECRET_SKILL_CONTENT_RULE,
  {
    ruleId: "shell-pipe-to-shell",
    severity: "critical",
    message: "Skill text includes pipe-to-shell install pattern",
    pattern: /\b(curl|wget)\b[^|\n]{0,120}\|\s*(sh|bash|zsh)\b/i,
  },
  {
    ruleId: "secret-exfiltration",
    severity: "critical",
    message: "Skill text may exfiltrate environment variables",
    pattern: /\b(process\.env|env)\b.{0,80}\b(fetch|curl|wget|http|https)\b/i,
  },
  {
    ruleId: "destructive-delete",
    severity: "warn",
    message: "Skill text contains broad destructive delete command",
    pattern: /\brm\s+-rf\s+(\/|\$HOME|~|\.)/i,
  },
  {
    ruleId: "unsafe-permissions",
    severity: "warn",
    message: "Skill text contains unsafe permission change",
    pattern: /\bchmod\s+(-R\s+)?777\b/i,
  },
];

const CHILD_PROCESS_EXEC_METHODS = new Set([
  "exec",
  "execSync",
  "spawn",
  "spawnSync",
  "execFile",
  "execFileSync",
]);

                             
                             
                                
  

// Only imports/requires establish provenance; unrelated aliases must not match.
function collectChildProcessBindings(source        )                       {
  const methodAliases = new Set        ();
  const namespaceAliases = new Set        ();

  // ESM named imports: import { spawn as launch, execFile } from "child_process"
  const esmNamed = /\bimport\s*\{([^}]*)\}\s*from\s*["'](?:node:)?child_process["']/g;
  // ESM default namespace: import cp from "child_process"
  const esmDefault = /\bimport\s+(\w+)\s+from\s*["'](?:node:)?child_process["']/g;
  // ESM namespace import: import * as proc from "child_process"
  const esmNamespace = /\bimport\s*\*\s*as\s+(\w+)\s+from\s*["'](?:node:)?child_process["']/g;
  // CJS destructured: const { exec: run, spawn } = require("child_process")
  const cjsDestructured =
    /\b(?:const|let|var)\s*\{([^}]*)\}\s*=\s*require\s*\(\s*["'](?:node:)?child_process["']\s*\)/g;
  // CJS namespace: const proc = require("child_process")
  const cjsNamespace =
    /\b(?:const|let|var)\s+(\w+)\s*=\s*require\s*\(\s*["'](?:node:)?child_process["']\s*\)/g;

  const collectSpecifiers = (specText        )       => {
    for (const rawSpec of specText.split(",")) {
      const spec = rawSpec.trim();
      // Renamed binding: `spawn as launch` (ESM) or `exec: run` (CJS)
      const asMatch = spec.match(/^(\w+)\s+(?:as)\s+(\w+)$/) ?? spec.match(/^(\w+)\s*:\s*(\w+)$/);
      if (asMatch?.[1] && asMatch[2]) {
        if (CHILD_PROCESS_EXEC_METHODS.has(asMatch[1])) {
          methodAliases.add(asMatch[2]);
        }
      }
      // Bare imported method name (`execFile`) is already matched by the
      // literal pattern, so no alias entry is needed for it.
    }
  };

  for (const pattern of [esmNamed, cjsDestructured]) {
    for (const match of source.matchAll(pattern)) {
      collectSpecifiers(expectDefined(match[1], "child_process import specifiers"));
    }
  }
  for (const pattern of [esmDefault, esmNamespace, cjsNamespace]) {
    for (const match of source.matchAll(pattern)) {
      namespaceAliases.add(expectDefined(match[1], "child_process namespace"));
    }
  }

  return { methodAliases, namespaceAliases };
}

// Report every standalone alias call in source order, excluding object members.
function matchAliasedChildProcessCalls(line        , methodAliases             )           {
  const calls           = [];
  for (const alias of methodAliases) {
    const pattern = new RegExp(`(?<![\\w.])${escapeRegExp(alias)}\\s*\\(`, "g");
    for (const callMatch of line.matchAll(pattern)) {
      calls.push(callMatch.index);
    }
  }
  return calls.toSorted((a, b) => a - b);
}

// Retain the conventional child_process names alongside proven namespace aliases.
const LITERAL_NAMESPACE_RECEIVERS = new Set(["cp", "childProcess", "child_process"]);

function isBenignMemberExecMatch(
  line        ,
  match                 ,
  namespaceAliases             ,
)          {
  // group 1 = direct call command, group 2 = computed-member command.
  const command = match[1] ?? match[2];
  if (!command) {
    return false;
  }

  const matchIndex = match.index;
  const charAtMatch = line[matchIndex];
  let receiver                    ;
  // Computed calls require a known receiver for every watched method;
  // direct calls require it only for .exec, excluding RegExp.exec.
  if (charAtMatch === '"' || charAtMatch === "'") {
    receiver = line.slice(0, matchIndex).match(/(\w+)\s*\[\s*$/)?.[1];
  } else if (command === "exec" && matchIndex > 0 && line[matchIndex - 1] === ".") {
    receiver = line.slice(0, matchIndex - 1).match(/(\w+)\s*$/)?.[1];
  } else {
    return false;
  }
  return (
    !receiver || (!namespaceAliases.has(receiver) && !LITERAL_NAMESPACE_RECEIVERS.has(receiver))
  );
}

function stripCommentsForHeuristics(source        )         {
  let stripped = "";
  let quote                         = null;
  let escaped = false;

  for (let i = 0; i < source.length; i++) {
    const ch = source[i] ?? "";
    const next = source[i + 1] ?? "";

    if (quote) {
      stripped += ch;
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === quote) {
        quote = null;
      }
      continue;
    }

    if (ch === "'" || ch === '"' || ch === "`") {
      quote = ch;
      stripped += ch;
      continue;
    }

    if (ch === "/" && (next === "/" || next === "*")) {
      const end = source.indexOf(next === "/" ? "\n" : "*/", i + 2);
      const afterComment = end < 0 ? source.length : end + (next === "/" ? 1 : 2);
      stripped += source.slice(i, afterComment).replace(/[^\n]/g, "");
      i = afterComment - 1;
      continue;
    }

    stripped += ch;
  }

  return stripped;
}

function findSourceRuleMatch(params   
                   
                 
                  
 )                                            {
  const sourceMatch = params.rule.pattern.exec(params.source);
  if (!sourceMatch) {
    return null;
  }
  if (params.rule.requiresContext && !params.rule.requiresContext.test(params.source)) {
    return null;
  }

  for (let i = 0; i < params.lines.length; i++) {
    if (!params.rule.pattern.test(params.lines[i] ?? "")) {
      continue;
    }

    if (params.rule.requiresContext && params.rule.requiresContextWindowLines !== undefined) {
      const start = Math.max(0, i - params.rule.requiresContextWindowLines);
      const end = Math.min(params.lines.length, i + params.rule.requiresContextWindowLines + 1);
      const windowSource = params.lines.slice(start, end).join("\n");
      if (!params.rule.requiresContext.test(windowSource)) {
        continue;
      }
    }

    return { line: i + 1, evidence: params.lines[i] ?? "" };
  }

  if (params.rule.requiresContextWindowLines !== undefined) {
    return null;
  }

  // Multiline rules cannot match any one line. Preserve the actual match start
  // so stored findings point at the dangerous text instead of file metadata.
  let line = 1;
  for (let i = 0; i < sourceMatch.index; i++) {
    if (params.source.charCodeAt(i) === 10) {
      line += 1;
    }
  }
  return { line, evidence: params.lines[line - 1] ?? truncateUtf16Safe(params.source, 120) };
}

export function scanSource(source        , filePath        )                     {
  const findings                     = [];
  const lines = source.split("\n");
  const heuristicSource = stripCommentsForHeuristics(source);

  const { methodAliases, namespaceAliases } = collectChildProcessBindings(heuristicSource);

  for (const rule of LINE_RULES) {
    if (rule.requiresContext && !rule.requiresContext.test(source)) {
      continue;
    }

    let acceptedMatches = 0;
    let omittedMatches = 0;
    let lastOmittedLine                    ;
    const addFinding = (line        , lineNumber        )       => {
      if (acceptedMatches >= MAX_LINE_RULE_FINDINGS_PER_RULE) {
        omittedMatches += 1;
        lastOmittedLine = lineNumber;
        return;
      }
      findings.push({
        ruleId: rule.ruleId,
        severity: rule.severity,
        file: filePath,
        line: lineNumber,
        message: rule.message,
        evidence: formatScanEvidence(line),
      });
      acceptedMatches += 1;
    };
    for (const [i, line] of lines.entries()) {
      const matches = line.matchAll(
        new RegExp(
          rule.pattern.source,
          rule.pattern.flags.includes("g") ? rule.pattern.flags : `${rule.pattern.flags}g`,
        ),
      );
      const literalDangerousExecIndexes = new Set        ();
      for (const match of matches) {
        if (
          rule.ruleId === "dangerous-exec" &&
          isBenignMemberExecMatch(line, match, namespaceAliases)
        ) {
          continue;
        }

        if (rule.ruleId === "suspicious-network") {
          const port = Number.parseInt(expectDefined(match[1], "scanner regex capture 1"), 10);
          if (STANDARD_PORTS.has(port)) {
            continue;
          }
        }

        addFinding(line, i + 1);
        if (rule.ruleId === "dangerous-exec") {
          literalDangerousExecIndexes.add(match.index);
        }
      }

      // Aliases follow literal matches; don't emit a call twice if both patterns match.
      if (rule.ruleId === "dangerous-exec" && methodAliases.size > 0) {
        for (const index of matchAliasedChildProcessCalls(line, methodAliases)) {
          if (literalDangerousExecIndexes.has(index)) {
            continue;
          }
          addFinding(line, i + 1);
        }
      }
    }
    if (lastOmittedLine !== undefined) {
      findings.push({
        ruleId: `${rule.ruleId}-truncated`,
        severity: rule.severity,
        file: filePath,
        line: lastOmittedLine,
        message: `${omittedMatches} additional ${rule.ruleId} matches omitted after ${MAX_LINE_RULE_FINDINGS_PER_RULE} findings`,
        evidence: `[${omittedMatches} additional matches omitted after ${MAX_LINE_RULE_FINDINGS_PER_RULE} findings]`,
      });
    }
  }

  findings.push(...scanSourceRules(SOURCE_RULES, heuristicSource, filePath, lines));
  return findings;
}

export function scanSkillContent(content        , filePath        )                     {
  return scanSourceRules(SKILL_CONTENT_RULES, content, filePath);
}

function scanSourceRules(
  rules                       ,
  source        ,
  filePath        ,
  evidenceLines           ,
)                     {
  const findings                     = [];
  const lines = source.split("\n");

  for (const rule of rules) {
    const match = findSourceRuleMatch({ rule, source, lines });
    if (!match) {
      continue;
    }
    findings.push({
      ruleId: rule.ruleId,
      severity: rule.severity,
      file: filePath,
      line: match.line,
      message: rule.message,
      // Scanner output is user-visible; redact the whole evidence line if any rule sees a key.
      evidence:
        rule.ruleId === "literal-secret"
          ? "[REDACTED CREDENTIAL]"
          : formatScanEvidence((evidenceLines ?? lines)[match.line - 1] ?? match.evidence),
    });
  }

  return findings;
}
