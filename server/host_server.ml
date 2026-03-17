open Yojson.Safe.Util

module Log = (val Logs.src_log (Logs.Src.create "host_server") : Logs.LOG)
module Async_response = Http_server.Async_response

type config = {
  host : string;
  port : int;
  service_name : string;
  service_hostname : string;
  bonjour_enabled : bool;
}

type t = {
  http_server : Http_server.t;
  sessions : Session_store.t;
  config : config;
  mutable bonjour_publisher : Bonjour_publisher.t option;
}

type sse_sink = {
  stream : Http_server.stream;
  sessions : Session_store.t;
  session_id : string;
  mutex : Mutex.t;
  pending : Models.stream_event Queue.t;
  mutable subscriber_id : string option;
  mutable replay_complete : bool;
  mutable draining : bool;
  mutable closed : bool;
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

let cleanup_sse_sink sink =
  let subscriber_id, should_close =
    Mutex.lock sink.mutex;
    let should_close = not sink.closed in
    let subscriber_id =
      if sink.closed then
        None
      else begin
        sink.closed <- true;
        sink.draining <- false;
        sink.replay_complete <- true;
        while not (Queue.is_empty sink.pending) do
          ignore (Queue.take sink.pending)
        done;
        let subscriber_id = sink.subscriber_id in
        sink.subscriber_id <- None;
        subscriber_id
      end
    in
    Mutex.unlock sink.mutex;
    (subscriber_id, should_close)
  in
  begin
    match subscriber_id with
    | Some id -> Session_store.unsubscribe sink.sessions sink.session_id id
    | None -> ()
  end;
  if should_close then Http_server.close_stream sink.stream

let write_sse_event sink event =
  try
    Http_server.write_stream sink.stream (format_sse_event event);
    true
  with exn ->
    Log.warn (fun m -> m "SSE stream write failed for %s: %s" sink.session_id (Printexc.to_string exn));
    cleanup_sse_sink sink;
    false

let drain_sse_sink sink =
  let rec loop () =
    Mutex.lock sink.mutex;
    let next_event =
      if sink.closed || Queue.is_empty sink.pending then begin
        sink.draining <- false;
        None
      end else
        Some (Queue.take sink.pending)
    in
    Mutex.unlock sink.mutex;
    match next_event with
    | None -> ()
    | Some event ->
        if write_sse_event sink event then loop ()
  in
  loop ()

let enqueue_live_sse_event sink event =
  Mutex.lock sink.mutex;
  let should_drain =
    if sink.closed then
      false
    else begin
      Queue.add event sink.pending;
      if sink.replay_complete && not sink.draining then begin
        sink.draining <- true;
        true
      end else
        false
    end
  in
  Mutex.unlock sink.mutex;
  if should_drain then drain_sse_sink sink

let finish_replay sink =
  Mutex.lock sink.mutex;
  let should_drain =
    if sink.closed then
      false
    else begin
      sink.replay_complete <- true;
      if Queue.is_empty sink.pending || sink.draining then
        false
      else begin
        sink.draining <- true;
        true
      end
    end
  in
  Mutex.unlock sink.mutex;
  if should_drain then drain_sse_sink sink

let find_session (server : t) session_id =
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

let attach_rpc_callbacks (server : t) (session : Agent_session.t) =
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

let create_session (server : t) (request : Models.create_session_request) =
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

let prompt_session (server : t) (session : Agent_session.t) (prompt : Models.prompt_request) =
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

let list_sessions_handler (server : t) reqd =
  let sessions = Session_store.list_sessions server.sessions |> Models.json_list_of_summaries in
  Http_server.respond_json reqd (`Assoc [("sessions", sessions)])

let health_handler reqd =
  Http_server.respond_json reqd (`Assoc [
    ("status", `String "ok");
    ("timestamp", `Float (Unix.gettimeofday ()));
  ])

let create_session_handler (server : t) reqd =
  read_json_body reqd (fun json ->
    match Models.parse_create_session_request json with
    | Error err -> Http_server.respond_json ~status:`Bad_request reqd (Json_utils.error_json err)
    | Ok request ->
        Http_server.submit_job server.http_server reqd (fun () ->
          match create_session server request with
          | Error err -> error_response ~status:`Internal_server_error err
          | Ok session -> json_response (`Assoc [("session", session_json session)])))

let handle_sse (server : t) session_id reqd =
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
      let sink = {
        stream;
        sessions = server.sessions;
        session_id;
        mutex = Mutex.create ();
        pending = Queue.create ();
        subscriber_id = None;
        replay_complete = false;
        draining = false;
        closed = false;
      } in
      let callback event =
        enqueue_live_sse_event sink event
      in
      begin
        match Session_store.subscribe_with_replay server.sessions session_id last_event_id callback with
        | Error err ->
            cleanup_sse_sink sink;
            Log.warn (fun m -> m "Failed to subscribe SSE client: %s" err)
        | Ok (subscriber_id, replay) ->
            Mutex.lock sink.mutex;
            sink.subscriber_id <- Some subscriber_id;
            Mutex.unlock sink.mutex;
            let rec write_replay = function
              | [] -> finish_replay sink
              | event :: rest ->
                  if write_sse_event sink event then
                    write_replay rest
            in
            write_replay replay
      end

let handle_session_route (server : t) meth path reqd =
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
    bonjour_publisher = None;
  } in
  Http_server.add_route http_server ~method_:None ~match_type:Http_server.Prefix "/sessions"
    (fun reqd ->
      let request = Http_server.Reqd.request reqd in
      let path, _query = Http_server.split_path_query request.target in
      handle_session_route server request.meth path reqd);
  Http_server.add_route http_server ~method_:(Some `GET) "/healthz" health_handler;
  Http_server.add_route http_server ~method_:(Some `POST) "/sessions" (create_session_handler server);
  server

let start (server : t) =
  if server.config.bonjour_enabled then
    server.bonjour_publisher <- Bonjour_publisher.start {
      Bonjour_publisher.instance_name = server.config.service_name;
      hostname = server.config.service_hostname;
      port = server.config.port;
      version = "0.1.0";
    };
  ignore (Http_server.start server.http_server)

let stop (server : t) =
  Bonjour_publisher.stop server.bonjour_publisher;
  server.bonjour_publisher <- None;
  Session_store.all_sessions server.sessions
  |> List.iter (fun session ->
       cleanup_session session;
       Session_store.remove_session server.sessions session.id);
  Http_server.stop server.http_server
