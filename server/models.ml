open Yojson.Safe.Util

type create_session_request = {
  folder_path : string;
  agent : string;
}

type prompt_request = {
  text : string;
}

type tool_decision_request = {
  request_id : Yojson.Safe.t option;
  call_id : string option;
  option_id : string option;
  decision : string option;
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

type available_agent = {
  id : string;
  display_name : string;
}

type server_info = {
  version : string;
  launch_root_path : string;
  default_agent : string option;
  available_agents : available_agent list;
}

let parse_create_session_request json =
  match Json_utils.field_string json "folderPath" with
  | Error err -> Error err
  | Ok folder_path ->
      begin
        match Json_utils.field_string json "agent" with
        | Error err -> Error err
        | Ok agent -> Ok { folder_path; agent }
      end

let parse_prompt_request json =
  match Json_utils.field_string json "text" with
  | Error err -> Error err
  | Ok text -> Ok { text }

let parse_tool_decision_request json =
  let request_id =
    match json |> member "requestId" with
    | `Null -> Ok None
    | (`String _ | `Int _ | `Intlit _ | `Float _) as value -> Ok (Some value)
    | _ -> Error "Field requestId must be a JSON-RPC id"
  in
  match request_id with
  | Error err -> Error err
  | Ok request_id ->
      begin
        match Json_utils.field_string_option json "callId" with
        | Error err -> Error err
        | Ok call_id ->
            begin
              match Json_utils.field_string_option json "optionId" with
              | Error err -> Error err
              | Ok option_id ->
                  begin
                    match Json_utils.field_string_option json "decision" with
                    | Error err -> Error err
                    | Ok decision ->
                        begin
                          match Json_utils.field_string_option json "note" with
                          | Error err -> Error err
                          | Ok note ->
                              if request_id = None && call_id = None then
                                Error "Missing field: requestId or callId"
                              else if option_id = None && decision = None then
                                Error "Missing field: optionId or decision"
                              else
                                Ok { request_id; call_id; option_id; decision; note }
                        end
                  end
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

let session_summary_to_json (summary : session_summary) =
  `Assoc [
    ("id", `String summary.id);
    ("status", `String summary.status);
    ("repoPath", `String summary.repo_path);
    ("worktreePath", `String summary.worktree_path);
    ("createdAt", `Float summary.created_at);
  ]

let json_list_of_summaries summaries =
  `List (List.map session_summary_to_json summaries)

let available_agent_to_json (agent : available_agent) =
  `Assoc [
    ("id", `String agent.id);
    ("displayName", `String agent.display_name);
  ]

let server_info_to_json info =
  `Assoc [
    ("version", `String info.version);
    ("launchRootPath", `String info.launch_root_path);
    ("defaultAgent",
      match info.default_agent with
      | Some agent -> `String agent
      | None -> `Null);
    ("availableAgents", `List (List.map available_agent_to_json info.available_agents));
  ]

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
