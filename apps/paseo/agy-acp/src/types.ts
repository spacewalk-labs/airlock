/**
 * Types for Google Antigravity `agy` streaming protocol and ACP adapter.
 */

export interface AgyUsage {
  input_tokens: number;
  output_tokens: number;
  thinking_tokens?: number;
  cache_read_tokens?: number;
  total_tokens: number;
}

export interface AgyToolInfo {
  name?: string;
  parameters?: Record<string, unknown>;
  output?: string;
  error?: { message?: string };
}

export interface AgySubagentInfo {
  conversation_id?: string;
  log_uri?: string;
}

export interface AgyInitEvent {
  event: 'init';
  conversation_id: string;
  init: {
    cwd: string;
    tools: string[];
    permission_mode?: string;
  };
}

export interface AgyStepUpdateEvent {
  event: 'step_update';
  step_update: {
    conversation_id: string;
    step_index: number;
    state: 'ACTIVE' | 'DONE' | 'ERROR' | string;
    step_type: 'user_input' | 'agent_response' | 'tool' | 'tool_call' | string;
    text_delta?: string;
    duration_seconds?: number;
    usage?: AgyUsage;
    tool_info?: AgyToolInfo;
    subagent_info?: AgySubagentInfo;
  };
}

// An action agy auto-denied in headless mode (no interactive approval).
export interface AgyDeniedAction {
  action?: string;
  display_name?: string;
}

export interface AgyResultEvent {
  event: 'result';
  result: {
    conversation_id: string;
    status: 'SUCCESS' | 'ERROR' | string;
    response: string;
    error?: string;
    duration_seconds?: number;
    num_turns?: number;
    usage?: AgyUsage;
    denied_actions?: AgyDeniedAction[];
  };
}

export type AgyStreamEvent = AgyInitEvent | AgyStepUpdateEvent | AgyResultEvent;

export interface AgyUserInputMessage {
  event: 'user';
  message: {
    content: string;
  };
}

export interface AgySessionOptions {
  binaryPath: string;
  cwd?: string;
  model?: string;
  effort?: 'low' | 'medium' | 'high';
  dangerouslySkipPermissions?: boolean;
  // Resume this agy conversation instead of starting a new one (`--conversation=`).
  conversationId?: string;
  // agy's own `--mode` flag (accept-edits | plan). Unset + dangerouslySkipPermissions
  // false is agy's read-only default; unset + dangerouslySkipPermissions true bypasses.
  agyMode?: 'accept-edits' | 'plan';
  sandbox?: boolean;
  // Extra `--add-dir` workspace roots beyond `cwd` (used for the image attach dir).
  addDirs?: string[];
  extraArgs?: string[];
  env?: Record<string, string>;
}

// Set when a `--conversation=` resume finds no matching conversation: agy starts a
// fresh one instead, and the caller should tell the user which id it actually got.
export interface AgyConversationMismatch {
  requested: string;
  actual: string;
}
