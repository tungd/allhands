#!/usr/bin/env python3
import json
import os
import sys
import time


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


def send_text_chunk(session_id, text):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": session_id,
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}
            }
        }
    })


def send_tool_approval_required(session_id, call_id):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": session_id,
            "update": {
                "sessionUpdate": "tool_approval_required",
                "toolCall": {
                    "callId": call_id,
                    "name": "run_test",
                    "arguments": {"target": "server"}
                }
            }
        }
    })


def send_request_permission(session_id, request_id, call_id):
    send({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "session/request_permission",
        "params": {
            "sessionId": session_id,
            "toolCall": {
                "callId": call_id,
                "name": "run_test",
                "arguments": {"target": "server"}
            },
            "options": [
                {"optionId": "approved", "name": "Approve", "kind": "allow_once"},
                {"optionId": "abort", "name": "Abort", "kind": "reject_once"}
            ]
        }
    })


def read_tool_decision(expected_session_id, expected_call_id, expected_request_id=None):
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        message = json.loads(line)
        if expected_request_id is not None and message.get("id") == expected_request_id:
            outcome = message.get("result", {}).get("outcome", {})
            option_id = outcome.get("optionId")
            return {
                "sessionId": expected_session_id,
                "callId": expected_call_id,
                "decision": option_id or outcome.get("outcome"),
                "optionId": option_id
            }
        if message.get("method") != "session/toolDecision":
            continue
        params = message.get("params", {})
        if params.get("sessionId") != expected_session_id:
            continue
        if params.get("callId") != expected_call_id:
            continue
        return params


session_counter = 0
tool_call_counter = 0

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
        delay_s = float(os.environ.get("FAKE_ACP_PROMPT_DELAY_S", "0") or "0")
        if delay_s > 0:
            time.sleep(delay_s)
        requires_approval = os.environ.get("FAKE_ACP_REQUIRE_APPROVAL") == "1"
        if requires_approval:
            tool_call_counter += 1
            call_id = f"call-{tool_call_counter}"
            permission_style = os.environ.get("FAKE_ACP_PERMISSION_STYLE", "legacy")
            request_id = 1000 + tool_call_counter
            if permission_style == "request":
                send_request_permission(child_session, request_id, call_id)
                decision = read_tool_decision(child_session, call_id, expected_request_id=request_id)
            else:
                send_tool_approval_required(child_session, call_id)
                decision = read_tool_decision(child_session, call_id)
            if decision is None:
                break
            send_text_chunk(
                child_session,
                f"Tool decision: {decision.get('optionId') or decision.get('decision', 'unknown')}",
            )
        send_text_chunk(child_session, f"Echo: {text}")
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
