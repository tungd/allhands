module Log = (val Logs.src_log (Logs.Src.create "session_store") : Logs.LOG)

type subscriber_id = string

type subscriber = {
  callback : Models.stream_event -> unit;
  mutex : Mutex.t;
  pending : Models.stream_event Queue.t;
  mutable draining : bool;
  mutable active : bool;
}

type entry = {
  session : Agent_session.t;
  mutable events : Models.stream_event list;
  mutable next_seq : int;
  subscribers : (subscriber_id, subscriber) Hashtbl.t;
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

let after_seq_of_last_event_id last_event_id =
  match last_event_id with
  | None -> 0
  | Some value -> Option.value ~default:0 (parse_event_id value)

let events_after_seq entry after_seq =
  entry.events
  |> List.filter (fun event -> event.Models.seq > after_seq)

let events_after store session_id last_event_id =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> []
    | Some entry ->
        events_after_seq entry (after_seq_of_last_event_id last_event_id))

let create_subscriber callback =
  {
    callback;
    mutex = Mutex.create ();
    pending = Queue.create ();
    draining = false;
    active = true;
  }

let make_subscriber_id () =
  Printf.sprintf "sub_%08x%08x" (Random.bits ()) (Random.bits ())

let subscribe_entry entry callback =
  let id = make_subscriber_id () in
  Hashtbl.replace entry.subscribers id (create_subscriber callback);
  id

let enqueue_event (subscriber : subscriber) event =
  Mutex.lock subscriber.mutex;
  let should_drain =
    if not subscriber.active then
      false
    else begin
      Queue.add event subscriber.pending;
      if subscriber.draining then false
      else begin
        subscriber.draining <- true;
        true
      end
    end
  in
  Mutex.unlock subscriber.mutex;
  should_drain

let clear_pending_events (subscriber : subscriber) =
  while not (Queue.is_empty subscriber.pending) do
    ignore (Queue.take subscriber.pending)
  done

let drain_subscriber subscriber_id (subscriber : subscriber) =
  let rec loop () =
    Mutex.lock subscriber.mutex;
    let next_event =
      if (not subscriber.active) || Queue.is_empty subscriber.pending then begin
        subscriber.draining <- false;
        None
      end else
        Some (Queue.take subscriber.pending)
    in
    Mutex.unlock subscriber.mutex;
    match next_event with
    | None -> ()
    | Some event ->
        begin
          try subscriber.callback event
          with exn ->
            Log.warn (fun m -> m "Subscriber %s failed: %s" subscriber_id (Printexc.to_string exn))
        end;
        loop ()
  in
  loop ()

let append_event store session_id ~type_ ~payload =
  let drainers, event =
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
          let drainers =
            Hashtbl.fold
              (fun id subscriber acc ->
                if enqueue_event subscriber event then (id, subscriber) :: acc else acc)
              entry.subscribers
              []
          in
          (drainers, Some event))
  in
  match event with
  | None -> None
  | Some event ->
      List.iter (fun (subscriber_id, subscriber) ->
        drain_subscriber subscriber_id subscriber
      ) drainers;
      Some event

let subscribe store session_id callback =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> Error "Unknown session"
    | Some entry ->
        let id = subscribe_entry entry callback in
        Ok id)

let subscribe_with_replay store session_id last_event_id callback =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> Error "Unknown session"
    | Some entry ->
        let replay = events_after_seq entry (after_seq_of_last_event_id last_event_id) in
        let id = subscribe_entry entry callback in
        Ok (id, replay))

let unsubscribe store session_id subscriber_id =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> ()
    | Some entry ->
        begin
          match Hashtbl.find_opt entry.subscribers subscriber_id with
          | None -> ()
          | Some subscriber ->
              Mutex.lock subscriber.mutex;
              subscriber.active <- false;
              subscriber.draining <- false;
              clear_pending_events subscriber;
              Mutex.unlock subscriber.mutex
        end;
        Hashtbl.remove entry.subscribers subscriber_id)

let update_status store session_id status =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sessions session_id with
    | None -> ()
    | Some entry -> entry.session.status <- status)
