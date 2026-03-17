let assert_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %s but got %s" label expected actual)

let () =
  let thought_json =
    Yojson.Safe.from_string
      {|{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}|}
  in
  let tool_json =
    Yojson.Safe.from_string
      {|{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":{"sessionUpdate":"tool_call","toolCall":{"name":"run_test"}}}}|}
  in
  let patch_json =
    Yojson.Safe.from_string
      {|{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":{"patch":"diff --git a/file b/file"}}}|}
  in
  let permission_json =
    Yojson.Safe.from_string
      {|{"jsonrpc":"2.0","id":77,"method":"session/request_permission","params":{"sessionId":"child","toolCall":{"callId":"call-1","name":"run_test"},"options":[{"optionId":"approved"}]}}|}
  in
  assert_equal "thought" "acp.thought" (fst (Event_mapper.from_agent_message thought_json));
  assert_equal "call" "acp.call" (fst (Event_mapper.from_agent_message tool_json));
  assert_equal "patch" "acp.patch" (fst (Event_mapper.from_agent_message patch_json));
  assert_equal "request_permission" "acp.call" (fst (Event_mapper.from_agent_message permission_json))
