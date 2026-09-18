import { ChildProcess, spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { createInterface, Interface as ReadlineInterface } from 'node:readline';
import {
  AgyConversationMismatch,
  AgyInitEvent,
  AgyResultEvent,
  AgySessionOptions,
  AgyStepUpdateEvent,
  AgyStreamEvent,
  AgyUsage,
  AgyUserInputMessage,
} from './types.js';

// How long a cancelled agy process gets to exit after SIGINT (or a respawn its
// predecessor after SIGTERM) before SIGKILL. Overridable so tests can prove
// the grace-period SIGKILL fallback without a multi-second sleep.
const CANCEL_EXIT_GRACE_MS = Number(process.env.AGY_ACP_CANCEL_GRACE_MS ?? 5000);
// stderr kept for the "exited before init" error message, nothing more.
const STDERR_TAIL_LINES = 5;

export interface PromptResult {
  status: 'SUCCESS' | 'ERROR';
  response: string;
  error?: string;
  conversationId: string;
  durationSeconds?: number;
  numTurns?: number;
  usage?: AgyUsage;
  deniedActions?: AgyResultEvent['result']['denied_actions'];
}

export class AgySession extends EventEmitter {
  private process: ChildProcess | null = null;
  private stdoutRl: ReadlineInterface | null = null;
  private stderrRl: ReadlineInterface | null = null;
  private initEvent: AgyInitEvent | null = null;
  private conversationId: string | null;
  private isClosing: boolean = false;
  private currentPromptReject: ((err: Error) => void) | null = null;
  private currentPromptResolve: ((result: PromptResult) => void) | null = null;
  private currentPromptEventHandler: ((event: AgyStepUpdateEvent) => void | Promise<void>) | null = null;
  private currentPromptWritten: boolean = false;
  private pendingEventPromises: Promise<void>[] = [];
  // Resolves once a process detached by cancel()/reconfigure() has exited.
  private exiting: Promise<void> | null = null;
  private startPromise: Promise<AgyInitEvent> | null = null;
  // Set by reconfigure(); the next prompt respawns agy on the same conversation.
  private restartPending: boolean = false;
  // A resume whose conversation agy could not find starts a fresh one instead.
  private conversationMismatch: AgyConversationMismatch | null = null;
  private stderrTail: string[] = [];

  constructor(private readonly options: AgySessionOptions) {
    super();
    this.conversationId = options.conversationId ?? null;
  }

  public getConversationId(): string | null {
    return this.conversationId;
  }

  public getConversationMismatch(): AgyConversationMismatch | null {
    return this.conversationMismatch;
  }

  public getInitEvent(): AgyInitEvent | null {
    return this.initEvent;
  }

  public isRunning(): boolean {
    return this.process !== null && !this.process.killed && this.process.exitCode === null;
  }

  public async start(): Promise<AgyInitEvent> {
    if (this.isRunning() && this.initEvent) {
      return this.initEvent;
    }

    const args: string[] = [
      '--input-format=stream-json',
      '--output-format=stream-json',
    ];

    if (this.options.dangerouslySkipPermissions ?? true) {
      args.push('--dangerously-skip-permissions');
    }

    if (this.options.agyMode) {
      args.push(`--mode=${this.options.agyMode}`);
    }

    if (this.options.sandbox) {
      args.push('--sandbox');
    }

    if (this.options.cwd) {
      args.push(`--add-dir=${this.options.cwd}`);
    }

    for (const dir of this.options.addDirs ?? []) {
      args.push(`--add-dir=${dir}`);
    }

    if (this.options.model) {
      args.push(`--model=${this.options.model}`);
    }

    if (this.options.effort) {
      args.push(`--effort=${this.options.effort}`);
    }

    if (this.conversationId) {
      args.push(`--conversation=${this.conversationId}`);
    }

    if (this.options.extraArgs && this.options.extraArgs.length > 0) {
      args.push(...this.options.extraArgs);
    }

    // A respawn must wait for its own init, not reuse the previous process's.
    this.initEvent = null;

    const child = spawn(this.options.binaryPath, args, {
      cwd: this.options.cwd ?? process.cwd(),
      env: {
        ...process.env,
        ...(this.options.env ?? {}),
      },
      stdio: ['pipe', 'pipe', 'pipe'],
      // A process group of its own lets the grace-period SIGKILL fallback (see
      // waitForExit) reach any tool subprocess agy left behind, not just agy
      // itself. Windows has no process groups; kill() below falls back there.
      detached: process.platform !== 'win32',
    });

    this.process = child;
    this.isClosing = false;
    this.stderrTail = [];

    if (!child.stdout || !child.stdin) {
      throw new Error('Failed to spawn agy process with valid stdio');
    }

    this.stdoutRl = createInterface({
      input: child.stdout,
      terminal: false,
    });

    if (child.stderr) {
      this.stderrRl = createInterface({
        input: child.stderr,
        terminal: false,
      });
      this.stderrRl.on('line', (line) => {
        if (line.trim()) {
          this.stderrTail = [...this.stderrTail, line].slice(-STDERR_TAIL_LINES);
          this.emit('stderr', line);
        }
      });
    }

    const initPromise = new Promise<AgyInitEvent>((resolve, reject) => {
      const onLine = (line: string) => {
        const trimmed = line.trim();
        if (!trimmed) return;

        try {
          const parsed = JSON.parse(trimmed) as AgyStreamEvent;
          if (parsed.event === 'init') {
            this.initEvent = parsed;
            if (this.conversationId && this.conversationId !== parsed.conversation_id) {
              this.conversationMismatch = {
                requested: this.conversationId,
                actual: parsed.conversation_id,
              };
            }
            this.conversationId = parsed.conversation_id;
            resolve(parsed);
          }
        } catch {
          // Non-JSON output line before init
        }
      };

      this.stdoutRl?.on('line', onLine);

      child.once('error', (err) => {
        reject(new Error(`Failed to start agy process: ${err.message}`));
      });

      child.once('exit', (code, signal) => {
        if (!this.initEvent) {
          const detail = this.stderrTail.join(' | ');
          reject(
            new Error(
              `agy process exited before emitting init event (code: ${code}, signal: ${signal})${
                detail ? `: ${detail}` : ''
              }`
            )
          );
        }
      });
    });

    // A process detached by cancel()/reconfigure() keeps draining its output;
    // drop it so a late `result` from the old turn cannot settle the next one.
    this.stdoutRl.on('line', (line) => {
      if (this.process === child) {
        this.handleStdoutLine(line);
      }
    });

    child.on('exit', (code, signal) => {
      this.handleProcessExit(child, code, signal);
    });

    return await initPromise;
  }

  private handleStdoutLine(line: string): void {
    const trimmed = line.trim();
    if (!trimmed) return;

    let event: AgyStreamEvent;
    try {
      event = JSON.parse(trimmed) as AgyStreamEvent;
    } catch {
      this.emit('rawStdout', line);
      return;
    }

    this.emit('event', event);

    if (event.event === 'step_update') {
      if (this.currentPromptEventHandler) {
        try {
          const promise = Promise.resolve(this.currentPromptEventHandler(event)).catch((err) => {
            this.emit('error', err);
          });
          this.pendingEventPromises.push(promise);
        } catch (err) {
          this.emit('error', err);
        }
      }
    } else if (event.event === 'result') {
      const resolve = this.currentPromptResolve;
      this.currentPromptResolve = null;
      this.currentPromptReject = null;
      this.currentPromptEventHandler = null;

      if (resolve) {
        const pending = [...this.pendingEventPromises];
        this.pendingEventPromises = [];
        void Promise.all(pending).then(() => {
          resolve({
            status: event.result.status === 'ERROR' ? 'ERROR' : 'SUCCESS',
            response: event.result.response,
            error: event.result.error,
            conversationId: event.result.conversation_id,
            durationSeconds: event.result.duration_seconds,
            numTurns: event.result.num_turns,
            usage: event.result.usage,
            deniedActions: event.result.denied_actions,
          });
        });
      }
    }
  }

  private handleProcessExit(child: ChildProcess, code: number | null, signal: string | null): void {
    if (this.process !== child) {
      // Detached by cancel()/reconfigure(); the current process (if any) is
      // not ours to touch.
      return;
    }

    this.stdoutRl?.close();
    this.stderrRl?.close();
    this.stdoutRl = null;
    this.stderrRl = null;
    this.process = null;

    if (this.currentPromptReject && !this.isClosing) {
      const reject = this.currentPromptReject;
      this.currentPromptReject = null;
      this.currentPromptResolve = null;
      this.currentPromptEventHandler = null;
      reject(new Error(`agy process terminated unexpectedly (code: ${code}, signal: ${signal})`));
    }

    this.emit('exit', code, signal);
  }

  public async prompt(
    content: string,
    onStepUpdate?: (event: AgyStepUpdateEvent) => void | Promise<void>
  ): Promise<PromptResult> {
    if (this.currentPromptReject) {
      throw new Error('A prompt is already in progress on this session');
    }

    const message: AgyUserInputMessage = {
      event: 'user',
      message: {
        content,
      },
    };

    // Register the prompt before any (re)spawn so cancel() can settle it at
    // once, even while a cancelled process is exiting or a new one starts.
    return new Promise<PromptResult>((resolve, reject) => {
      this.currentPromptResolve = resolve;
      this.currentPromptReject = reject;
      this.currentPromptEventHandler = onStepUpdate ?? null;
      this.currentPromptWritten = false;
      void this.writePrompt(message, reject);
    });
  }

  private async writePrompt(message: AgyUserInputMessage, reject: (err: Error) => void): Promise<void> {
    const isCurrent = () => this.currentPromptReject === reject;
    const fail = (err: Error) => {
      if (isCurrent()) {
        this.clearCurrentPrompt();
        reject(err);
      }
    };

    try {
      if (this.restartPending) {
        this.restartPending = false;
        this.detachProcess('SIGTERM');
      }
      if (this.exiting) {
        await this.exiting;
      }
      if (!this.isRunning() || !this.initEvent) {
        this.startPromise ??= this.start().finally(() => {
          this.startPromise = null;
        });
        await this.startPromise;
      }
    } catch (err) {
      fail(err instanceof Error ? err : new Error(String(err)));
      return;
    }

    if (!isCurrent()) {
      return; // cancelled while waiting for agy
    }

    if (!this.process || !this.process.stdin) {
      fail(new Error('No active agy stdin stream available'));
      return;
    }

    this.currentPromptWritten = true;
    const payload = JSON.stringify(message) + '\n';
    this.process.stdin.write(payload, 'utf8', (err) => {
      if (err) {
        fail(new Error(`Failed to write prompt to agy stdin: ${err.message}`));
      }
    });
  }

  // Model, effort, mode and sandbox are launch flags, so changing them means a
  // new agy process on the same conversation. Applied lazily by the next
  // prompt (via writePrompt's restartPending check) so a running turn is
  // never cut short.
  public reconfigure(options: Partial<AgySessionOptions>): void {
    Object.assign(this.options, options);
    this.restartPending = true;
  }

  private detachProcess(signal: NodeJS.Signals): void {
    const child = this.process;
    if (!child || !this.isRunning()) {
      return;
    }
    this.process = null;
    this.stdoutRl = null;
    this.stderrRl = null;
    this.exiting = waitForExit(child, CANCEL_EXIT_GRACE_MS);
    try {
      child.stdin?.end();
      child.kill(signal);
    } catch {
      // Process might already be stopping
    }
  }

  private clearCurrentPrompt(): void {
    this.currentPromptResolve = null;
    this.currentPromptReject = null;
    this.currentPromptEventHandler = null;
    this.currentPromptWritten = false;
  }

  public cancel(): void {
    if (this.currentPromptReject) {
      const reject = this.currentPromptReject;
      const written = this.currentPromptWritten;
      this.clearCurrentPrompt();
      this.pendingEventPromises = [];

      // agy's stream-json input has no cancel event (it ignores unknown
      // events), so SIGINT is the only way to stop a turn, and it ends the
      // whole process. Detach that process now; the next prompt waits for
      // it to exit and resumes the conversation in a fresh one.
      if (written) {
        this.detachProcess('SIGINT');
      }

      reject(new Error('Prompt was cancelled'));
    }
  }

  public close(): void {
    this.isClosing = true;
    this.cancel();

    if (this.process && this.isRunning()) {
      try {
        this.process.stdin?.end();
        this.process.kill('SIGTERM');
      } catch {
        // Ignore
      }
    }
  }
}

// Waits for a detached child to exit on its own; past the grace period it is
// SIGKILLed. The kill targets the child's own process group (it was spawned
// detached) so a tool subprocess agy left running dies with it — a plain
// child.kill('SIGKILL') only reaches agy itself and leaks the rest. Falls
// back to a direct kill if the group is already gone or on platforms
// (Windows) that have none.
function waitForExit(child: ChildProcess, graceMs: number): Promise<void> {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      try {
        if (process.platform !== 'win32' && typeof child.pid === 'number') {
          process.kill(-child.pid, 'SIGKILL');
        } else {
          child.kill('SIGKILL');
        }
      } catch {
        try {
          child.kill('SIGKILL');
        } catch {
          // Already gone
        }
      }
    }, graceMs);
    child.once('exit', () => {
      clearTimeout(timer);
      resolve();
    });
  });
}
