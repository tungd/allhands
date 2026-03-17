open Yojson.Safe.Util

let classify_session_update update =
  match update |> member "sessionUpdate" |> to_string_option with
  | Some ("agent_message_chunk" | "agent_thought_chunk" | "thought" | "reasoning") -> "acp.thought"
  | Some ("tool_call" | "tool_approval_required") -> "acp.call"
  | Some "patch" -> "acp.patch"
  | Some "error" -> "acp.error"
  | _ ->
      if update |> member "patch" <> `Null then "acp.patch"
      else if update |> member "toolCall" <> `Null then "acp.call"
      else "acp.status"

let request_permission_payload json =
  let params = json |> member "params" in
  let request_id = json |> member "id" in
  match params with
  | `Assoc fields -> `Assoc (("requestId", request_id) :: fields)
  | _ -> `Assoc [("requestId", request_id); ("params", params)]

let from_agent_message json =
  match json |> member "method" |> to_string_option with
  | Some "session/request_permission" ->
      ("acp.call", request_permission_payload json)
  | Some "session/update" ->
      let params = json |> member "params" in
      let update = params |> member "update" in
      (classify_session_update update, params)
  | Some _ -> ("acp.status", json)
  | None ->
      if json |> member "error" <> `Null then ("acp.error", json)
      else ("acp.status", json)
