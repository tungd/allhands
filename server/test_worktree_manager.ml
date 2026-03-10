let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let run_or_fail command =
  if Sys.command command <> 0 then failwith ("command failed: " ^ command)

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let () =
  let repo = temp_dir "allhands_repo_" in
  run_or_fail (Printf.sprintf "git -C %s init >/dev/null 2>&1" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s config user.email test@example.com" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s config user.name Tester" (Filename.quote repo));
  write_file (Filename.concat repo "README.md") "hello";
  run_or_fail (Printf.sprintf "git -C %s add README.md" (Filename.quote repo));
  run_or_fail (Printf.sprintf "git -C %s commit -m init >/dev/null 2>&1" (Filename.quote repo));
  match Worktree_manager.create_worktree ~repo_path:repo ~session_id:"session_worktree" with
  | Error err -> failwith err
  | Ok worktree ->
      if not (Sys.file_exists worktree) then failwith "expected worktree to exist";
      Worktree_manager.remove_worktree ~repo_path:repo ~worktree_path:worktree
