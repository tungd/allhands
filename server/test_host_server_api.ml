open Yojson.Safe.Util

let assert_int_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %d but got %d" label expected actual)

let assert_string_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %S but got %S" label expected actual)

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

let () =
  test_server_info_and_session_launch ()
