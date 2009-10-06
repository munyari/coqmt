(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id: auto.ml 12187 2009-06-13 19:36:59Z msozeau $ *)

open Pp
open Util
open Names
open Nameops
open Term
open Termops
open Sign
open Environ
open Inductive
open Evd
open Reduction
open Typing
open Pattern
open Matching
open Tacmach
open Proof_type
open Pfedit
open Rawterm
open Evar_refiner
open Tacred
open Tactics
open Tacticals
open Clenv
open Hiddentac
open Libnames
open Nametab
open Libobject
open Library
open Printer
open Declarations
open Tacexpr
open Mod_subst

(****************************************************************************)
(*            The Type of Constructions Autotactic Hints                    *)
(****************************************************************************)

type auto_tactic = 
  | Res_pf     of constr * clausenv (* Hint Apply *)
  | ERes_pf    of constr * clausenv (* Hint EApply *)
  | Give_exact of constr                  
  | Res_pf_THEN_trivial_fail of constr * clausenv (* Hint Immediate *)
  | Unfold_nth of evaluable_global_reference       (* Hint Unfold *)
  | Extern     of glob_tactic_expr       (* Hint Extern *) 

type pri_auto_tactic = { 
  pri  : int;            (* A number between 0 and 4, 4 = lower priority *)
  pat  : constr_pattern option; (* A pattern for the concl of the Goal *)
  code : auto_tactic     (* the tactic to apply when the concl matches pat *)
}

type hint_entry = global_reference option * pri_auto_tactic

let pri_ord {pri=pri1} {pri=pri2} = pri1 - pri2

let pri_order {pri=pri1} {pri=pri2} = pri1 <= pri2

let insert v l = 
  let rec insrec = function
    | [] -> [v]
    | h::tl -> if pri_order v h then v::h::tl else h::(insrec tl)
  in 
  insrec l

(* Nov 98 -- Papageno *)
(* Les Hints sont r�-organis�s en plusieurs databases. 

  La table imp�rative "searchtable", de type "hint_db_table",
   associe une database (hint_db) � chaque nom.

  Une hint_db est une table d'association fonctionelle constr -> search_entry
  Le constr correspond � la constante de t�te de la conclusion.

  Une search_entry est un triplet comprenant :
     - la liste des tactiques qui n'ont pas de pattern associ�
     - la liste des tactiques qui ont un pattern
     - un discrimination net born� (Btermdn.t) constitu� de tous les
       patterns de la seconde liste de tactiques *)

type stored_data = pri_auto_tactic

type search_entry = stored_data list * stored_data list * stored_data Btermdn.t

let empty_se = ([],[],Btermdn.create ())

let add_tac pat t st (l,l',dn) =
  match pat with
  | None -> if not (List.mem t l) then (insert t l, l', dn) else (l, l', dn)
  | Some pat -> if not (List.mem t l') then (l, insert t l', Btermdn.add st dn (pat,t)) else (l, l', dn)

let rebuild_dn st (l,l',dn) =
  (l, l', List.fold_left (fun dn t -> Btermdn.add (Some st) dn (Option.get t.pat, t))
    (Btermdn.create ()) l')
    
let lookup_tacs (hdc,c) st (l,l',dn) =
  let l'  = List.map snd (Btermdn.lookup st dn c) in
  let sl' = Sort.list pri_order l' in
    Sort.merge pri_order l sl'

module Constr_map = Map.Make(struct 
			       type t = global_reference
			       let compare = Pervasives.compare 
			     end)

let is_transparent_gr (ids, csts) = function
  | VarRef id -> Idpred.mem id ids
  | ConstRef cst -> Cpred.mem cst csts
  | IndRef _ | ConstructRef _ -> false
      
let fmt_autotactic =
  function
  | Res_pf (c,clenv) -> (str"apply " ++ pr_lconstr c)
  | ERes_pf (c,clenv) -> (str"eapply " ++ pr_lconstr c)
  | Give_exact c -> (str"exact " ++ pr_lconstr c)
  | Res_pf_THEN_trivial_fail (c,clenv) -> 
      (str"apply " ++ pr_lconstr c ++ str" ; trivial")
  | Unfold_nth c -> (str"unfold " ++  pr_evaluable_reference c)
  | Extern tac -> 
      (str "(external) " ++ Pptactic.pr_glob_tactic (Global.env()) tac)

let pr_autotactic = fmt_autotactic

module Hint_db = struct

  type t = { 
    hintdb_state : Names.transparent_state;
    use_dn : bool;
    hintdb_map : search_entry Constr_map.t;
    (* A list of unindexed entries starting with an unfoldable constant
       or with no associated pattern. *)
    hintdb_nopat : stored_data list
  }

  let empty st use_dn = { hintdb_state = st;
			  use_dn = use_dn;
			  hintdb_map = Constr_map.empty;
			  hintdb_nopat = [] }
    
  let find key db =
    try Constr_map.find key db.hintdb_map
    with Not_found -> empty_se
      
  let map_none db = 
    Sort.merge pri_order db.hintdb_nopat []
      
  let map_all k db =
    let (l,l',_) = find k db in
      Sort.merge pri_order (db.hintdb_nopat @ l) l'

  let map_auto (k,c) db =
    let st = if db.use_dn then Some db.hintdb_state else None in
    let l' = lookup_tacs (k,c) st (find k db) in
      Sort.merge pri_order db.hintdb_nopat l'
	
  let is_exact = function 
    | Give_exact _ -> true
    | _ -> false

  let rebuild_db st' db = 
    { db with hintdb_map = Constr_map.map (rebuild_dn st') db.hintdb_map }

  let add_one (k,v) db =
    let st',rebuild =
      match v.code with
      | Unfold_nth egr ->
	  let (ids,csts) = db.hintdb_state in
	    (match egr with
	    | EvalVarRef id -> (Idpred.add id ids, csts)
	    | EvalConstRef cst -> (ids, Cpred.add cst csts)), true
      | _ -> db.hintdb_state, false
    in
    let dnst, db, k =
      if db.use_dn then
	let db', k' = 
	  if rebuild then rebuild_db st' db, k
	  else (* not an unfold *)
	    (match k with
	    | Some gr -> db, if is_transparent_gr st' gr then None else k
	    | None -> db, None)
	in
	  (Some st', db', k')
      else None, db, k
    in
    let pat = if not db.use_dn && is_exact v.code then None else v.pat in
      match k with
      | None ->
	  if not (List.mem v db.hintdb_nopat) then
	    { db with hintdb_nopat = v :: db.hintdb_nopat }
	  else db
      | Some gr ->
	  let oval = find gr db in
	    { db with hintdb_map = Constr_map.add gr (add_tac pat v dnst oval) db.hintdb_map;
	      hintdb_state = st' }
	
  let add_list l db = List.fold_right add_one l db
    
  let iter f db = 
    f None db.hintdb_nopat;
    Constr_map.iter (fun k (l,l',_) -> f (Some k) (l@l')) db.hintdb_map
    
  let transparent_state db = db.hintdb_state

  let set_transparent_state db st =
    let db = if db.use_dn then rebuild_db st db else db in
      { db with hintdb_state = st }

  let use_dn db = db.use_dn
	
end

module Hintdbmap = Gmap

type hint_db = Hint_db.t

type frozen_hint_db_table = (string,hint_db) Hintdbmap.t 

type hint_db_table = (string,hint_db) Hintdbmap.t ref

type hint_db_name = string

let searchtable = (ref Hintdbmap.empty : hint_db_table)
  
let searchtable_map name = 
  Hintdbmap.find name !searchtable
let searchtable_add (name,db) = 
  searchtable := Hintdbmap.add name db !searchtable
let current_db_names () =
  Hintdbmap.dom !searchtable

(**************************************************************************)
(*                       Definition of the summary                        *)
(**************************************************************************)

let auto_init : (unit -> unit) ref = ref (fun () -> ())
  
let init     () = searchtable := Hintdbmap.empty; !auto_init ()
let freeze   () = !searchtable
let unfreeze fs = searchtable := fs

let _ = Summary.declare_summary "search"
	  { Summary.freeze_function   = freeze;
	    Summary.unfreeze_function = unfreeze;
	    Summary.init_function     = init;
	    Summary.survive_module = false;
	    Summary.survive_section   = false }

 
(**************************************************************************)
(*             Auxiliary functions to prepare AUTOHINT objects            *)
(**************************************************************************)

let rec nb_hyp c = match kind_of_term c with
  | Prod(_,_,c2) -> if noccurn 1 c2 then 1+(nb_hyp c2) else nb_hyp c2
  | _ -> 0 

(* adding and removing tactics in the search table *)

let try_head_pattern c = 
  try head_pattern_bound c
  with BoundPattern -> error "Bound head variable."

let dummy_goal = 
  {it = make_evar empty_named_context_val mkProp;
   sigma = empty}

let make_exact_entry pri (c,cty) =
  let cty = strip_outer_cast cty in
  match kind_of_term cty with
    | Prod (_,_,_) -> 
	failwith "make_exact_entry"
    | _ ->
        let ce = mk_clenv_from dummy_goal (c,cty) in
	let c' = clenv_type ce in
	let pat = Pattern.pattern_of_constr c' in
	(Some (head_of_constr_reference (fst (head_constr cty))),
	   { pri=(match pri with Some pri -> pri | None -> 0); pat=Some pat; code=Give_exact c })

let make_apply_entry env sigma (eapply,hnf,verbose) pri (c,cty) =
  let cty = if hnf then hnf_constr env sigma cty else cty in
    match kind_of_term cty with
    | Prod _ ->
        let ce = mk_clenv_from dummy_goal (c,cty) in
	let c' = clenv_type ce in
	let pat = Pattern.pattern_of_constr c' in
        let hd = (try head_pattern_bound pat
          with BoundPattern -> failwith "make_apply_entry") in
        let nmiss = List.length (clenv_missing ce) in
	if nmiss = 0 then 
	  (Some hd,
          { pri = (match pri with None -> nb_hyp cty | Some p -> p);
            pat = Some pat;
            code = Res_pf(c,{ce with env=empty_env}) })
	else begin
	  if not eapply then failwith "make_apply_entry";
          if verbose then
	    warn (str "the hint: eapply " ++ pr_lconstr c ++
	    str " will only be used by eauto");
          (Some hd,
            { pri = (match pri with None -> nb_hyp cty + nmiss | Some p -> p);
              pat = Some pat;
              code = ERes_pf(c,{ce with env=empty_env}) })
        end
    | _ -> failwith "make_apply_entry"
 
(* flags is (e,h,v) with e=true if eapply and h=true if hnf and v=true if verbose 
   c is a constr
   cty is the type of constr *)

let make_resolves env sigma flags pri c =
  let cty = type_of env sigma c in
  let ents = 
    map_succeed 
      (fun f -> f (c,cty)) 
      [make_exact_entry pri; make_apply_entry env sigma flags pri]
  in 
  if ents = [] then
    errorlabstrm "Hint" 
      (pr_lconstr c ++ spc() ++ 
        (if pi1 flags then str"cannot be used as a hint."
	else str "can be used as a hint only for eauto."));
  ents

(* used to add an hypothesis to the local hint database *)
let make_resolve_hyp env sigma (hname,_,htyp) = 
  try
    [make_apply_entry env sigma (true, true, false) None
       (mkVar hname, htyp)]
  with 
    | Failure _ -> []
    | e when Logic.catchable_exception e -> anomaly "make_resolve_hyp"

(* REM : in most cases hintname = id *)
let make_unfold (ref, eref) =
  (Some ref,
   { pri = 4;
     pat = None;
     code = Unfold_nth eref })

let make_extern pri pat tacast = 
  let hdconstr = Option.map try_head_pattern pat in 
  (hdconstr,
   { pri=pri;
     pat = pat;
     code= Extern tacast })

let make_trivial env sigma c =
  let t = hnf_constr env sigma (type_of env sigma c) in
  let hd = head_of_constr_reference (fst (head_constr t)) in
  let ce = mk_clenv_from dummy_goal (c,t) in
  (Some hd, { pri=1;
         pat = Some (Pattern.pattern_of_constr (clenv_type ce));
         code=Res_pf_THEN_trivial_fail(c,{ce with env=empty_env}) })

open Vernacexpr

(**************************************************************************)
(*               declaration of the AUTOHINT library object               *)
(**************************************************************************)

(* If the database does not exist, it is created *)
(* TODO: should a warning be printed in this case ?? *)
let add_hint dbname hintlist = 
  try 
    let db = searchtable_map dbname in
    let db' = Hint_db.add_list hintlist db in
    searchtable_add (dbname,db')
  with Not_found -> 
    let db = Hint_db.add_list hintlist (Hint_db.empty empty_transparent_state false) in
    searchtable_add (dbname,db)

let add_transparency dbname grs b =
  let db = searchtable_map dbname in
  let st = Hint_db.transparent_state db in
  let st' = 
    List.fold_left (fun (ids, csts) gr -> 
      match gr with
      | EvalConstRef c -> (ids, (if b then Cpred.add else Cpred.remove) c csts)
      | EvalVarRef v -> (if b then Idpred.add else Idpred.remove) v ids, csts)
      st grs
  in searchtable_add (dbname, Hint_db.set_transparent_state db st')
    
type hint_action = | CreateDB of bool * transparent_state
		   | AddTransparency of evaluable_global_reference list * bool
		   | AddTactic of (global_reference option * pri_auto_tactic) list

let cache_autohint (_,(local,name,hints)) = 
  match hints with
  | CreateDB (b, st) -> searchtable_add (name, Hint_db.empty st b)
  | AddTransparency (grs, b) -> add_transparency name grs b
  | AddTactic hints -> add_hint name hints

let forward_subst_tactic = 
  ref (fun _ -> failwith "subst_tactic is not installed for auto")

let set_extern_subst_tactic f = forward_subst_tactic := f

let subst_autohint (_,subst,(local,name,hintlist as obj)) = 
  let trans_clenv clenv = Clenv.subst_clenv subst clenv in
  let trans_data data code = 	      
    { data with
	pat = Option.smartmap (subst_pattern subst) data.pat ;
	code = code ;
    }
  in
  let subst_key gr =
    let (lab'', elab') = subst_global subst gr in
    let gr' = 
      (try head_of_constr_reference (fst (head_constr_bound elab'))
       with Tactics.Bound -> lab'')
    in if gr' == gr then gr else gr'
  in
  let subst_hint (k,data as hint) =
    let k' = Option.smartmap subst_key k in
    let data' = match data.code with
      | Res_pf (c, clenv) ->
	  let c' = subst_mps subst c in
	    if c==c' then data else
	      trans_data data (Res_pf (c', trans_clenv clenv))
      | ERes_pf (c, clenv) ->
	  let c' = subst_mps subst c in
	    if c==c' then data else
	      trans_data data (ERes_pf (c', trans_clenv clenv))
      | Give_exact c ->
	  let c' = subst_mps subst c in
	    if c==c' then data else
	      trans_data data (Give_exact c')
      | Res_pf_THEN_trivial_fail (c, clenv) ->
	  let c' = subst_mps subst c in
	    if c==c' then data else
	      let code' = Res_pf_THEN_trivial_fail (c', trans_clenv clenv) in
		trans_data data code'
      | Unfold_nth ref -> 
          let ref' = subst_evaluable_reference subst ref in
           if ref==ref' then data else
	    trans_data data (Unfold_nth ref')
      | Extern tac ->
	  let tac' = !forward_subst_tactic subst tac in
	    if tac==tac' then data else
	      trans_data data (Extern tac')
    in
      if k' == k && data' == data then hint else
	(k',data')
  in
    match hintlist with
    | CreateDB _ -> obj
    | AddTransparency (grs, b) -> 
	let grs' = list_smartmap (subst_evaluable_reference subst) grs in
	  if grs==grs' then obj else (local, name, AddTransparency (grs', b))
    | AddTactic hintlist ->
	let hintlist' = list_smartmap subst_hint hintlist in
	  if hintlist' == hintlist then obj else
	    (local,name,AddTactic hintlist')
	      
let classify_autohint (_,((local,name,hintlist) as obj)) =
  if local or hintlist = (AddTactic []) then Dispose else Substitute obj

let export_autohint ((local,name,hintlist) as obj) =
  if local then None else Some obj

let (inAutoHint,outAutoHint) =
  declare_object {(default_object "AUTOHINT") with
                    cache_function = cache_autohint;
		    load_function = (fun _ -> cache_autohint);
		    subst_function = subst_autohint;
		    classify_function = classify_autohint;
                    export_function = export_autohint }


let create_hint_db l n st b = 
  Lib.add_anonymous_leaf (inAutoHint (l,n,CreateDB (b, st)))
      
(**************************************************************************)
(*                     The "Hint" vernacular command                      *)
(**************************************************************************)
let add_resolves env sigma clist local dbnames =
  List.iter
    (fun dbname ->
       Lib.add_anonymous_leaf
	 (inAutoHint
	    (local,dbname, AddTactic
     	      (List.flatten (List.map (fun (x, hnf, y) ->
		make_resolves env sigma (true,hnf,Flags.is_verbose()) x y) clist)))))
    dbnames


let add_unfolds l local dbnames =
  List.iter 
    (fun dbname -> Lib.add_anonymous_leaf 
       (inAutoHint (local,dbname, AddTactic (List.map make_unfold l))))
    dbnames

let add_transparency l b local dbnames =
  List.iter 
    (fun dbname -> Lib.add_anonymous_leaf 
       (inAutoHint (local,dbname, AddTransparency (l, b))))
    dbnames

let add_extern pri pat tacast local dbname =
  (* We check that all metas that appear in tacast have at least
     one occurence in the left pattern pat *)
  let tacmetas = [] in
    match pat with
    | Some (patmetas,pat) ->
	(match (list_subtract tacmetas patmetas) with
	| i::_ ->
	    errorlabstrm "add_extern" 
	      (str "The meta-variable ?" ++ pr_patvar i ++ str" is not bound.")
	| []  ->
	    Lib.add_anonymous_leaf
	      (inAutoHint(local,dbname, AddTactic [make_extern pri (Some pat) tacast])))
    | None -> 
	Lib.add_anonymous_leaf
	  (inAutoHint(local,dbname, AddTactic [make_extern pri None tacast]))

let add_externs pri pat tacast local dbnames = 
  List.iter (add_extern pri pat tacast local) dbnames

let add_trivials env sigma l local dbnames =
  List.iter
    (fun dbname ->
       Lib.add_anonymous_leaf (
	 inAutoHint(local,dbname, AddTactic (List.map (make_trivial env sigma) l))))
    dbnames

let forward_intern_tac = 
  ref (fun _ -> failwith "intern_tac is not installed for auto")

let set_extern_intern_tac f = forward_intern_tac := f

let add_hints local dbnames0 h =
  let dbnames = if dbnames0 = [] then ["core"] else dbnames0 in
  let env = Global.env() and sigma = Evd.empty in
  let f = Constrintern.interp_constr sigma env in
  match h with
  | HintsResolve lhints ->	
      add_resolves env sigma (List.map (fun (pri, b, x) -> pri, b, f x) lhints) local dbnames
  | HintsImmediate lhints ->
      add_trivials env sigma (List.map f lhints) local dbnames
  | HintsUnfold lhints ->
      let f r =
	let gr = Syntax_def.global_with_alias r in
        let r' = match gr with
         | ConstRef c -> EvalConstRef c
         | VarRef c -> EvalVarRef c
         | _ -> 
           errorlabstrm "evalref_of_ref"
            (str "Cannot coerce" ++ spc () ++ pr_global gr ++ spc () ++
             str "to an evaluable reference.")
        in
	  Dumpglob.add_glob (loc_of_reference r) gr;
	 (gr,r') in
      add_unfolds (List.map f lhints) local dbnames
 | HintsTransparency (lhints, b) ->
      let f r =
	let gr = Syntax_def.global_with_alias r in
        let r' = match gr with
         | ConstRef c -> EvalConstRef c
         | VarRef c -> EvalVarRef c
         | _ -> 
           errorlabstrm "evalref_of_ref"
            (str "Cannot coerce" ++ spc () ++ pr_global gr ++ spc () ++
             str "to an evaluable reference.")
        in
	  Dumpglob.add_glob (loc_of_reference r) gr;
	  r' in
      add_transparency (List.map f lhints) b local dbnames
  | HintsConstructors lqid ->
      let add_one qid =
        let env = Global.env() and sigma = Evd.empty in
        let isp = inductive_of_reference qid in
        let consnames = (snd (Global.lookup_inductive isp)).mind_consnames in
        let lcons = list_tabulate
          (fun i -> None, true, mkConstruct (isp,i+1)) (Array.length consnames) in
        add_resolves env sigma lcons local dbnames in
      List.iter add_one lqid
  | HintsExtern (pri, patcom, tacexp) ->
      let pat =	Option.map (Constrintern.intern_constr_pattern Evd.empty (Global.env())) patcom in
      let tacexp = !forward_intern_tac (match pat with None -> [] | Some (l, _) -> l) tacexp in
      add_externs pri pat tacexp local dbnames
  | HintsDestruct(na,pri,loc,pat,code) ->
      if dbnames0<>[] then
        warn (str"Database selection not implemented for destruct hints");
      Dhyp.add_destructor_hint local na loc pat pri code

(**************************************************************************)
(*                    Functions for printing the hints                    *)
(**************************************************************************)

let pr_autotactic =
  function
  | Res_pf (c,clenv) -> (str"apply " ++ pr_lconstr c)
  | ERes_pf (c,clenv) -> (str"eapply " ++ pr_lconstr c)
  | Give_exact c -> (str"exact " ++ pr_lconstr c)
  | Res_pf_THEN_trivial_fail (c,clenv) -> 
      (str"apply " ++ pr_lconstr c ++ str" ; trivial")
  | Unfold_nth c -> (str"unfold " ++  pr_evaluable_reference c)
  | Extern tac -> 
      (str "(external) " ++ Pptactic.pr_glob_tactic (Global.env()) tac)

let pr_hint v =
  (pr_autotactic v.code ++ str"(" ++ int v.pri ++ str")" ++ spc ())

let pr_hint_list hintlist =
  (str "  " ++ hov 0 (prlist pr_hint hintlist) ++ fnl ())

let pr_hints_db (name,db,hintlist) =
  (str "In the database " ++ str name ++ str ":" ++
     if hintlist = [] then (str " nothing" ++ fnl ())
     else (fnl () ++ pr_hint_list hintlist))

(* Print all hints associated to head c in any database *)
let pr_hint_list_for_head c = 
  let dbs = Hintdbmap.to_list !searchtable in
  let valid_dbs = 
    map_succeed 
      (fun (name,db) -> (name,db,Hint_db.map_all c db)) 
      dbs 
  in
  if valid_dbs = [] then 
    (str "No hint declared for :" ++ pr_global c)
  else 
    hov 0 
      (str"For " ++ pr_global c ++ str" -> " ++ fnl () ++
	 hov 0 (prlist pr_hints_db valid_dbs))

let pr_hint_ref ref = pr_hint_list_for_head ref

(* Print all hints associated to head id in any database *)
let print_hint_ref ref =  ppnl(pr_hint_ref ref)

let pr_hint_term cl = 
  try 
    let dbs = Hintdbmap.to_list !searchtable in
    let valid_dbs = 
      let fn = try 
	  let (hdc,args) = head_constr_bound cl in
	  let hd = head_of_constr_reference hdc in
	    if occur_existential cl then
	      Hint_db.map_all hd
	    else Hint_db.map_auto (hd, applist (hdc,args))
	with Bound -> Hint_db.map_none
      in
	map_succeed (fun (name, db) -> (name, db, fn db)) dbs
    in
      if valid_dbs = [] then 
	(str "No hint applicable for current goal")
      else
	(str "Applicable Hints :" ++ fnl () ++
	    hov 0 (prlist pr_hints_db valid_dbs))
  with Match_failure _ | Failure _ -> 
    (str "No hint applicable for current goal")

let error_no_such_hint_database x =
  error ("No such Hint database: "^x^".")
	  
let print_hint_term cl = ppnl (pr_hint_term cl)

(* print all hints that apply to the concl of the current goal *)
let print_applicable_hint () = 
  let pts = get_pftreestate () in 
  let gl = nth_goal_of_pftreestate 1 pts in 
  print_hint_term (pf_concl gl)
    
(* displays the whole hint database db *)
let print_hint_db db =
  let (ids, csts) = Hint_db.transparent_state db in
  msg (hov 0
	  (str"Unfoldable variable definitions: " ++ pr_idpred ids ++ fnl () ++
	   str"Unfoldable constant definitions: " ++ pr_cpred csts ++ fnl ()));
  Hint_db.iter 
    (fun head hintlist ->
      match head with
      | Some head ->
	  msg (hov 0 
		  (str "For " ++ pr_global head ++ str " -> " ++
		      pr_hint_list hintlist))
      | None ->
	  msg (hov 0 
		  (str "For any goal -> " ++
		      pr_hint_list hintlist)))
    db

let print_hint_db_by_name dbname =
  try 
    let db = searchtable_map dbname in print_hint_db db
  with Not_found -> 
    error_no_such_hint_database dbname
  
(* displays all the hints of all databases *)
let print_searchtable () =
  Hintdbmap.iter
    (fun name db ->
       msg (str "In the database " ++ str name ++ str ":" ++ fnl ());
       print_hint_db db)
    !searchtable

(**************************************************************************)
(*                           Automatic tactics                            *)
(**************************************************************************)

(**************************************************************************)
(*          tactics with a trace mechanism for automatic search           *)
(**************************************************************************)

let priority l = List.filter (fun (_,hint) -> hint.pri = 0) l

let select_unfold_extern =
  List.filter (function (_,{code = (Unfold_nth _ | Extern _)}) -> true | _ -> false)

(* tell auto not to reuse already instantiated metas in unification (for
   compatibility, since otherwise, apply succeeds oftener) *)

open Unification

let auto_unif_flags = {
  modulo_conv_on_closed_terms = Some full_transparent_state; 
  use_metas_eagerly = false;
  modulo_delta = empty_transparent_state;
}

(* Try unification with the precompiled clause, then use registered Apply *)

let unify_resolve_nodelta (c,clenv) gl = 
  let clenv' = connect_clenv gl clenv in
  let _ = clenv_unique_resolver false ~flags:auto_unif_flags clenv' gl in  
  h_simplest_apply c gl

let unify_resolve flags (c,clenv) gl = 
  let clenv' = connect_clenv gl clenv in
  let _ = clenv_unique_resolver false ~flags clenv' gl in  
  h_apply true false [inj_open c,NoBindings] gl

let unify_resolve_gen = function
  | None -> unify_resolve_nodelta
  | Some flags -> unify_resolve flags

(* builds a hint database from a constr signature *)
(* typically used with (lid, ltyp) = pf_hyps_types <some goal> *)

let add_hint_lemmas eapply lems hint_db gl =
  let hintlist' = 
    list_map_append (pf_apply make_resolves gl (eapply,true,false) None) lems in
  Hint_db.add_list hintlist' hint_db

let make_local_hint_db eapply lems gl =
  let sign = pf_hyps gl in
  let hintlist = list_map_append (pf_apply make_resolve_hyp gl) sign in
  add_hint_lemmas eapply lems
    (Hint_db.add_list hintlist (Hint_db.empty empty_transparent_state false)) gl

(* Serait-ce possible de compiler d'abord la tactique puis de faire la
   substitution sans passer par bdize dont l'objectif est de pr�parer un
   terme pour l'affichage ? (HH) *)

(* Si on enl�ve le dernier argument (gl) conclPattern est calcul� une
fois pour toutes : en particulier si Pattern.somatch produit une UserError 
Ce qui fait que si la conclusion ne matche pas le pattern, Auto �choue, m�me
si apr�s Intros la conclusion matche le pattern.
*)

(* conclPattern doit �chouer avec error car il est rattraper par tclFIRST *)

let forward_interp_tactic = 
  ref (fun _ -> failwith "interp_tactic is not installed for auto")

let set_extern_interp f = forward_interp_tactic := f

let conclPattern concl pat tac gl =
  let constr_bindings = 
    match pat with 
    | None -> []
    | Some pat ->
	try matches pat concl
	with PatternMatchingFailure -> error "conclPattern" in
    !forward_interp_tactic constr_bindings tac gl

(**************************************************************************)
(*                           The Trivial tactic                           *)
(**************************************************************************)

(* local_db is a Hint database containing the hypotheses of current goal *)
(* Papageno : cette fonction a �t� pas mal simplifi�e depuis que la base
  de Hint imp�rative a �t� remplac�e par plusieurs bases fonctionnelles *)

let flags_of_state st =
  {auto_unif_flags with 
    modulo_conv_on_closed_terms = Some st; modulo_delta = st}

let hintmap_of hdc concl =
  match hdc with
  | None -> Hint_db.map_none
  | Some hdc ->
      if occur_existential concl then Hint_db.map_all hdc
      else Hint_db.map_auto (hdc,concl)
	
let rec trivial_fail_db mod_delta db_list local_db gl =
  let intro_tac = 
    tclTHEN intro 
      (fun g'->
	 let hintl = make_resolve_hyp (pf_env g') (project g') (pf_last_hyp g')
	 in trivial_fail_db mod_delta db_list (Hint_db.add_list hintl local_db) g')
  in
  tclFIRST 
    (assumption::intro_tac::
     (List.map tclCOMPLETE 
       (trivial_resolve mod_delta db_list local_db (pf_concl gl)))) gl

and my_find_search_nodelta db_list local_db hdc concl =
  List.map (fun hint -> (None,hint)) 
    (list_map_append (hintmap_of hdc concl) (local_db::db_list))

and my_find_search mod_delta =
  if mod_delta then my_find_search_delta
  else my_find_search_nodelta
    
and my_find_search_delta db_list local_db hdc concl =
  let flags = {auto_unif_flags with use_metas_eagerly = true} in
  let f = hintmap_of hdc concl in
    if occur_existential concl then 
      list_map_append
	(fun db -> 
	  if Hint_db.use_dn db then 
	    let flags = flags_of_state (Hint_db.transparent_state db) in
	      List.map (fun x -> (Some flags,x)) (f db)
	  else
	    let flags = {flags with modulo_delta = Hint_db.transparent_state db} in
	      List.map (fun x -> (Some flags,x)) (f db))
	(local_db::db_list)
    else
      list_map_append (fun db -> 
	if Hint_db.use_dn db then 
	  let flags = flags_of_state (Hint_db.transparent_state db) in
	    List.map (fun x -> (Some flags, x)) (f db)
	else
	  let (ids, csts as st) = Hint_db.transparent_state db in
	  let flags, l =
	    let l =
	      match hdc with None -> Hint_db.map_none db
	      | Some hdc ->
		  if (Idpred.is_empty ids && Cpred.is_empty csts)
		  then Hint_db.map_auto (hdc,concl) db
		  else Hint_db.map_all hdc db
	    in {flags with modulo_delta = st}, l
	  in List.map (fun x -> (Some flags,x)) l)
      	(local_db::db_list)

and tac_of_hint db_list local_db concl (flags, {pat=p; code=t}) =
  match t with
  | Res_pf (term,cl) -> unify_resolve_gen flags (term,cl)
  | ERes_pf (_,c) -> (fun gl -> error "eres_pf")
  | Give_exact c  -> exact_check c
  | Res_pf_THEN_trivial_fail (term,cl) -> 
      tclTHEN 
        (unify_resolve_gen flags (term,cl))
        (trivial_fail_db (flags <> None) db_list local_db)
  | Unfold_nth c -> unfold_in_concl [all_occurrences,c]
  | Extern tacast -> conclPattern concl p tacast
      
and trivial_resolve mod_delta db_list local_db cl = 
  try 
    let head = 
      try let hdconstr,_ = head_constr_bound cl in
	    Some (head_of_constr_reference hdconstr)
      with Bound -> None
    in
      List.map (tac_of_hint db_list local_db cl)
	(priority 
	    (my_find_search mod_delta db_list local_db head cl))
  with Not_found -> []

let trivial lems dbnames gl =
  let db_list = 
    List.map
      (fun x -> 
	 try 
	   searchtable_map x
	 with Not_found -> 
	   error_no_such_hint_database x)
      ("core"::dbnames) 
  in
  tclTRY (trivial_fail_db false db_list (make_local_hint_db false lems gl)) gl 
    
let full_trivial lems gl =
  let dbnames = Hintdbmap.dom !searchtable in
  let dbnames = list_subtract dbnames ["v62"] in
  let db_list = List.map (fun x -> searchtable_map x) dbnames in
  tclTRY (trivial_fail_db false db_list (make_local_hint_db false lems gl)) gl

let gen_trivial lems = function
  | None -> full_trivial lems
  | Some l -> trivial lems l

let inj_open c = (Evd.empty,c)

let h_trivial lems l =
  Refiner.abstract_tactic (TacTrivial (List.map inj_open lems,l))
    (gen_trivial lems l)

(**************************************************************************)
(*                       The classical Auto tactic                        *)
(**************************************************************************)

let possible_resolve mod_delta db_list local_db cl =
  try 
    let head = 
      try let hdconstr,_ = head_constr_bound cl in
	    Some (head_of_constr_reference hdconstr)
      with Bound -> None
    in
      List.map (tac_of_hint db_list local_db cl)
	(my_find_search mod_delta db_list local_db head cl)
  with Not_found -> []

let decomp_unary_term_then (id,_,typc) kont1 kont2 gl =
  try
    let ccl = applist (head_constr typc) in
    match Hipattern.match_with_conjunction ccl with
    | Some (_,args) ->
	tclTHEN (simplest_case (mkVar id)) (kont1 (List.length args)) gl
    | None ->
	kont2 gl
  with UserError _ -> kont2 gl

let decomp_empty_term (id,_,typc) gl = 
  if Hipattern.is_empty_type typc then 
    simplest_case (mkVar id) gl 
  else 
    errorlabstrm "Auto.decomp_empty_term" (str "Not an empty type.")

let extend_local_db gl decl db =
  Hint_db.add_list (make_resolve_hyp (pf_env gl) (project gl) decl) db

(* Try to decompose hypothesis [decl] into atomic components of a 
   conjunction with maximum depth [p] (or solve the goal from an 
   empty type) then call the continuation tactic with hint db extended 
   with the obtappined not-further-decomposable hypotheses *)

let rec decomp_and_register_decl p kont (id,_,_ as decl) db gl =
  if p = 0 then
    kont (extend_local_db gl decl db) gl
  else
    tclORELSE0
      (decomp_empty_term decl)
      (decomp_unary_term_then decl (intros_decomp (p-1) kont [] db)
	(kont (extend_local_db gl decl db))) gl

(* Introduce [n] hypotheses, then decompose then with maximum depth [p] and
   call the continuation tactic [kont] with the hint db extended
   with the so-obtained not-further-decomposable hypotheses *)

and intros_decomp p kont decls db n =
  if n = 0 then
    decomp_and_register_decls p kont decls db
  else
    tclTHEN intro (tclLAST_DECL (fun d ->
      (intros_decomp p kont (d::decls) db (n-1))))

(* Decompose hypotheses [hyps] with maximum depth [p] and
   call the continuation tactic [kont] with the hint db extended
   with the so-obtained not-further-decomposable hypotheses *)

and decomp_and_register_decls p kont decls =
  List.fold_left (decomp_and_register_decl p) kont decls


(* decomp is an natural number giving an indication on decomposition 
   of conjunction in hypotheses, 0 corresponds to no decomposition *)
(* n is the max depth of search *)
(* local_db contains the local Hypotheses *)

exception Uplift of tactic list

let rec search_gen p n mod_delta db_list local_db =
  let rec search n local_db gl =
    if n=0 then error "BOUND 2";
    tclFIRST
      (assumption ::
       intros_decomp p (search n) [] local_db 1 ::
       List.map (fun ntac -> tclTHEN ntac (search (n-1) local_db)) 
	(possible_resolve mod_delta db_list local_db (pf_concl gl))) gl
  in
  search n local_db

let search = search_gen 0

let default_search_depth = ref 5

let delta_auto mod_delta n lems dbnames gl =
  let db_list = 
    List.map
      (fun x -> 
	 try 
	   searchtable_map x
	 with Not_found -> 
	   error_no_such_hint_database x)
      ("core"::dbnames) 
  in
  tclTRY (search n mod_delta db_list (make_local_hint_db false lems gl)) gl

let auto = delta_auto false

let new_auto = delta_auto true

let default_auto = auto !default_search_depth [] []

let delta_full_auto mod_delta n lems gl = 
  let dbnames = Hintdbmap.dom !searchtable in
  let dbnames = list_subtract dbnames ["v62"] in
  let db_list = List.map (fun x -> searchtable_map x) dbnames in
  tclTRY (search n mod_delta db_list (make_local_hint_db false lems gl)) gl

let full_auto = delta_full_auto false
let new_full_auto = delta_full_auto true

let default_full_auto gl = full_auto !default_search_depth [] gl

let gen_auto n lems dbnames =
  let n = match n with None -> !default_search_depth | Some n -> n in
  match dbnames with
  | None -> full_auto n lems
  | Some l -> auto n lems l

let inj_or_var = Option.map (fun n -> ArgArg n)

let h_auto n lems l =
  Refiner.abstract_tactic (TacAuto (inj_or_var n,List.map inj_open lems,l))
    (gen_auto n lems l)

(**************************************************************************)
(*                  The "destructing Auto" from Eduardo                   *)
(**************************************************************************)

(* Depth of search after decomposition of hypothesis, by default 
   one look for an immediate solution *) 
let default_search_decomp = ref 20

let destruct_auto p lems n gl = 
  decomp_and_register_decls p (fun local_db gl ->
    search_gen p n false (List.map searchtable_map ["core";"extcore"])
      (add_hint_lemmas false lems local_db gl) gl)
    (pf_hyps gl)
    (Hint_db.empty empty_transparent_state false)
    gl
    
let dautomatic des_opt lems n = tclTRY (destruct_auto des_opt lems n)

let dauto (n,p) lems =
  let p = match p with Some p -> p | None -> !default_search_decomp in
  let n = match n with Some n -> n | None -> !default_search_depth in
  dautomatic p lems n

let default_dauto = dauto (None,None) []

let h_dauto (n,p) lems =
  Refiner.abstract_tactic (TacDAuto (inj_or_var n,p,List.map inj_open lems))
    (dauto (n,p) lems)

(***************************************)
(*** A new formulation of Auto *********)
(***************************************)

let make_resolve_any_hyp env sigma (id,_,ty) =
  let ents = 
    map_succeed
      (fun f -> f (mkVar id,ty)) 
      [make_exact_entry None; make_apply_entry env sigma (true,true,false) None]
  in 
  ents

type autoArguments =
  | UsingTDB       
  | Destructing   

let keepAfter tac1 tac2 = 
  (tclTHEN tac1 
     (function g -> tac2 [pf_last_hyp g] g))

let compileAutoArg contac = function
  | Destructing -> 
      (function g -> 
         let ctx = pf_hyps g in  
	 tclFIRST 
           (List.map 
              (fun (id,_,typ) -> 
                let cl = snd (decompose_prod typ) in
                 if Hipattern.is_conjunction cl
		 then 
		   tclTHENSEQ [simplest_elim (mkVar id); clear [id]; contac] 
                 else 
		   tclFAIL 0 (pr_id id ++ str" is not a conjunction"))
	     ctx) g)
  | UsingTDB ->  
      (tclTHEN  
         (Tacticals.tryAllClauses 
            (function 
               | Some ((_,id),_) -> Dhyp.h_destructHyp false id
               | None          -> Dhyp.h_destructConcl))
         contac)

let compileAutoArgList contac = List.map (compileAutoArg contac)

let rec super_search n db_list local_db argl gl =
  if n = 0 then error "BOUND 2";
  tclFIRST
    (assumption
     ::
     tclTHEN intro 
        (fun g -> 
	   let hintl = pf_apply make_resolve_any_hyp g (pf_last_hyp g) in
	   super_search n db_list (Hint_db.add_list hintl local_db)
	     argl g)
     ::
     List.map (fun ntac -> 
            tclTHEN ntac 
              (super_search (n-1) db_list local_db argl))
         (possible_resolve false db_list local_db (pf_concl gl))
      @
      compileAutoArgList (super_search (n-1) db_list local_db argl) argl) gl

let search_superauto n to_add argl g = 
  let sigma =
    List.fold_right
      (fun (id,c) -> add_named_decl (id, None, pf_type_of g c))
      to_add empty_named_context in
  let db0 = list_map_append (make_resolve_hyp (pf_env g) (project g)) sigma in
  let db = Hint_db.add_list db0 (make_local_hint_db false [] g) in
  super_search n [Hintdbmap.find "core" !searchtable] db argl g

let superauto n to_add argl  = 
  tclTRY (tclCOMPLETE (search_superauto n to_add argl))

let default_superauto g = superauto !default_search_depth [] [] g

let interp_to_add gl r =
  let r = Syntax_def.locate_global_with_alias (qualid_of_reference r) in
  let id = id_of_global r in
  (next_ident_away id (pf_ids_of_hyps gl), constr_of_global r)

let gen_superauto nopt l a b gl =
  let n = match nopt with Some n -> n | None -> !default_search_depth in
  let al = (if a then [Destructing] else [])@(if b then [UsingTDB] else []) in
  superauto n (List.map (interp_to_add gl) l) al gl

let h_superauto no l a b =
  Refiner.abstract_tactic (TacSuperAuto (no,l,a,b)) (gen_superauto no l a b)

