open Yojson.Safe.Util

type create_session_request = {
  repo_path : string;
  agent_command : string;
  agent_args : string list;
}

type prompt_request = {
  text : string;
}

type tool_decision_request = {
  call_id : string;
  decision : string;
  note : string option;
}

type stream_event = {
  id : string;
  session_id : string;
  seq : int;
  type_ : string;
  timestamp : float;
  payload : Yojson.Safe.t;
}

type session_summary = {
  id : string;
  status : string;
  repo_path : string;
  worktree_path : string;
  created_at : float;
}

let parse_create_session_request json =
  match Json_utils.field_string json "repoPath" with
  | Error err -> Error err
  | Ok repo_path ->
      begin
        match Json_utils.field_string json "agentCommand" with
        | Error err -> Error err
        | Ok agent_command ->
            begin
              match Json_utils.field_string_list json "agentArgs" with
              | Error err -> Error err
              | Ok agent_args -> Ok { repo_path; agent_command; agent_args }
            end
      end

let parse_prompt_request json =
  match Json_utils.field_string json "text" with
  | Error err -> Error err
  | Ok text -> Ok { text }

let parse_tool_decision_request json =
  match Json_utils.field_string json "callId" with
  | Error err -> Error err
  | Ok call_id ->
      begin
        match Json_utils.field_string json "decision" with
        | Error err -> Error err
        | Ok decision ->
            begin
              match Json_utils.field_string_option json "note" with
              | Error err -> Error err
              | Ok note -> Ok { call_id; decision; note }
            end
      end

let stream_event_to_json (event : stream_event) =
  `Assoc [
    ("id", `String event.id);
    ("sessionId", `String event.session_id);
    ("seq", `Int event.seq);
    ("type", `String event.type_);
    ("timestamp", `Float event.timestamp);
    ("payload", event.payload);
  ]

let session_summary_to_json summary =
  `Assoc [
    ("id", `String summary.id);
    ("status", `String summary.status);
    ("repoPath", `String summary.repo_path);
    ("worktreePath", `String summary.worktree_path);
    ("createdAt", `Float summary.created_at);
  ]

let json_list_of_summaries summaries =
  `List (List.map session_summary_to_json summaries)

let text_prompt_blocks text =
  `List [
    `Assoc [
      ("type", `String "text");
      ("text", `String text);
    ]
  ]

let prompt_text_from_json json =
  json
  |> member "prompt"
  |> to_list
  |> List.filter_map (fun item ->
       match item |> member "type" |> to_string_option with
       | Some "text" -> item |> member "text" |> to_string_option
       | _ -> None)
  |> String.concat "\n\n"
