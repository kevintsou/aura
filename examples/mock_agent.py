#!/usr/bin/env python3
"""A minimal "bring your own agent" endpoint for Aura, with no LLM inside.

It speaks the same protocol as OpenAI Chat Completions, which is all Aura
needs (see docs/ai-agent-api.md):

  GET  /v1/models            -> {"data": [{"id": "mock-agent"}]}
  POST /v1/chat/completions  -> a tool call, or a final answer

Flow: when the user asks something, it asks Aura to run the
`aggregate_transactions` tool (Aura runs it on the phone and sends the
result back); then it turns that result into a short answer. Replace the
two `decide_*` functions with your own logic or LLM calls.

Run:  python3 examples/mock_agent.py [port]     (default 8766)
Then in Aura: 設定 → AI 連線 → 自訂 Agent API → http://localhost:8766/v1
(Android emulator: http://10.0.2.2:8766/v1)
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "mock-agent"


def decide_tool_call(messages, tools):
    """First step: ask Aura for data via one of the tools it offered."""
    offered = {t["function"]["name"] for t in tools}
    if "aggregate_transactions" not in offered:
        return None
    return {
        "id": f"call_{int(time.time() * 1000)}",
        "type": "function",
        "function": {
            "name": "aggregate_transactions",
            "arguments": json.dumps({"group_by": "main_category", "top_n": 5}),
        },
    }


def decide_answer(tool_result):
    """Second step: answer from the numbers Aura computed on the phone."""
    if "error" in tool_result:
        return f"查詢失敗：{tool_result['error']}"
    lines = [
        f"（示範 Agent）支出合計 NT${tool_result['total']:,}，共 {tool_result['count']} 筆。",
        "前幾大分類：",
    ]
    for g in tool_result["groups"][:5]:
        lines.append(f"・{g['key']}：NT${g['total']:,}（{g.get('share', 0)}%）")
    return "\n".join(lines)


def completion(message, finish_reason):
    return {
        "id": f"chatcmpl-{int(time.time() * 1000)}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": MODEL,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        # Lets the Flutter web build call this server during development.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self._send(204, {})

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._send(200, {"object": "list", "data": [{"id": MODEL, "object": "model"}]})
        self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._send(404, {"error": {"message": "not found"}})
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        messages, tools = req.get("messages", []), req.get("tools", [])
        last = messages[-1] if messages else {}
        print(f"<- {last.get('role')}: {str(last.get('content'))[:120]}", flush=True)
        if last.get("role") == "tool":
            answer = decide_answer(json.loads(last["content"]))
            return self._send(200, completion({"role": "assistant", "content": answer}, "stop"))
        call = decide_tool_call(messages, tools)
        if call is None:
            text = "OK" if "OK" in str(last.get("content")) else "這個示範 Agent 需要 Aura 的帳本工具。"
            return self._send(200, completion({"role": "assistant", "content": text}, "stop"))
        print(f"-> tool call {call['function']['name']} {call['function']['arguments']}", flush=True)
        return self._send(
            200,
            completion({"role": "assistant", "content": None, "tool_calls": [call]}, "tool_calls"),
        )

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
    print(f"mock agent on http://localhost:{port}/v1", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
