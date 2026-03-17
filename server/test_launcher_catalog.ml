let assert_true label value =
  if not value then failwith label

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

let test_detect_available_with () =
  let launchers =
    Launcher_catalog.detect_available_with (function
      | "codex" | "codex-acp" | "claude" -> true
      | _ -> false)
  in
  assert_true "codex should be detected"
    (List.exists (fun launcher -> launcher.Launcher_catalog.id = "codex") launchers);
  assert_true "claude should not be detected without adapter"
    (not (List.exists (fun launcher -> launcher.Launcher_catalog.id = "claude") launchers));
  assert_string_equal "default agent prefers codex"
    "codex"
    (Option.value ~default:"" (Launcher_catalog.default_agent_id launchers))

let test_parse_create_session_request () =
  let json = Yojson.Safe.from_string {|{"folderPath":"apps/api","agent":"codex"}|} in
  match Models.parse_create_session_request json with
  | Error err -> failwith err
  | Ok request ->
      assert_string_equal "folderPath" "apps/api" request.Models.folder_path;
      assert_string_equal "agent" "codex" request.agent

let test_resolve_folder () =
  let root = temp_dir "allhands_launch_root_" in
  let nested = Filename.concat root "nested" in
  let child = Filename.concat nested "child" in
  ensure_dir nested;
  ensure_dir child;
  let expect_ok label folder expected =
    match Launcher_catalog.resolve_folder ~launch_root_path:root ~folder_path:folder with
    | Error err -> failwith (Printf.sprintf "%s: unexpected error: %s" label err)
    | Ok path -> assert_string_equal label expected path
  in
  let expect_error label folder =
    match Launcher_catalog.resolve_folder ~launch_root_path:root ~folder_path:folder with
    | Ok path -> failwith (Printf.sprintf "%s: expected error but got %s" label path)
    | Error _ -> ()
  in
  expect_ok "dot path" "." root;
  expect_ok "direct child" "nested" nested;
  expect_ok "nested child" "nested/child" child;
  expect_error "empty path" "";
  expect_error "absolute path" root;
  expect_error "escaping path" "../outside";
  expect_error "normalized escape" "nested/../../outside"

let () =
  test_detect_available_with ();
  test_parse_create_session_request ();
  test_resolve_folder ()
