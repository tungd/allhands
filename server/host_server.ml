open Yojson.Safe.Util

module Log = (val Logs.src_log (Logs.Src.create "host_server") : Logs.LOG)
module Async_response = Http_server.Async_response

type config = {
  host : string;
  port : int;
  service_name : string;
  service_hostname : string;
  bonjour_enabled : bool;
  launch_root_path : string;
  available_launchers : Launcher_catalog.launcher list;
  acp_request_timeout_s : float;
  acp_prompt_timeout_s : float;
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

let json_to_string json =
  Yojson.Safe.to_string json

let api_headers = [("cache-control", "private, no-store")]
let ui_html_cache_control = "no-cache, must-revalidate"
let ui_asset_cache_control = "no-cache, must-revalidate"
let immutable_asset_cache_control = "public, max-age=31536000, immutable"

let string_of_process_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit:%d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signaled:%d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped:%d" signal

let make_session_id () =
  Random.self_init ();
  Printf.sprintf "session_%08x%08x" (Random.bits ()) (Random.bits ())

let async_json_response ?(status=`OK) json =
  Async_response.json ~status ~headers:api_headers json

let error_response ?(status=`Bad_request) message =
  async_json_response ~status (Json_utils.error_json message)

let respond_api_json ?(status=`OK) reqd json =
  Http_server.respond_json ~status ~headers:api_headers reqd json

let respond_api_text ?(status=`OK) reqd text =
  Http_server.respond_text ~status ~headers:api_headers reqd text

let serve_ui_file reqd ~file_name ~content_type ~cache_control =
  match Web_ui_assets.read file_name, Web_ui_assets.hash file_name with
  | Some body, Some hash ->
      Http_server.respond_static reqd
        ~content_type
        ~cache_control
        ~etag:(Printf.sprintf "\"%s\"" hash)
        body
  | _ ->
    Http_server.respond_text ~status:`Not_found reqd "Asset not found"

let read_any_body reqd on_json =
  let request = Http_server.Reqd.request reqd in
  let content_type =
    match H1.Headers.get request.headers "content-type" with
    | Some ct -> String.lowercase_ascii ct
    | None -> "application/json"
  in
  Http_server.read_body (Http_server.Reqd.request_body reqd) (function
    | Error (`Too_large max_bytes) ->
        respond_api_json ~status:`Payload_too_large reqd (`Assoc [
          ("error", `String "Request body too large");
          ("maxBytes", `Int max_bytes);
        ])
    | Error (`Exception exn) ->
        respond_api_json ~status:`Bad_request reqd (`Assoc [
          ("error", `String (Printexc.to_string exn));
        ])
    | Ok body ->
        if String.starts_with ~prefix:"application/x-www-form-urlencoded" content_type then
          let pairs =
            body
            |> String.split_on_char '&'
            |> List.filter_map (fun pair ->
                 match String.split_on_char '=' pair with
                 | [k; v] ->
                     let decode s =
                       let s = String.map (fun c -> if c = '+' then ' ' else c) s in
                       try Uri.pct_decode s with _ -> s
                     in
                     Some (decode k, `String (decode v))
                 | _ -> None)
          in
          on_json (`Assoc pairs)
        else
          try on_json (Yojson.Safe.from_string body)
          with Yojson.Json_error err ->
            respond_api_json ~status:`Bad_request reqd (`Assoc [
              ("error", `String ("Invalid JSON: " ^ err));
            ]))

let split_segments path =
  path
  |> String.split_on_char '/'
  |> List.filter (fun segment -> segment <> "")

let request_header request name =
  H1.Headers.get (request : H1.Request.t).headers name

let format_sse_event (event : Models.stream_event) =
  let html = Ui_view.render_event_card event |> Ui_view.to_string_elt in
  let data =
    html
    |> String.split_on_char '\n'
    |> List.map (fun line -> "data: " ^ line)
    |> String.concat "\n"
  in
  Printf.sprintf "id: %s\nevent: message\n%s\n\n"
    event.Models.id
    data

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
  Log.info (fun m ->
    m "Cleaning up session %s (repo=%s worktree=%s)"
      session.id
      session.repo_path
      session.worktree_path);
  begin
    match session.Agent_session.rpc with
    | Some rpc -> Agent_rpc.terminate rpc
    | None -> ()
  end;
  Worktree_manager.remove_worktree
    ~repo_path:session.repo_path
    ~worktree_path:session.worktree_path

let permission_request_call_id payload =
  match payload |> member "toolCall" |> member "callId" |> to_string_option with
  | Some call_id -> Some call_id
  | None -> payload |> member "callId" |> to_string_option

let permission_request_id payload =
  match payload |> member "requestId" with
  | `Null -> None
  | value -> Some value

let is_permission_request_payload payload =
  payload |> member "options" <> `Null && permission_request_id payload <> None

let register_permission_request (session : Agent_session.t) payload =
  match permission_request_call_id payload, permission_request_id payload with
  | Some call_id, Some request_id ->
      Hashtbl.replace session.pending_permission_requests call_id request_id
  | _ -> ()

let resolve_permission_request_id (session : Agent_session.t) request =
  match request.Models.request_id, request.call_id with
  | Some request_id, _ -> Some request_id
  | None, Some call_id -> Hashtbl.find_opt session.pending_permission_requests call_id
  | None, None -> None

let option_id_of_request request =
  match request.Models.option_id, request.decision with
  | Some option_id, _ -> Some option_id
  | None, Some "approved" -> Some "approved"
  | None, Some "abort" -> Some "abort"
  | None, Some "denied" -> Some "denied"
  | None, Some decision -> Some decision
  | None, None -> None

let respond_to_permission_request (session : Agent_session.t) request =
  match session.Agent_session.rpc, resolve_permission_request_id session request, option_id_of_request request with
  | Some rpc, Some request_id, Some option_id ->
      begin
        match request.call_id with
        | Some call_id -> Hashtbl.remove session.pending_permission_requests call_id
        | None -> ()
      end;
      Agent_rpc.send_response rpc ~id:request_id
        ~result:(`Assoc [
          ("outcome", `Assoc [
            ("outcome", `String "selected");
            ("optionId", `String option_id);
          ]);
        ])
  | Some _, None, _ -> Error "Unknown permission request"
  | Some _, _, None -> Error "Missing permission option"
  | None, _, _ -> Error "Session is not ready"

let cancel_pending_permission_requests (session : Agent_session.t) =
  match session.Agent_session.rpc with
  | None -> Ok ()
  | Some rpc ->
      let pending =
        Hashtbl.fold (fun call_id request_id acc -> (call_id, request_id) :: acc)
          session.pending_permission_requests
          []
      in
      let rec loop = function
        | [] -> Ok ()
        | (call_id, request_id) :: rest ->
            Hashtbl.remove session.pending_permission_requests call_id;
            begin
              match Agent_rpc.send_response rpc ~id:request_id
                      ~result:(`Assoc [
                        ("outcome", `Assoc [("outcome", `String "cancelled")]);
                      ]) with
              | Ok () -> loop rest
              | Error err -> Error err
            end
      in
      loop pending

let attach_rpc_callbacks (server : t) (session : Agent_session.t) =
  let on_message json =
    let event_type, payload = Event_mapper.from_agent_message json in
    Log.debug (fun m ->
      m "ACP message for %s mapped to %s: %s"
        session.id
        event_type
        (json_to_string json));
    if event_type = "acp.call" && is_permission_request_payload payload then
      register_permission_request session payload;
    ignore (Session_store.append_event server.sessions session.Agent_session.id ~type_:event_type ~payload);
    begin
      match event_type with
      | "acp.thought" | "acp.call" | "acp.patch" -> Session_store.update_status server.sessions session.id "busy"
      | "acp.error" -> Session_store.update_status server.sessions session.id "error"
      | _ -> ()
    end
  in
  let on_stderr line =
    Log.warn (fun m -> m "ACP stderr for %s: %s" session.id line);
    ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
      ~payload:(`Assoc [("stream", `String "stderr"); ("line", `String line)]))
  in
  let on_exit status =
    let status_text = string_of_process_status status in
    Log.warn (fun m -> m "Agent process exited for %s: %s" session.id status_text);
    let payload =
      `Assoc [
        ("state", `String "stopped");
        ("status", `String status_text);
      ]
    in
    Session_store.update_status server.sessions session.id "stopped";
    ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status" ~payload)
  in
  (on_message, on_stderr, on_exit)

let initialize_agent server (session : Agent_session.t) =
  let on_message, on_stderr, on_exit = attach_rpc_callbacks server session in
  Log.info (fun m ->
    m "Launching agent for %s with command=%s args=[%s] cwd=%s"
      session.id
      session.agent_command
      (String.concat "; " session.agent_args)
      session.worktree_path);
  match Agent_rpc.create
          ~command:session.agent_command
          ~args:session.agent_args
          ~on_message
          ~on_stderr
          ~on_exit with
  | Error err ->
      Log.err (fun m -> m "Failed to spawn agent for %s: %s" session.id err);
      Error err
  | Ok rpc ->
      session.rpc <- Some rpc;
      begin
        Log.info (fun m -> m "Sending initialize to agent for %s" session.id);
        match Agent_rpc.send_request rpc ~method_:"initialize"
                ~timeout_s:server.config.acp_request_timeout_s
                ~params:(`Assoc [("protocolVersion", `Int 1)]) with
        | Error err ->
            Log.err (fun m -> m "Initialize failed for %s: %s" session.id err);
            Error err
        | Ok result ->
            Log.info (fun m ->
              m "Initialize succeeded for %s: %s"
                session.id
                (json_to_string result));
            ignore (Session_store.append_event server.sessions session.id ~type_:"acp.init" ~payload:result);
            let params =
              `Assoc [
                ("cwd", `String session.worktree_path);
                ("mcpServers", `List []);
              ]
            in
            begin
              Log.info (fun m ->
                m "Sending session/new for %s: %s"
                  session.id
                  (json_to_string params));
              match Agent_rpc.send_request rpc ~method_:"session/new"
                      ~timeout_s:server.config.acp_request_timeout_s
                      ~params with
              | Error err ->
                  Log.err (fun m -> m "session/new failed for %s: %s" session.id err);
                  Error err
              | Ok result ->
                  let child_session_id = result |> member "sessionId" |> to_string in
                  Log.info (fun m ->
                    m "session/new succeeded for %s -> child session %s payload=%s"
                      session.id
                      child_session_id
                      (json_to_string result));
                  session.child_session_id <- Some child_session_id;
                  session.status <- "ready";
                  Session_store.update_status server.sessions session.id "ready";
                  ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
                    ~payload:(`Assoc [("state", `String "ready")]));
                  Ok ()
            end
      end

let create_session_with_launcher (server : t) ~repo_path (launcher : Launcher_catalog.launcher) =
  Log.info (fun m ->
    m "Creating session with launcher=%s repo=%s"
      launcher.Launcher_catalog.id
      repo_path);
  match Worktree_manager.create_worktree ~repo_path ~session_id:(make_session_id ()) with
  | Error err ->
      Log.err (fun m ->
        m "Failed to create worktree for repo=%s launcher=%s: %s"
          repo_path
          launcher.Launcher_catalog.id
          err);
      Error err
  | Ok worktree_path ->
      let id = Filename.basename worktree_path in
      let session =
        Agent_session.create
          ~id
          ~repo_path
          ~worktree_path
          ~agent_command:launcher.command
          ~agent_args:launcher.args
      in
      Log.info (fun m ->
        m "Session %s created with worktree=%s"
          session.id
          session.worktree_path);
      Session_store.add_session server.sessions session;
      ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
        ~payload:(`Assoc [("state", `String "starting")]));
      match initialize_agent server session with
      | Ok () ->
          Log.info (fun m -> m "Session %s is ready" session.id);
          Ok session
      | Error err ->
          Log.err (fun m -> m "Session %s failed during startup: %s" session.id err);
          cleanup_session session;
          Session_store.remove_session server.sessions session.id;
          Error err

let prompt_session (server : t) (session : Agent_session.t) (prompt : Models.prompt_request) =
  Log.info (fun m ->
    m "Prompt request for %s: %S"
      session.id
      prompt.text);
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
        match Agent_rpc.send_request rpc ~method_:"session/prompt"
                ~params
                ~timeout_s:server.config.acp_prompt_timeout_s with
        | Error err ->
            Log.err (fun m -> m "Prompt failed for %s: %s" session.id err);
            Session_store.update_status server.sessions session.id "error";
            ignore (Session_store.append_event server.sessions session.id ~type_:"acp.error"
              ~payload:(`Assoc [("message", `String err)]));
            Error err
        | Ok result ->
            Log.info (fun m ->
              m "Prompt completed for %s: %s"
                session.id
                (json_to_string result));
            Session_store.update_status server.sessions session.id "ready";
            ignore (Session_store.append_event server.sessions session.id ~type_:"acp.status"
              ~payload:(`Assoc [("state", `String "ready"); ("stopReason", result |> member "stopReason")]));
            Ok result
      end
  | _ ->
      Log.warn (fun m -> m "Prompt rejected for %s because session is not ready" session.id);
      Error "Session is not ready"

let cancel_session server (session : Agent_session.t) =
  Log.info (fun m -> m "Cancel request for %s" session.id);
  begin
    match cancel_pending_permission_requests session with
    | Ok () -> ()
    | Error err ->
        Log.warn (fun m -> m "Failed to cancel pending permission requests for %s: %s" session.id err)
  end;
  match session.Agent_session.rpc, session.child_session_id with
  | Some rpc, Some child_session_id ->
      Agent_rpc.send_request rpc ~method_:"session/cancel"
        ~timeout_s:server.config.acp_request_timeout_s
        ~params:(`Assoc [("sessionId", `String child_session_id)])
  | _ ->
      Log.warn (fun m -> m "Cancel rejected for %s because session is not ready" session.id);
      Error "Session is not ready"

let tool_decision (session : Agent_session.t) (request : Models.tool_decision_request) =
  Log.info (fun m ->
    m "Tool decision for %s call=%s option=%s decision=%s note=%s"
      session.id
      (Option.value ~default:"" request.call_id)
      (Option.value ~default:"" request.option_id)
      (Option.value ~default:"" request.decision)
      (Option.value ~default:"" request.note));
  match option_id_of_request request with
  | Some _ when resolve_permission_request_id session request <> None ->
      respond_to_permission_request session request
  | _ ->
      match session.Agent_session.rpc, session.child_session_id, request.call_id, request.decision with
      | Some rpc, Some child_session_id, Some call_id, Some decision ->
          Agent_rpc.send_notification rpc ~method_:"session/toolDecision"
            ~params:(`Assoc [
              ("sessionId", `String child_session_id);
              ("callId", `String call_id);
              ("decision", `String decision);
              ("note", match request.note with Some note -> `String note | None -> `Null);
            ])
      | _ -> Error "Session is not ready"

let session_json (session : Agent_session.t) =
  Models.session_summary_to_json (Agent_session.to_summary session)

let list_sessions_handler (server : t) reqd =
  let sessions = Session_store.list_sessions server.sessions |> Models.json_list_of_summaries in
  respond_api_json reqd (`Assoc [("sessions", sessions)])

let health_handler reqd =
  respond_api_json reqd (`Assoc [
    ("status", `String "ok");
    ("timestamp", `Float (Unix.gettimeofday ()));
  ])

let server_info_handler (server : t) reqd =
  let server_info =
    {
      Models.version = Build_info.version;
      Models.launch_root_path = server.config.launch_root_path;
      default_agent = Launcher_catalog.default_agent_id server.config.available_launchers;
      available_agents =
        List.map (fun launcher ->
          {
            Models.id = launcher.Launcher_catalog.id;
            display_name = launcher.display_name;
          })
          server.config.available_launchers;
    }
  in
  respond_api_json reqd (Models.server_info_to_json server_info)

let create_session_handler (server : t) reqd =
  read_any_body reqd (fun json ->
    Log.info (fun m -> m "POST /sessions payload=%s" (json_to_string json));
    match Models.parse_create_session_request json with
    | Error err ->
        Log.warn (fun m -> m "Invalid create session request: %s" err);
        respond_api_json ~status:`Bad_request reqd (Json_utils.error_json err)
    | Ok request ->
        begin
          match Launcher_catalog.resolve server.config.available_launchers request.agent with
          | None ->
              Log.warn (fun m ->
                m "Create session requested unavailable agent=%s" request.agent);
              respond_api_json ~status:`Bad_request reqd
                (Json_utils.error_json "Requested agent is not available on this server")
          | Some launcher ->
              begin
                match Launcher_catalog.resolve_folder
                        ~launch_root_path:server.config.launch_root_path
                        ~folder_path:request.folder_path with
                | Error err ->
                    Log.warn (fun m ->
                      m "Create session rejected folderPath=%s: %s"
                        request.folder_path
                        err);
                    respond_api_json ~status:`Bad_request reqd (Json_utils.error_json err)
                | Ok repo_path ->
                    Http_server.submit_job server.http_server reqd (fun () ->
                      Log.info (fun m ->
                        m "Create session request accepted agent=%s folderPath=%s resolvedRepo=%s"
                          request.agent
                          request.folder_path
                          repo_path);
                      match create_session_with_launcher server ~repo_path launcher with
                      | Error err ->
                          Log.err (fun m ->
                            m "Create session failed for repo=%s agent=%s: %s"
                              repo_path
                              request.agent
                              err);
                          error_response ~status:`Internal_server_error err
                      | Ok session ->
                          Log.info (fun m -> m "Create session succeeded id=%s" session.id);
                          async_json_response (`Assoc [("session", session_json session)]))
              end
        end)

let handle_sse (server : t) session_id reqd =
  match find_session server session_id with
  | None ->
      Log.warn (fun m -> m "SSE requested for unknown session %s" session_id);
      respond_api_text ~status:`Not_found reqd "Session not found"
  | Some _session ->
      Log.info (fun m -> m "Opening SSE stream for %s" session_id);
      let request = Http_server.Reqd.request reqd in
      let last_event_id = request_header request "last-event-id" in
      let stream =
        Http_server.respond_stream reqd ~headers:[
          ("content-type", "text/event-stream");
          ("cache-control", "no-cache, no-transform");
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
            Log.warn (fun m -> m "Failed SSE subscribe for %s: %s" session_id err);
            Log.warn (fun m -> m "Failed to subscribe SSE client: %s" err)
        | Ok (subscriber_id, replay) ->
            Log.info (fun m ->
              m "SSE subscribed for %s subscriber=%s replay=%d"
                session_id
                subscriber_id
                (List.length replay));
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

let serve_ui_asset reqd asset_name =
  let asset_spec =
    match asset_name with
    | "htmx-sse.js" ->
        Some ("text/javascript; charset=utf-8", ui_asset_cache_control)
    | "app.css" ->
        Some ("text/css; charset=utf-8", ui_asset_cache_control)
    | "htmx-2.0.4.min.js" ->
        Some ("text/javascript; charset=utf-8", immutable_asset_cache_control)
    | _ -> None
  in
  match asset_spec with
  | Some (content_type, cache_control) ->
      serve_ui_file reqd ~file_name:asset_name ~content_type ~cache_control
  | _ ->
      Http_server.respond_text ~status:`Not_found reqd "Asset not found"

let handle_ui_route server path reqd =
  match split_segments path with
  | ["ui"] ->
      let html = Ui_view.render_home () |> Ui_view.to_string in
      Http_server.respond_text ~headers:[("content-type", "text/html; charset=utf-8")] reqd html
  | ["ui"; "session"; session_id] ->
      begin
        match find_session server session_id with
        | None ->
            Http_server.respond_text ~status:`Not_found reqd "Session not found"
        | Some session ->
            let summary = Agent_session.to_summary session in
            let html = Ui_view.render_session summary |> Ui_view.to_string in
            Http_server.respond_text ~headers:[("content-type", "text/html; charset=utf-8")] reqd html
      end
  | ["ui"; "assets"; asset_name] -> serve_ui_asset reqd asset_name
  | _ -> Http_server.respond_text ~status:`Not_found reqd "Not found"

let handle_session_route (server : t) meth path reqd =
  match split_segments path with
  | ["sessions"] when meth = `GET -> list_sessions_handler server reqd
  | ["sessions"; session_id] when meth = `GET ->
      begin
        match find_session server session_id with
        | None ->
            Log.warn (fun m -> m "GET unknown session %s" session_id);
            respond_api_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session -> respond_api_json reqd (`Assoc [("session", session_json session)])
      end
  | ["sessions"; session_id] when meth = `DELETE ->
      begin
        match find_session server session_id with
        | None ->
            Log.warn (fun m -> m "DELETE unknown session %s" session_id);
            respond_api_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            Log.info (fun m -> m "Deleting session %s" session_id);
            cleanup_session session;
            Session_store.remove_session server.sessions session_id;
            respond_api_json reqd (`Assoc [("deleted", `Bool true)])
      end
  | ["sessions"; session_id; "events"] when meth = `GET -> handle_sse server session_id reqd
  | ["sessions"; session_id; "prompts"] when meth = `POST ->
      begin
        match find_session server session_id with
        | None ->
            Log.warn (fun m -> m "POST /prompts unknown session %s" session_id);
            respond_api_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            read_any_body reqd (fun json ->
              match Models.parse_prompt_request json with
              | Error err ->
                  Log.warn (fun m -> m "Invalid prompt request for %s: %s" session_id err);
                  respond_api_json ~status:`Bad_request reqd (Json_utils.error_json err)
              | Ok prompt ->
                  begin
                    match Http_server.submit_detached_job server.http_server (fun () ->
                      ignore (prompt_session server session prompt)
                    ) with
                    | Error err ->
                        respond_api_json ~status:`Service_unavailable reqd (Json_utils.error_json err)
                    | Ok () ->
                        respond_api_json reqd (`Assoc [("accepted", `Bool true)])
                  end)
      end
  | ["sessions"; session_id; "tool-decisions"] when meth = `POST ->
      begin
        match find_session server session_id with
        | None ->
            Log.warn (fun m -> m "POST /tool-decisions unknown session %s" session_id);
            respond_api_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            read_any_body reqd (fun json ->
              match Models.parse_tool_decision_request json with
              | Error err ->
                  Log.warn (fun m -> m "Invalid tool decision request for %s: %s" session_id err);
                  respond_api_json ~status:`Bad_request reqd (Json_utils.error_json err)
              | Ok request ->
                  begin
                    ignore (Session_store.append_event server.sessions session_id ~type_:"acp.call"
                      ~payload:(`Assoc [
                        ("requestId",
                          match request.request_id with
                          | Some request_id -> request_id
                          | None -> `Null);
                        ("callId",
                          match request.call_id with
                          | Some call_id -> `String call_id
                          | None -> `Null);
                        ("optionId",
                          match option_id_of_request request with
                          | Some option_id -> `String option_id
                          | None -> `Null);
                        ("decision",
                          match request.decision with
                          | Some decision -> `String decision
                          | None -> `Null);
                        ("outcome",
                          match option_id_of_request request with
                          | Some _ -> `String "selected"
                          | None -> `Null);
                        ("note", match request.note with Some note -> `String note | None -> `Null);
                      ]));
                    match tool_decision session request with
                    | Ok () -> respond_api_json reqd (`Assoc [("accepted", `Bool true)])
                    | Error err -> respond_api_json ~status:`Internal_server_error reqd (Json_utils.error_json err)
                  end)
      end
  | ["sessions"; session_id; "cancel"] when meth = `POST ->
      begin
        match find_session server session_id with
        | None ->
            Log.warn (fun m -> m "POST /cancel unknown session %s" session_id);
            respond_api_json ~status:`Not_found reqd (Json_utils.error_json "Unknown session")
        | Some session ->
            Http_server.submit_job server.http_server reqd (fun () ->
              match cancel_session server session with
              | Error err -> error_response ~status:`Internal_server_error err
              | Ok result -> async_json_response (`Assoc [("result", result)]))
      end
  | _ -> respond_api_text ~status:`Not_found reqd "Not found"

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
  Http_server.add_route http_server ~method_:(Some `GET) "/ui"
    (fun reqd -> handle_ui_route server "/ui" reqd);
  Http_server.add_route http_server ~method_:(Some `GET) ~match_type:Http_server.Prefix "/ui/"
    (fun reqd ->
      let request = Http_server.Reqd.request reqd in
      let path, _query = Http_server.split_path_query request.target in
      handle_ui_route server path reqd);
  Http_server.add_route http_server ~method_:(Some `GET) "/healthz" health_handler;
  Http_server.add_route http_server ~method_:(Some `GET) "/server-info" (server_info_handler server);
  Http_server.add_route http_server ~method_:(Some `POST) "/sessions" (create_session_handler server);
  server

let start (server : t) =
  if server.config.bonjour_enabled then
    server.bonjour_publisher <- Bonjour_publisher.start {
      Bonjour_publisher.instance_name = server.config.service_name;
      hostname = server.config.service_hostname;
      port = server.config.port;
      version = Build_info.version;
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
