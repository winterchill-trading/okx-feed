open! Core
open Async

type t =
  { tcp : (Socket.Address.Inet.t, int) Tcp.Server.t
  ; mutable connections : int
  ; received : string Queue.t
  ; sockets : string Pipe.Writer.t Stack.t
  ; writers : Writer.t Stack.t
  ; mutable websockets : string Websocket.t list
  }

let rec read_headers reader acc =
  match%bind Reader.read_line reader with
  | `Eof | `Ok "" -> return (List.rev acc)
  | `Ok line ->
    read_headers
      reader
      (match String.lsplit2 line ~on:':' with
       | Some (k, v) -> (String.lowercase k, String.strip v) :: acc
       | None -> acc)
;;

let handle t reader writer =
  let%bind headers = read_headers reader [] in
  let key = List.Assoc.find_exn headers ~equal:String.equal "sec-websocket-key" in
  Writer.write
    writer
    (sprintf
       "HTTP/1.1 101 Switching Protocols\r\n\
        Upgrade: websocket\r\n\
        Connection: Upgrade\r\n\
        Sec-WebSocket-Accept: %s\r\n\
        \r\n"
       (Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key));
  let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
  t.connections <- t.connections + 1;
  t.websockets <- ws :: t.websockets;
  let from_client, to_client = Websocket.pipes ws in
  Stack.push t.sockets to_client;
  Stack.push t.writers writer;
  Pipe.iter_without_pushback from_client ~f:(Queue.enqueue t.received)
;;

let start () =
  let t_ref = ref None in
  let%map tcp =
    Tcp.Server.create
      ~on_handler_error:`Ignore
      (Tcp.Where_to_listen.bind_to Localhost On_port_chosen_by_os)
      (fun _ reader writer -> handle (Option.value_exn !t_ref) reader writer)
  in
  let t =
    { tcp
    ; connections = 0
    ; received = Queue.create ()
    ; sockets = Stack.create ()
    ; writers = Stack.create ()
    ; websockets = []
    }
  in
  t_ref := Some t;
  t
;;

let config t =
  let port = Tcp.Server.listening_on t.tcp in
  Okx_feed.Config.create
    ~url:(Uri.of_string (sprintf "ws://127.0.0.1:%d/ws/v5/public" port))
    ()
;;

let connections t = t.connections
let received t = Queue.to_list t.received

let send t frame =
  match Stack.top t.sockets with
  | Some w -> Pipe.write_without_pushback_if_open w frame
  | None -> raise_s [%message "Fake_ws.send: no connection"]
;;

(* An unmasked, final text frame (server to client). *)
let encode_text_frame payload =
  let len = String.length payload in
  let header =
    if len < 126
    then [ 0x81; len ]
    else if len < 65536
    then [ 0x81; 126; len lsr 8; len land 0xff ]
    else 0x81 :: 127 :: List.init 8 ~f:(fun i -> (len lsr (8 * (7 - i))) land 0xff)
  in
  String.of_char_list (List.map header ~f:Char.of_int_exn) ^ payload
;;

let write_raw t bytes =
  match Stack.top t.writers with
  | Some w -> Writer.write w bytes
  | None -> raise_s [%message "Fake_ws.write_raw: no connection"]
;;

let drop t =
  match t.websockets with
  | ws :: _ -> Websocket.close ws ~code:Endpoint_going_away ~reason:"bye"
  | [] -> return ()
;;

let wait_until ?(timeout = Time_ns.Span.of_int_sec 5) f =
  let deadline = Time_ns.add (Time_ns.now ()) timeout in
  Deferred.repeat_until_finished () (fun () ->
    if f ()
    then return (`Finished true)
    else if Time_ns.( > ) (Time_ns.now ()) deadline
    then return (`Finished false)
    else (
      let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
      `Repeat ()))
;;

let close t = Tcp.Server.close ~close_existing_connections:true t.tcp
