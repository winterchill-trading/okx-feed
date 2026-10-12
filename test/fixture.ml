open! Core

let data_dir = "fixtures"
let date = Date.of_string "2026-10-12"
let streams = Market_data.Stream.[ Trades; Bbo; L2; Funding ]

let path stream =
  sprintf
    "%s/raw/okx/%s/BTC-USDT-SWAP/2026/10/12/16-53.ndjson"
    data_dir
    (Market_data.Stream.to_string stream)
;;

let lines stream =
  In_channel.read_lines (path stream)
  |> List.map ~f:(fun line -> Market_data.Raw_minute.Line.parse line |> Or_error.ok_exn)
;;

let frames stream =
  List.filter_map (lines stream) ~f:(function
    | Frame { payload; _ } -> Some payload
    | Disconnect -> None)
;;
