open Tyxml.Html

let status_class = function
  | "ready" -> "status-ready"
  | "busy" -> "status-busy"
  | "stopped" -> "status-stopped"
  | "error" -> "status-error"
  | _ -> "status-neutral"

let layout ?(title="All Hands") content =
  html
    (head (Tyxml.Html.title (txt title)) [
      meta ~a:[a_charset "utf-8"] ();
      meta ~a:[a_name "viewport"; a_content "width=device-width, initial-scale=1"] ();
      link ~rel:[`Stylesheet] ~href:"/ui/assets/app.css" ();
      script ~a:[a_src "/ui/assets/htmx-2.0.4.min.js"] (txt "");
      script ~a:[a_src "/ui/assets/htmx-sse.js"] (txt "");
    ])
    (body [
      div ~a:[a_class ["page-background"]] [];
      div ~a:[a_id "app"] content
    ])

let render_home () =
  layout [
    div ~a:[a_class ["ui-home"]] [
      div ~a:[a_class ["empty-state"]] [
        p ~a:[a_class ["eyebrow"]] [txt "All Hands Web UI"];
        h1 [txt "Open a session URL directly"];
        p [txt "Use /ui/session/<session-id> to attach to a running session."];
      ]
    ]
  ]

let render_event_card (event : Models.stream_event) =
  let time_label =
    let tm = Unix.gmtime event.timestamp in
    Printf.sprintf "%02d:%02d:%02d" tm.tm_hour tm.tm_min tm.tm_sec
  in
  let kind_class = "event-" ^ event.type_ in
  let title = match event.type_ with
    | "acp.thought" -> "Thought"
    | "acp.call" -> "Tool Call"
    | "acp.patch" -> "Patch"
    | "acp.status" -> "Status"
    | t -> t
  in
  article ~a:[a_class ["event-card"; kind_class; "event-system"]; a_user_data "seq" (string_of_int event.seq)] [
    div ~a:[a_class ["event-meta"]] [
      span ~a:[a_class ["event-kind"]] [txt title];
      span ~a:[a_class ["event-time"]] [txt time_label];
    ];
    (match event.type_ with
     | "acp.thought" ->
         let body = Yojson.Safe.Util.member "body" event.payload |> Yojson.Safe.Util.to_string_option in
         p ~a:[a_class ["event-body"; "event-body-thought"]] [txt (Option.value ~default:"" body)]
     | "acp.patch" ->
         let body = Yojson.Safe.Util.member "body" event.payload |> Yojson.Safe.Util.to_string_option in
         pre ~a:[a_class ["code-block"]] [txt (Option.value ~default:"" body)]
     | _ ->
         let body = Yojson.Safe.Util.member "body" event.payload |> Yojson.Safe.Util.to_string_option in
         p ~a:[a_class ["event-body"]] [txt (Option.value ~default:"" body)])
  ]

let render_session (session : Models.session_summary) =
  layout ~title:("Session: " ^ session.id) [
    div ~a:[a_class ["session-screen"]] [
      header ~a:[a_class ["session-header"]] [
        div ~a:[a_class ["header-main"]] [
          p ~a:[a_class ["eyebrow"]] [txt "All Hands Session"];
          h1 [txt session.id];
          div ~a:[a_class ["header-paths"]] [
            p ~a:[a_class ["path-line"]] [txt ("Repo: " ^ session.repo_path)];
            p ~a:[a_class ["path-line"]] [txt ("Worktree: " ^ session.worktree_path)];
          ]
        ];
        div ~a:[a_class ["header-status"]] [
          span ~a:[a_id "status-pill"; a_class ["status-pill"; status_class session.status]] [txt session.status];
          button ~a:[
            a_class ["button"; "button-secondary"];
            a_user_data "hx-post" ("/sessions/" ^ session.id ^ "/cancel");
            a_user_data "hx-swap" "none"
          ] [txt "Cancel"]
        ]
      ];
      main ~a:[
        a_class ["session-content"];
        a_user_data "hx-ext" "sse";
        a_user_data "sse-connect" ("/sessions/" ^ session.id ^ "/events");
        a_user_data "sse-swap" "acp.init,acp.status,acp.thought,acp.call,acp.patch,acp.error";
        a_user_data "hx-swap" "beforeend"
      ] [
        div ~a:[a_class ["timeline"]] []
      ];
      form ~a:[
        a_class ["composer"];
        a_user_data "hx-post" ("/sessions/" ^ session.id ^ "/prompts");
        a_user_data "hx-swap" "none";
        a_user_data "hx-on--after-request" "this.reset()"
      ] [
        label ~a:[a_label_for "prompt"; a_class ["field-label"]] [txt "Prompt"];
        textarea ~a:[
          a_id "prompt"; a_name "text"; a_class ["prompt-input"];
          a_rows 4; a_placeholder "Ask the agent what to do next..."
        ] (txt "");
        div ~a:[a_class ["composer-row"]] [
          span ~a:[a_class ["composer-hint"]] [txt "Prompt the live session directly from the browser."];
          button ~a:[a_button_type `Submit; a_class ["button"; "button-primary"]] [txt "Send Prompt"]
        ]
      ]
    ]
  ]

let to_string html =
  let buf = Buffer.create 1024 in
  let fmt = Format.formatter_of_buffer buf in
  Tyxml.Html.pp () fmt html;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let to_string_elt elt =
  let buf = Buffer.create 1024 in
  let fmt = Format.formatter_of_buffer buf in
  Tyxml.Html.pp_elt () fmt elt;
  Format.pp_print_flush fmt ();
  Buffer.contents buf
