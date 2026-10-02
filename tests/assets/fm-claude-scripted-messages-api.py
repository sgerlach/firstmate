#!/usr/bin/env python3
"""A scripted local stand-in for the Anthropic Messages API, for isolated Claude Code TUI tests.

Usage: fm-claude-scripted-messages-api.py <port-file> <request-log>

It listens on 127.0.0.1 at a free port, writes the port to <port-file>, and appends every
request body it receives to <request-log> as one JSON line, so a test can prove what did
or did not reach the model. Claude Code merges and reorders blocks within a role, so the
script answers by counts rather than by position:

- each user text naming a Firstmate operational doorbell gets one OPERATIONAL_PROCESSED;
- each user text asking to read notes.txt gets one narrated Bash call, and once that
  call's result is in, the reply naming the three words;
- anything else, including Claude Code's own tool-less side requests, gets a short reply.

No credential is read and no model token is spent.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NOTES_PROMPT = "Read notes.txt"
DOORBELL = "Firstmate operational input waiting"
NOTES_COMMAND = "sleep 8; cat notes.txt"
NOTES_REPLY = "The three words are alpha, beta, and gamma."
OPERATIONAL_REPLY = "OPERATIONAL_PROCESSED"
# Each streamed answer waits this long first, so the working row is on screen while requesting.
STREAM_DELAY_SECONDS = 1.5


def blocks_of(message):
    content = message.get("content", "")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return content


def count_texts(blocks, needle):
    return sum(1 for block in blocks if block.get("type") == "text" and needle in block.get("text", ""))


def answer(body):
    """The content blocks and stop reason the script answers this request with."""
    tools = {tool.get("name") for tool in body.get("tools") or []}
    if "Bash" not in tools:
        return [{"type": "text", "text": "Lab."}], "end_turn"
    user, assistant = [], []
    for message in body.get("messages", []):
        (user if message.get("role") == "user" else assistant).extend(blocks_of(message))
    if count_texts(user, DOORBELL) > count_texts(assistant, OPERATIONAL_REPLY):
        return [{"type": "text", "text": OPERATIONAL_REPLY}], "end_turn"
    replies = count_texts(assistant, NOTES_REPLY)
    if count_texts(user, NOTES_PROMPT) <= replies:
        return [{"type": "text", "text": "Lab."}], "end_turn"
    calls = sum(1 for block in assistant if block.get("type") == "tool_use")
    if calls > replies:
        return [{"type": "text", "text": NOTES_REPLY}], "end_turn"
    return [
        {"type": "text", "text": "Let me read the notes."},
        {
            "type": "tool_use",
            "id": "toolu_scripted_%d" % int(time.time() * 1000),
            "name": "Bash",
            "input": {"command": NOTES_COMMAND, "description": "Read the notes"},
        },
    ], "tool_use"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply_json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply_json(200, {"data": [], "has_more": False})

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        with open(REQUEST_LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if "/count_tokens" in self.path:
            self.reply_json(200, {"input_tokens": 100})
            return
        if "/v1/messages" not in self.path:
            self.reply_json(404, {"type": "error", "error": {"type": "not_found_error", "message": self.path}})
            return
        content, stop = answer(body)
        usage = {"input_tokens": 100, "output_tokens": 20, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        message = {
            "id": "msg_scripted",
            "type": "message",
            "role": "assistant",
            "model": body.get("model", "claude-haiku-4-5"),
            "content": content,
            "stop_reason": stop,
            "stop_sequence": None,
            "usage": usage,
        }
        if not body.get("stream"):
            self.reply_json(200, message)
            return
        time.sleep(STREAM_DELAY_SECONDS)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.stream(message, content, stop)
        self.close_connection = True

    def event(self, name, data):
        self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode())
        self.wfile.flush()

    def stream(self, message, content, stop):
        start = dict(message, content=[], stop_reason=None, usage=dict(message["usage"], output_tokens=1))
        self.event("message_start", {"type": "message_start", "message": start})
        for index, block in enumerate(content):
            if block["type"] == "text":
                opening = {"type": "text", "text": ""}
                delta = {"type": "text_delta", "text": block["text"]}
            else:
                opening = {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}
                delta = {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}
            self.event("content_block_start", {"type": "content_block_start", "index": index, "content_block": opening})
            self.event("content_block_delta", {"type": "content_block_delta", "index": index, "delta": delta})
            self.event("content_block_stop", {"type": "content_block_stop", "index": index})
        self.event(
            "message_delta",
            {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 20}},
        )
        self.event("message_stop", {"type": "message_stop"})


if __name__ == "__main__":
    PORT_FILE, REQUEST_LOG = sys.argv[1], sys.argv[2]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(PORT_FILE + ".tmp", "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    # Publish the port atomically, so a reader never sees a partial number.
    os.replace(PORT_FILE + ".tmp", PORT_FILE)
    server.serve_forever()
