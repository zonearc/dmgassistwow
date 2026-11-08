/**
 * WoW 12.0 Taint & Secret Value Audit Scanner
 *
 * This scanner is designed to be run against the TypeScript addon-generator
 * source file. It extracts Lua template strings from generate* functions and
 * checks them against the WoW 12.0 taint/secret value rules.
 *
 * Usage: npx tsx .agents/skills/wow-taint-model/reference/audit-scanner.ts
 */

import * as fs from "fs";
import * as path from "path";

interface Violation {
  rule: string;
  severity: "CRITICAL" | "HIGH" | "MEDIUM" | "LOW";
  generator: string;
  lineInTemplate: number;
  line: string;
  explanation: string;
}

// APIs that return secret values in WoW 12.0
const SECRET_RETURN_APIS: Record<string, { when: string; type: string }> = {
  "UnitHealth": { when: "always", type: "number" },
  "UnitHealthMax": { when: "always", type: "number" },
  "UnitName": { when: "non-player/pet in combat", type: "string" },
  "UnitFullName": { when: "non-player/pet in combat", type: "string" },
  "UnitClass": { when: "conditional", type: "string" },
  "UnitPower": { when: "power-restricted", type: "number" },
  "UnitPowerMax": { when: "power-restricted", type: "number" },
  "GetUnitName": { when: "non-player/pet in combat", type: "string" },
};

// Protected functions that must never be called from addon code
const PROTECTED_FUNCTIONS = [
  "C_UI.Reload",
  "ReloadUI",
  "CastSpellByName",
  "CastSpellByID",
  "CastSpellBySlot",
  "TargetUnit",
  "AssistUnit",
  "FocusUnit",
  "ClearFocus",
  "UseAction",
  "UseInventoryItem",
  "UseContainerItem",
  "JoinBattlefield",
  "AcceptBattlefieldPort",
  "PickupAction",
  "PlaceAction",
  "SetBinding",
  "SetBindingSpell",
  "SetBindingClick",
  "SetBindingItem",
  "RunMacro",
  "RunMacroText",
];

// Extract template blocks from generator functions
function extractTemplates(source: string): { name: string; template: string }[] {
  const templates: { name: string; template: string }[] = [];
  const funcRegex = /function (generate\w+)\([^)]*\)[^{]*\{/g;
  let match;

  while ((match = funcRegex.exec(source)) !== null) {
    const funcName = match[1];
    const startIdx = match.index;

    // Find matching closing brace
    let depth = 0;
    let funcEnd = startIdx;
    for (let i = match.index + match[0].length - 1; i < source.length; i++) {
      if (source[i] === "{") depth++;
      if (source[i] === "}") {
        depth--;
        if (depth === 0) {
          funcEnd = i;
          break;
        }
      }
    }

    const funcBody = source.substring(startIdx, funcEnd + 1);

    // Extract template literal content (backtick strings)
    const templateRegex = /`([\s\S]*?)`/g;
    let tmatch;
    const templateParts: string[] = [];
    while ((tmatch = templateRegex.exec(funcBody)) !== null) {
      templateParts.push(tmatch[1]);
    }

    if (templateParts.length > 0) {
      templates.push({
        name: funcName,
        template: templateParts.join("\n"),
      });
    }
  }

  return templates;
}

function checkRule_P1_DirectComparison(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];
  const apiNames = Object.keys(SECRET_RETURN_APIS);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("--")) continue; // skip Lua comments

    for (const api of apiNames) {
      // Check: api(...) == or api(...) ~= or api(...) < etc WITHOUT Detaint wrapper
      // Must distinguish == (comparison) from = (assignment). Look for ==, ~=, <=, >=, <, >
      const comparePattern = new RegExp(
        `${api}\\s*\\([^)]*\\)\\s*(?:==|~=|<=|>=|(?<!=)[<>](?!=))`,
      );
      if (comparePattern.test(line)) {
        const detaintWrapped = new RegExp(
          `Detaint(?:Str|Bool)?\\(\\s*${api}\\s*\\(`,
        );
        if (!detaintWrapped.test(line)) {
          violations.push({
            rule: "P1",
            severity: "CRITICAL",
            generator,
            lineInTemplate: i + 1,
            line: line.substring(0, 200),
            explanation: `Direct comparison with ${api}() return value. ${api} can return secret values (${SECRET_RETURN_APIS[api].when}). Must wrap in Detaint() first.`,
          });
        }
      }

      // Also check: something == api(...)
      const reversePattern = new RegExp(
        `(?:==|~=|<=|>=|(?<!=)[<>](?!=))\\s*${api}\\s*\\([^)]*\\)`,
      );
      if (reversePattern.test(line)) {
        const detaintWrapped = new RegExp(
          `Detaint(?:Str|Bool)?\\(\\s*${api}\\s*\\(`,
        );
        if (!detaintWrapped.test(line)) {
          violations.push({
            rule: "P1",
            severity: "CRITICAL",
            generator,
            lineInTemplate: i + 1,
            line: line.substring(0, 200),
            explanation: `Comparison against ${api}() return. Must wrap in Detaint() first.`,
          });
        }
      }
    }
  }

  return violations;
}

function checkRule_P2_BooleanTest(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];
  const apiNames = Object.keys(SECRET_RETURN_APIS);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("--")) continue;

    for (const api of apiNames) {
      // Check: if api(...) then / not api(...) / api(...) and
      const boolPatterns = [
        new RegExp(`if\\s+${api}\\s*\\(`),
        new RegExp(`not\\s+${api}\\s*\\(`),
        new RegExp(`${api}\\s*\\([^)]*\\)\\s+and\\b`),
        new RegExp(`${api}\\s*\\([^)]*\\)\\s+or\\b`),
      ];

      for (const pattern of boolPatterns) {
        if (pattern.test(line)) {
          // Skip if wrapped in Detaint
          const detaintWrapped = new RegExp(
            `Detaint(?:Str|Bool)?\\(\\s*${api}\\s*\\(`,
          );
          if (!detaintWrapped.test(line)) {
            violations.push({
              rule: "P2",
              severity: "CRITICAL",
              generator,
              lineInTemplate: i + 1,
              line: line.substring(0, 200),
              explanation: `Boolean test on ${api}() return value. Secret values cannot be boolean-tested. Wrap in Detaint() first.`,
            });
            break;
          }
        }
      }
    }
  }

  return violations;
}

function checkRule_P3_Arithmetic(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];
  const numericApis = Object.entries(SECRET_RETURN_APIS)
    .filter(([, v]) => v.type === "number")
    .map(([k]) => k);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("--")) continue;

    for (const api of numericApis) {
      // Check: api(...) + / - / * / /
      const arithPattern = new RegExp(
        `(?<!Detaint\\()${api}\\s*\\([^)]*\\)\\s*[+\\-*/%%]`,
      );
      if (arithPattern.test(line)) {
        const detaintWrapped = new RegExp(
          `Detaint\\(\\s*${api}\\s*\\(`,
        );
        if (!detaintWrapped.test(line)) {
          violations.push({
            rule: "P3",
            severity: "CRITICAL",
            generator,
            lineInTemplate: i + 1,
            line: line.substring(0, 200),
            explanation: `Arithmetic on ${api}() return value. Secret numbers cannot have arithmetic performed on them. Wrap in Detaint() first.`,
          });
        }
      }
    }
  }

  return violations;
}

function checkRule_P4_TableKey(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];
  const apiNames = Object.keys(SECRET_RETURN_APIS);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("--")) continue;

    for (const api of apiNames) {
      // Check: something[api(...)] = 
      const keyPattern = new RegExp(`\\[\\s*${api}\\s*\\(`);
      if (keyPattern.test(line)) {
        const detaintWrapped = new RegExp(
          `\\[\\s*Detaint(?:Str)?\\(\\s*${api}`,
        );
        if (!detaintWrapped.test(line)) {
          violations.push({
            rule: "P4",
            severity: "CRITICAL",
            generator,
            lineInTemplate: i + 1,
            line: line.substring(0, 200),
            explanation: `Using ${api}() as table key. This crashes AND irrevocably poisons the table. Wrap in DetaintStr()/Detaint() first.`,
          });
        }
      }
    }
  }

  return violations;
}

function checkRule_P5_MissingAliases(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];

  const hasAnyDetaintUsage = lines.some(
    (l) =>
      !l.trim().startsWith("--") &&
      (/Detaint\(/.test(l) ||
        /DetaintStr\(/.test(l) ||
        /DetaintBool\(/.test(l)),
  );

  if (!hasAnyDetaintUsage) return violations;

  const hasDetaintAlias = lines.some(
    (l) =>
      /local\s+Detaint\s*=/.test(l) ||
      /local\s+function\s+Detaint\s*\(/.test(l),
  );
  const hasDetaintStrAlias = lines.some(
    (l) =>
      /local\s+DetaintStr\s*=/.test(l) ||
      /local\s+function\s+DetaintStr\s*\(/.test(l),
  );
  const hasDetaintBoolAlias = lines.some(
    (l) =>
      /local\s+DetaintBool\s*=/.test(l) ||
      /local\s+function\s+DetaintBool\s*\(/.test(l),
  );

  const usesDetaintBare = (pattern: RegExp) =>
    lines.some(
      (l) => !l.trim().startsWith("--") && pattern.test(l),
    );

  const usesDetaint = usesDetaintBare(/(?<![.A-Za-z])Detaint\(/);
  const usesDetaintStr = lines.some(
    (l) => !l.trim().startsWith("--") && /(?<!CLF\.)DetaintStr\(/.test(l),
  );
  const usesDetaintBool = lines.some(
    (l) => !l.trim().startsWith("--") && /(?<!CLF\.)DetaintBool\(/.test(l),
  );

  if (usesDetaint && !hasDetaintAlias) {
    violations.push({
      rule: "P5",
      severity: "CRITICAL",
      generator,
      lineInTemplate: 0,
      line: "(file-level check)",
      explanation:
        'File uses Detaint() but has no "local Detaint = ..." alias. Will crash with "Detaint is nil".',
    });
  }
  if (usesDetaintStr && !hasDetaintStrAlias) {
    violations.push({
      rule: "P5",
      severity: "CRITICAL",
      generator,
      lineInTemplate: 0,
      line: "(file-level check)",
      explanation:
        'File uses DetaintStr() but has no "local DetaintStr = ..." alias. Will crash with "DetaintStr is nil".',
    });
  }
  if (usesDetaintBool && !hasDetaintBoolAlias) {
    violations.push({
      rule: "P5",
      severity: "CRITICAL",
      generator,
      lineInTemplate: 0,
      line: "(file-level check)",
      explanation:
        'File uses DetaintBool() but has no "local DetaintBool = ..." alias. Will crash with "DetaintBool is nil".',
    });
  }

  return violations;
}

function checkRule_P6_TostringEquals(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("--")) continue;

    // Check: tostring(val) == "true" or tostring(val) == "false"
    if (/tostring\s*\([^)]+\)\s*==\s*"(?:true|false)"/.test(line)) {
      violations.push({
        rule: "P6",
        severity: "HIGH",
        generator,
        lineInTemplate: i + 1,
        line: line.substring(0, 200),
        explanation:
          'tostring(val) == "true" can crash if val is a secret value. Use val==true fast path or string.find("true") pattern instead.',
      });
    }
  }

  return violations;
}

function checkRule_P7_ProtectedFunctions(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("--")) continue;

    for (const func of PROTECTED_FUNCTIONS) {
      const escaped = func.replace(".", "\\.");
      const pattern = new RegExp(`(?<![.-])${escaped}\\s*\\(`);
      if (pattern.test(line)) {
        violations.push({
          rule: "P7",
          severity: "CRITICAL",
          generator,
          lineInTemplate: i + 1,
          line: line.substring(0, 200),
          explanation: `Calling protected function ${func}(). This will fire ADDON_ACTION_BLOCKED in combat.`,
        });
      }
    }
  }

  return violations;
}

function checkRule_P10_SelectWithSecret(
  lines: string[],
  generator: string,
): Violation[] {
  const violations: Violation[] = [];
  const apiNames = Object.keys(SECRET_RETURN_APIS);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("--")) continue;

    for (const api of apiNames) {
      if (new RegExp(`select\\s*\\(\\s*${api}\\s*\\(`).test(line)) {
        violations.push({
          rule: "P10",
          severity: "HIGH",
          generator,
          lineInTemplate: i + 1,
          line: line.substring(0, 200),
          explanation: `Using ${api}() as index to select(). If the value is secret, this crashes.`,
        });
      }
    }
  }

  return violations;
}

function runAudit(sourceFile: string): void {
  const source = fs.readFileSync(sourceFile, "utf8");
  const templates = extractTemplates(source);
  const allViolations: Violation[] = [];

  console.log(`\n${"=".repeat(70)}`);
  console.log("WoW 12.0 TAINT & SECRET VALUE AUDIT");
  console.log(`${"=".repeat(70)}`);
  console.log(`Source: ${sourceFile}`);
  console.log(`Found ${templates.length} generator functions with templates\n`);

  for (const { name, template } of templates) {
    const lines = template.split("\n");

    const checks = [
      checkRule_P1_DirectComparison(lines, name),
      checkRule_P2_BooleanTest(lines, name),
      checkRule_P3_Arithmetic(lines, name),
      checkRule_P4_TableKey(lines, name),
      checkRule_P5_MissingAliases(lines, name),
      checkRule_P6_TostringEquals(lines, name),
      checkRule_P7_ProtectedFunctions(lines, name),
      checkRule_P10_SelectWithSecret(lines, name),
    ];

    for (const violations of checks) {
      allViolations.push(...violations);
    }
  }

  // Report
  const critical = allViolations.filter((v) => v.severity === "CRITICAL");
  const high = allViolations.filter((v) => v.severity === "HIGH");
  const medium = allViolations.filter((v) => v.severity === "MEDIUM");
  const low = allViolations.filter((v) => v.severity === "LOW");

  if (allViolations.length === 0) {
    console.log("✅ NO VIOLATIONS FOUND — All generated Lua is taint-safe!\n");
  } else {
    if (critical.length > 0) {
      console.log(`\n🔴 CRITICAL (${critical.length} — will crash in WoW):`);
      for (const v of critical) {
        console.log(`  [${v.rule}] ${v.generator}:${v.lineInTemplate}`);
        console.log(`       ${v.explanation}`);
        console.log(`       Code: ${v.line}`);
        console.log();
      }
    }

    if (high.length > 0) {
      console.log(`\n🟠 HIGH (${high.length} — likely to crash):`);
      for (const v of high) {
        console.log(`  [${v.rule}] ${v.generator}:${v.lineInTemplate}`);
        console.log(`       ${v.explanation}`);
        console.log(`       Code: ${v.line}`);
        console.log();
      }
    }

    if (medium.length > 0) {
      console.log(`\n🟡 MEDIUM (${medium.length}):`);
      for (const v of medium) {
        console.log(`  [${v.rule}] ${v.generator}:${v.lineInTemplate}`);
        console.log(`       ${v.explanation}`);
        console.log();
      }
    }

    if (low.length > 0) {
      console.log(`\n🔵 LOW (${low.length}):`);
      for (const v of low) {
        console.log(`  [${v.rule}] ${v.generator}:${v.lineInTemplate}`);
        console.log(`       ${v.explanation}`);
        console.log();
      }
    }
  }

  console.log(`${"=".repeat(70)}`);
  console.log(
    `SUMMARY: ${critical.length} critical, ${high.length} high, ${medium.length} medium, ${low.length} low`,
  );
  console.log(`${"=".repeat(70)}\n`);

  // Exit with error code if critical violations found
  if (critical.length > 0) {
    process.exit(1);
  }
}

// Run against the addon generator
const generatorPath = path.resolve(__dirname, "../../../../server/addon-generator.ts");
runAudit(generatorPath);
