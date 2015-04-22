(* parmap is disabled because it crashes the program, maybe the update to ocaml 4.00 did it. *)

(* before running experiments:
   - set number of cores in parmap to the cpus in /proc/cpuinfo
   - sample_traces: 
     - set number_of_samples - the number of samples to generate for each track
     - prob_jump_list - the probability of jumping to use to sample the whole set
   - spot_log: set number_of_runs to number of runs over the same trace that then are averaged.

   note: 
   - number of resulting tracks is prob_jump_list X number_of_samples, 
   - number of runs of the mechanism is prob_jump_list X number_of_samples X number_of_runs

   Additionally set:
   - rho and eta in the bm_u_fist and bm_n_first, just if you know what you are doing
   - speed in skip_to_prediction
   - epsilon, radius_safe in spot_log
*)

(* aptitude install ocaml libocamlgsl-ocaml-dev libxml-light-ocaml-dev ocaml-batteries-included libcalendar-ocaml-dev make emacs tuareg-mode *)

(* compile statically, including gsl library *)
(* ocamlopt -I +gsl gsl.cmxa geo_stripped.ml -noautolink -cclib '-Wl,-Bstatic -lmlgsl -lgsl -lgslcblas -Wl,-Bdynamic -lz' -verbose *)

(* http://stackoverflow.com/questions/2638664/is-there-any-free-ocaml-to-c-translator *)
(* ocamlc -output-obj -o foo.c foo.ml *)
(* gcc -L/usr/lib/ocaml foo.c -lcamlrun -lm -lncurses *)

(* ocamlbuild -use-ocamlfind geo.native -- *)
(* ocamlbuild -use-ocamlfind -tag debug geo.native -- 
   run with OCAMLRUNPARAM=b to see stack trace of exceptions
*)


(* general: head new stuff, tail old stuff *)

(* merkartor projection vs. utm
   todo expected error of linear and polar laplacian, to use in weights of prediction and comparison with independence noise 
   todo prediction can use easy points, because they passed the test and so, removed the expected error of the linear laplacian with respect to alpha they where pretty close to the secret
   todo sanity checks, relations of parameters, this can be put in the meta
 *)




open Batteries

open Util
open Geo
open Laplacian
open Formats




(* 
   Takes the filename of a trace, creates a directory with a saple of the trace with prob_jump.
*)

let sample small_jump big_jump accuracy prob_jump filename =

  let label_by_speed max_speed track =
    let rec label_by_speed_in labelled track =
      match track with
        [] -> failwith "Empty argument"
      | pt::[] -> labelled
      | pt1::pt2::rest ->
        
        let period_calendar = CalendarLib.Calendar.sub pt1.time pt2.time in
        let period_sec = CalendarLib.Time.Period.length (CalendarLib.Calendar.Period.safe_to_time period_calendar) in
        let distance = Utm.distance pt1.coord pt2.coord in
        let speed = (distance /. 1000.) /. (float (abs period_sec) /. 3600.) in (* km/h *)

        if speed <= max_speed
        then label_by_speed_in ((pt1, true)::labelled) (pt2::rest)
        else label_by_speed_in ((pt1,false)::labelled) (pt2::rest)
    in
    let res = label_by_speed_in [] (List.rev track) in
    res
  in


  let random_jump prob_jump small big = 
    let sigma = 0.2 in
    let gauss () = 1. +. (Gsl_cdf.gaussian_Pinv ~p:(Random.float 1.) ~sigma:sigma) in (* increase sigma for more variance *)
    
    let seconds = 
      if prob_jump >= (Random.float 1.)
      then big   *. (gauss ())
      else small *. (gauss ())
    in
    let step = CalendarLib.Calendar.Period.second (int_of_float seconds) in
    step
  in
  (* accuracy in minutes *)
  let find_closest accuracy timestamp points =
    let rec find_closest_in best_pt timestamp points =
      let accuracy = accuracy * 60 in            (* seconds *)

      let best_gap = CalendarLib.Calendar.sub timestamp (fst best_pt).time in
      let best_gap_sec = abs (CalendarLib.Time.Period.length (CalendarLib.Calendar.Period.safe_to_time best_gap)) in

      match points with
        [] -> 
          if best_gap_sec <= accuracy
          then (Some best_pt,[])                     (* always returns the last point *)
          else (None, [])
      | (pt,label)::rest ->
        let gap = CalendarLib.Calendar.sub timestamp pt.time  in
        let gap_sec = abs (CalendarLib.Time.Period.length (CalendarLib.Calendar.Period.safe_to_time gap)) in
        if gap_sec <= best_gap_sec
        then find_closest_in (pt,label) timestamp rest
        else
          if best_gap_sec <= accuracy
          then (Some best_pt,points)
          else (None, points)
    in
    find_closest_in (List.hd points) timestamp (List.tl points)
  in

  let subsample small_jump big_jump accuracy track =
    let rec subsample_in sampled timestamp rest_track =
      match rest_track with
        [] -> sampled
      | _ ->
        let small = small_jump *. 60. in                     (* param seconds *)
        let big   =   big_jump *. 60. in                     (* param seconds *)
        let point = List.hd sampled in
        let next_timestamp = CalendarLib.Calendar.add timestamp (random_jump prob_jump small big) in
        let closest = find_closest accuracy next_timestamp ((point,true)::rest_track) in

        match closest with
          None,[] -> sampled
        | None,rest_track -> subsample_in sampled next_timestamp rest_track
        | Some(_,false),rest_track -> 
            subsample_in sampled next_timestamp rest_track
        | Some(next_point,true),rest_track ->

          if next_point.idx = point.idx (* we are still *)
          then
            let new_point = {coord = point.coord; idx = point.idx; time = next_timestamp} in
            let next_sampled = new_point::sampled in
            let next_timestamp = (List.hd next_sampled).time in
            subsample_in next_sampled next_timestamp rest_track (* list gets inverted *)
          else
            let next_sampled = next_point::sampled in
            let next_timestamp = (List.hd next_sampled).time in 
            subsample_in next_sampled next_timestamp rest_track (* list gets inverted *)
    in
    let track_rev = List.rev track in
    let start = fst (List.hd track_rev) in
    subsample_in [start] start.time (List.tl track_rev)
  in

  let xml = (Xml.parse_file filename) in
  let track = track_of_gpx xml in       (* head is newest *)
  let max_speed = 15. in                (* param km *)
  let segments = label_by_speed max_speed track in
  let sampled = subsample small_jump big_jump accuracy segments in
  if (List.length sampled) > 5 
  then Some sampled
  else None


let sample_traces small_jump big_jump accuracy src_dir dst_dir = 
  let number_of_samples = 1 in     (* param *)
  let prob_jump_list = [0.0;0.1;0.2;0.3;0.4;0.5;0.6;0.7;0.8;0.9;1.0] in

  let input_traces_names = Array.to_list (Sys.readdir src_dir) in
  let n_input_traces = List.length input_traces_names in

  let src_dir = deslash src_dir in
  let dst_dir = deslash dst_dir in
  (try Unix.mkdir dst_dir 0o755; with Unix.Unix_error (Unix.EEXIST,_,_) -> (););

  let sample_prior prob_of_jump =
    let dst_dir_prior = Printf.sprintf "%s/%3.1f" dst_dir prob_of_jump in
    (try Unix.mkdir dst_dir_prior 0o755; with Unix.Unix_error (Unix.EEXIST,_,_) -> (););

    let _ = parmap
      (fun input_trace_name -> 
        List.iter 
          (fun idx -> 
            let sampled_trace = sample small_jump big_jump accuracy prob_of_jump (src_dir^"/"^input_trace_name) in
            let filename = String.sub input_trace_name 0 (String.length input_trace_name -4) in
            match sampled_trace with
              Some trace -> xml_to_file (Printf.sprintf "%s/%s-%03i.gpx" dst_dir_prior filename idx) (gpx_of_track trace);
            | None -> ()) 
          (enumerate number_of_samples))
      input_traces_names;
    in
    ()
  in
  let _ = List.iter sample_prior prob_jump_list in

  Printf.printf "Generated max %i samples.\n" (number_of_samples * n_input_traces * (List.length prob_jump_list));
  ()







(* 
   post-processing

*)

let compute_errors secs obss = 
  let distances = BatList.map2 (fun sec (pt,meta) -> Utm.distance sec.coord pt) secs obss in
  distances


type stat_run = {n_so_far: int; pr_so_far: float; e_so_far: float; skipped_so_far:float; et_so_far:float; ei_so_far:float;}
type stat     = {n: float; pr: float; avg_u: float; avg_u_2: float; avg_e:float; avg_l:float; bpp:float; skipped:float; et_tot:float; ei_tot:float;}

let sprint_stat stat =
  (* Printf.sprintf "n:%f pr:%5.1f%% avg_u:%6.4f avg_e:%7.2f %7.2f\n" *)
  Printf.sprintf "%f %5.1f %6.4f %7.2f %7.2f"
    stat.n (stat.pr *. 100.) stat.avg_u stat.avg_e stat.bpp


let compute_percentile value list = 
  let sorted = List.sort compare list in
  let length = float (List.length list) in
  let n = (length *. value /. 100.) +. 0.5 in
  let n_rounded = if (n -. (floor n)) < 0.5 then floor n else ceil n in
  List.nth sorted (int_of_float n_rounded)


let chop_bad_part secs obss = 
  let elaborated_obss = List.filter (fun (pt,meta) -> if meta.et = -1. then false else true) obss in

  let n = List.length elaborated_obss in

  let elaborated_secs = BatList.drop ((List.length secs) - n) secs in
  (elaborated_secs,elaborated_obss)
  

let statistics_run obss =

  let elaborated_obss = List.filter (fun (pt,meta) -> if meta.et = -1. then false else true) obss in

  let n = List.length elaborated_obss in
  let et_tot = List.fold_left (fun tot (_,meta) -> tot +. meta.et) 0. elaborated_obss in
  let ei_tot = List.fold_left (fun tot (_,meta) -> tot +. if meta.h then meta.e else 0.) 0. elaborated_obss in
  let e_tot = et_tot +. ei_tot in

  (* let wrongs = List.length (List.filter (fun (_,meta) -> meta.et >= meta.e) elaborated_obss) in *)
  (* if wrongs > 0 then Printf.printf "Sbagliai: %f%%\n" ((float wrongs) /. (float n)); *)

  let hards = List.fold_left (fun tot (pt,meta) -> if meta.h then tot+1 else tot) 0 elaborated_obss in
  let prediction_rate = (float (n - hards)) /. (float n) in

  let skipped_obss = List.filter (fun (pt,meta) -> if meta.et = 0. && meta.e = 0. then true else false) elaborated_obss in
  let skipped = (float (List.length skipped_obss)) /. (float n) in
  
  {n_so_far = n; pr_so_far = prediction_rate; e_so_far = e_tot; skipped_so_far = skipped; et_so_far = et_tot; ei_so_far = ei_tot}


(* head is the newest *)
let statistics secs obss =

  (* let elaborated_obss = List.filter (fun (pt,meta) -> if meta.et = -1. then false else true) obss in *)

  (* let n = List.length elaborated_obss in *)

  (* let hards = List.fold_left (fun tot (pt,meta) -> if meta.h then tot+1 else tot) 0 elaborated_obss in *)
  (* let prediction_rate = (float (n - hards)) /. (float n) in *)

  (* let skipped_obss = List.filter (fun (pt,meta) -> if meta.et = 0. && meta.e = 0. then true else false) elaborated_obss in *)
  (* let skipped = (float (List.length skipped_obss)) /. (float n) in *)

  (* let e_tot = List.fold_left (fun tot meta -> if meta.h then tot+.meta.e else tot) 0. real_metas in *)
  (* let et_tot = List.fold_left (fun tot meta -> if meta.l = 0. then tot else tot+.meta.et) 0. real_metas in *)

  let stat = statistics_run obss in
  let n = stat.n_so_far in
  let prediction_rate = stat.pr_so_far in
  let skipped = stat.skipped_so_far in

  let elaborated_obss = BatList.drop ((List.length obss) - n) obss in
  let elaborated_secs = BatList.drop ((List.length secs) - n) secs in

  let utilities = List.map (fun (pt,meta) -> 
    if meta.et = 0. && meta.e <> 0. then worst_noise_polar meta.e 
    else max (worst_noise_polar meta.e) ((worst_noise_linear meta.et) +. meta.l)) 
    elaborated_obss 
  in
  if List.length utilities = 0 then Printf.printf "utilities: elab_obss %i  secs %i obss %i \n " (List.length elaborated_obss) (List.length secs) (List.length obss);
  let avg_u = avg utilities in

  let utilities_2 = List.map (fun (pt,meta) -> 
    if meta.et = 0. && meta.e <> 0. then worst_noise_polar meta.e 
    else alpha_of_delta 0.1 stat.pr_so_far (meta.et,meta.e,meta.l))
    elaborated_obss 
  in
  if List.length utilities_2 = 0 then Printf.printf "utilities2: elab_obss %i  secs %i obss %i \n " (List.length elaborated_obss) (List.length secs) (List.length obss);
  let avg_u_2 = avg utilities_2 in

  let errors = compute_errors elaborated_secs elaborated_obss in
  if List.length errors = 0 then Printf.printf "List errors vuota\n";
  let avg_e = avg errors in
  (* let max_e = List.fold_left (fun tmp err -> max tmp err) (-. infinity) errors in *)
  (* let max_e = compute_percentile 90. errors in *)

  let bpp = stat.e_so_far /. (float stat.n_so_far) in (* bpp *)
  let avg_l = avg (List.map (fun (pt,meta) -> meta.l) elaborated_obss) in

  {n = (float n); pr = prediction_rate; avg_u = avg_u; avg_u_2 = avg_u_2; avg_e = avg_e; avg_l=avg_l; bpp = bpp; skipped = skipped; et_tot = stat.et_so_far; ei_tot = stat.ei_so_far}


let average_stat stats =
  let n_stat = float (List.length stats) in
  let zero = {n = 0.; pr = 0.; avg_u = 0.; avg_u_2 = 0.; avg_e = 0.; avg_l = 0.; bpp = 0.; skipped = 0.; et_tot = 0.; ei_tot = 0.} in
  let sum = List.fold_left (fun sum stat ->
    {n = sum.n +. stat.n;
     pr = sum.pr +. stat.pr;
     avg_u = sum.avg_u +. stat.avg_u;
     avg_u_2 = sum.avg_u_2 +. stat.avg_u_2;
     avg_e = sum.avg_e +. stat.avg_e;
     avg_l = sum.avg_l +. stat.avg_l;
     bpp = sum.bpp +. stat.bpp;
     skipped = sum.skipped +. stat.skipped;
     et_tot = sum.et_tot +. stat.et_tot;
     ei_tot = sum.ei_tot +. stat.ei_tot;
    }) zero stats in

  {n = sum.n /. n_stat;
   pr = sum.pr /. n_stat;
   avg_u = sum.avg_u /. n_stat;
   avg_u_2 = sum.avg_u_2 /. n_stat;
   avg_e = sum.avg_e /. n_stat;
   avg_l = sum.avg_l /. n_stat;
   bpp = sum.bpp /. n_stat;
   skipped = sum.skipped /. n_stat;                   (* this is not averaged *)
   et_tot = sum.et_tot /. n_stat;
   ei_tot = sum.ei_tot /. n_stat}


(* @return index of stat in stats closest to avg of stats *)
let representative_stat stats =
  let avg = average_stat stats in
  let distances_stats = List.map (fun stat ->
    {n = abs_float (stat.n -. avg.n);
     pr = abs_float (stat.pr -. avg.pr);
     avg_u = abs_float (stat.avg_u -. avg.avg_u);
     avg_u_2 = abs_float (stat.avg_u_2 -. avg.avg_u_2);
     avg_e = abs_float (stat.avg_e -. avg.avg_e);
     avg_l = abs_float (stat.avg_l -. avg.avg_l);
     bpp = abs_float (stat.bpp -. avg.bpp); (* this is ignored in the sorting *)
     skipped = abs_float (stat.skipped -. avg.skipped); (* ignored *)
     et_tot = abs_float (stat.et_tot -. avg.et_tot);
     ei_tot = abs_float (stat.ei_tot -. avg.ei_tot);
     }) stats in
  let distance_stats = List.map (fun stat ->
    (* stat.n +. stat.pr +. stat.avg_u +. stat.avg_e)  *)
    stat.avg_e)
    distances_stats 
  in
  let indexed = indicize distance_stats in
  let sorted = List.sort (fun (_,e1) (_,e2) -> compare e1 e2) indexed in
  fst (List.hd sorted)





(*           
   PREDICTION
*)


(* super simple prediction *)
(* let super_simple_prediction obss = *)
(*   let (x0,y0) = fst (List.nth obss 0) in *)
(*   let (x1,y1) = fst (List.nth obss 1) in *)
(*   let x = x0 +. (x0 -. x1) in *)
(*   let y = y0 +. (y0 -. y1) in *)
(*   (x,y) *)


(* 
  least square prediction 
 *)

let project_point_to_line (x0,y0) (c0,c1) = 
  let x = ((c1 *. y0) +. x0 -. (c1 *. c0)) /. ((c1 ** 2.) +. 1.) in
  let y = c0 +. (x *. c1) in
  (x,y)

let rotate_pt angle pt = 
  let (x,y) = pt in
  ((x *. (cos (angle))) -. (y *. (sin (angle))),
   (x *. (sin (angle))) +. (y *. (cos (angle))))


let rotate angle pts = List.map (rotate_pt angle) pts

(* @param pts list of points representing a straight line 
   @return angle in radiants between [pi,-pi] of the inclination the line 
*)
let get_inclination pts = 
 
    let (x0,y0) = List.hd pts in
    let (xn,yn) = List.nth pts (List.length pts -1) in

    let direction_x = float (sign_float (x0 -. xn)) in
    let direction_y = float (sign_float (y0 -. yn)) in

    let slope = (y0 -. yn) /. (x0 -. xn) in
    let angle = atan2 ((abs_float slope) *. direction_y) direction_x in
    angle


open Gsl_fun
open Gsl_fit

(* @param obss observables, they must be at least two, last is more recent 
   @return point predicted
   
   we approximate straigth lines
   normally two points are enough to approximate a straight line withp=out noisy, in our case we ask at least 3
*)
let prediction_linear_least_square obss = 
  let all = fst (List.split obss) in
  let hards = fst (List.split (List.filter (fun (_,meta) -> meta.h) obss)) in
  let n = List.length hards in
  match n with
  | 0 -> ((Utm.make 0. 0.),0.)  (* no particular reason *)
  | 1 -> (List.hd all,0.)  (* just return the only observables we have *)
  | _ ->
     let all = (List.map (fun p -> Utm.tuple p) all) in
     let system_angle = get_inclination all in
     let all_rotated = rotate (-.system_angle) all in

    (* STRATEGY without weights *)
    (* let hards_rotated = rotate (-. system_angle) hards in *)
    (* let (hxs,hys) = List.split hards_rotated in *)
    (* let ahx = Array.of_list hxs in *)
    (* let ahy = Array.of_list hys in *)
    (* let coeffs = Gsl_fit.linear ahx ahy in *)
    (* let avg_error = coeffs.sumsq /. float n in *)


    (* STRATEGY with weights *)
    let weights = List.map (fun (_,meta) -> if meta.h
      then 1. /. ((expected_value_polar meta.e) ** 2.)
      else 1. /. (meta.l ** 2.)) obss in
    let (xs,ys) = List.split all_rotated in
    let ahx = Array.of_list xs in
    let ahy = Array.of_list ys in
    let aw = Array.of_list weights in
    let coeffs = Gsl_fit.linear ~weight:aw ahx ahy in
    let avg_error = coeffs.sumsq /. ((float n) *. (List.fold_left (fun tmp w -> tmp +. (w ** 2.)) 0. weights)) in


    let (xp,yp) = project_point_to_line (List.hd all_rotated) (coeffs.c0,coeffs.c1) in

    let step = avg (intra_distances Utm.distance (List.map (fun (x,y) -> Utm.make x y) all_rotated)) in
    let direction_x = float (sign_float (ahx.(0) -. ahx.(1))) in
    let direction_y = float (sign_float (ahy.(0) -. ahy.(1))) in
    
    let angle = atan2 ((abs_float coeffs.c1) *. direction_y) direction_x in
    let x = xp +. ((cos angle) *. step) in
    let y = yp +. ((sin angle) *. step) in

    (* linear_est returns the standard_deviation too *)
    (* if coeffs.sumsq <> coeffs.sumsq then failwith "Prediction: non a number";  *)

    let (new_x,new_y) = rotate_pt system_angle (x,y) in
    let pt = Utm.make new_x new_y in
    (pt, avg_error)



(* 
  LINEAR PREDICTION 
 *)
      
let linear obss =
  match obss with
  | [] -> ((Utm.make 0. 0.),{d = 0; turn=false; pred_e = 0.})  (* no particular reason *)
  | (pt,_)::[] ->  (pt,{d = 1; turn=false; pred_e = 0.})  (* just return the only observables we have *)
  | _ -> 

    (* BEST ERROR STRATEGY *)
    (* let nhards = List.length (List.filter (fun (pt,meta) -> meta.h) obss) in *)
    (* let min_depth = if nhards > 2 then 3 else 2 in (* minimum should be 3 because prediction is linear thus there is no error for two points *) *)
    (* let max_depth = 30 in                      (* parameter *) *)
    (* let depths = Array.to_list (Array.init (max_depth-min_depth) (fun i -> min_depth+i)) in *)
    (* let values = List.combine depths (List.map (fun depth -> let sub_obss = sublist obss depth in *)
    (*                                                          prediction_linear_least_square sub_obss) depths) in *)
    (* let sorted = List.sort (fun (d1,(p1,e1)) (d2,(p2,e2)) -> compare e1 e2) values in *)
    (* let (depth,(pt,err)) = List.hd sorted in *)
    (* let turnpoint = false in *)

    (* TURNING DETECTION STRATEGY *)
    let rec until_last_turn l =
      match l with
        [] -> []
      | (pt,meta)::rest -> if meta.pred.turn then (pt,meta)::[] else (pt,meta)::(until_last_turn rest)
    in
    let sub_obss = until_last_turn obss in
    let (pt,err) = prediction_linear_least_square sub_obss in
    let avg_errs = avg (List.map (fun (p,m) -> m.pred.pred_e) obss) in
    let turnpoint = if err > avg_errs *. 10. then true else false in (* param *)
    let depth = List.length sub_obss in


    (pt, {d = depth; turn = turnpoint; pred_e = err;})



(* 
  PARROT PREDICTION 
 *)

let parrot obss =
  match obss with
  | [] -> ((Utm.make 0. 0.),{d = 0; turn=false; pred_e = 0.})  (* no particular reason *)
  | (pt,_)::[] ->  (pt,{d = 1; turn=false; pred_e = 0.})  (* just return the only observables we have *)
  | _ -> 

    let rec first_hard l = match l with [] -> None | (pt,meta)::rest -> if meta.h then Some pt else first_hard rest in
    let (pt,depth) = 
      match first_hard obss with
        None -> (fst (List.hd obss),0)                 (* just return last easy observable *)
      | Some pt -> (pt,1)
    in
    let err = 0. in
    let turnpoint = false in

    (pt, {d = depth; turn = turnpoint; pred_e = err;}) (* error in this case is useless *)



let prediction = parrot



(* @param alpha prediction precision 
   @param pred  predicted point
   @param sec   secret point 
   @return true if the prediction is good 
*)
let theta alpha pred sec = if (Utm.distance pred sec) < alpha then true else false

(* differentially private version with laplacian noise *)
let theta_dp epsilon_theta alpha predicted secret =
  (* if alpha = infinity then true else  *)
  (*   if alpha = 0. then false else  *)
      let noise = noise_linear epsilon_theta in
      if (Utm.distance predicted secret) < (alpha +. noise) then true else false



(*  
    MECHANISMS
*)

let mechanism_independent_noise epsilon secs = 
  List.map (fun sec -> noise_polar epsilon sec) secs


let mechanism_independent_noise_budget budget secs = 
  let epsilon_step = budget /. float (List.length secs) in
  mechanism_independent_noise epsilon_step secs








(* 
  Budget Managers 
*)



(* todo move these constants *)
let c_i = (epsilon_of_radius_polar 1.)
let c_l = (epsilon_of_radius_linear 1.)

let skip_to_independent run = 
  match run with
    [] -> ((* print_string "skip_to_ind\n"; *) true)
  | _ -> false


let rec find_last_hard l = 
  match l with 
    [] -> None
  | (pt,meta)::rest -> if meta.h then Some (pt,meta) else (find_last_hard rest) 


let skip_to_prediction time alpha run = 
  let speed = 0.5 in  (* n_first*)                     (* km/h *) (*TODO check *)
  (* let speed = 0.15 in (\* u_first*\)                     (\* km/h *\) *)

  let last_hard = find_last_hard run in

  match last_hard with
    None -> false
  | Some (pt,meta) ->
    let period_calendar = CalendarLib.Calendar.sub time meta.t in
    let period_sec = CalendarLib.Time.Period.length (CalendarLib.Calendar.Period.safe_to_time period_calendar) in

    if period_sec < 0 then (Printf.printf "skip_to_pred wrong time %i sec\n" period_sec; false)
    else
      let distance = speed *. ((float period_sec) /. 60.) *. 1000. in
  
      if distance <= alpha
      then (
      (* Printf.printf "distance %f <= alpha %f\n" distance alpha; *)
        true)
      else false


(* correct formulas with rho and eta *)
let init_bm_u_first epsilon alpha prediction_rate skip_enable = 
  let rho = 0.8 in                      (* noise vs threshold *)
  let eta = 0.5 in                      (* adjusts utility to prior, make it smaller to fit your prior, higher to cover all prior *)

  let n_ind = epsilon *. alpha /. c_i in

  let compute_min_pr eps_step = (c_l /. c_i) *. eta *. (1. +. (1. /. rho)) in
  let min_pr = compute_min_pr (epsilon /. n_ind) in

  if not (prediction_rate >= min_pr && prediction_rate <= 1.) then failwith (Printf.sprintf "Wrong prediction rate. [%f - 1]\n" min_pr)
  else
    fun time run ->
      let stat = statistics_run run in
      let epsilon_so_far = stat.e_so_far in
    
      if (epsilon -. epsilon_so_far < 0.000001)         (* TODO check this precision *)
      then ((* Printf.printf "End of budget\n"; *) (-1.,-1.,-1.))
      else if (skip_to_prediction time alpha run) && skip_enable
      then (0.,0.,alpha)
      else if (skip_to_independent run) && skip_enable
      then (0.,(epsilon /. n_ind),0.)   (* epsilon_{I'} *)
      else (
        (* if not (prediction_rate >= compute_min_pr (epsilon_step)) then Printf.printf "We are not gonna make it...\n"; *)

        (* let prediction_rate = if (stat.n_so_far >= 10) then stat.pr_so_far else prediction_rate in (\* TODO super ccheckkk!!!! *\) *)
        
        let epsilon_theta = eta *. (c_l /. alpha) *. (1. +. (1. /. rho)) in
        let epsilon_i = c_i /. alpha in
        let threshold = c_l /. (rho *. epsilon_theta) in
        
        (epsilon_theta, epsilon_i, threshold))


(* correct formulas with rho and eta *)
let init_bm_n_first epsilon n prediction_rate skip_enable =
  let rho = 0.8 in                      (* noise vs threshold *)
  let eta = 0.6 in                      (* utility ind vs utility pred *)
  
  let compute_min_pr eps_step = (c_l /. c_i) *. eta *. (1. +. (1. /. rho)) in
  let min_pr = compute_min_pr (epsilon /. n) in

  let rate = epsilon /. n in
  if not (prediction_rate >= min_pr && prediction_rate <= 1.) then failwith (Printf.sprintf "Wrong prediction rate. [%f - 1]\n" min_pr)
  else
    fun time run ->

      let stat = statistics_run run in
      let n_so_far = float (stat.n_so_far) in
      let epsilon_so_far = stat.e_so_far in
      let delta_e = epsilon -. epsilon_so_far in

      let last_alpha = let hard = find_last_hard run in match hard with Some (pt,meta) -> meta.l | None -> 0. in
    
    if delta_e <= 0. || n_so_far = n
    then ((* Printf.printf "End of budget\n"; *) (-1.,-1.,-1.))
    else if n_so_far = (n-.1.)
    then (
      let epsilon_i = delta_e in
      let epsilon_theta = 0. in
      let threshold = 0. in
      (epsilon_theta, epsilon_i, threshold))
    else if (skip_to_prediction time (last_alpha *. 0.8 ) run) && skip_enable
    then (0.,0.,last_alpha)
    else if (skip_to_independent run) && skip_enable
    then (0.,(epsilon /. n),0.)   (* epsilon_{I'} *)
    else (
      (* if not (prediction_rate >= compute_min_pr (epsilon_step)) then Printf.printf "We are not gonna make it...\n"; *)
      
      let prediction_rate = if (n_so_far >= 10.) || (n_so_far >= n /. 4.) then stat.pr_so_far else prediction_rate in (* TODO super ccheckkk!!!! *)
      if n = n_so_far then failwith "bm n_first: you should have stopped before";

      let epsilon_i = rate /. ((1. -. prediction_rate) +. (c_l /. c_i) *. eta *. (1. +. (1. /. rho))) in
      let epsilon_theta = (c_l /. c_i) *. eta *. (1. +. (1. /. rho)) *. epsilon_i in
      let threshold = c_l /. (rho *. epsilon_theta) in
      (epsilon_theta, epsilon_i, threshold))


(* @param secs (x,y) the head is newest
   @return obss (x,y),(bool,epsilon,epsilon_theta,alpha) head is newest 
*)
let mechanism budget_manager secs =
  let rec mechanism_in idx obss secs = 
    match secs with
    | [] -> obss
    | sec::rest -> 
      let (epsilon_theta, epsilon_i, threshold) = budget_manager sec.time obss in

      (* Printf.printf "%i: epsilon_theta %f epsilon_i %f threshold %f\n" idx epsilon_theta epsilon_i threshold; *)
      if epsilon_i < epsilon_theta then Printf.printf "ei < et!!\n";

      let (predicted,params) = prediction obss in 

      let b = 
        if epsilon_theta = -1. then true                              (* stop condition *)
        else if epsilon_theta = 0. && epsilon_i = 0. then true        (* skip to pred *)
        else if epsilon_theta = 0. && epsilon_i > 0. then false       (* skip to ind *)
        else if epsilon_theta > 0. && epsilon_i > 0. then 
          if epsilon_theta <= epsilon_i then (theta_dp epsilon_theta threshold predicted sec.coord)
          else failwith "Budget manager spends more in et than ei."
        else  failwith "Budget manager returned wrong values."
      in

      let obs = 
        if b
        then 
          (* TODO here idx could come from meta_pre *)
          let meta = {i = idx; t = sec.time; h = false; e = epsilon_i; et = epsilon_theta; l = threshold; pred = params} in
          (predicted,meta)
        else 
          let noisy = noise_polar epsilon_i sec.coord in
          let meta = {i = idx; t = sec.time; h = true; e = epsilon_i; et = epsilon_theta; l = threshold; pred = params} in
          (noisy,meta)
      in
      mechanism_in (idx+1) (obs::obss) rest
  in
  let rsecs = List.rev secs in           (* head is the oldest secret *)
  mechanism_in 0 [] rsecs






(*            *)
(* playground *)
(*            *)

type result = {i:int; obs: ((float * float) * meta) list; sampled: point list; stat: stat}

(* breadth first: PRO accurate percentile, CONS: mooore memory *)
let spot_log pri u n skip_enable directory =
  let radius_safe = 100. in             (* param *)
  let global_budget = 10. in
  let epsilon = (log global_budget) /. radius_safe in (* param *)
  let number_of_runs = 3 in        (* param *)
  let strict = false in             (* only accept traces long enough *)

  if (u = 0. && n = 0.) || (u <> 0. && n <> 0.) then failwith "Wrong parameters.";
  let u_first = if n = 0. then true else false in

  let directory = deslash directory in

  let bm = if u_first then init_bm_u_first epsilon u pri skip_enable else init_bm_n_first epsilon n pri skip_enable in
  let mechanism = mechanism bm in

  let prob_of_jump_list = List.sort compare (list_dir directory) in
  let number_of_samples_per_prior = List.length (list_dir (directory^"/"^(List.hd prob_of_jump_list)^"/")) in


  let average_over_prior prob_of_jump =

    let average_over_track sample_path =
      let sampled_track = track_of_gpx (Xml.parse_file sample_path) in
      let name = Filename.chop_extension sample_path in
      Printf.printf "%s\n" name; flush_all ();
      (* (try Unix.mkdir ("tmp/"^(Filename.dirname name)) 0o755; with Unix.Unix_error (Unix.EEXIST,_,_) -> ();); *)
      (* let filename = "tmp/"^name^"-sec" in *)
      (* geojson_to_file (filename^".json") (geojson_of_simple_track sampled_track); *)
      (* xml_to_file (filename^".gpx") (gpx_of_track sampled_track); *)

      let run_mechanism () =
        let obs = mechanism sampled_track in
        let stat = statistics sampled_track obs in
        if u_first && strict then
          (let (_,meta) = List.hd obs in
          if meta.et = (-. 1.)
          then Some (obs,stat)
          else None)
        else Some (obs,stat)
      in
      
      if (not u_first) && (float (List.length sampled_track) < n) && strict
      then None
      else(
        let option_obs_stats = repeat (run_mechanism) number_of_runs in
        let (some_obs_stats,none_obs_stats) = List.partition (fun x -> match x with Some _ -> true | None -> false) option_obs_stats in
        if (List.length none_obs_stats) > 0
        then None
        else (
          let obs_stats = List.map (fun x -> match x with Some x -> x | _ -> failwith "bad filter") some_obs_stats in
          
          let (obss,stats) = List.split obs_stats in
          
          (* complete versione *)
          (* let stat = average_stat stats in *)
          (* let errors = List.flatten (List.map (fun obs -> let (s,o) = chop_bad_part sampled_track obs in compute_errors s o) obss) in *)

          (* short version *)
          let idx = representative_stat stats in
          let stat = List.nth stats idx in
          let obs = List.nth obss idx in

          (* let filename = "tmp/"^name^"-obs" in *)
          (* geojson_to_file (filename^".json") (geojson_of_rich_track obs); *)
          (* xml_to_file (filename^".gpx") (gpx_of_rich_track obs); *)

          let errors = let (s,o) = chop_bad_part sampled_track obs in compute_errors s o in
          Some (stat,errors)))
    in

    let samples_paths = List.map (fun name -> directory^"/"^prob_of_jump^"/"^name) (list_dir (directory^"/"^prob_of_jump)) in
    let option_err_stats = parmap average_over_track samples_paths in
    let (some_err_stats,none_err_stats) = List.partition (fun x -> match x with Some _ -> true | None -> false) option_err_stats in
    let err_stats = List.map (fun x -> match x with Some x -> x | _ -> failwith "bad filter") some_err_stats in
    let none_length = List.length none_err_stats in
    let (stats,errors) = List.split err_stats in
    match stats with
      [] -> None 
    | _ -> 
      let percentile = compute_percentile 90. (List.flatten errors) in
      let avg_all = avg (List.flatten errors) in
      let stat = average_stat stats in
      (* Printf.printf "prior %s      avg_e %f     95 percentile %f     length %f     avg_all %f\n"  *)
        (* prob_of_jump stat.avg_e percentile stat.n avg_all; *)
      Printf.printf "%s " prob_of_jump; flush_all ();
      Some (stat,percentile, avg_all, none_length)
  in
  let results = List.map average_over_prior prob_of_jump_list in
  Printf.printf "\n"; flush_all ();

  (* compute info of independent mechanism *)
  let epsiloni_indep = if u = 0. then epsilon /. n else epsilon_of_radius_polar u in
  let n_indep = epsilon /. epsiloni_indep in
  let avg_u_indep = worst_noise_polar epsiloni_indep in
  let avg_e_indep = expected_value_polar epsiloni_indep in
  let bpp_ind = epsilon /. n_indep in
  let ppp_ind = bpp_ind /. epsilon *. 100. in

  (* log statistics *)
  let dir = directory^"-sanitized" in                    (* param *)
  (try Unix.mkdir dir 0o755; with Unix.Unix_error (Unix.EEXIST,_,_) -> (););

  let param_string = (Printf.sprintf "-%.2f-%.0f-%.0f" pri u n)^(if skip_enable then "-skip" else "-noskip") in

  let filename = "all"^param_string in
  let log = open_out (dir^"/"^filename^".log") in

  output_string log (Printf.sprintf "#pri:%.2f u:%.0f n:%.0f %s   %i samples\n" pri u n (if skip_enable then "skip" else "noskip") number_of_samples_per_prior);
  output_string log "#jump  coverage  pr    avg_e  avg_e_ind  avg_n  n_ind     avg_u   avg_u_2   percentile avg_u_ind   ppp   ppp_ind  skipped  test avg_l\n";
  output_string log (List.fold_left2 (fun s prob_of_jump result ->
    match result with 
      Some (stat,percentile,avg_all,none_length) ->
        let coverage = (float (number_of_samples_per_prior - none_length)) /. (float number_of_samples_per_prior) in
        let ppp = stat.bpp /. epsilon *. 100. in
        let test = stat.et_tot /. (stat.et_tot +. stat.ei_tot) *. 100. in
          s^(Printf.sprintf " %s    %3.3f   %3.2f  %7.2f  %7.2f   %5.1f  %5.1f    %8.2f  %8.2f  %8.2f  %8.2f  %5.2f   %5.2f    %5.2f   %5.2f %8.2f\n"
              prob_of_jump coverage (stat.pr *. 100.) avg_all avg_e_indep stat.n  n_indep stat.avg_u stat.avg_u_2 percentile avg_u_indep ppp ppp_ind (stat.skipped *. 100.) test stat.avg_l)
    | None -> s^(Printf.sprintf " %s  \n" prob_of_jump))
                       "" prob_of_jump_list results);
  close_out log;


  let log = open_out (dir^"/"^filename^".plot") in

  output_string log (Printf.sprintf "pri=%.2f; u=%.0f; n=%.0f; number_of_traces=%i; file=\"%s.log\"; set title \"%s\"\n set output \"%s.png\"\n" pri u n number_of_samples_per_prior filename filename filename);
  close_out log



let compute_intra_speeds track = 
  let rec intra_speeds_in speeds track = 
      match track with
        [] -> failwith "Empty argument"
      | pt::[] -> speeds
      | pt1::pt2::rest -> 
  
        let period_calendar = CalendarLib.Calendar.sub pt1.time pt2.time in
        let period_sec = CalendarLib.Time.Period.length (CalendarLib.Calendar.Period.safe_to_time period_calendar) in
        let distance = Utm.distance pt1.coord pt2.coord in
        let speed = (distance /. 1000.) /. (float period_sec /. 3600.) in (* km/h *)
        intra_speeds_in (speed::speeds) (pt2::rest)
  in
  let res = intra_speeds_in [] track in
  List.rev res


let mega_filter filename_src filename_dst = 
  let xml = (Xml.parse_file filename_src) in
  let track = track_of_gpx xml in

  let length_filter track = 
    let min_length = 20 in                (* paramter number of points*)
    let length = List.length track in
    let bool_length = length >= min_length in
    bool_length
  in

  (* let box_filter track = *)
  (*   let box_latlon = (39.8211942,40.023408,116.2051392,116.5374756) in (\* beijing *\) *)
  (* (\* let box_latlon = (49.5874568,49.6309501,6.0804176,6.1799812) in (\\* luxembourg *\\) *\) *)
  (* (\* let box_latlon = (48.8131942,48.9044488,2.2226715,2.4224854) in (\\* paris *\\) *\) *)
  (*   let bool_inbox = (List.length (List.filter (fun pt -> is_in_box box_latlon pt.coord) track)) = (List.length track) in *)
  (*   bool_inbox *)
  (* in *)

  let period_filter track =
    let min_period = 20. in         (* param minutes*)
    let newest = (List.hd track).time in
    let oldest = (List.nth track (List.length track -1)).time in
    
    let period_calendar = CalendarLib.Calendar.sub newest oldest in
    let period_sec = CalendarLib.Time.Period.length (CalendarLib.Calendar.Period.safe_to_time period_calendar) in
    let period = (float period_sec) /. 60. in
    let bool_period = period >= min_period in
    bool_period
  in

  (* let max_speed = 15. in                (\* parameter km/h*\) *)
  (* let distance = List.fold_left (+.) 0. (intra_distances_xy (List.map (fun pt -> pt.coord) track)) in *)
  (* let speed = (distance /. 1000.)  /. (period /. 60.) in (\* km/h *\) *)
  (* (\* let bool_speed = speed <= max_speed in *\) *)
  (* let bool_speed = true in *)

  let speed_filter track = 
    let intra_speeds = compute_intra_speeds track in
    let query_speed = 15. in            (* param km/h *)
    let ratio = (float (List.length (List.filter (fun speed -> speed < query_speed) intra_speeds))) /. (float (List.length track -1)) in
    let bool_speed = ratio >= 0.1 in
    bool_speed
  in

  let rec apply_filters track filters =
    match filters with
      [] -> true
    | filter::rest -> 
      let passed = filter track in
      if passed then apply_filters track rest
      else false
  in
  let passed = apply_filters track [length_filter;period_filter;speed_filter] in

  (* Printf.printf " %s  length %4.i  Period %4.f  ratio %6.4f  " filename length period ratio; *)
  if passed 
  then (
    (* Printf.printf "%s OK\n" filename_src; *)
    xml_to_file filename_dst (gpx_of_track track))
  else(
    (* Printf.printf "%s Not good.\n" filename_src; *)
    ())



(* todo: this shoudl be applied to sample_traces too *)
let do_on_a_dir func src_dir dst_dir =
  let input_filenames = Array.to_list (Sys.readdir src_dir) in
  (* let n_input_traces = List.length input_traces_names in *)

  let src_dir = deslash src_dir in
  let dst_dir = deslash dst_dir in
  (try Unix.mkdir dst_dir 0o755; with Unix.Unix_error (Unix.EEXIST,_,_) -> (););

  let _ = parmap
    (fun input_filename -> 
      (* Printf.printf "doing on a dir %s\n" input_filename; *)
      let input_path  = src_dir^"/"^input_filename in
      let output_path = dst_dir^"/"^input_filename in
      func input_path output_path
    )
    input_filenames
  in 
  ()


let mega_stat filename dst_fake= 
  let xml = (Xml.parse_file filename) in
  let track = track_of_gpx xml in

  let length = List.length track in

  let newest = (List.hd track).time in
  let oldest = (List.nth track (List.length track -1)).time in
  
  let period_calendar = CalendarLib.Calendar.sub newest oldest in
  let period_sec = CalendarLib.Time.Period.length (CalendarLib.Calendar.Period.safe_to_time period_calendar) in
  let period = (float period_sec) /. 60. in

  let intra_distances = (intra_distances Utm.distance (List.map (fun pt -> pt.coord) track)) in
  let distance = List.fold_left (+.) 0. intra_distances in
  let speed = (distance /. 1000.)  /. (period /. 60.) in (* km/h *)

  let intra_speeds = compute_intra_speeds track in
  let query_speed = 15. in
  let ratio = (float (List.length (List.filter (fun speed -> speed < query_speed) intra_speeds))) /. (float (length-1)) in
  let max_speed = BatList.max intra_speeds in
  (* List.iter (fun d -> Printf.printf "%f " d) (compute_intra_speeds track); Printf.printf "\n"; *)
  Printf.printf " %s length %5.i  distance %9.1f  Period %4.f  speed %5.1f  maxspeed %5.1f  ratio %5.1f\n" filename length (distance) period speed max_speed ratio


let sample_stat directory = 
  let directory = deslash directory in

  let priors = List.sort compare (list_dir directory) in

  let avg_lengths = parmap (fun prior -> 
    let traces = list_dir (directory^"/"^prior) in
    let lengths = List.map (fun trace ->   
      let track = track_of_gpx (Xml.parse_file (directory^"/"^prior^"/"^trace)) in
      let l = List.length track in
      if l = 0 then failwith "Zero length trace!";
      l)
      traces
    in
    avg (List.map float lengths))
    priors
  in
  List.iter2 (fun prior length -> Printf.printf "%s %f\n" prior length) priors avg_lengths



(* check that 90th percentile and worst_noise_polar coincide *)
let indep () =
  let p1_ll = Wgs.make 48.84437 2.332964 in    (* paris *)
  let point = Utm.of_latlon p1_ll in

  let epsilon = 0.1 in

  let errors = repeat (fun () ->
    let noisy = noise_polar epsilon point in
    Utm.distance noisy point) 
    500000
  in
  let avg = avg errors in
  let max = worst_noise_polar epsilon in
  let perc = compute_percentile 90. errors in
  Printf.printf "avg %f   max %f    perc %f\n" avg max perc;
  ()




let main () =
  let argv = Sys.argv in
  if (Array.length argv) = 0 then failwith "No arguments";
      
  let command = argv.(1) in
  let src_dir = argv.(2) in

  match command with

    "filter" -> (
      let dst_dir = src_dir^"-filtered" in

      (* Printf.printf "filter src_dir:%s dst_dir:%s\n" src_dir dst_dir; *)
      do_on_a_dir mega_filter src_dir dst_dir;
      do_on_a_dir mega_stat dst_dir dst_dir;
      ())
  | "sample" ->
(
    Printf.printf "sample\n";
    let small = float_of_string argv.(3) in
    let big = float_of_string argv.(4) in
    let accuracy = int_of_string argv.(5) in
    let dst_dir = Printf.sprintf "%s-sampled-%i-%i-%i" src_dir (int_of_float small) (int_of_float big) accuracy in

    sample_traces small big accuracy src_dir dst_dir;
    sample_stat dst_dir;
    ())
  | "run" ->
    (
      Printf.printf "run\n";
      let pr = float_of_string argv.(3) in
      let u = float_of_string argv.(4) in
      let n = float_of_string argv.(5) in
      let skip = bool_of_string argv.(6) in
 
      spot_log  pr  u  n  skip  src_dir; 
      ())
  | "gpx2json" ->
      let src_dir = deslash src_dir in
      let dst_dir = (deslash src_dir)^"-json" in
      let input_filenames = Array.to_list (Sys.readdir src_dir) in

      (try Unix.mkdir dst_dir 0o755; with Unix.Unix_error (Unix.EEXIST,_,_) -> (););
      
      let _ = parmap
        (fun input_filename -> 
          let input_path  = src_dir^"/"^input_filename in
          let output_filename = (Filename.chop_extension input_filename)^".json" in
          let output_path = dst_dir^"/"^output_filename in
          Printf.printf "From %s to %s\n" input_path output_path;
          let track = track_of_gpx (Xml.parse_file input_path) in
          geojson_to_file output_path (geojson_of_simple_track track);
        )
        input_filenames
      in
      ()
  | "tdrive2gpx" ->
    let src_file = argv.(2) in
    let dst_file = argv.(3) in
    gpx_of_tdrive src_file dst_file;
    ()
  | _ -> failwith "Not a valid command"





let _ = main ()

