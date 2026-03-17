open Yojson.Safe.Util

module Log = (val Logs.src_log (Logs.Src.create "agent_rpc") : Logs.LOG)

type pending_response = {
  mutex : Mutex.t;
  condition : Condition.t;
  mutable response : Yojson.Safe.t option;
}

type t = {
  process : Agent_process.t;
  pending : (int, pending_response) Hashtbl.t;
  pending_mutex : Mutex.t;
}

let response_id json =
  match json |> member "id" with
  | `Int value -> Some value
  | `Intlit value -> Some (int_of_string value)
  | _ -> None

let handle_response t json =
  match response_id json with
  | None -> ()
  | Some id ->
      Mutex.lock t.pending_mutex;
      let pending = Hashtbl.find_opt t.pending id in
      (match pending with
       | Some response ->
           Hashtbl.remove t.pending id;
           Mutex.unlock t.pending_mutex;
           Mutex.lock response.mutex;
           response.response <- Some json;
           Condition.signal response.condition;
           Mutex.unlock response.mutex
       | None ->
           Mutex.unlock t.pending_mutex;
           Log.warn (fun m -> m "Dropping unmatched ACP response id=%d" id))

let create ~command ~args ~on_message ~on_stderr ~on_exit =
  let pending = Hashtbl.create 16 in
  let pending_mutex = Mutex.create () in
  let rpc_holder : t option ref = ref None in
  let on_stdout json =
    match !rpc_holder with
    | None -> ()
    | Some rpc ->
        if json |> member "id" <> `Null && ((json |> member "result") <> `Null || (json |> member "error") <> `Null) then
          handle_response rpc json
        else
          on_message json
  in
  match Agent_process.spawn ~command ~args ~on_stdout ~on_stderr ~on_exit with
  | Error err -> Error err
  | Ok process ->
      let rpc = { process; pending; pending_mutex } in
      rpc_holder := Some rpc;
      Ok rpc

let await_response pending ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    Mutex.lock pending.mutex;
    let result = pending.response in
    Mutex.unlock pending.mutex;
    match result with
    | Some response -> Ok response
    | None when Unix.gettimeofday () >= deadline -> Error "Timed out waiting for ACP response"
    | None ->
        Unix.sleepf 0.01;
        loop ()
  in
  loop ()

let send_request ?(timeout_s=300.0) t ~method_ ~params =
  let id = Agent_process.next_request_id t.process in
  let pending = {
    mutex = Mutex.create ();
    condition = Condition.create ();
    response = None;
  } in
  Mutex.lock t.pending_mutex;
  Hashtbl.replace t.pending id pending;
  Mutex.unlock t.pending_mutex;
  match Agent_process.send_json t.process (Json_utils.jsonrpc_request ~id ~method_ ~params) with
  | Error err ->
      Mutex.lock t.pending_mutex;
      Hashtbl.remove t.pending id;
      Mutex.unlock t.pending_mutex;
      Error err
  | Ok () ->
      begin
        match await_response pending ~timeout_s with
        | Error err -> Error err
        | Ok response ->
            match response |> member "error" with
            | `Null -> Ok (response |> member "result")
            | error ->
                let message =
                  error |> member "message" |> to_string_option |> Option.value ~default:"ACP error"
                in
                Error message
      end

let send_notification t ~method_ ~params =
  Agent_process.send_json t.process (Json_utils.jsonrpc_notification ~method_ ~params)

let send_response t ~id ~result =
  Agent_process.send_json t.process (Json_utils.jsonrpc_response ~id ~result)

let terminate t =
  Agent_process.terminate t.process
