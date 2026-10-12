open! Core

type t = { url : Uri.t }

let sexp_of_t { url } = [%sexp { url : string = Uri.to_string url }]
let mainnet_url = Uri.of_string "wss://ws.okx.com:8443/ws/v5/public"
let mainnet = { url = mainnet_url }
let create ?(url = mainnet_url) () = { url }
