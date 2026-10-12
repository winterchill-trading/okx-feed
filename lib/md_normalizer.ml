open! Core

module T = struct
  type t = Normalizer.t

  let venue = Market_data.Venue.Okx
  let create () = Normalizer.create ()

  let frame t ~recv_ts payload =
    Or_error.map (Normalizer.frame t ~recv_ts payload) ~f:(fun o -> o.events)
  ;;

  let disconnect t = Normalizer.reset t
end

include T

let normalizer : Market_data.Normalizer.t = (module T)
