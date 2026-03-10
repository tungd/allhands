module Log = (val Logs.src_log (Logs.Src.create "agent_process") : Logs.LOG)

type t = {
  command : string;
  args : string list;
  pid : int;
  stdin_channel : out_channel;
  stdout_channel : in_channel;
  stderr_channel : in_channel;
  write_mutex : Mutex.t;
  next_id : int Atomic.t;
  mutable closed : bool;
  closed_mutex : Mutex.t;
  mutable stdout_domain : unit Domain.t option;
  mutable stderr_domain : unit Domain.t option;
  on_stdout : Yojson.Safe.t -> unit;
  on_stderr : string -> unit;
  on_exit : Unix.process_status -> unit;
}

let mark_closed t =
  Mutex.lock t.closed_mutex;
  let already_closed = t.closed in
  if not already_closed then t.closed <- true;
  Mutex.unlock t.closed_mutex;
  already_closed

let notify_exit t =
  if not (mark_closed t) then
    let _, status = Unix.waitpid [] t.pid in
    t.on_exit status

let create_channels ~command ~args =
  let stdin_r, stdin_w = Unix.pipe () in
  let stdout_r, stdout_w = Unix.pipe () in
  let stderr_r, stderr_w = Unix.pipe () in
  try
    let argv = Array.of_list (command :: args) in
    let pid =
      Unix.create_process_env command argv (Unix.environment ()) stdin_r stdout_w stderr_w
    in
    Unix.close stdin_r;
    Unix.close stdout_w;
    Unix.close stderr_w;
    Ok (pid, stdin_w, stdout_r, stderr_r)
  with exn ->
    Unix.close stdin_r;
    Unix.close stdin_w;
    Unix.close stdout_r;
    Unix.close stdout_w;
    Unix.close stderr_r;
    Unix.close stderr_w;
    Error (Printexc.to_string exn)

let spawn ~command ~args ~on_stdout ~on_stderr ~on_exit =
  match create_channels ~command ~args with
  | Error err -> Error err
  | Ok (pid, stdin_w, stdout_r, stderr_r) ->
      let t = {
        command;
        args;
        pid;
        stdin_channel = Unix.out_channel_of_descr stdin_w;
        stdout_channel = Unix.in_channel_of_descr stdout_r;
        stderr_channel = Unix.in_channel_of_descr stderr_r;
        write_mutex = Mutex.create ();
        next_id = Atomic.make 1;
        closed = false;
        closed_mutex = Mutex.create ();
        stdout_domain = None;
        stderr_domain = None;
        on_stdout;
        on_stderr;
        on_exit;
      } in
      let stdout_domain =
        Domain.spawn (fun () ->
          try
            while true do
              let line = input_line t.stdout_channel in
              if String.trim line <> "" then
                try t.on_stdout (Yojson.Safe.from_string line)
                with exn -> t.on_stderr (Printf.sprintf "Invalid agent JSON: %s" (Printexc.to_string exn))
            done
          with
          | End_of_file ->
              notify_exit t
          | Sys_error _ ->
            notify_exit t)
      in
      let stderr_domain =
        Domain.spawn (fun () ->
          try
            while true do
              let line = input_line t.stderr_channel in
              if String.trim line <> "" then t.on_stderr line
            done
          with
          | End_of_file -> ()
          | Sys_error _ -> ())
      in
      t.stdout_domain <- Some stdout_domain;
      t.stderr_domain <- Some stderr_domain;
      Ok t

let next_request_id t =
  Atomic.fetch_and_add t.next_id 1

let send_json t json =
  let payload = Yojson.Safe.to_string json in
  Mutex.lock t.write_mutex;
  try
    output_string t.stdin_channel payload;
    output_char t.stdin_channel '\n';
    flush t.stdin_channel;
    Mutex.unlock t.write_mutex;
    Ok ()
  with exn ->
    Mutex.unlock t.write_mutex;
    Error (Printexc.to_string exn)

let terminate t =
  if not (mark_closed t) then (
    (try Unix.kill t.pid Sys.sigterm with _ -> ());
    (try close_out_noerr t.stdin_channel with _ -> ());
    let rec wait_for_exit deadline =
      if Unix.gettimeofday () >= deadline then (
        (try Unix.kill t.pid Sys.sigkill with _ -> ());
        Unix.waitpid [] t.pid
      ) else
        match Unix.waitpid [Unix.WNOHANG] t.pid with
        | 0, _ ->
            Unix.sleepf 0.05;
            wait_for_exit deadline
        | result -> result
    in
    let _, status =
      try wait_for_exit (Unix.gettimeofday () +. 2.0)
      with Unix.Unix_error _ -> (t.pid, Unix.WEXITED 0)
    in
    (try close_in_noerr t.stdout_channel with _ -> ());
    (try close_in_noerr t.stderr_channel with _ -> ());
    (match t.stdout_domain with Some d -> ignore (Domain.join d) | None -> ());
    (match t.stderr_domain with Some d -> ignore (Domain.join d) | None -> ());
    t.on_exit status;
    Log.info (fun m -> m "Terminated agent process %d" t.pid)
  )
