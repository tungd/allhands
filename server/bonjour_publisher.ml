module Log = (val Logs.src_log (Logs.Src.create "bonjour_publisher") : Logs.LOG)

type config = {
  instance_name : string;
  hostname : string;
  port : int;
  version : string;
}

type t = {
  pid : int;
}

let command = "/usr/bin/dns-sd"

let is_available () =
  Sys.file_exists command

let start (config : config) =
  if not (is_available ()) then begin
    Log.warn (fun m -> m "dns-sd not available; Bonjour advertisement disabled");
    None
  end else
    let txt_name = Printf.sprintf "name=%s" config.instance_name in
    let txt_hostname = Printf.sprintf "hostname=%s" config.hostname in
    let txt_version = Printf.sprintf "version=%s" config.version in
    let argv = [|
      command;
      "-R";
      config.instance_name;
      "_allhands._tcp";
      "local";
      string_of_int config.port;
      txt_name;
      txt_hostname;
      txt_version;
    |] in
    match Unix.fork () with
    | 0 ->
        Unix.execv command argv
    | pid ->
        Log.info (fun m -> m "Advertising Bonjour service %s on port %d" config.instance_name config.port);
        Some { pid }

let stop = function
  | None -> ()
  | Some publisher ->
      begin
        try Unix.kill publisher.pid Sys.sigterm with _ -> ()
      end;
      begin
        try ignore (Unix.waitpid [] publisher.pid) with _ -> ()
      end
