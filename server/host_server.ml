open Yojson.Safe.Util

module Log = (val Logs.src_log (Logs.Src.create "host_server") : Logs.LOG)
module Async_response = Http_server.Async_response

type config = {
  host : string;
  port : int;
}

type t = {
  http_server : Http_server.t;
  sessions : Session_store.t;
  config : config;
}

let make_session_id () =
  Random.self_init ();
  Printf.sprintf "session_%08x%08x" (Random.bits ()) (Random.bits ())

let json_response ?(status=`OK) json =
  Async_response.json ~status json

let error_response ?(status=`Bad_request) message =
  json_response ~status (Json_utils.error_json message)

let read_json_body reqd on_json =
  Http_server.read_body (Http_server.Reqd.request_body reqd) (function
    | Error (`Too_large max_bytes) ->
        Http_server.respond_json ~status:`Payload_too_large reqd (`Assoc [
          ("error", `String "Request body too large");
          ("maxBytes", `Int max_bytes);
        ])
    | Error (`Exception exn) ->
        Http_server.respond_json ~status:`Bad_request reqd (`Assoc [
          ("error", `String (Printexc.to_string exn));
        ])
    | Ok body ->
        try on_json (Yojson.Safe.from_string body)
        with Yojson.Json_error err ->
          Http_server.respond_json ~status:`Bad_request reqd (`Assoc [
            ("error", `String ("Invalid JSON: " ^ err));
          ]))

let split_segments path =
  path
  |> String.split_on_char '/'
  |> List.filter (fun segment -> segment <> "")

let request_header request name =
  H1.Headers.get (request : H1.Request.t).headers name

let format_sse_event (event : Models.stream_event) =
  Printf.sprintf "id: %s\nevent: %s\ndata: %s\n\n"
    event.Models.id
    event.Models.type_
    (Yojson.Safe.to_string (Models.stream_event_to_json event))

let find_session server session_id =
  Session_store.find_session server.sessions session_id

let cleanup_session (session : Agent_session.t) =
  begin
    match session.Agent_session.rpc with
    | Some rpc -> Agent_rpc.terminate rpc
    | None -> ()
  end;
  Worktree_manager.remove_worktree
    ~repo_path:session.repo_path
    ~worktree_path:session.worktree_path

let attach_rpc_callbacks server (session : Agent_session.t) =
  let on_message json =
    let event_type, payload = Event_mapper.from_agent_message json in
    ignore (Session_store.append_event server.sessions session.Agent_session.id ~type_:event_type ~payload);
    begin
      match event_type with
      | "acp.thought" | "acp.call" | "acp.patch" -> Session_store.update_status server.sessions session.id "busy"
      | "acp.error" -> Session_store.update_status server.sessions session.id "error"
      | _ -> ()
    end
  in
  let on_stderr line =
    ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
      ~payload:(`Assoc [("stream", `String "stderr"); ("line", `String line)]))
  in
  let on_exit status =
    let payload =
      `Assoc [
        ("state", `String "stopped");
        ("status", `String
          (match status with
           | Unix.WEXITED code -> Printf.sprintf "exit:%d" code
           | Unix.WSIGNALED signal -> Printf.sprintf "signaled:%d" signal
           | Unix.WSTOPPED signal -> Printf.sprintf "stopped:%d" signal));
      ]
    in
    Session_store.update_status server.sessions session.id "stopped";
    ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status" ~payload)
  in
  (on_message, on_stderr, on_exit)

let initialize_agent server (session : Agent_session.t) =
  let on_message, on_stderr, on_exit = attach_rpc_callbacks server session in
  match Agent_rpc.create
          ~command:session.agent_command
          ~args:session.agent_args
          ~on_message
          ~on_stderr
          ~on_exit with
  | Error err -> Error err
  | Ok rpc ->
      session.rpc <- Some rpc;
      begin
        match Agent_rpc.send_request rpc ~method_:"initialize" ~params:(`Assoc []) with
        | Error err -> Error err
        | Ok result ->
            ignore (Session_store.append_event server.sessions session.id ~type_:"acp.init" ~payload:result);
            let params =
              `Assoc [
                ("cwd", `String session.worktree_path);
                ("mcpServers", `List []);
              ]
            in
            begin
              match Agent_rpc.send_request rpc ~method_:"session/new" ~params with
              | Error err -> Error err
              | Ok result ->
                  let child_session_id = result |> member "sessionId" |> to_string in
                  session.child_session_id <- Some child_session_id;
                  session.status <- "ready";
                  Session_store.update_status server.sessions session.id "ready";
                  ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
                    ~payload:(`Assoc [("state", `String "ready")]));
                  Ok ()
            end
      end

let create_session server (request : Models.create_session_request) =
  match Worktree_manager.create_worktree ~repo_path:request.repo_path ~session_id:(make_session_id ()) with
  | Error err -> Error err
  | Ok worktree_path ->
      let id = Filename.basename worktree_path in
      let session =
        Agent_session.create
          ~id
          ~repo_path:request.repo_path
          ~worktree_path
          ~agent_command:request.agent_command
          ~agent_args:request.agent_args
      in
      Session_store.add_session server.sessions session;
      ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
        ~payload:(`Assoc [("state", `String "starting")]));
      match initialize_agent server session with
      | Ok () -> Ok session
      | Error err ->
          cleanup_session session;
          Session_store.remove_session server.sessions session.id;
          Error err

let prompt_session server (session : Agent_session.t) (prompt : Models.prompt_request) =
  Session_store.update_status server.sessions session.id "busy";
  ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
    ~payload:(`Assoc [("state", `String "busy")]));
  match session.Agent_session.rpc, session.child_session_id with
  | Some rpc, Some child_session_id ->
      let params =
        `Assoc [
          ("sessionId", `String child_session_id);
          ("prompt", Models.text_prompt_blocks prompt.text);
        ]
      in
      begin
        match Agent_rpc.send_request rpc ~method_:"session/prompt" ~params ~timeout_s:120.0 with
        | Error err ->
            Session_store.update_status server.sessions session.id "error";
            ignore (Session_store.append_event server.sessions session.id ~type_:"acp.error"
              ~payload:(`Assoc [("message", `String err)]));
            Error err
        | Ok result ->
            Session_store.update_status server.sessions session.id "ready";
            ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
              ~payload:(`Assoc [("state", `String "ready"); ("stopReason", result |> member "stopReason")]));
            Ok result
      end
  | _ -> Error "Session is not ready"

let cancel_session _server (session : Agent_session.t) =
  match session.Agent_session.rpc, session.child_session_id with
  | Some rpc, Some child_session_id ->
      Agent_rpc.send_request rpc ~method_:"session/cancel"
        ~params:(`Assoc [("sessionId", `String child_session_id)])
  | _ -> Error "Session is not ready"

let tool_decision (session : Agent_session.t) (request : Models.tool_decision_request) =
  match session.Agent_session.rpc, session.child_session_id with
  | Some rpc, Some child_session_id ->
      Agent_rpc.send_notification rpc ~method_:"session/toolDecision"
        ~params:(`Assoc [
          ("sessionId", `String child_session_id);
          ("callId", `String request.call_id);
          ("decision", `String request.decision);
          ("note", match request.note with Some note -> `String note | None -> `Null);
        ])
  | _ -> Error "Session is not ready"

let session_json (session : Agent_session.t) =
  Models.session_summary_to_json (Agent_session.to_summary session)

let list_sessions_handler server reqd =
  let sessions = Session_store.list_sessions server.sessions |> Models.json_list_of_summaries in
  Http_server.respond_json reqd (`Assoc [("sessions", sessions)])

let health_handler reqd =
  Http_server.respond_json reqd (`Assoc [
    ("status", `String "ok");
    ("timestamp", `Float (Unix.gettimeofday ()));
  ])

let create_session_handler server reqd =
  read_json_body reqd (fun json ->
    match Models.parse_create_session_request json with
    | Error err -> Http_server.respond_json ~status:`Bad_request reqd (Json_utils.error_json err)
    | Ok request ->
        Http_server.submit_job server.http_server reqd (fun () ->
          match create_session server request with
          | Error err -> error_response ~status:`Internal_server_error err
          | Ok session -> json_response (`Assoc [("session", session_json session)])))

let handle_sse server session_id reqd =
  match find_session server session_id with
  | None -> Http_server.respond_text ~status:`Not_found reqd "Session not found"
  | Some _session ->
      let request = Http_server.Reqd.request reqd in
      let last_event_id = request_header request "last-event-id" in
      let stream =
        Http_server.respond_stream reqd ~headers:[
          ("content-type", "text/event-stream");
          ("cache-control", "no-cache");
          ("connection", "keep-alive");
        ]
      in
      let replay = Session_store.events_after server.sessions session_id last_event_id in
      List.iter (fun event -> Http_server.write_stream stream (format_sse_event event)) replay;
      let subscriber_ref = ref None in
      let callback event =
        try
          Http_server.write_stream stream (format_sse_event event)
        with exn ->
          begin
            match !subscriber_ref with
            | Some subscriber_id -> Session_store.unsubscribe server.sessions session_id subscriber_id
            | None -> ()
          end;
          Http_server.close_stream stream;
          raise exn
      in
      begin
        match Session_store.subscribe server.sessions session_id callback with
        | Error err ->
            Http_server.close_stream stream;
            Log.warn (fun m -> m "Failed to subscribe SSE client: %s" err)
        | Ok subscriber_id -> subscriber_ref := Some subscriber_id
      end

let handle_session_route server meth path reqd =
  match split_segments path with
  | ["sessions"] when meth = `GET -> list_sessions_handler server reqd
  | ["sessions"; session_id] when meth = `GET ->
      begin
        match find_session server session_id with
        | None -> Http_server.respond_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session -> Http_server.respond_json reqd (`Assoc [("session", session_json session)])
      end
  | ["sessions"; session_id] when meth = `DELETE ->
      begin
        match find_session server session_id with
        | None -> Http_server.respond_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            cleanup_session session;
            Session_store.remove_session server.sessions session_id;
            Http_server.respond_json reqd (`Assoc [("deleted", `Bool true)])
      end
  | ["sessions"; session_id; "events"] when meth = `GET -> handle_sse server session_id reqd
  | ["sessions"; session_id; "prompts"] when meth = `POST ->
      begin
        match find_session server session_id with
        | None -> Http_server.respond_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            read_json_body reqd (fun json ->
              match Models.parse_prompt_request json with
              | Error err -> Http_server.respond_json ~status:`Bad_request reqd (Json_utils.error_json err)
              | Ok prompt ->
                  Http_server.submit_job server.http_server reqd (fun () ->
                    match prompt_session server session prompt with
                    | Error err -> error_response ~status:`Internal_server_error err
                    | Ok result -> json_response (`Assoc [("result", result)])))
      end
  | ["sessions"; session_id; "tool-decisions"] when meth = `POST ->
      begin
        match find_session server session_id with
        | None -> Http_server.respond_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            read_json_body reqd (fun json ->
              match Models.parse_tool_decision_request json with
              | Error err -> Http_server.respond_json ~status:`Bad_request reqd (Json_utils.error_json err)
              | Ok request ->
                  begin
                    ignore (Session_store.append_event server.sessions session_id ~type_:"acp.call"
                      ~payload:(`Assoc [
                        ("callId", `String request.call_id);
                        ("decision", `String request.decision);
                        ("note", match request.note with Some note -> `String note | None -> `Null);
                      ]));
                    match tool_decision session request with
                    | Ok () -> Http_server.respond_json reqd (`Assoc [("accepted", `Bool true)])
                    | Error err -> Http_server.respond_json ~status:`Internal_server_error reqd (Json_utils.error_json err)
                  end)
      end
  | ["sessions"; session_id; "cancel"] when meth = `POST ->
      begin
        match find_session server session_id with
        | None -> Http_server.respond_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            Http_server.submit_job server.http_server reqd (fun () ->
              match cancel_session server session with
              | Error err -> error_response ~status:`Internal_server_error err
              | Ok result -> json_response (`Assoc [("result", result)]))
      end
  | _ -> Http_server.respond_text ~status:`Not_found reqd "Not found"

let create config =
  let http_server = Http_server.create ~host:config.host ~port:config.port ~idle_timeout_s:300.0 () in
  let server = {
    http_server;
    sessions = Session_store.create ();
    config;
  } in
  Http_server.add_route http_server ~method_:None ~match_type:Http_server.Prefix "/sessions"
    (fun reqd ->
      let request = Http_server.Reqd.request reqd in
      let path, _query = Http_server.split_path_query request.target in
      handle_session_route server request.meth path reqd);
  Http_server.add_route http_server ~method_:(Some `GET) "/healthz" health_handler;
  Http_server.add_route http_server ~method_:(Some `POST) "/sessions" (create_session_handler server);
  server

let start server =
  ignore (Http_server.start server.http_server)

let stop server =
  Session_store.all_sessions server.sessions
  |> List.iter (fun session ->
       cleanup_session session;
       Session_store.remove_session server.sessions session.id);
  Http_server.stop server.http_server
