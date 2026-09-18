// Unit tests for the pure helpers in acp-agent.ts (model grouping/resolution,
// tool description) and subprocess-backed live catalog recovery.
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import {
  AntigravityAcpAgent,
  buildAvailableCommands,
  collectSkillCommands,
  describeTool,
  groupModels,
  parseModelId,
  parseSkillDescription,
  readSkillsJsonRoots,
  resolveAgyModel,
  scanSkillRoot,
  skillRootsFor,
} from '../dist/acp-agent.js';

const SAMPLE_MODELS = [
  ['gemini-3.8-flash-high', 'Gemini 3.8 Flash (High)'],
  ['gemini-3.8-flash-medium', 'Gemini 3.8 Flash (Medium)'],
  ['gemini-3.8-flash-low', 'Gemini 3.8 Flash (Low)'],
  ['claude-sonnet-4-6', 'Claude Sonnet 4.6 (Thinking)'],
];

describe('groupModels', () => {
  it('groups effort variants under one family, sorted low→high', () => {
    const families = groupModels(SAMPLE_MODELS);
    const flash = families.get('gemini-3.8-flash');
    assert.ok(flash);
    assert.equal(flash.name, 'Gemini 3.8 Flash');
    assert.deepEqual(flash.efforts, ['low', 'medium', 'high']);
  });

  it('treats a model with no effort suffix as its own family with no efforts', () => {
    const families = groupModels(SAMPLE_MODELS);
    const sonnet = families.get('claude-sonnet-4-6');
    assert.ok(sonnet);
    assert.deepEqual(sonnet.efforts, []);
  });
});

describe('parseModelId', () => {
  it('splits a family-effort id', () => {
    assert.deepEqual(parseModelId('gemini-3.8-flash-high'), { family: 'gemini-3.8-flash', effort: 'high' });
  });

  it('leaves an id with no effort suffix as its own family', () => {
    assert.deepEqual(parseModelId('claude-sonnet-4-6'), { family: 'claude-sonnet-4-6', effort: undefined });
  });

  it('handles undefined', () => {
    assert.deepEqual(parseModelId(undefined), { family: undefined, effort: undefined });
  });
});

describe('resolveAgyModel', () => {
  const families = groupModels(SAMPLE_MODELS);

  it('returns the exact family-effort id when the effort is offered', () => {
    assert.equal(resolveAgyModel(families, 'gemini-3.8-flash', 'high'), 'gemini-3.8-flash-high');
  });

  it('falls back to the nearest offered effort, higher on a tie', () => {
    // claude-sonnet-4-6 offers no effort variants at all -> family id itself.
    assert.equal(resolveAgyModel(families, 'claude-sonnet-4-6', 'high'), 'claude-sonnet-4-6');
  });

  it('defaults to medium when no effort is requested', () => {
    assert.equal(resolveAgyModel(families, 'gemini-3.8-flash', undefined), 'gemini-3.8-flash-medium');
  });

  it('returns the family id itself for an unknown family', () => {
    assert.equal(resolveAgyModel(families, 'unknown-family', 'high'), 'unknown-family');
  });
});

describe('describeTool', () => {
  it('titles a shell command execution and truncates a long one', () => {
    const long = 'x'.repeat(200);
    const tool = describeTool({ name: 'run_command', parameters: { CommandLine: long } });
    assert.equal(tool.kind, 'execute');
    assert.ok(tool.title.startsWith(`Run ${'x'.repeat(120)}\n…`));
    assert.equal(tool.rawInput.command, long);
  });

  it('titles a file read with the basename only', () => {
    const tool = describeTool({ name: 'view_file', parameters: { AbsolutePath: '/repo/src/deep/path/file.ts' } });
    assert.equal(tool.kind, 'read');
    assert.equal(tool.title, 'Read file.ts');
    assert.deepEqual(tool.locations, [{ path: '/repo/src/deep/path/file.ts' }]);
  });

  it('falls back to the raw tool name for an unmapped tool', () => {
    const tool = describeTool({ name: 'some_future_tool', parameters: {} });
    assert.equal(tool.kind, 'other');
    assert.equal(tool.title, 'some_future_tool');
  });

  it('falls back to a generic name when tool_info is missing entirely', () => {
    const tool = describeTool(undefined);
    assert.equal(tool.title, 'tool_execution');
    assert.equal(tool.kind, 'other');
  });
});

describe('parseSkillDescription', () => {
  it('reads a single-line description', () => {
    assert.equal(
      parseSkillDescription('---\nname: x\ndescription: Just a skill\n---\nbody\n'),
      'Just a skill',
    );
  });

  it('folds a >- block scalar to one line', () => {
    assert.equal(
      parseSkillDescription('---\nname: x\ndescription: >-\n  First line\n  second line\n---\n'),
      'First line second line',
    );
  });

  it('stops a block scalar at the next key', () => {
    assert.equal(
      parseSkillDescription('---\ndescription: >-\n  kept\nlicense: MIT\n---\n'),
      'kept',
    );
  });

  it('returns undefined without frontmatter or description', () => {
    assert.equal(parseSkillDescription('no frontmatter here'), undefined);
    assert.equal(parseSkillDescription('---\nname: x\n---\n'), undefined);
  });
});

describe('skill discovery', () => {
  async function fixtureHome() {
    const home = await mkdtemp(join(tmpdir(), 'agy-acp-home-'));
    const skillsRoot = join(home, 'skills');
    await mkdir(join(skillsRoot, 'alpha'), { recursive: true });
    await writeFile(
      join(skillsRoot, 'alpha', 'SKILL.md'),
      '---\nname: alpha\ndescription: >-\n  Alpha does things\n  across lines\n---\n',
    );
    await mkdir(join(skillsRoot, 'usage'), { recursive: true });
    await writeFile(join(skillsRoot, 'usage', 'SKILL.md'), '---\nname: usage\ndescription: clash\n---\n');
    await mkdir(join(skillsRoot, 'nodesc'), { recursive: true });
    await writeFile(join(skillsRoot, 'nodesc', 'SKILL.md'), '---\nname: nodesc\n---\n');
    await mkdir(join(skillsRoot, 'empty'), { recursive: true });
    await mkdir(join(home, '.gemini', 'config'), { recursive: true });
    await writeFile(
      join(home, '.gemini', 'config', 'skills.json'),
      JSON.stringify({ entries: [{ path: skillsRoot }, { path: 'relative/ignored' }] }),
    );
    return { home, skillsRoot };
  }

  it('reads absolute skills.json entry paths only', async () => {
    const { home, skillsRoot } = await fixtureHome();
    try {
      assert.deepEqual(readSkillsJsonRoots(home), [skillsRoot]);
      assert.deepEqual(readSkillsJsonRoots(join(home, 'nonexistent')), []);
    } finally {
      await rm(home, { recursive: true, force: true });
    }
  });

  it('orders roots workspace-first and skips unreadable ones', async () => {
    const { home, skillsRoot } = await fixtureHome();
    try {
      const cwd = await mkdtemp(join(tmpdir(), 'agy-acp-ws-'));
      try {
        assert.deepEqual(skillRootsFor(home, cwd), [
          join(cwd, '.agents', 'skills'),
          join(home, '.gemini', 'config', 'skills'),
          skillsRoot,
        ]);
      } finally {
        await rm(cwd, { recursive: true, force: true });
      }
    } finally {
      await rm(home, { recursive: true, force: true });
    }
  });

  it('scans one root level, requiring SKILL.md', async () => {
    const { home, skillsRoot } = await fixtureHome();
    try {
      assert.deepEqual(await scanSkillRoot(skillsRoot), [
        { name: 'alpha', description: 'Alpha does things across lines' },
        { name: 'nodesc', description: 'Run the nodesc skill' },
        { name: 'usage', description: 'clash' },
      ]);
      assert.deepEqual(await scanSkillRoot(join(skillsRoot, 'missing')), []);
    } finally {
      await rm(home, { recursive: true, force: true });
    }
  });

  it('builds picker commands: local first, first root wins, local wins clashes', async () => {
    const { home } = await fixtureHome();
    const cwd = await mkdtemp(join(tmpdir(), 'agy-acp-ws-'));
    try {
      await mkdir(join(cwd, '.agents', 'skills', 'alpha'), { recursive: true });
      await writeFile(
        join(cwd, '.agents', 'skills', 'alpha', 'SKILL.md'),
        '---\nname: alpha\ndescription: workspace wins\n---\n',
      );
      const commands = await buildAvailableCommands(home, cwd);
      const byName = new Map(commands.map((c) => [c.name, c.description]));
      // Local adapter command keeps its own description on clash.
      assert.equal(byName.get('usage'), 'View model quota usage');
      // Workspace root beats the skills.json root on duplicates.
      assert.equal(byName.get('alpha'), 'workspace wins');
      assert.equal(byName.get('nodesc'), 'Run the nodesc skill');
      assert.deepEqual(
        commands.map((c) => c.name).slice(0, 10),
        ['usage', 'credits', 'model', 'effort', 'agents', 'skills', 'hooks', 'permissions', 'changelog', 'help'],
      );
    } finally {
      await rm(cwd, { recursive: true, force: true });
      await rm(home, { recursive: true, force: true });
    }
  });

  it('collects nothing usable without any roots', async () => {
    assert.deepEqual(await collectSkillCommands('/nonexistent-home', '/nonexistent-ws'), []);
  });
});


describe('live model catalog recovery', () => {
  it('does not advertise or permanently cache a fallback after a failed listing', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'agy-model-catalog-'));
    const binary = join(dir, 'agy');
    const count = join(dir, 'calls');
    await writeFile(binary, `#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
const count = ${JSON.stringify(count)};
let calls = 0;
try { calls = Number(readFileSync(count, 'utf8')); } catch {}
writeFileSync(count, String(calls + 1));
if (calls === 0) { process.stderr.write('temporary catalog failure'); process.exit(1); }
process.stdout.write('gemini-3.7-flash-medium\\tGemini 3.7 Flash (Medium)\\n');
`, { mode: 0o700 });
    const agent = new AntigravityAcpAgent({ binaryPath: binary });
    try {
      await assert.rejects(agent.getModelCatalog(), /Could not list agy models/);
      const catalog = await agent.getModelCatalog();
      assert.deepEqual(catalog.list, [['gemini-3.7-flash-medium', 'Gemini 3.7 Flash (Medium)']]);
      assert.ok(catalog.families.has('gemini-3.7-flash'));
      assert.ok(!catalog.families.has('gemini-3.8-flash'), 'no fabricated fallback models');
      assert.equal(await agent.getModelCatalog(), catalog, 'successful catalog is cached');
    } finally {
      agent.closeAll();
      await rm(dir, { recursive: true, force: true });
    }
  });
});
