// Jarvis on OpenCode: its turn events, as `jarvis hook lead <kind> opencode <generation>`.
// `jarvis lead` copies this file into its launch folder beside lead-opencode.json (jarvis,
// agent, generation, the role prefix) and adds it to OPENCODE_CONFIG_CONTENT's plugin
// list. Which session is Jarvis's root is decided by jarvis (lib/hooks.sh), which binds the
// session whose prompt begins with the prefix; this forwards, with each session's id:
//   a build-agent prompt beginning with the prefix → working, with the prompt
//   session.status busy (from idle) → working; idle (after busy or retry) → stop, then ok
//     unless the turn had an error; retry with a message → limit (state retry)
//   session.error → limit (state error), its message and HTTP status
// A subagent's session (one created with a parentID) is never forwarded. OpenCode calls
// `event` without awaiting it, so every callback joins one queue and each runs to its
// exit (10 s at most) before the next starts: busy and idle can't land out of order.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

export const JarvisLeadEvents = async () => {
  let cfg;
  try {
    cfg = JSON.parse(readFileSync(new URL("./lead-opencode.json", import.meta.url), "utf8"));
  } catch {
    return {};
  }
  if (!cfg?.jarvis || !cfg.generation || !cfg.prefix) return {};
  const children = new Set();
  const turns = new Map(); // session id → { busy, failed }
  let queue = Promise.resolve();

  const run = (kind, payload) =>
    new Promise((done) => {
      let child;
      try {
        child = spawn(cfg.jarvis, ["hook", "lead", kind, cfg.agent || "opencode", cfg.generation], {
          stdio: ["pipe", "ignore", "ignore"],
        });
      } catch {
        return done();
      }
      const timer = setTimeout(() => child.kill("SIGKILL"), 10000);
      child.on("error", () => { clearTimeout(timer); done(); });
      child.on("close", () => { clearTimeout(timer); done(); });
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify(payload));
    });
  const send = (kind, payload) => {
    queue = queue.then(() => run(kind, payload)).catch(() => {});
    return queue;
  };
  const turn = (sid) => {
    if (!turns.has(sid)) turns.set(sid, { busy: false, failed: false });
    return turns.get(sid);
  };
  const text = (e) => String(e ?? "").replace(/[\u0000-\u001f]+/g, " ").slice(0, 300);

  return {
    "chat.message": async (input, output) => {
      try {
        const sid = input?.sessionID;
        if (!sid || children.has(sid) || input?.agent !== "build") return queue;
        const prompt = (output?.parts || [])
          .filter((p) => p?.type === "text" && typeof p.text === "string")
          .map((p) => p.text)
          .join("");
        if (!prompt.startsWith(cfg.prefix)) return queue;
        return send("working", { session_id: sid, prompt: prompt.slice(0, 300) });
      } catch {
        return queue;
      }
    },
    event: async ({ event } = {}) => {
      try {
        const p = event?.properties || {};
        if (p.info?.parentID && p.info?.id) children.add(p.info.id);
        const sid = p.sessionID;
        if (!sid || children.has(sid)) return queue;
        if (event.type === "session.status") {
          const s = turn(sid);
          const t = p.status?.type;
          if (t === "busy") {
            if (!s.busy) { s.busy = true; s.failed = false; return send("working", { session_id: sid }); }
          } else if (t === "retry") {
            const was = s.busy;
            s.busy = true;
            if (p.status?.message) return send("limit", { session_id: sid, state: "retry", error: text(p.status.message) });
            if (!was) return send("working", { session_id: sid });
          } else if (t === "idle" && s.busy) {
            s.busy = false;
            const failed = s.failed;
            s.failed = false;
            send("stop", { session_id: sid });
            return failed ? queue : send("ok", { session_id: sid });
          }
        } else if (event.type === "session.error") {
          const s = turn(sid);
          s.failed = true;
          const e = p.error || {};
          const code = Number(e.data?.statusCode) || 0;
          return send("limit", { session_id: sid, state: "error", error: text(e.data?.message ?? e.message ?? e.name), status_code: code });
        }
      } catch {}
      return queue;
    },
  };
};
