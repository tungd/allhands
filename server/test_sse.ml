open Yojson.Safe.Util

module Log = (val Logs.src_log (Logs.Src.create "test_sse") : Logs.LOG)

let assert_true label value =
  if not value then failwith label

let assert_int_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %d but got %d" label expected actual)

let assert_string_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %s but got %s" label expected actual)

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

let read_all_lines ic =
  let rec loop acc =
    match input_line ic with
    | line -> loop (line :: acc)
    | exception End_of_file -> String.concat "\n" (List.rev acc)
  in
  loop []

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

let make_session id =
  Agent_session.create
    ~id
    ~repo_path:"/tmp/repo"
    ~worktree_path:"/tmp/worktree"
    ~agent_command:"/bin/echo"
    ~agent_args:[]

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "server"
  | None -> Sys.getcwd ()

let sse_client_script () =
  Filename.concat (source_root ()) "test_support/sse_client.py"

let sse_url port session_id =
  Printf.sprintf "http://127.0.0.1:%d/sessions/%s/events" port session_id

let run_sse_client ?ready_file ?last_event_id ?(timeout_s=5.0) ?(start_read_delay_ms=0)
    port session_id expected_count =
  let args = ref [
    "python3";
    sse_client_script ();
    "--url"; sse_url port session_id;
    "--expect"; string_of_int expected_count;
    "--timeout"; string_of_float timeout_s;
  ] in
  begin
    match ready_file with
    | Some path -> args := !args @ ["--ready-file"; path]
    | None -> ()
  end;
  begin
    match last_event_id with
    | Some event_id -> args := !args @ ["--last-event-id"; event_id]
    | None -> ()
  end;
  if start_read_delay_ms > 0 then
    args := !args @ ["--start-read-delay-ms"; string_of_int start_read_delay_ms];
  let ic = Unix.open_process_args_in "python3" (Array.of_list !args) in
  let output = read_all_lines ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> Yojson.Safe.from_string output
  | Unix.WEXITED code ->
      failwith (Printf.sprintf "sse_client.py exited with status %d" code)
  | Unix.WSIGNALED signal ->
      failwith (Printf.sprintf "sse_client.py was signaled: %d" signal)
  | Unix.WSTOPPED signal ->
      failwith (Printf.sprintf "sse_client.py was stopped: %d" signal)

let spawn_sse_client ?last_event_id ?(timeout_s=5.0) ?(start_read_delay_ms=0)
    port session_id expected_count =
  let ready_file = Filename.temp_file "allhands_sse_ready_" ".flag" in
  Sys.remove ready_file;
  let worker =
    Domain.spawn (fun () ->
      run_sse_client
        ~ready_file
        ?last_event_id
        ~timeout_s
        ~start_read_delay_ms
        port
        session_id
        expected_count)
  in
  wait_until
    ~timeout_s
    (Printf.sprintf "SSE client readiness for %s" session_id)
    (fun () -> Sys.file_exists ready_file);
  (ready_file, worker)

let join_sse_client ready_file worker =
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists ready_file then Sys.remove ready_file)
    (fun () -> Domain.join worker)

let with_server_session name f =
  let port = find_free_port () in
  let server = Host_server.create {
    Host_server.host = "127.0.0.1";
    port;
    service_name = "All Hands Test";
    service_hostname = "allhands-test";
    bonjour_enabled = false;
    launch_root_path = Sys.getcwd ();
    available_launchers = [];
  } in
  let session = make_session ("session_" ^ name) in
  Host_server.start server;
  wait_until "HTTP server startup" (fun () -> Http_server.is_running server.Host_server.http_server);
  Session_store.add_session server.Host_server.sessions session;
  Fun.protect
    ~finally:(fun () -> Host_server.stop server)
    (fun () -> f server session port)

let client_error json =
  json |> member "error" |> to_string_option

let client_status json =
  json |> member "status" |> to_int

let client_header json name =
  json
  |> member "headers"
  |> to_assoc
  |> List.find_map (fun (key, value) ->
       if String.equal key (String.lowercase_ascii name) then Some (to_string value) else None)

let client_events json =
  json |> member "events" |> to_list

let event_payload_json event =
  event |> member "data" |> to_string |> Yojson.Safe.from_string

let event_seq event =
  event_payload_json event |> member "seq" |> to_int

let event_id event =
  event |> member "id" |> to_string

let event_name event =
  event |> member "event" |> to_string

let assert_client_ok label json =
  begin
    match client_error json with
    | Some err -> failwith (Printf.sprintf "%s: unexpected SSE client error: %s" label err)
    | None -> ()
  end;
  assert_int_equal (label ^ ": status") 200 (client_status json);
  let content_type = Option.value ~default:"" (client_header json "content-type") in
  assert_true (label ^ ": content-type should be text/event-stream")
    (String.starts_with ~prefix:"text/event-stream" content_type);
  let cache_control = Option.value ~default:"" (client_header json "cache-control") in
  assert_true (label ^ ": cache-control should include no-cache")
    (string_contains cache_control "no-cache");
  assert_true (label ^ ": cache-control should include no-transform")
    (string_contains cache_control "no-transform")

let assert_event_sequences label ~start_seq ~count events =
  let actual = List.map event_seq events in
  let expected = List.init count (fun idx -> start_seq + idx) in
  if actual <> expected then
    failwith
      (Printf.sprintf "%s: expected seqs %s but got %s"
         label
         (String.concat "," (List.map string_of_int expected))
         (String.concat "," (List.map string_of_int actual)))

let publish_numbered_event store session_id index =
  ignore
    (Session_store.append_event store session_id
       ~type_:(Printf.sprintf "test.event%d" index)
       ~payload:(`Assoc [("value", `Int index)]))

let publish_large_event store session_id index payload_size =
  ignore
    (Session_store.append_event store session_id
       ~type_:(Printf.sprintf "test.replay%d" index)
       ~payload:(`Assoc [
         ("value", `Int index);
         ("blob", `String (String.make payload_size 'x'));
       ]))

let test_basic_sse_stream () =
  Log.info (fun m -> m "Test 1: Basic SSE stream over HTTP");
  with_server_session "basic" (fun server session port ->
    let ready_file, worker = spawn_sse_client port session.id 3 in
    for index = 1 to 3 do
      publish_numbered_event server.Host_server.sessions session.id index
    done;
    let result = join_sse_client ready_file worker in
    let events = client_events result in
    assert_client_ok "basic stream" result;
    assert_int_equal "basic stream: event count" 3 (List.length events);
    assert_event_sequences "basic stream" ~start_seq:1 ~count:3 events;
    List.iteri (fun idx event ->
      let seq = idx + 1 in
      assert_string_equal
        (Printf.sprintf "basic stream: event %d id" seq)
        (Printf.sprintf "%s:%d" session.id seq)
        (event_id event);
      assert_string_equal
        (Printf.sprintf "basic stream: event %d type" seq)
        (Printf.sprintf "test.event%d" seq)
        (event_name event))
      events)

let test_replay_with_last_event_id () =
  Log.info (fun m -> m "Test 2: Replay with Last-Event-ID");
  with_server_session "replay" (fun server session port ->
    for index = 1 to 3 do
      publish_numbered_event server.Host_server.sessions session.id index
    done;
    let result =
      run_sse_client
        ~last_event_id:(Printf.sprintf "%s:1" session.id)
        port
        session.id
        2
    in
    let events = client_events result in
    assert_client_ok "replay" result;
    assert_int_equal "replay: event count" 2 (List.length events);
    assert_event_sequences "replay" ~start_seq:2 ~count:2 events)

let test_concurrent_http_subscribers () =
  Log.info (fun m -> m "Test 3: Multiple concurrent HTTP SSE subscribers");
  with_server_session "multi_clients" (fun server session port ->
    let clients =
      Array.init 3 (fun _ -> spawn_sse_client ~timeout_s:8.0 port session.id 5)
    in
    for index = 1 to 5 do
      publish_numbered_event server.Host_server.sessions session.id index
    done;
    Array.iteri (fun idx (ready_file, worker) ->
      let result = join_sse_client ready_file worker in
      let events = client_events result in
      assert_client_ok (Printf.sprintf "subscriber %d" idx) result;
      assert_int_equal (Printf.sprintf "subscriber %d: event count" idx) 5 (List.length events);
      assert_event_sequences (Printf.sprintf "subscriber %d" idx) ~start_seq:1 ~count:5 events)
      clients)

let test_concurrent_publishers () =
  Log.info (fun m -> m "Test 4: Concurrent publishers preserve ordered SSE delivery");
  with_server_session "concurrent_publishers" (fun server session port ->
    let clients =
      Array.init 2 (fun _ -> spawn_sse_client ~timeout_s:12.0 port session.id 30)
    in
    let publishers =
      Array.init 3 (fun publisher_idx ->
        Domain.spawn (fun () ->
          let start_index = (publisher_idx * 10) + 1 in
          for offset = 0 to 9 do
            publish_numbered_event server.Host_server.sessions session.id (start_index + offset);
            Unix.sleepf 0.002
          done))
    in
    Array.iter Domain.join publishers;
    Array.iteri (fun idx (ready_file, worker) ->
      let result = join_sse_client ready_file worker in
      let events = client_events result in
      assert_client_ok (Printf.sprintf "concurrent publisher subscriber %d" idx) result;
      assert_int_equal
        (Printf.sprintf "concurrent publisher subscriber %d: event count" idx)
        30
        (List.length events);
      assert_event_sequences
        (Printf.sprintf "concurrent publisher subscriber %d" idx)
        ~start_seq:1
        ~count:30
        events)
      clients)

let test_replay_live_boundary () =
  Log.info (fun m -> m "Test 5: Replay/live handoff does not drop events");
  with_server_session "replay_boundary" (fun server session port ->
    let backlog_count = 1000 in
    let live_count = 20 in
    for index = 1 to backlog_count do
      publish_large_event server.Host_server.sessions session.id index 4096
    done;
    let ready_file, worker =
      spawn_sse_client
        ~timeout_s:20.0
        ~start_read_delay_ms:150
        port
        session.id
        (backlog_count + live_count)
    in
    for index = backlog_count + 1 to backlog_count + live_count do
      publish_numbered_event server.Host_server.sessions session.id index
    done;
    let result = join_sse_client ready_file worker in
    let events = client_events result in
    assert_client_ok "replay/live boundary" result;
    assert_int_equal
      "replay/live boundary: event count"
      (backlog_count + live_count)
      (List.length events);
    assert_event_sequences
      "replay/live boundary"
      ~start_seq:1
      ~count:(backlog_count + live_count)
      events)

let test_disconnect_cleanup () =
  Log.info (fun m -> m "Test 6: Disconnecting one SSE client does not break others");
  with_server_session "disconnect" (fun server session port ->
    let ready_file_one, worker_one = spawn_sse_client ~timeout_s:8.0 port session.id 1 in
    let ready_file_two, worker_two = spawn_sse_client ~timeout_s:8.0 port session.id 3 in
    publish_numbered_event server.Host_server.sessions session.id 1;
    let result_one = join_sse_client ready_file_one worker_one in
    let events_one = client_events result_one in
    assert_client_ok "disconnect first client" result_one;
    assert_int_equal "disconnect first client: event count" 1 (List.length events_one);
    assert_event_sequences "disconnect first client" ~start_seq:1 ~count:1 events_one;
    publish_numbered_event server.Host_server.sessions session.id 2;
    publish_numbered_event server.Host_server.sessions session.id 3;
    let result_two = join_sse_client ready_file_two worker_two in
    let events_two = client_events result_two in
    assert_client_ok "disconnect remaining client" result_two;
    assert_int_equal "disconnect remaining client: event count" 3 (List.length events_two);
    assert_event_sequences "disconnect remaining client" ~start_seq:1 ~count:3 events_two)

let () =
  Log.info (fun m -> m "Starting SSE concurrency tests");
  test_basic_sse_stream ();
  Log.info (fun m -> m "Test 1 passed");
  test_replay_with_last_event_id ();
  Log.info (fun m -> m "Test 2 passed");
  test_concurrent_http_subscribers ();
  Log.info (fun m -> m "Test 3 passed");
  test_concurrent_publishers ();
  Log.info (fun m -> m "Test 4 passed");
  test_replay_live_boundary ();
  Log.info (fun m -> m "Test 5 passed");
  test_disconnect_cleanup ();
  Log.info (fun m -> m "Test 6 passed");
  Log.info (fun m -> m "All SSE concurrency tests passed!")
