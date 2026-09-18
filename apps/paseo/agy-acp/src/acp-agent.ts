import * as acp from '@agentclientprotocol/sdk';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, rmSync } from 'node:fs';
import { appendFile, mkdir, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { AgySession } from './agy-session.js';
import { AgyStepUpdateEvent } from './types.js';

const execFileAsync = promisify(execFile);

export type Effort = 'low' | 'medium' | 'high';
const EFFORTS: Effort[] = ['low', 'medium', 'high'];

export type ModelEntry = [id: string, label: string];

const MODEL_LIST_TIMEOUT_MS = 15_000;

// Context window per model family. agy does not report it; these are the
// published limits of the underlying models.
function contextWindowFor(family: string): number {
  if (family.startsWith('gemini-')) return 1_048_576;
  if (family.startsWith('claude-')) return 200_000;
  if (family.startsWith('gpt-oss-')) return 131_072;
  return 1_000_000;
}

interface ModeDef {
  id: string;
  name: string;
  description: string;
  flags: { dangerouslySkipPermissions: boolean; agyMode?: 'accept-edits' | 'plan'; sandbox: boolean };
}

// agy runs headless, so any tool that would ask for approval is auto-denied.
// Each mode is therefore a fixed set of launch flags.
const MODES: ModeDef[] = [
  {
    id: 'bypassPermissions',
    name: 'Bypass permissions',
    description: 'Auto-approve every tool (--dangerously-skip-permissions)',
    flags: { dangerouslySkipPermissions: true, agyMode: undefined, sandbox: false },
  },
  {
    id: 'acceptEdits',
    name: 'Accept edits',
    description: 'File edits allowed; commands are auto-denied (--mode=accept-edits)',
    flags: { dangerouslySkipPermissions: false, agyMode: 'accept-edits', sandbox: false },
  },
  {
    id: 'plan',
    name: 'Plan',
    description: 'Read and write a plan only; workspace writes and commands are auto-denied (--mode=plan)',
    flags: { dangerouslySkipPermissions: false, agyMode: 'plan', sandbox: false },
  },
  {
    id: 'readOnly',
    name: 'Read only',
    description: 'Reads only; writes and commands are auto-denied',
    flags: { dangerouslySkipPermissions: false, agyMode: undefined, sandbox: false },
  },
  {
    id: 'sandbox',
    name: 'Sandbox',
    description: 'Auto-approve, terminal restricted (--sandbox)',
    flags: { dangerouslySkipPermissions: true, agyMode: undefined, sandbox: true },
  },
];

// Commands agy answers itself. They are refused (and end the process) inside a
// stream-json session, so they run as a separate `agy --print` invocation.
const LOCAL_COMMANDS: { name: string; description: string }[] = [
  { name: 'usage', description: 'View model quota usage' },
  { name: 'credits', description: 'Show remaining G1 credits' },
  { name: 'model', description: 'Show or set the model: /model <id>' },
  { name: 'effort', description: 'Show or set the reasoning effort: /effort low|medium|high' },
  { name: 'agents', description: 'List available custom agents' },
  { name: 'skills', description: 'List available skills' },
  { name: 'hooks', description: 'Show hook configurations' },
  { name: 'permissions', description: 'Show tool permissions' },
  { name: 'changelog', description: 'Show release notes' },
  { name: 'help', description: 'Show available commands' },
];
const LOCAL_COMMAND_ALIASES: Record<string, string> = { quota: 'usage', settings: 'config' };

export interface SkillCommand {
  name: string;
  description: string;
}

const SKILL_DESCRIPTION_LIMIT = 300;
const SKILL_NAME_PATTERN = /^[A-Za-z0-9_-]+$/;

// First line of a SKILL.md frontmatter `description:` — a single line or a
// `>`/`|` block scalar folded to one line. Unparseable input yields
// undefined and the caller falls back to a generic description.
export function parseSkillDescription(skillMd: string): string | undefined {
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---/.exec(skillMd);
  if (!frontmatter) return undefined;
  const lines = frontmatter[1].split('\n');
  const idx = lines.findIndex((line) => /^description:\s*(.*)$/.test(line));
  if (idx < 0) return undefined;
  const rest = (/^description:\s*(.*)$/.exec(lines[idx])?.[1] ?? '').trim();
  let text: string;
  if (/^[>|][-+]?(?:\s|$)/.test(rest)) {
    // Block scalar: the value is the following indented lines.
    const collected: string[] = [];
    const inline = rest.replace(/^[>|][-+]?/, '').trim();
    if (inline) collected.push(inline);
    for (const line of lines.slice(idx + 1)) {
      if (/^\s*$/.test(line)) continue;
      if (!/^[ \t]/.test(line)) break;
      collected.push(line.trim());
    }
    text = collected.join(' ');
  } else {
    text = rest.replace(/^['"]|['"]$/g, '');
  }
  text = text.replace(/\s+/g, ' ').trim();
  if (!text) return undefined;
  return text.length > SKILL_DESCRIPTION_LIMIT ? `${text.slice(0, SKILL_DESCRIPTION_LIMIT - 1)}…` : text;
}

// Absolute skill-root dirs from `~/.gemini/config/skills.json` entries.
// Unreadable/malformed config yields no roots, never an exception.
export function readSkillsJsonRoots(home: string): string[] {
  try {
    const parsed: unknown = JSON.parse(
      readFileSync(path.join(home, '.gemini', 'config', 'skills.json'), 'utf8'),
    );
    const entries = (parsed as { entries?: unknown }).entries;
    if (!Array.isArray(entries)) return [];
    return entries
      .map((entry) => (entry as { path?: unknown } | null)?.path)
      .filter((p): p is string => typeof p === 'string' && path.isAbsolute(p));
  } catch {
    return [];
  }
}

// Skill roots agy itself resolves, in precedence order: the workspace's
// `.agents/skills`, the global `~/.gemini/config/skills`, then whatever
// `skills.json` entries point at (normally `~/.claude/skills`). Only roots
// agy reads are advertised — listing a skill agy cannot resolve would turn
// the picker into a dead end. Notably NOT the workspace `.claude/skills`:
// agy never reads repo skills there.
export function skillRootsFor(home: string, cwd: string): string[] {
  return [
    path.join(cwd, '.agents', 'skills'),
    path.join(home, '.gemini', 'config', 'skills'),
    ...readSkillsJsonRoots(home),
  ];
}

// One-level scan: `<dir>/<name>/SKILL.md`. Missing/unreadable entries are
// skipped, so a half-written root degrades to fewer commands, not a failure.
export async function scanSkillRoot(dir: string): Promise<SkillCommand[]> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  const found: SkillCommand[] = [];
  for (const entry of entries) {
    if (!SKILL_NAME_PATTERN.test(entry.name)) continue;
    try {
      const st = entry.isSymbolicLink() ? await stat(path.join(dir, entry.name)) : entry;
      if (!st.isDirectory()) continue;
      const md = await readFile(path.join(dir, entry.name, 'SKILL.md'), 'utf8');
      found.push({
        name: entry.name,
        description: parseSkillDescription(md) ?? `Run the ${entry.name} skill`,
      });
    } catch {
      continue;
    }
  }
  found.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return found;
}

// All discoverable skills, first root wins on duplicate names.
export async function collectSkillCommands(home: string, cwd: string): Promise<SkillCommand[]> {
  const seen = new Set<string>();
  const out: SkillCommand[] = [];
  for (const root of skillRootsFor(home, cwd)) {
    for (const skill of await scanSkillRoot(root)) {
      if (seen.has(skill.name)) continue;
      seen.add(skill.name);
      out.push(skill);
    }
  }
  return out;
}

// What Paseo's `/` picker gets: the local adapter commands first, then
// skills unless the name collides (the local command wins — e.g. `skills`
// itself stays the lister, not a skill).
export async function buildAvailableCommands(
  home: string,
  cwd: string,
): Promise<{ name: string; description: string }[]> {
  const commands = LOCAL_COMMANDS.map(({ name, description }) => ({ name, description }));
  const taken = new Set(commands.map((command) => command.name));
  for (const skill of await collectSkillCommands(home, cwd)) {
    if (taken.has(skill.name)) continue;
    taken.add(skill.name);
    commands.push(skill);
  }
  return commands;
}

const TOOL_KINDS: Record<string, string> = {
  run_command: 'execute',
  send_command_input: 'execute',
  command_status: 'execute',
  view_file: 'read',
  list_dir: 'read',
  find_by_name: 'search',
  grep_search: 'search',
  write_to_file: 'edit',
  replace_file_content: 'edit',
  multi_replace_file_content: 'edit',
  sed_file: 'edit',
  notebook_edit: 'edit',
  read_url_content: 'fetch',
  search_web: 'fetch',
};

const TRANSCRIPT_TEXT_LIMIT = 8_000;

export interface ModelFamily {
  id: string;
  name: string;
  efforts: Effort[];
}

// Groups `agy models` entries ("gemini-3.8-flash-high", ...) by family
// ("gemini-3.8-flash") so the picker shows one model with an effort selector
// instead of one row per effort variant.
export function groupModels(list: ModelEntry[]): Map<string, ModelFamily> {
  const families = new Map<string, ModelFamily>();
  for (const [id, label] of list) {
    const match = /^(.*)-(low|medium|high)$/.exec(id);
    const familyId = match ? match[1] : id;
    const family = families.get(familyId) ?? {
      id: familyId,
      name: match ? label.replace(/\s*\((low|medium|high)\)\s*$/i, '') : label,
      efforts: [] as Effort[],
    };
    if (match) {
      family.efforts.push(match[2] as Effort);
    }
    families.set(familyId, family);
  }
  for (const family of families.values()) {
    family.efforts.sort((a, b) => EFFORTS.indexOf(a) - EFFORTS.indexOf(b));
  }
  return families;
}

export function parseModelId(modelId: string | undefined): { family: string | undefined; effort: Effort | undefined } {
  const match = /^(.*)-(low|medium|high)$/.exec(modelId ?? '');
  return match ? { family: match[1], effort: match[2] as Effort } : { family: modelId, effort: undefined };
}

// The agy model id for a family at an effort. Families without effort variants
// ignore it; a missing variant falls back to the nearest one, higher on a tie.
export function resolveAgyModel(families: Map<string, ModelFamily>, familyId: string | undefined, effort: Effort | undefined): string {
  const family = familyId ? families.get(familyId) : undefined;
  if (!family || family.efforts.length === 0) {
    return familyId ?? '';
  }
  if (effort && family.efforts.includes(effort)) {
    return `${familyId}-${effort}`;
  }
  const want = EFFORTS.indexOf(effort ?? 'medium');
  const nearest = [...family.efforts].sort((a, b) => {
    const da = Math.abs(EFFORTS.indexOf(a) - want);
    const db = Math.abs(EFFORTS.indexOf(b) - want);
    return da - db || EFFORTS.indexOf(b) - EFFORTS.indexOf(a);
  })[0];
  return `${familyId}-${nearest}`;
}

function toolParam(params: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = params?.[key];
    if (typeof value === 'string' && value.trim()) {
      return value;
    }
  }
  return undefined;
}

function truncate(text: string, limit: number): string {
  return text.length > limit ? `${text.slice(0, limit)}\n… (${text.length - limit} more chars)` : text;
}

export interface DescribedTool {
  title: string;
  kind: string;
  rawInput: Record<string, unknown>;
  locations?: { path: string }[];
}

// ACP tool_call fields from an agy tool step: kind picks Paseo's detail view,
// rawInput carries the command/path/query it renders.
export function describeTool(toolInfo: { name?: string; parameters?: Record<string, unknown> } | undefined): DescribedTool {
  const name = toolInfo?.name ?? 'tool_execution';
  const params = toolInfo?.parameters ?? {};
  const kind = TOOL_KINDS[name] ?? 'other';
  const filePath = toolParam(params, ['AbsolutePath', 'TargetFile', 'DirectoryPath', 'SearchPath', 'SearchDirectory', 'File', 'Path']);
  const command = toolParam(params, ['CommandLine', 'Command']);
  const url = toolParam(params, ['Url', 'URL', 'url']);
  const query = toolParam(params, ['Query', 'Pattern', 'query', 'SearchQuery']);

  let title = name;
  if (kind === 'execute' && command) title = `Run ${truncate(command, 120)}`;
  else if (kind === 'read' && filePath) title = `Read ${path.basename(filePath)}`;
  else if (kind === 'edit' && filePath) title = `Edit ${path.basename(filePath)}`;
  else if (kind === 'search' && query) title = `Search ${truncate(query, 80)}`;
  else if (kind === 'fetch' && (url || query)) title = `Fetch ${truncate((url ?? query) as string, 120)}`;

  return {
    title,
    kind,
    rawInput: {
      tool: name,
      ...params,
      ...(command ? { command, cwd: toolParam(params, ['Cwd']) } : {}),
      ...(filePath ? { path: filePath } : {}),
      ...(url ? { url } : {}),
      ...(query ? { query } : {}),
    },
    locations: filePath ? [{ path: filePath }] : undefined,
  };
}

export interface AntigravityAcpAgentOptions {
  binaryPath: string;
  defaultModel?: string;
  defaultEffort?: Effort;
  dangerouslySkipPermissions?: boolean;
  // Where session transcripts + resume metadata live. Defaults under ~/.cache.
  stateDir?: string;
  // Where per-session image-attachment temp dirs are created. Defaults under the OS tmpdir.
  attachDir?: string;
  // HOME override for skill discovery (tests). Defaults to os.homedir().
  home?: string;
}

interface SessionState {
  sessionId: string | null;
  cwd: string;
  models: ModelEntry[];
  families: Map<string, ModelFamily>;
  family: string | undefined;
  effort: Effort;
  modeId: string;
  notice: string | null;
  pendingText: string;
  attachDir: string;
  agy: AgySession;
}

export class AntigravityAcpAgent {
  private readonly sessions = new Map<string, SessionState>();
  private readonly stateDir: string;
  private readonly attachRoot: string;
  private modelFamiliesPromise: Promise<{ list: ModelEntry[]; families: Map<string, ModelFamily> }> | null = null;

  constructor(private readonly options: AntigravityAcpAgentOptions) {
    this.stateDir = options.stateDir ?? path.join(homedir(), '.cache', 'google-antigravity-acp', 'sessions');
    this.attachRoot = options.attachDir ?? path.join(tmpdir(), 'agy-acp-attach');
  }

  public getSession(sessionId: string): AgySession | undefined {
    return this.sessions.get(sessionId)?.agy;
  }

  public createApp(): acp.AgentApp {
    return acp
      .agent({
        name: 'google-antigravity',
      })
      .onRequest('initialize', async (_ctx) => {
        return {
          protocolVersion: acp.PROTOCOL_VERSION,
          agentCapabilities: {
            // History is replayed from this adapter's own transcript; the
            // conversation itself continues via `agy --conversation`.
            loadSession: true,
            promptCapabilities: { image: true, embeddedContext: true },
            sessionCapabilities: { resume: {}, close: {}, delete: {} },
          },
          agentInfo: {
            name: 'google-antigravity',
            version: '1.2.1',
            title: 'Google Antigravity Agent',
          },
        };
      })
      .onRequest('authenticate', async (_ctx) => {
        return {};
      })
      // ctx.params.mcpServers (session/new|load|resume) is intentionally not
      // forwarded to agy: the fork has no evidence agy's CLI accepts an MCP
      // server list at all (no such flag observed in any capture this fork
      // is built from), and passing an unverified flag risks a silent
      // behavior change worse than the gap. See README.md "Known
      // limitations" before adding one — confirm against a real `agy
      // --help`/docs first.
      .onRequest('session/new', async (ctx: any) => {
        const state = await this.openSession({ cwd: ctx.params.cwd });
        this.announceCommands(state, ctx.client);
        return this.sessionSetup(state);
      })
      .onRequest('session/load', async (ctx: any) => {
        const state = await this.openSession({ cwd: ctx.params.cwd, sessionId: ctx.params.sessionId });
        await this.replayTranscript(state, ctx.client);
        this.announceCommands(state, ctx.client);
        return this.sessionSetup(state);
      })
      .onRequest('session/resume', async (ctx: any) => {
        const state = await this.openSession({ cwd: ctx.params.cwd, sessionId: ctx.params.sessionId });
        this.announceCommands(state, ctx.client);
        return this.sessionSetup(state);
      })
      .onRequest('session/set_mode', async (ctx: any) => {
        const state = this.requireSession(ctx.params.sessionId);
        this.applyMode(state, ctx.params.modeId);
        return {};
      })
      .onRequest('session/set_config_option', async (ctx: any) => {
        const state = this.requireSession(ctx.params.sessionId);
        await this.applyConfigOption(state, ctx.params.configId, ctx.params.value);
        // Model and effort move together, so the other option changed too.
        await this.notifyConfig(state, ctx.client);
        return {
          configOptions: this.getConfigOptions(state),
        };
      })
      .onRequest('session/prompt', async (ctx: any) => {
        const sessionId = ctx.params.sessionId;
        const state = this.requireSession(sessionId);
        const promptText = await this.extractPromptText(state, ctx.params.prompt);
        await this.record(state, {
          sessionUpdate: 'user_message_chunk',
          content: { type: 'text', text: promptText },
        });

        const local = await this.runLocalCommand(state, promptText, ctx.client);
        if (local) {
          await this.flushTranscript(state);
          return { stopReason: 'end_turn' as const };
        }

        if (state.notice) {
          await this.say(state, ctx.client, `${state.notice}\n\n`);
          state.notice = null;
        }

        const turnUsage = { inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0, totalTokens: 0 };
        try {
          const result = await state.agy.prompt(promptText, async (stepEvent) => {
            await this.handleStepUpdate(state, stepEvent, ctx.client, turnUsage);
          });
          await this.persistMeta(state);

          if (result.deniedActions?.length) {
            const names = result.deniedActions.map((action) => action.display_name ?? action.action).join(', ');
            await this.say(
              state,
              ctx.client,
              `\n\n> agy auto-denied: ${names} (mode: ${state.modeId}). Switch to bypassPermissions to allow.\n`
            );
          }

          if (result.status === 'ERROR') {
            if (result.error?.includes('cancelled')) {
              return { stopReason: 'cancelled' as const, usage: turnUsage };
            }
            // agy can answer and still report ERROR (seen: a 503 "No capacity"
            // after the reply was streamed). Keep the answer, show the error.
            if (result.response?.trim()) {
              await this.say(state, ctx.client, `\n\n> agy reported an error after replying: ${result.error ?? 'unknown error'}\n`);
              return { stopReason: 'end_turn' as const, usage: turnUsage };
            }
            throw new acp.RequestError(-32603, `agy: ${result.error ?? 'turn failed'}`, {
              details: result.error ?? 'turn failed',
            });
          }

          return {
            stopReason: 'end_turn' as const,
            usage: turnUsage,
          };
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          if (message.includes('cancelled') || message.includes('Abort')) {
            return { stopReason: 'cancelled' as const };
          }
          throw err;
        } finally {
          await this.flushTranscript(state);
        }
      })
      .onRequest('session/close', async (ctx: any) => {
        const state = this.sessions.get(ctx.params.sessionId);
        if (state) {
          state.agy.close();
          this.sessions.delete(ctx.params.sessionId);
          await rm(state.attachDir, { recursive: true, force: true });
        }
        return {};
      })
      // Distinct from close(): close ends the live process but keeps the
      // transcript/meta cache so a later session/load can still replay it.
      // delete is permanent — the agent record itself is gone (Paseo's own
      // "delete" on session/list), so the cache this adapter keeps for it
      // (the whole point of the S14 review finding: nothing here has a TTL,
      // so an explicit delete is the only cleanup path that exists) must go too.
      .onRequest('session/delete', async (ctx: any) => {
        const sessionId = ctx.params.sessionId;
        const state = this.sessions.get(sessionId);
        if (state) {
          state.agy.close();
          this.sessions.delete(sessionId);
          await rm(state.attachDir, { recursive: true, force: true });
        }
        await rm(this.transcriptPath(sessionId), { force: true });
        await rm(path.join(this.stateDir, `${sessionId}.meta.json`), { force: true });
        return {};
      })
      .onNotification('session/cancel', async (ctx: any) => {
        if (ctx.params?.sessionId) {
          this.sessions.get(ctx.params.sessionId)?.agy.cancel();
        }
      });
  }

  private requireSession(sessionId: string): SessionState {
    const state = this.sessions.get(sessionId);
    if (!state) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    return state;
  }

  // `agy models` lists one id per model and effort (gemini-3.8-flash-high …).
  // Those ids are the model choices; effort is the same choice seen per family.
  private getModelCatalog(): Promise<{ list: ModelEntry[]; families: Map<string, ModelFamily> }> {
    this.modelFamiliesPromise ??= execFileAsync(this.options.binaryPath, ['models'], {
      timeout: MODEL_LIST_TIMEOUT_MS,
    })
      .then(({ stdout }) => {
        const list: ModelEntry[] = stdout
          .split('\n')
          .map((line) => line.split('\t'))
          .filter((parts) => parts.length >= 2 && parts[0].trim())
          .map(([id, label]) => [id.trim(), label.trim()] as ModelEntry);
        if (list.length === 0) {
          throw new Error('agy models returned no models');
        }
        return { list, families: groupModels(list) };
      })
      .catch((err) => {
        // A failed query is not a catalog. Keep it retryable instead of
        // advertising fabricated models for the lifetime of this process.
        this.modelFamiliesPromise = null;
        throw new acp.RequestError(-32603, `Could not list agy models; retry the provider refresh: ${err instanceof Error ? err.message : String(err)}`);
      });
    return this.modelFamiliesPromise;
  }

  // Opens a new conversation, or reattaches one when sessionId is given. For
  // new sessions the ACP session id is agy's conversation id, so a later
  // session/load after an adapter restart finds the same conversation.
  private async openSession({ cwd, sessionId }: { cwd: string; sessionId?: string }): Promise<SessionState> {
    const { list: models, families } = await this.getModelCatalog();
    const defaultFamily = families.has('gemini-3.8-flash') ? 'gemini-3.8-flash' : families.keys().next().value;
    const configured = parseModelId(this.options.defaultModel ?? defaultFamily);
    if (!families.has(configured.family as string)) {
      throw new acp.RequestError(-32602, `Configured agy model is not in the live catalog: ${String(this.options.defaultModel)}`);
    }
    const meta = sessionId ? await this.readMeta(sessionId) : null;
    // Safe by default: a session opened with no explicit opt-in (e.g. a
    // child agent spawned by an unattended parent of another provider) starts
    // readOnly, not bypassPermissions. Only an explicit `true` unlocks bypass.
    const defaultMode = this.options.dangerouslySkipPermissions === true ? 'bypassPermissions' : 'readOnly';

    const attachDir = path.join(this.attachRoot, randomUUID());
    await mkdir(attachDir, { recursive: true, mode: 0o700 });

    const state: SessionState = {
      sessionId: sessionId ?? null,
      cwd,
      models,
      families,
      family: configured.family,
      effort: configured.effort ?? this.options.defaultEffort ?? 'medium',
      modeId: defaultMode,
      notice: null,
      pendingText: '',
      attachDir,
      agy: null as unknown as AgySession,
    };

    state.agy = new AgySession({
      binaryPath: this.options.binaryPath,
      // agy's permission check compares resolved paths, so a symlinked
      // workspace would have its own files denied.
      cwd: await realpath(cwd).catch(() => cwd),
      conversationId: meta?.conversationId ?? sessionId,
      addDirs: [attachDir],
      ...this.launchOptions(state),
    });

    if (process.env.AGY_ACP_TRACE) {
      state.agy.on('event', (event) => {
        void appendFile(process.env.AGY_ACP_TRACE as string, `${JSON.stringify(event)}\n`).catch(() => undefined);
      });
    }

    await state.agy.start();

    const mismatch = state.agy.getConversationMismatch();
    if (mismatch) {
      state.notice = `_(agy could not find conversation ${mismatch.requested}; continuing in a new conversation ${mismatch.actual}.)_`;
    }

    state.sessionId ??= state.agy.getConversationId();
    this.sessions.set(state.sessionId as string, state);
    await this.persistMeta(state);
    return state;
  }

  private launchOptions(state: SessionState) {
    const mode = MODES.find((entry) => entry.id === state.modeId) ?? MODES[0];
    return {
      model: this.currentModelId(state),
      effort: undefined,
      ...mode.flags,
    };
  }

  private sessionSetup(state: SessionState) {
    return {
      // Non-null by construction: openSession() fills sessionId before this runs.
      sessionId: state.sessionId as string,
      configOptions: this.getConfigOptions(state),
      modes: {
        currentModeId: state.modeId,
        // Paseo picks an unattended mode when an unattended agent of another
        // provider creates this one; without it that create is refused.
        availableModes: MODES.map(({ id, name, description, flags }) => ({
          id,
          name,
          description,
          ...(flags.dangerouslySkipPermissions ? { _meta: { paseo: { isUnattended: true } } } : {}),
        })),
      },
    };
  }

  private currentModelId(state: SessionState): string {
    return resolveAgyModel(state.families, state.family, state.effort);
  }

  private getConfigOptions(state: SessionState): acp.SessionConfigOption[] {
    const family = state.family ? state.families.get(state.family) : undefined;
    return [
      // Modes are also listed here: Paseo rebuilds its mode list from config
      // options on every config_option_update, and would otherwise drop them.
      {
        id: 'mode',
        name: 'Mode',
        category: 'mode',
        type: 'select',
        currentValue: state.modeId,
        options: MODES.map(({ id, name, description }) => ({ value: id, name, description })),
      } as unknown as acp.SessionConfigOption,
      {
        id: 'model',
        name: 'Model',
        category: 'model',
        type: 'select',
        // One row per family; the effort lives only in the thinking selector,
        // otherwise the picker shows "Gemini 3.8 Flash (High)" next to "Medium".
        currentValue: state.family,
        options: [...state.families.values()].map(({ id, name }) => ({ value: id, name })),
      } as unknown as acp.SessionConfigOption,
      {
        id: 'thinking',
        name: 'Thinking effort',
        category: 'thought_level',
        type: 'select',
        currentValue: state.effort,
        options: EFFORTS.map((effort) => ({
          value: effort,
          name: effort[0].toUpperCase() + effort.slice(1),
          description:
            family && family.efforts.length > 0 && !family.efforts.includes(effort)
              ? `not offered by ${family.name}; nearest is used`
              : undefined,
        })),
      } as unknown as acp.SessionConfigOption,
    ];
  }

  private async applyConfigOption(state: SessionState, configId: string, value: unknown): Promise<void> {
    if (configId === 'model') {
      // An agy model id ("gemini-3.8-flash-high") or a family ("gemini-3.8-flash").
      const known = state.models.some(([id]) => id === value);
      const parsed = known ? parseModelId(value as string) : { family: String(value), effort: undefined };
      if (!known && !state.families.has(parsed.family as string)) {
        throw new acp.RequestError(-32602, `Unknown agy model: ${String(value)}`);
      }
      state.family = parsed.family;
      if (parsed.effort) {
        state.effort = parsed.effort;
      }
    } else if (configId === 'mode') {
      this.applyMode(state, value as string);
      return;
    } else if (configId === 'thinking') {
      if (!EFFORTS.includes(value as Effort)) {
        throw new acp.RequestError(-32602, `Unknown effort: ${String(value)}`);
      }
      state.effort = value as Effort;
    } else {
      throw new acp.RequestError(-32602, `Unsupported session config option: ${configId}`);
    }
    state.agy.reconfigure(this.launchOptions(state));
  }

  private applyMode(state: SessionState, modeId: string): void {
    if (!MODES.some((mode) => mode.id === modeId)) {
      throw new acp.RequestError(-32602, `Unknown mode: ${modeId}`);
    }
    state.modeId = modeId;
    state.agy.reconfigure(this.launchOptions(state));
  }

  // Slash commands are sent after the session/new response: Paseo drops
  // session updates for a session id it has not received yet. Skills come
  // from the same roots agy itself resolves, so the `/` picker lists exactly
  // what a prompt like `/share-docs ...` would reach (it falls through
  // runLocalCommand to agy, which expands the skill).
  private announceCommands(state: SessionState, client: acp.AgentContext): void {
    setTimeout(() => {
      void buildAvailableCommands(this.homeDir, state.cwd)
        .then((availableCommands) =>
          client.notify(acp.methods.client.session.update, {
            sessionId: state.sessionId,
            update: {
              sessionUpdate: 'available_commands_update',
              availableCommands,
            },
          } as any),
        )
        .catch(() => undefined);
    }, 50);
  }

  private get homeDir(): string {
    return this.options.home ?? homedir();
  }

  private async runLocalCommand(state: SessionState, text: string, client: acp.AgentContext): Promise<boolean> {
    const match = /^\/([a-z-]+)(?:\s+(.*))?$/s.exec(text.trim());
    if (!match) {
      return false;
    }
    const name = LOCAL_COMMAND_ALIASES[match[1]] ?? match[1];
    const arg = match[2]?.trim();

    if (name === 'model' && arg) {
      await this.applyConfigOption(state, 'model', arg);
      await this.notifyConfig(state, client);
      await this.say(state, client, `Model set to ${this.currentModelId(state)} (applies from the next turn).\n`);
      return true;
    }
    if (name === 'effort' && arg) {
      await this.applyConfigOption(state, 'thinking', arg);
      await this.notifyConfig(state, client);
      await this.say(state, client, `Effort set to ${state.effort} → ${this.currentModelId(state)} (applies from the next turn).\n`);
      return true;
    }
    if (name === 'config') {
      await this.say(state, client, '/config is interactive-only in agy; use the model, effort and mode pickers instead.\n');
      return true;
    }
    if (!LOCAL_COMMANDS.some((command) => command.name === name)) {
      return false; // skills and custom commands go to agy itself
    }

    let output: string;
    try {
      const { stdout, stderr } = await execFileAsync(this.options.binaryPath, ['--print', `/${name}`], {
        cwd: state.cwd,
        timeout: 30_000,
      });
      output = (stdout || stderr).trim();
    } catch (err) {
      output = `agy /${name} failed: ${err instanceof Error ? err.message : String(err)}`;
    }
    const current = name === 'model' || name === 'effort' ? `Current: ${this.currentModelId(state)}\n\n` : '';
    await this.say(state, client, `${current}\`\`\`\n${output}\n\`\`\`\n`);
    return true;
  }

  private async notifyConfig(state: SessionState, client: acp.AgentContext): Promise<void> {
    await client.notify(acp.methods.client.session.update, {
      sessionId: state.sessionId,
      update: {
        sessionUpdate: 'config_option_update',
        configOptions: this.getConfigOptions(state),
      },
    } as any);
  }

  private async say(state: SessionState, client: acp.AgentContext, text: string): Promise<void> {
    const update = {
      sessionUpdate: 'agent_message_chunk',
      content: { type: 'text', text },
    };
    await client.notify(acp.methods.client.session.update, { sessionId: state.sessionId, update } as any);
    await this.record(state, update);
  }

  // agy's stream-json input accepts text blocks only. Images are written to a
  // directory added to the agy workspace and referenced by path; agy opens
  // them with view_file.
  private async extractPromptText(state: SessionState, prompt: acp.ContentBlock[] | string): Promise<string> {
    if (typeof prompt === 'string') return prompt;
    if (!Array.isArray(prompt)) return String(prompt);

    const parts: string[] = [];
    let imageCount = 0;
    for (const block of prompt as any[]) {
      if (block.type === 'text') {
        parts.push(block.text);
      } else if (block.type === 'resource_link') {
        parts.push(`[${block.name ?? 'resource'}](${block.uri})`);
      } else if (block.type === 'resource') {
        const res = block.resource;
        if (res && 'text' in res && typeof res.text === 'string') {
          parts.push(res.text);
        }
      } else if (block.type === 'image' && typeof block.data === 'string') {
        imageCount += 1;
        const ext = (block.mimeType ?? 'image/png').split('/')[1]?.replace('jpeg', 'jpg') ?? 'png';
        const file = path.join(state.attachDir, `${randomUUID()}.${ext}`);
        await writeFile(file, Buffer.from(block.data, 'base64'), { mode: 0o600 });
        parts.push(`[Attached image ${imageCount}: ${file} — open it with view_file]`);
      }
    }
    return parts.filter(Boolean).join('\n');
  }

  private async handleStepUpdate(
    state: SessionState,
    event: AgyStepUpdateEvent,
    client: acp.AgentContext,
    turnUsage: { inputTokens: number; outputTokens: number; thoughtTokens: number; cachedReadTokens: number; totalTokens: number }
  ): Promise<void> {
    const step = event.step_update;
    const updates: Record<string, unknown>[] = [];

    if (step.step_type === 'agent_response') {
      if (step.text_delta) {
        updates.push({
          sessionUpdate: 'agent_message_chunk',
          content: { type: 'text', text: step.text_delta },
        });
      }
    } else if (step.step_type === 'tool' || step.step_type === 'tool_call') {
      const toolCallId = `step_${step.step_index}`;
      const tool = describeTool(step.tool_info);
      if (step.state === 'ACTIVE') {
        updates.push({
          sessionUpdate: 'tool_call',
          toolCallId,
          title: tool.title,
          kind: tool.kind,
          status: 'in_progress',
          rawInput: tool.rawInput,
          ...(tool.locations ? { locations: tool.locations } : {}),
        });
      } else if (step.state === 'DONE' || step.state === 'ERROR') {
        const output = step.tool_info?.output;
        const errorMessage = step.tool_info?.error?.message;
        const text = output ?? errorMessage;
        updates.push({
          sessionUpdate: 'tool_call_update',
          toolCallId,
          title: tool.title,
          kind: tool.kind,
          status: step.state === 'ERROR' ? 'failed' : 'completed',
          rawInput: tool.rawInput,
          rawOutput: step.state === 'ERROR' ? { error: errorMessage ?? 'Tool call failed' } : { output: output ?? '' },
          content: text ? [{ type: 'content', content: { type: 'text', text } }] : undefined,
        });
      }
    }

    if (step.usage) {
      turnUsage.inputTokens += step.usage.input_tokens ?? 0;
      turnUsage.outputTokens += step.usage.output_tokens ?? 0;
      turnUsage.thoughtTokens += step.usage.thinking_tokens ?? 0;
      turnUsage.cachedReadTokens += step.usage.cache_read_tokens ?? 0;
      turnUsage.totalTokens += step.usage.total_tokens ?? 0;
      // total_tokens of one model call = the context it saw plus its output.
      updates.push({
        sessionUpdate: 'usage_update',
        used: step.usage.total_tokens,
        size: contextWindowFor(state.family ?? ''),
      });
    }

    for (const update of updates) {
      await client.notify(acp.methods.client.session.update, { sessionId: state.sessionId, update } as any);
      if (update.sessionUpdate !== 'usage_update') {
        await this.record(state, update);
      }
    }
  }

  private transcriptPath(sessionId: string): string {
    return path.join(this.stateDir, `${sessionId}.jsonl`);
  }

  private async readMeta(sessionId: string): Promise<{ conversationId: string; cwd: string } | null> {
    try {
      return JSON.parse(await readFile(path.join(this.stateDir, `${sessionId}.meta.json`), 'utf8'));
    } catch {
      return null;
    }
  }

  // Only needed when the ACP session id is not agy's conversation id (a
  // resumed session whose conversation agy no longer had).
  private async persistMeta(state: SessionState): Promise<void> {
    if (state.agy.getConversationId() === state.sessionId) {
      return;
    }
    await mkdir(this.stateDir, { recursive: true, mode: 0o700 });
    await writeFile(
      path.join(this.stateDir, `${state.sessionId}.meta.json`),
      `${JSON.stringify({ conversationId: state.agy.getConversationId(), cwd: state.cwd })}\n`,
      { mode: 0o600 }
    );
  }

  // The transcript holds what this adapter showed the client, so session/load
  // can replay it; agy keeps the model-side context itself. Message text is
  // coalesced so one turn is a handful of lines.
  private async record(state: SessionState, update: Record<string, unknown>): Promise<void> {
    if (update.sessionUpdate === 'agent_message_chunk') {
      state.pendingText += (update.content as { text: string }).text;
      return;
    }
    await this.flushTranscript(state);
    const stored = { ...update };
    if (Array.isArray(stored.content)) {
      stored.content = (stored.content as any[]).map((item) =>
        item.type === 'content' && item.content.type === 'text'
          ? { ...item, content: { ...item.content, text: truncate(item.content.text, TRANSCRIPT_TEXT_LIMIT) } }
          : item
      );
    }
    await this.appendTranscript(state, stored);
  }

  private async flushTranscript(state: SessionState): Promise<void> {
    if (!state.pendingText) {
      return;
    }
    const text = state.pendingText;
    state.pendingText = '';
    await this.appendTranscript(state, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } });
  }

  private async appendTranscript(state: SessionState, update: Record<string, unknown>): Promise<void> {
    await mkdir(this.stateDir, { recursive: true, mode: 0o700 });
    await appendFile(this.transcriptPath(state.sessionId as string), `${JSON.stringify(update)}\n`, { mode: 0o600 });
  }

  private async replayTranscript(state: SessionState, client: acp.AgentContext): Promise<void> {
    let lines: string[];
    try {
      lines = (await readFile(this.transcriptPath(state.sessionId as string), 'utf8')).split('\n').filter(Boolean);
    } catch {
      return;
    }
    for (const line of lines) {
      let update: unknown;
      try {
        update = JSON.parse(line);
      } catch {
        continue;
      }
      await client.notify(acp.methods.client.session.update, { sessionId: state.sessionId, update } as any);
    }
  }

  public closeAll(): void {
    for (const state of this.sessions.values()) {
      state.agy.close();
      rmSync(state.attachDir, { recursive: true, force: true });
    }
    this.sessions.clear();
  }
}
