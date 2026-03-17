#!/usr/bin/env python3
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def prompt_text(params):
    blocks = params.get("prompt", [])
    parts = []
    for block in blocks:
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n\n".join(parts)


session_counter = 0

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    msg_id = message.get("id")

    if method == "initialize":
        protocol_version = message.get("params", {}).get("protocolVersion")
        if protocol_version != 1:
            send({
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params"
                }
            })
        else:
            send({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "protocolVersion": 1,
                    "agentInfo": {"name": "fake-agent", "version": "0.1.0"},
                    "agentCapabilities": {"promptCapabilities": {}, "sessionCapabilities": {}}
                }
            })
    elif method == "session/new":
        session_counter += 1
        send({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"sessionId": f"child-{session_counter}"}
        })
    elif method == "session/prompt":
        child_session = message["params"]["sessionId"]
        text = prompt_text(message["params"])
        send({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": child_session,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": f"Echo: {text}"}
                }
            }
        })
        send({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"stopReason": "end_turn"}
        })
    elif method == "session/cancel":
        send({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {}
        })
    elif method == "session/toolDecision":
        continue
    else:
        send({
            "jsonrpc": "2.0",
            "id": msg_id,
            "error": {"code": -32601, "message": f"unknown method {method}"}
        })
