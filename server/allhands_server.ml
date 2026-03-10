module Log = (val Logs.src_log (Logs.Src.create "allhands_server") : Logs.LOG)

let run ~host ~port =
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Info);
  let server = Host_server.create { Host_server.host = host; port } in
  Host_server.start server;
  Log.info (fun m -> m "All Hands server listening on http://%s:%d" host port);
  let rec loop () =
    Unix.sleepf 3600.0;
    loop ()
  in
  try loop ()
  with exn ->
    Host_server.stop server;
    raise exn

let () =
  let host = ref "127.0.0.1" in
  let port = ref 8080 in
  let specs = [
    ("--host", Arg.Set_string host, "Host to bind");
    ("--port", Arg.Set_int port, "Port to bind");
  ] in
  Arg.parse specs (fun _ -> ()) "allhands_server";
  run ~host:!host ~port:!port
