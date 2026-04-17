type launcher = {
  id : string;
  display_name : string;
  command : string;
  args : string list;
}

let codex_launcher = {
  id = "codex";
  display_name = "Codex";
  command = "codex-acp";
  args = [];
}

let claude_launcher = {
  id = "claude";
  display_name = "Claude Code";
  command = "claude-agent-acp";
  args = [];
}

let gemini_launcher = {
  id = "gemini";
  display_name = "Gemini CLI";
  command = "gemini";
  args = ["--acp"];
}

let split_path path =
  String.split_on_char ':' path
  |> List.filter (fun segment -> segment <> "")

let is_executable_file path =
  try
    Unix.access path [Unix.X_OK];
    (Unix.stat path).Unix.st_kind <> Unix.S_DIR
  with _ -> false

let executable_exists_with ~path_env executable =
  if String.contains executable '/' then
    is_executable_file executable
  else
    split_path path_env
    |> List.exists (fun dir -> is_executable_file (Filename.concat dir executable))

let executable_exists executable =
  executable_exists_with
    ~path_env:(Option.value ~default:"" (Sys.getenv_opt "PATH"))
    executable

let detect_available_with probe =
  let launchers = ref [] in
  if probe "gemini" then
    launchers := gemini_launcher :: !launchers;
  if probe "codex" && probe "codex-acp" then
    launchers := codex_launcher :: !launchers;
  if probe "claude" && probe "claude-agent-acp" then
    launchers := claude_launcher :: !launchers;
  List.rev !launchers

let detect_available () =
  detect_available_with executable_exists

let default_agent_id launchers =
  if List.exists (fun launcher -> String.equal launcher.id codex_launcher.id) launchers then
    Some codex_launcher.id
  else if List.exists (fun launcher -> String.equal launcher.id claude_launcher.id) launchers then
    Some claude_launcher.id
  else if List.exists (fun launcher -> String.equal launcher.id gemini_launcher.id) launchers then
    Some gemini_launcher.id
  else
    None

let resolve launchers id =
  List.find_opt (fun launcher -> String.equal launcher.id id) launchers

let resolve_folder ~launch_root_path ~folder_path =
  let folder_path = String.trim folder_path in
  if folder_path = "" then
    Error "folderPath must not be empty"
  else if not (Filename.is_relative folder_path) then
    Error "folderPath must be a relative path under the launch root"
  else
    let parts = String.split_on_char '/' folder_path in
    let rec normalize acc = function
      | [] -> Ok acc
      | "" :: rest
      | "." :: rest -> normalize acc rest
      | ".." :: rest ->
          begin
            match acc with
            | [] -> Error "folderPath must stay within the launch root"
            | _ :: acc_rest -> normalize acc_rest rest
          end
      | part :: rest -> normalize (part :: acc) rest
    in
    match normalize [] parts with
    | Error err -> Error err
    | Ok normalized_parts ->
        let normalized_parts = List.rev normalized_parts in
        let resolved_path =
          match normalized_parts with
          | [] -> launch_root_path
          | head :: tail -> List.fold_left Filename.concat (Filename.concat launch_root_path head) tail
        in
        begin
          try
            let stats = Unix.stat resolved_path in
            if stats.Unix.st_kind = Unix.S_DIR then
              Ok resolved_path
            else
              Error "folderPath must resolve to a directory"
          with Unix.Unix_error (Unix.ENOENT, _, _) ->
            Error "folderPath must resolve to an existing directory"
        end
