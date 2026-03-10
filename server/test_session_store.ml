let make_session id =
  Agent_session.create
    ~id
    ~repo_path:"/tmp/repo"
    ~worktree_path:"/tmp/worktree"
    ~agent_command:"/bin/echo"
    ~agent_args:[]

let () =
  let store = Session_store.create () in
  let session = make_session "session_test" in
  Session_store.add_session store session;
  ignore (Session_store.append_event store session.id ~type_:"acp.status" ~payload:(`Assoc [("state", `String "ready")]));
  ignore (Session_store.append_event store session.id ~type_:"acp.thought" ~payload:(`Assoc [("text", `String "hello")]));
  let replay = Session_store.events_after store session.id (Some "session_test:1") in
  match replay with
  | [event] when event.Models.seq = 2 -> ()
  | _ -> failwith "expected replay to return only the second event"
