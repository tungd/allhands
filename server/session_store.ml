module Log = (val Logs.src_log (Logs.Src.create "session_store") : Logs.LOG)

type subscriber_id = string

type entry = {
  session : Agent_session.t;
  mutable events : Models.stream_event list;
  mutable next_seq : int;
  subscribers : (subscriber_id, Models.stream_event -> unit) Hashtbl.t;
}

type t = {
  sessions : (string, entry) Hashtbl.t;
  mutex : Mutex.t;
}

let create () =
  {
    sessions = Hashtbl.create 32;
    mutex = Mutex.create ();
  }

let with_lock store f =
  Mutex.lock store.mutex;
  try
    let value = f () in
    Mutex.unlock store.mutex;
    value
  with exn ->
    Mutex.unlock store.mutex;
    raise exn

let add_session store session =
  with_lock store (fun () ->
    Hashtbl.replace store.sessions session.Agent_session.id {
      session;
      events = [];
      next_seq = 1;
      subscribers = Hashtbl.create 8;
    })

let find_session store session_id =
  with_lock store (fun () ->
    Hashtbl.find_opt store.sessions session_id |> Option.map (fun entry -> entry.session))

let list_sessions store =
  with_lock store (fun () ->
    Hashtbl.fold (fun _ entry acc -> Agent_session.to_summary entry.session :: acc) store.sessions []
    |> List.sort (fun (a : Models.session_summary) (b : Models.session_summary) ->
         compare b.created_at a.created_at))

let all_sessions store =
  with_lock store (fun () ->
    Hashtbl.fold (fun _ entry acc -> entry.session :: acc) store.sessions [])

let remove_session store session_id =
  with_lock store (fun () -> Hashtbl.remove store.sessions session_id)

let parse_event_id event_id =
  match String.rindex_opt event_id ':' with
  | None -> int_of_string_opt event_id
  | Some idx ->
      let seq = String.sub event_id (idx + 1) (String.length event_id - idx - 1) in
      int_of_string_opt seq

let events_after store session_id last_event_id =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> []
    | Some entry ->
        let after_seq =
          match last_event_id with
          | None -> 0
          | Some value -> Option.value ~default:0 (parse_event_id value)
        in
        entry.events
        |> List.filter (fun event -> event.Models.seq > after_seq))

let append_event store session_id ~type_ ~payload =
  let subscribers, event =
    with_lock store (fun () ->
      match Hashtbl.find_opt store.sessions session_id with
      | None -> ([], None)
      | Some entry ->
          let seq = entry.next_seq in
          entry.next_seq <- seq + 1;
          let event = {
            Models.id = Printf.sprintf "%s:%d" session_id seq;
            session_id;
            seq;
            type_;
            timestamp = Unix.gettimeofday ();
            payload;
          } in
          entry.events <- entry.events @ [event];
          let subscribers =
            Hashtbl.fold (fun id callback acc -> (id, callback) :: acc) entry.subscribers []
          in
          (subscribers, Some event))
  in
  match event with
  | None -> None
  | Some event ->
      List.iter (fun (subscriber_id, callback) ->
        try callback event
        with exn ->
          Log.warn (fun m -> m "Subscriber %s failed: %s" subscriber_id (Printexc.to_string exn))
      ) subscribers;
      Some event

let subscribe store session_id callback =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> Error "Unknown session"
    | Some entry ->
        let id = Printf.sprintf "sub_%08x%08x" (Random.bits ()) (Random.bits ()) in
        Hashtbl.replace entry.subscribers id callback;
        Ok id)

let unsubscribe store session_id subscriber_id =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> ()
    | Some entry -> Hashtbl.remove entry.subscribers subscriber_id)

let update_status store session_id status =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> ()
    | Some entry -> entry.session.status <- status)
