// [paseo-acp-model-rejection] Reject unavailable model selections before callers
// commit their requested model. Exit 0 writes a candidate, 10 means complete,
// 20 means missing/ambiguous/partially patched anchors and writes nothing.
import fs from 'node:fs';

const target = process.argv[2];
if (!target) {
    console.error('usage: acp-model-rejection.mjs <acp-agent.js>');
    process.exit(1);
}
const source = fs.readFileSync(target, 'utf8');
const edits = [
    ['available-model',
        '                this.warnInvalidSelection(modelId, `is not a valid ${this.provider} model. Available options: ${this.availableModels\n                    ?.map((model) => model.modelId)\n                    .join(", ")}`);\n                return;',
        '                this.warnInvalidSelection(modelId, `is not a valid ${this.provider} model. Available options: ${this.availableModels\n                    ?.map((model) => model.modelId)\n                    .join(", ")}`);\n                // [paseo-acp-model-rejection] An invalid selection must not look successful.\n                throw new Error(`Model ${modelId} is not a valid ${this.provider} model`);'],
    ['config-choice',
        '            this.warnInvalidSelection(modelId, `is not a valid ${this.provider} model config option. Available options: ${flattenSelectOptions(modelOption.options)\n                .map((option) => option.value)\n                .join(", ")}`);\n            return;',
        '            this.warnInvalidSelection(modelId, `is not a valid ${this.provider} model config option. Available options: ${flattenSelectOptions(modelOption.options)\n                .map((option) => option.value)\n                .join(", ")}`);\n            // [paseo-acp-model-rejection] Keep the previous model when the choice is unavailable.\n            throw new Error(`Model ${modelId} is not a valid ${this.provider} model config option`);'],
];
const unique = (text) => source.includes(text) && source.indexOf(text) === source.lastIndexOf(text);
if (edits.every(([, oldText, newText]) => unique(newText) && !source.includes(oldText))) {
    console.log('ALREADY');
    process.exit(10);
}
if (source.includes('[paseo-acp-model-rejection]') || !edits.every(([, oldText]) => unique(oldText))) {
    console.error('SKIP: anchors missing, ambiguous, or partially patched (upstream drift?)');
    process.exit(20);
}
let result = source;
for (const [, oldText, newText] of edits) result = result.replace(oldText, newText);
fs.writeFileSync(`${target}.paseo-new.mjs`, result);
console.log('PATCHED');
