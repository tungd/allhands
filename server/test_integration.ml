open Yojson.Safe.Util

let assert_true label value =
  if not value then failwith label

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let run_or_fail command =
  if Sys.command command <> 0 then failwith ("command failed: " ^ command)

let create_repo () =
  let repo = temp_dir "allhands_integration_repo_" in
  run_or_fail (Printf.sprintf "git -C %s init >/dev/null 2>&1" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s config user.email test@example.com" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s config user.name Tester" (Filename.quote repo));
  write_file (Filename.concat repo "README.md") "hello";
  run_or_fail (Printf.sprintf "git -C %s add README.md" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s commit -m init >/dev/null 2>&1" (Filename.quote repo));
  repo

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "server"
  | None -> Sys.getcwd ()

let unique_session_id () =
  Random.self_init ();
  Printf.sprintf "session_integration_%08x%08x" (Random.bits ()) (Random.bits ())

let () =
  let repo = create_repo () in
  let worktree =
    match Worktree_manager.create_worktree ~repo_path:repo ~session_id:(unique_session_id ()) with
    | Ok path -> path
    | Error err -> failwith err
  in
  let seen_events = ref [] in
  let on_message json =
    seen_events := Event_mapper.from_agent_message json :: !seen_events
  in
  let on_stderr line =
    seen_events := ("acp.status", `Assoc [("stderr", `String line)]) :: !seen_events
  in
  let on_exit _status = () in
  let agent_script = Filename.concat (source_root ()) "test_support/fake_acp_agent.py" in
  let rpc =
    match Agent_rpc.create
            ~command:"/usr/bin/env"
            ~args:["python3"; agent_script]
            ~on_message
            ~on_stderr
            ~on_exit with
    | Ok rpc -> rpc
    | Error err -> failwith err
  in
  let initialize =
    Agent_rpc.send_request rpc ~method_:"initialize"
      ~params:(`Assoc [("protocolVersion", `Int 1)])
  in
  begin
    match initialize with
    | Ok _ -> ()
    | Error err -> failwith err
  end;
  let session_result =
    Agent_rpc.send_request rpc ~method_:"session/new"
      ~params:(`Assoc [("cwd", `String worktree); ("mcpServers", `List [])])
  in
  let child_session =
    match session_result with
    | Ok result -> result |> member "sessionId" |> to_string
    | Error err -> failwith err
  in
  let prompt_result =
    Agent_rpc.send_request rpc ~method_:"session/prompt"
      ~params:(`Assoc [
        ("sessionId", `String child_session);
        ("prompt", Models.text_prompt_blocks "hello world");
      ])
  in
  begin
    match prompt_result with
    | Ok result ->
        assert_true "expected end_turn"
          (result |> member "stopReason" |> to_string = "end_turn")
    | Error err -> failwith err
  end;
  assert_true "expected at least one mapped thought event"
    (List.exists (fun (event_type, _payload) -> event_type = "acp.thought") !seen_events);
  Agent_rpc.terminate rpc;
  Worktree_manager.remove_worktree ~repo_path:repo ~worktree_path:worktree
