open Yojson.Safe.Util

let assert_int_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %d but got %d" label expected actual)

let assert_string_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %S but got %S" label expected actual)

let assert_true label value =
  if not value then failwith label

let string_contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > haystack_length then false
    else if String.sub haystack index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let ensure_dir path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let run_or_fail command =
  if Sys.command command <> 0 then failwith ("command failed: " ^ command)

let create_repo ?(with_subdir=false) () =
  let repo = temp_dir "allhands_host_repo_" in
  run_or_fail (Printf.sprintf "git -C %s init >/dev/null 2>&1" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s config user.email test@example.com" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s config user.name Tester" (Filename.quote repo));
  write_file (Filename.concat repo "README.md") "hello";
  if with_subdir then begin
    let nested = Filename.concat repo "nested" in
    ensure_dir nested;
    write_file (Filename.concat nested "note.txt") "child";
  end;
  run_or_fail (Printf.sprintf "git -C %s add . >/dev/null 2>&1" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s commit -m init >/dev/null 2>&1" (Filename.quote repo));
  repo

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "server"
  | None -> Sys.getcwd ()

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | _ -> failwith "failed to allocate TCP port")

let wait_until ?(timeout_s=5.0) ?(sleep_s=0.02) label predicate =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if predicate () then ()
    else if Unix.gettimeofday () >= deadline then
      failwith (Printf.sprintf "Timed out waiting for %s" label)
    else begin
      Unix.sleepf sleep_s;
      loop ()
    end
  in
  loop ()

let http_json ?body ~method_ url =
  let body_expr =
    match body with
    | Some json -> Printf.sprintf "body = %S.encode('utf-8')" json
    | None -> "body = None"
  in
  let script =
    String.concat "\n" [
      "import json, time, urllib.request, urllib.error";
      body_expr;
      Printf.sprintf "req = urllib.request.Request(%S, data=body, method=%S)" url method_;
      "if body is not None:";
      "    req.add_header('Content-Type', 'application/json')";
      "for attempt in range(10):";
      "    try:";
      "        with urllib.request.urlopen(req) as resp:";
      "            raw = resp.read().decode('utf-8')";
      "            print(json.dumps({'status': resp.status, 'body': json.loads(raw) if raw else None}))";
      "            break";
      "    except urllib.error.HTTPError as err:";
      "        raw = err.read().decode('utf-8')";
      "        print(json.dumps({'status': err.code, 'body': json.loads(raw) if raw else None}))";
      "        break";
      "    except Exception as err:";
      "        if attempt == 9:";
      "            print(json.dumps({'status': -1, 'body': {'error': str(err)}}))";
      "        else:";
      "            time.sleep(0.1)";
    ]
  in
  let ic = Unix.open_process_args_in "python3" [| "python3"; "-c"; script |] in
  let response = input_line ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> Yojson.Safe.from_string response
  | _ -> failwith "python http client failed"

let http_raw ?body ?(headers=[]) ~method_ url =
  let body_expr =
    match body with
    | Some text -> Printf.sprintf "body = %S.encode('utf-8')" text
    | None -> "body = None"
  in
  let header_lines =
    headers
    |> List.map (fun (name, value) ->
         Printf.sprintf "req.add_header(%S, %S)" name value)
    |> String.concat "\n"
  in
  let script =
    String.concat "\n" [
      "import json, time, urllib.request, urllib.error";
      body_expr;
      Printf.sprintf "req = urllib.request.Request(%S, data=body, method=%S)" url method_;
      header_lines;
      "for attempt in range(10):";
      "    try:";
      "        with urllib.request.urlopen(req) as resp:";
      "            raw = resp.read().decode('utf-8')";
      "            print(json.dumps({'status': resp.status, 'headers': {k.lower(): v for (k, v) in resp.getheaders()}, 'body': raw}))";
      "            break";
      "    except urllib.error.HTTPError as err:";
      "        raw = err.read().decode('utf-8')";
      "        print(json.dumps({'status': err.code, 'headers': {k.lower(): v for (k, v) in err.headers.items()}, 'body': raw}))";
      "        break";
      "    except Exception as err:";
      "        if attempt == 9:";
      "            print(json.dumps({'status': -1, 'headers': {}, 'body': str(err)}))";
      "        else:";
      "            time.sleep(0.1)";
    ]
  in
  let ic = Unix.open_process_args_in "python3" [| "python3"; "-c"; script |] in
  let response = input_line ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> Yojson.Safe.from_string response
  | _ -> failwith "python http client failed"

let response_header response name =
  response
  |> member "headers"
  |> to_assoc
  |> List.find_map (fun (key, value) ->
       if String.equal key (String.lowercase_ascii name) then Some (to_string value) else None)

let with_server ~launch_root_path ~available_launchers f =
  let port = find_free_port () in
  let server = Host_server.create {
    Host_server.host = "127.0.0.1";
    port;
    service_name = "All Hands Test";
    service_hostname = "allhands-test";
    bonjour_enabled = false;
    launch_root_path;
    available_launchers;
    acp_request_timeout_s = 300.0;
    acp_prompt_timeout_s = 300.0;
  } in
  Host_server.start server;
  wait_until "HTTP server startup" (fun () -> Http_server.is_running server.Host_server.http_server);
  Fun.protect
    ~finally:(fun () -> Host_server.stop server)
    (fun () -> f server port)

let test_server_info_and_session_launch () =
  let repo = create_repo ~with_subdir:true () in
  let fake_agent = Filename.concat (source_root ()) "test_support/fake_acp_agent.py" in
  let launcher = {
    Launcher_catalog.id = "codex";
    display_name = "Codex";
    command = "/usr/bin/env";
    args = ["python3"; fake_agent];
  } in
  with_server ~launch_root_path:repo ~available_launchers:[launcher] (fun server port ->
    let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
    let info = http_json ~method_:"GET" (base_url ^ "/server-info") in
    assert_int_equal "server-info status" 200 (info |> member "status" |> to_int);
    let info_body = info |> member "body" in
    assert_string_equal "server version" "dev" (info_body |> member "version" |> to_string);
    assert_string_equal "launch root" repo (info_body |> member "launchRootPath" |> to_string);
    assert_string_equal "default agent" "codex" (info_body |> member "defaultAgent" |> to_string);
    assert_int_equal "available agent count" 1 (info_body |> member "availableAgents" |> to_list |> List.length);
    let root_session =
      match Host_server.create_session_with_launcher server ~repo_path:repo launcher with
      | Ok session -> session
      | Error err -> failwith err
    in
    assert_string_equal "root session repo"
      repo
      root_session.Agent_session.repo_path;
    let nested_repo = Filename.concat repo "nested" in
    let nested_session =
      match Host_server.create_session_with_launcher server ~repo_path:nested_repo launcher with
      | Ok session -> session
      | Error err -> failwith err
    in
    assert_string_equal "nested session repo"
      nested_repo
      nested_session.Agent_session.repo_path)

let test_prompt_endpoint_accepts_immediately () =
  let repo = create_repo () in
  let fake_agent = Filename.concat (source_root ()) "test_support/fake_acp_agent.py" in
  let launcher = {
    Launcher_catalog.id = "codex";
    display_name = "Codex";
    command = "/usr/bin/env";
    args = ["FAKE_ACP_PROMPT_DELAY_S=1.0"; "python3"; fake_agent];
  } in
  with_server ~launch_root_path:repo ~available_launchers:[launcher] (fun server port ->
    let session =
      match Host_server.create_session_with_launcher server ~repo_path:repo launcher with
      | Ok session -> session
      | Error err -> failwith err
    in
    let before_events = Session_store.events_after server.Host_server.sessions session.id None in
    let last_event_id =
      before_events
      |> List.rev
      |> List.hd
      |> fun event -> Some event.Models.id
    in
    let prompt_url = Printf.sprintf "http://127.0.0.1:%d/sessions/%s/prompts" port session.id in
    let started_at = Unix.gettimeofday () in
    let response =
      http_json ~method_:"POST"
        ~body:(Yojson.Safe.to_string (`Assoc [("text", `String "hello world")]))
        prompt_url
    in
    let elapsed = Unix.gettimeofday () -. started_at in
    assert_int_equal "prompt accept status" 200 (response |> member "status" |> to_int);
    assert_true "prompt accepted" (response |> member "body" |> member "accepted" |> to_bool);
    assert_true "prompt response should be immediate" (elapsed < 0.5);
    wait_until ~timeout_s:3.0 "prompt completion" (fun () ->
      match Session_store.find_session server.Host_server.sessions session.id with
      | None -> false
      | Some current -> String.equal current.Agent_session.status "ready");
    let prompt_events = Session_store.events_after server.Host_server.sessions session.id last_event_id in
    assert_true "expected busy status event after prompt"
      (List.exists (fun event ->
         event.Models.type_ = "acp.status"
         && (event.Models.payload |> member "state" |> to_string_option = Some "busy"))
         prompt_events);
    assert_true "expected thought event after prompt"
      (List.exists (fun event -> event.Models.type_ = "acp.thought") prompt_events);
    assert_true "expected ready status event after prompt"
      (List.exists (fun event ->
         event.Models.type_ = "acp.status"
         && (event.Models.payload |> member "state" |> to_string_option = Some "ready"))
         prompt_events))

let test_ui_routes_and_cache_headers () =
  let repo = create_repo () in
  let fake_agent = Filename.concat (source_root ()) "test_support/fake_acp_agent.py" in
  let launcher = {
    Launcher_catalog.id = "codex";
    display_name = "Codex";
    command = "/usr/bin/env";
    args = ["python3"; fake_agent];
  } in
  with_server ~launch_root_path:repo ~available_launchers:[launcher] (fun server port ->
    let session =
      match Host_server.create_session_with_launcher server ~repo_path:repo launcher with
      | Ok session -> session
      | Error err -> failwith err
    in
    let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
    let session_shell = http_raw ~method_:"GET" (base_url ^ "/ui/session/" ^ session.id) in
    assert_int_equal "ui shell status" 200 (session_shell |> member "status" |> to_int);
    let shell_cache = Option.value ~default:"" (response_header session_shell "cache-control") in
    assert_string_equal "ui shell cache-control" "no-cache, must-revalidate" shell_cache;
    let shell_etag = Option.value ~default:"" (response_header session_shell "etag") in
    assert_true "ui shell etag present" (shell_etag <> "");
    assert_true "ui shell body looks like html"
      (string_contains
         (String.lowercase_ascii (session_shell |> member "body" |> to_string))
         "<!doctype html>");

    let session_shell_cached =
      http_raw
        ~method_:"GET"
        ~headers:[("If-None-Match", shell_etag)]
        (base_url ^ "/ui/session/" ^ session.id)
    in
    assert_int_equal "ui shell 304" 304 (session_shell_cached |> member "status" |> to_int);

    let app_js = http_raw ~method_:"GET" (base_url ^ "/ui/assets/app.js") in
    assert_int_equal "app.js status" 200 (app_js |> member "status" |> to_int);
    assert_string_equal "app.js cache-control"
      "no-cache, must-revalidate"
      (Option.value ~default:"" (response_header app_js "cache-control"));
    let app_js_etag = Option.value ~default:"" (response_header app_js "etag") in
    assert_true "app.js etag present" (app_js_etag <> "");
    let app_js_cached =
      http_raw
        ~method_:"GET"
        ~headers:[("If-None-Match", app_js_etag)]
        (base_url ^ "/ui/assets/app.js")
    in
    assert_int_equal "app.js 304" 304 (app_js_cached |> member "status" |> to_int);

    let mithril = http_raw ~method_:"GET" (base_url ^ "/ui/assets/mithril-2.3.8.min.js") in
    assert_int_equal "mithril asset status" 200 (mithril |> member "status" |> to_int);
    assert_string_equal "mithril cache-control"
      "public, max-age=31536000, immutable"
      (Option.value ~default:"" (response_header mithril "cache-control"));

    let info = http_raw ~method_:"GET" (base_url ^ "/server-info") in
    assert_string_equal "server-info cache-control"
      "private, no-store"
      (Option.value ~default:"" (response_header info "cache-control"));

    let session_json = http_raw ~method_:"GET" (base_url ^ "/sessions/" ^ session.id) in
    assert_string_equal "session get cache-control"
      "private, no-store"
      (Option.value ~default:"" (response_header session_json "cache-control")))

let test_http_server_records_fatal_loop_error () =
  let port = find_free_port () in
  let server = Http_server.create ~host:"127.0.0.1" ~port () in
  ignore (Http_server.start server);
  wait_until "raw HTTP server startup" (fun () -> Http_server.is_running server);
  let listener =
    match server.Http_server.listener with
    | Some fd -> fd
    | None -> failwith "expected listener to be present after startup"
  in
  Unix.close listener;
  wait_until "raw HTTP server crash" (fun () -> not (Http_server.is_running server));
  let last_error =
    match Http_server.last_error server with
    | Some error -> error
    | None -> failwith "expected HTTP server crash reason to be recorded"
  in
  assert_true "http server crash reason should not be empty" (String.trim last_error <> "");
  Http_server.stop server

let () =
  test_server_info_and_session_launch ();
  test_prompt_endpoint_accepts_immediately ();
  test_ui_routes_and_cache_headers ();
  test_http_server_records_fatal_loop_error ()
