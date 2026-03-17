type t = {
  id : string;
  repo_path : string;
  worktree_path : string;
  agent_command : string;
  agent_args : string list;
  created_at : float;
  mutable status : string;
  mutable child_session_id : string option;
  mutable rpc : Agent_rpc.t option;
  pending_permission_requests : (string, Yojson.Safe.t) Hashtbl.t;
}

let create ~id ~repo_path ~worktree_path ~agent_command ~agent_args =
  {
    id;
    repo_path;
    worktree_path;
    agent_command;
    agent_args;
    created_at = Unix.gettimeofday ();
    status = "starting";
    child_session_id = None;
    rpc = None;
    pending_permission_requests = Hashtbl.create 8;
  }

let to_summary session =
  {
    Models.id = session.id;
    status = session.status;
    repo_path = session.repo_path;
    worktree_path = session.worktree_path;
    created_at = session.created_at;
  }
