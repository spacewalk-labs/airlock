// Drives complete methods and selection helpers extracted from a real delivered
// ACP module. --self-test also checks the vendored bundle and drift/idempotence.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

function excerpt(source, start, end) {
    const a = source.indexOf(start);
    const b = source.indexOf(end, a + start.length);
    assert.ok(a >= 0 && b > a, `missing method/helper: ${start}`);
    return source.slice(a, b).replace(/^export /, '');
}
async function verify(target, managerTarget) {
    const source = fs.readFileSync(target, 'utf8');
    const helpers = [
        excerpt(source, 'export function resolveACPModelSelection(', 'export function deriveModesFromACP('),
        excerpt(source, 'export function findSelectConfigOption(', 'function findSelectConfigOptionById('),
        excerpt(source, 'function findSelectConfigChoice(', 'function deriveConfigFeatureSelectOptions('),
    ].join('\n');
    const methods = excerpt(source, '    async setModel(modelId) {', '    async setThinkingOption(');
    const Session = new Function(`${helpers}\nreturn class {\n${methods}\n};`)();
    const managerSource = managerTarget ? fs.readFileSync(managerTarget, 'utf8') : null;
    const Manager = managerSource ? new Function(`return class {\n${excerpt(managerSource,
        '    async setAgentModel(agentId, modelId) {', '    async setAgentThinkingOption(')}\n};`)() : null;
    for (const kind of ['availableModels', 'configChoices']) {
        const calls = [], warnings = [], events = [];
        const session = Object.assign(new Session(), {
            provider: 'acp', sessionId: 'fixture', currentModel: 'previous',
            availableModels: kind === 'availableModels' ? [{ modelId: 'valid' }] : [],
            configOptions: kind === 'configChoices' ? [{ id: 'model', category: 'model', type: 'select',
                options: [{ group: 'fixture', options: [{ value: 'valid', name: 'Valid' }] }] }] : [],
            connection: {
                unstable_setSessionModel: async (request) => { calls.push(request); },
                setSessionConfigOption: async (request) => { calls.push(request); return {}; },
            },
            warnInvalidSelection: (...args) => warnings.push(args),
            modelSelectionUnavailableMessage: () => 'model selection unavailable',
            applyConfigOptionResponse: ({ requestedValue }) => requestedValue,
            runtimeInfo() { return { model: this.currentModel }; },
            pushEvent: (event) => events.push(event),
        });
        const agent = { session, config: { model: 'previous' }, runtimeInfo: { model: 'previous' } };
        const managerCalls = [];
        const manager = Manager ? Object.assign(new Manager(), {
            requireSessionAgent: () => agent,
            drainSessionEvents: async () => managerCalls.push('drain'),
            touchUpdatedAt: () => managerCalls.push('touch'),
            emitState: () => managerCalls.push('emit'),
        }) : null;
        const select = (model) => manager ? manager.setAgentModel('fixture', model) : session.setModel(model);
        await assert.rejects(select('missing-model'), /Model missing-model is not a valid acp model/);
        assert.equal(session.currentModel, 'previous');
        assert.equal(agent.config.model, 'previous');
        assert.equal(agent.runtimeInfo.model, 'previous');
        assert.deepEqual(calls, []);
        assert.deepEqual(events, []);
        assert.deepEqual(managerCalls, []);
        assert.equal(warnings.length, 1);
        await select('valid');
        assert.equal(session.currentModel, 'valid');
        assert.equal(calls.length, 1);
        assert.equal(events[0].type, 'model_changed');
        if (manager) {
            assert.equal(agent.config.model, 'valid');
            assert.equal(agent.runtimeInfo.model, 'valid');
            assert.deepEqual(managerCalls, ['drain', 'touch', 'emit']);
        }
    }
    console.log('PASS invalid model rejects without state changes; valid selections reach the ACP consumer');
}

if (process.argv[2] === '--self-test') {
    const patcher = process.argv[3];
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'paseo-model-rejection-'));
    try {
        const bundle = fileURLToPath(new URL('../vendor/guarded-0.8.0/getpaseo-server-0.8.0.tgz', import.meta.url));
        const acp = 'package/dist/server/server/agent/providers/acp-agent.js';
        const manager = 'package/dist/server/server/agent/agent-manager.js';
        const extraction = spawnSync('tar', ['-xzf', bundle, '-C', tmp, acp, manager], { encoding: 'utf8' });
        assert.equal(extraction.status, 0, extraction.stderr);
        const target = path.join(tmp, acp);
        const original = fs.readFileSync(target, 'utf8');
        const run = () => spawnSync(process.execPath, [patcher, target], { encoding: 'utf8' });
        assert.equal(run().status, 0);
        const candidate = `${target}.paseo-new.mjs`;
        assert.equal(spawnSync(process.execPath, ['--check', candidate]).status, 0);
        await verify(candidate, path.join(tmp, manager));
        const patched = fs.readFileSync(candidate, 'utf8');
        fs.unlinkSync(candidate);
        fs.writeFileSync(target, patched);
        assert.equal(run().status, 10);
        assert.ok(!fs.existsSync(candidate));
        for (const broken of [
            original.replace('model config option. Available options:', 'broken config anchor. Available options:'),
            original + original,
            patched.replace('throw new Error(`Model ${modelId} is not a valid ${this.provider} model`);', 'return;'),
        ]) {
            fs.writeFileSync(target, broken);
            assert.equal(run().status, 20);
            assert.equal(fs.readFileSync(target, 'utf8'), broken);
            assert.ok(!fs.existsSync(candidate));
        }
        console.log('PASS complete idempotence and missing/duplicate/partial anchors fail closed');
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
} else {
    if (!process.argv[2]) throw new Error('usage: acp-model-rejection.test.mjs <acp-agent.js> [agent-manager.js]');
    await verify(process.argv[2], process.argv[3]);
}
