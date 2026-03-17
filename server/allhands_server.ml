module Log = (val Logs.src_log (Logs.Src.create "allhands_server") : Logs.LOG)

let run ~host ~port ~service_name ~service_hostname ~bonjour_enabled =
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  let launch_root_path = Sys.getcwd () in
  let available_launchers = Launcher_catalog.detect_available () in
  let server = Host_server.create {
    Host_server.host = host;
    port;
    service_name;
    service_hostname;
    bonjour_enabled;
    launch_root_path;
    available_launchers;
  } in
  Host_server.start server;
  Log.info (fun m -> m "All Hands server listening on http://%s:%d" host port);
  Log.info (fun m -> m "Launch root: %s" launch_root_path);
  Log.info (fun m -> m "Available ACP launchers: %s"
    (match available_launchers with
     | [] -> "none"
     | launchers ->
         String.concat ", "
           (List.map (fun launcher -> launcher.Launcher_catalog.id) launchers)));
  Log.info (fun m -> m "Bonjour advertised hostname: http://%s:%d" service_hostname port);
  let rec loop () =
    Unix.sleepf 3600.0;
    loop ()
  in
  try loop ()
  with exn ->
    Host_server.stop server;
    raise exn

let () =
  let default_hostname = Unix.gethostname () in
  let default_service_name =
    match String.split_on_char '.' default_hostname with
    | "" :: _ | [] -> default_hostname
    | head :: _ -> head
  in
  let host = ref "0.0.0.0" in
  let port = ref 21991 in
  let service_name = ref default_service_name in
  let service_hostname = ref default_hostname in
  let bonjour_enabled = ref true in
  let specs = [
    ("--host", Arg.Set_string host, "Host to bind");
    ("--port", Arg.Set_int port, "Port to bind");
    ("--service-name", Arg.Set_string service_name, "Bonjour service instance name");
    ("--service-hostname", Arg.Set_string service_hostname, "Bonjour advertised hostname");
    ("--no-bonjour", Arg.Clear bonjour_enabled, "Disable Bonjour service advertisement");
  ] in
  Arg.parse specs (fun _ -> ()) "allhands_server";
  run
    ~host:!host
    ~port:!port
    ~service_name:!service_name
    ~service_hostname:!service_hostname
    ~bonjour_enabled:!bonjour_enabled
