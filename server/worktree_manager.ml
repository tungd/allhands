module Log = (val Logs.src_log (Logs.Src.create "worktree_manager") : Logs.LOG)

let ensure_directory path =
  let rec build current =
    if current = "" || current = "." || current = "/" then ()
    else if Sys.file_exists current then ()
    else (
      build (Filename.dirname current);
      Unix.mkdir current 0o755)
  in
  build path

let run_command args =
  let command = String.concat " " (List.map Filename.quote args) in
  Sys.command command = 0

let is_git_repo path =
  Sys.command (Printf.sprintf "git -C %s rev-parse --is-inside-work-tree >/dev/null 2>&1" (Filename.quote path)) = 0

let worktree_root repo_path =
  Filename.concat (Filename.concat (Filename.dirname repo_path) ".allhands") "worktrees"

let create_worktree ~repo_path ~session_id =
  if not (Sys.file_exists repo_path && is_git_repo repo_path) then
    Error "repoPath must be an existing git work tree"
  else
    let root = worktree_root repo_path in
    ensure_directory root;
    let path = Filename.concat root session_id in
    if Sys.file_exists path then
      Error "worktree path already exists"
    else if run_command ["git"; "-C"; repo_path; "worktree"; "add"; "--detach"; path; "HEAD"] then (
      Log.info (fun m -> m "Created worktree %s for %s" path session_id);
      Ok path
    ) else
      Error "failed to create git worktree"

let remove_worktree ~repo_path ~worktree_path =
  if Sys.file_exists repo_path && is_git_repo repo_path then
    ignore (run_command ["git"; "-C"; repo_path; "worktree"; "remove"; "--force"; worktree_path]);
  if Sys.file_exists worktree_path then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote worktree_path)))
