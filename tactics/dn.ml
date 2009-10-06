(* -*- compile-command: "make -C .. bin/coqtop.byte" -*- *)
(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id: dn.ml 11282 2008-07-28 11:51:53Z msozeau $ *)

(* This file implements the basic structure of what Chet called
   ``discrimination nets''. If my understanding is right, it serves
   to associate actions (for example, tactics) with a priority to term
   patterns, so that if a hypothesis matches a pattern in the net,
   then the associated tactic is applied. Discrimination nets are used
   (only) to implement the tactics Auto, DHyp and Point.

   A discrimination net is a tries structure, that is, a tree structure 
   specially conceived for searching patterns, like for example strings
   --see the file Tlm.ml in the directory lib/util--. Here the tries
   structure are used for looking for term patterns.

   This module is then used in :
     - termdn.ml   (discrimination nets of terms);
     - btermdn.ml  (discrimination nets of terms with bounded depth,
                    used in the tactic auto);
     - nbtermdn.ml (named discrimination nets with bounded depth, used
                    in the tactics Dhyp and Point).
  Eduardo (4/8/97) *)

(* Definition of the basic structure *)

type ('lbl,'pat) decompose_fun = 'pat -> ('lbl * 'pat list) option

type 'res lookup_res = Label of 'res | Nothing | Everything
    
type ('lbl,'tree) lookup_fun = 'tree -> ('lbl * 'tree list) lookup_res

type ('lbl,'pat,'inf) t = (('lbl * int) option,'pat * 'inf) Tlm.t

let create () = Tlm.empty

(* [path_of dna pat] returns the list of nodes of the pattern [pat] read in 
prefix ordering, [dna] is the function returning the main node of a pattern *)

let path_of dna =
  let rec path_of_deferred = function
    | [] -> []
    | h::tl -> pathrec tl h
	    
  and pathrec deferred t =
    match dna t with
    | None -> 
	None :: (path_of_deferred deferred)
    | Some (lbl,[]) ->
	(Some (lbl,0))::(path_of_deferred deferred)
    | Some (lbl,(h::def_subl as v)) ->
	(Some (lbl,List.length v))::(pathrec (def_subl@deferred) h)
  in 
  pathrec []
    
let tm_of tm lbl =
  try [Tlm.map tm lbl, true] with Not_found -> []
    
let rec skip_arg n tm =
  if n = 0 then [tm,true]
  else
    List.flatten 
      (List.map 
	  (fun a -> match a with
	  | None -> skip_arg (pred n) (Tlm.map tm a)
	  | Some (lbl,m) -> 
	      skip_arg (pred n + m) (Tlm.map tm a)) 
	  (Tlm.dom tm))
      
let lookup tm dna t =
  let rec lookrec t tm =
    match dna t with
    | Nothing -> tm_of tm None
    | Label(lbl,v) ->
	tm_of tm None@
	  (List.fold_left 
	      (fun l c -> 
		List.flatten(List.map (fun (tm, b) ->
		  if b then lookrec c tm
		  else [tm,b]) l))
              (tm_of tm (Some(lbl,List.length v))) v)
    | Everything -> skip_arg 1 tm
  in 
    List.flatten (List.map (fun (tm,b) -> Tlm.xtract tm) (lookrec t tm))

let add tm dna (pat,inf) =
  let p = path_of dna pat in Tlm.add tm (p,(pat,inf))
    
let rmv tm dna (pat,inf) =
  let p = path_of dna pat in Tlm.rmv tm (p,(pat,inf))
    
let app f tm = Tlm.app (fun (_,p) -> f p) tm

