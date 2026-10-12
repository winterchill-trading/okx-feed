(lang dune 3.17)

(name okx-feed)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/okx-feed))

(package
 (name okx-feed)
 (synopsis "Read-only public OKX market data feed for Async")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_ssl
  venue-net
  market-data
  ppx_jane
  ppx_yojson_conv
  yojson
  uri))
