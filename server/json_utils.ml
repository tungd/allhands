open Yojson.Safe.Util

let field_string json name =
  match json |> member name with
  | `String value -> Ok value
  | `Null -> Error (Printf.sprintf "Missing field: %s" name)
  | _ -> Error (Printf.sprintf "Field %s must be a string" name)

let field_string_option json name =
  match json |> member name with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error (Printf.sprintf "Field %s must be a string" name)

let field_string_list json name =
  match json |> member name with
  | `Null -> Ok []
  | `List items ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest -> collect (value :: acc) rest
        | _ -> Error (Printf.sprintf "Field %s must be a list of strings" name)
      in
      collect [] items
  | _ -> Error (Printf.sprintf "Field %s must be a list of strings" name)

let jsonrpc_request ~id ~method_ ~params =
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int id);
    ("method", `String method_);
    ("params", params);
  ]

let jsonrpc_notification ~method_ ~params =
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("method", `String method_);
    ("params", params);
  ]

let error_json message =
  `Assoc [("error", `String message)]

let string_member name json =
  json |> member name |> to_string_option

let int_member name json =
  json |> member name |> to_int_option
