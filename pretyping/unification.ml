(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id: unification.ml 12163 2009-06-06 17:36:47Z herbelin $ *)

open Pp
open Util
open Names
open Nameops
open Term
open Termops
open Sign
open Environ
open Evd
open Reduction
open Reductionops
open Rawterm
open Pattern
open Evarutil
open Pretype_errors
open Retyping
open Coercion.Default

(* if lname_typ is [xn,An;..;x1,A1] and l is a list of terms,
   gives [x1:A1]..[xn:An]c' such that c converts to ([x1:A1]..[xn:An]c' l) *)

let abstract_scheme env c l lname_typ =
  List.fold_left2 
    (fun t (locc,a) (na,_,ta) ->
       let na = match kind_of_term a with Var id -> Name id | _ -> na in
(* [occur_meta ta] test removed for support of eelim/ecase but consequences
   are unclear...
       if occur_meta ta then error "cannot find a type for the generalisation"
       else *) if occur_meta a then lambda_name env (na,ta,t)
       else lambda_name env (na,ta,subst_term_occ locc a t))
    c
    (List.rev l)
    lname_typ

let abstract_list_all env evd typ c l =
  let ctxt,_ = decomp_n_prod env (evars_of evd) (List.length l) typ in
  let l_with_all_occs = List.map (function a -> (all_occurrences,a)) l in
  let p = abstract_scheme env c l_with_all_occs ctxt in 
  try 
    if is_conv_leq env (evars_of evd) (Typing.mtype_of env evd p) typ then p
    else error "abstract_list_all"
  with UserError _ | Type_errors.TypeError _ ->
    error_cannot_find_well_typed_abstraction env (evars_of evd) p l

(**)

(* A refinement of [conv_pb]: the integers tells how many arguments
   were applied in the context of the conversion problem; if the number
   is non zero, steps of eta-expansion will be allowed
*)

type conv_pb_up_to_eta = Cumul | ConvUnderApp of int * int

let topconv = ConvUnderApp (0,0)
let of_conv_pb = function CONV -> topconv | CUMUL -> Cumul
let conv_pb_of = function ConvUnderApp _ -> CONV | Cumul -> CUMUL
let prod_pb = function ConvUnderApp _ -> topconv | pb -> pb

let opp_status = function
  | IsSuperType -> IsSubType
  | IsSubType -> IsSuperType
  | ConvUpToEta _ | UserGiven as x -> x

let add_type_status (x,y) = ((x,TypeNotProcessed),(y,TypeNotProcessed))

let extract_instance_status = function
  | Cumul -> add_type_status (IsSubType, IsSuperType)
  | ConvUnderApp (n1,n2) -> add_type_status (ConvUpToEta n1, ConvUpToEta n2)

let rec assoc_pair x = function
    [] -> raise Not_found
  | (a,b,_)::l -> if compare a x = 0 then b else assoc_pair x l

let rec subst_meta_instances bl c =
  match kind_of_term c with
    | Meta i -> (try assoc_pair i bl with Not_found -> c)
    | _ -> map_constr (subst_meta_instances bl) c

let solve_pattern_eqn_array (env,nb) sigma f l c (metasubst,evarsubst) =
  match kind_of_term f with
    | Meta k -> 
	let c = solve_pattern_eqn env (Array.to_list l) c in
	let n = Array.length l - List.length (fst (decompose_lam c)) in
	let pb = (ConvUpToEta n,TypeNotProcessed) in
	  if noccur_between 1 nb c then
            (k,lift (-nb) c,pb)::metasubst,evarsubst
	  else error_cannot_unify_local env sigma (mkApp (f, l),c,c)
    | Evar ev ->
      (* Currently unused: incompatible with eauto/eassumption backtracking *)
	metasubst,(ev,solve_pattern_eqn env (Array.to_list l) c)::evarsubst
    | _ -> assert false

let push d (env,n) = (push_rel_assum d env,n+1)

(*******************************)

(* Unification � l'ordre 0 de m et n: [unify_0 env sigma cv_pb m n]
   renvoie deux listes:

   metasubst:(int*constr)list    r�colte les instances des (Meta k)
   evarsubst:(constr*constr)list r�colte les instances des (Const "?k")

   Attention : pas d'unification entre les diff�rences instances d'une
   m�me meta ou evar, il peut rester des doublons *)

(* Unification order: *)
(* Left to right: unifies first argument and then the other arguments *)
(*let unify_l2r x = List.rev x
(* Right to left: unifies last argument and then the other arguments *)
let unify_r2l x = x

let sort_eqns = unify_r2l
*)

type unify_flags = { 
  modulo_conv_on_closed_terms : Names.transparent_state option;
  use_metas_eagerly : bool;
  modulo_delta : Names.transparent_state;
  can_dp_delayed : bool;
}

let default_unify_flags = {
  modulo_conv_on_closed_terms = Some full_transparent_state;
  use_metas_eagerly = true;
  modulo_delta = full_transparent_state;
  can_dp_delayed = true;
}

let default_no_delta_unify_flags = {
  modulo_conv_on_closed_terms = Some full_transparent_state;
  use_metas_eagerly = true;
  modulo_delta = empty_transparent_state;
  can_dp_delayed = true;
}

let expand_key env = function
  | Some (ConstKey cst) -> constant_opt_value env cst
  | Some (VarKey id) -> named_body id env
  | Some (RelKey _) -> None
  | None -> None
      
let key_of flags f =
  match kind_of_term f with
  | Const cst when is_transparent (ConstKey cst) &&
        Cpred.mem cst (snd flags.modulo_delta) ->
      Some (ConstKey cst) 
  | Var id when is_transparent (VarKey id) &&
        Idpred.mem id (fst flags.modulo_delta) ->
      Some (VarKey id)
  | _ -> None
      
let oracle_order env cf1 cf2 =
  match cf1 with
  | None ->
      (match cf2 with 
      | None -> None
      | Some k2 -> Some false)
  | Some k1 -> 
      match cf2 with
      | None -> Some true
      | Some k2 -> Some (Conv_oracle.oracle_order k1 k2)

type unif_delayed = {
  ud_unif_pb : constr * constr;
  ud_environ : Environ.env * int;
  ud_cv_pb   : conv_pb_up_to_eta;
  ud_unfold  : bool;
}

type unif_state = {
  us_metasubst : Evd.metabinding list;
  us_evarsubst : (constr pexistential * constr) list;
  us_delayed   : unif_delayed list;
}

let ex_metasubst = fun evd subst ->
  { subst with us_metasubst = evd :: subst.us_metasubst }

let ex_evarsubst = fun x subst ->
  { subst with us_evarsubst = x :: subst.us_evarsubst }

let ex_delayed = fun x subst ->
  { subst with us_delayed = x :: subst.us_delayed }

let ex_to_subst = fun subst ->
  (subst.us_metasubst, subst.us_evarsubst)

let ex_from_subst = fun (metasubst, evarsubst) delayed ->
  { us_metasubst = metasubst;
    us_evarsubst = evarsubst;
    us_delayed   = delayed; }

let trivial_unify =
  fun top_subst top_env sigma conv_at_top flags ->
    fun sub_subst sub_env pb m n ->
      let subst =
        if   flags.use_metas_eagerly
        then fst sub_subst
        else fst top_subst
      in
    match subst_defined_metas subst m with
    | Some m1 ->
	if (match flags.modulo_conv_on_closed_terms with
	    Some flags ->
	      is_trans_fconv (conv_pb_of pb) flags top_env sigma m1 n
	  | None -> false) then true else
        if (not (is_ground_term (create_evar_defs sigma) m1))
            || occur_meta_or_existential n then false else
               error_cannot_unify sub_env sigma (m, n)
    | _ -> false

let delayable = fun env ->
  let bindings = Environ.DP.bindings env in
  let rec entry = fun t ->
    match kind_of_term t with
    | Ind       i     -> Some (Decproc.DPE_Inductive   i)
    | Construct c     -> Some (Decproc.DPE_Constructor c)
    | Const     c     -> Some (Decproc.DPE_Constant    c)
    | App      (t, _) -> entry t
    | _               -> None
  in
    fun t ->
      match entry t with
      | None -> false
      | Some entry -> begin
          match Decproc.Bindings.revbinding_symbol bindings entry with
          | None   -> false
          | Some _ -> true
        end

let unify_0_with_initial_metas =
  fun conv_at_top top_subst top_env top_pb sigma flags m n ->

  let trivial_unify =
    trivial_unify top_subst top_env sigma conv_at_top
  in

  let rec unirec_rec (env, bn as envnb) pb b flags subst curm curn =
    let cM = Evarutil.whd_castappevar sigma curm
    and cN = Evarutil.whd_castappevar sigma curn in 

      if flags.can_dp_delayed then begin
        if (delayable env cM) && (delayable env cN) then
          let delayed = {
            ud_unif_pb = (cM, cN);
            ud_environ = envnb;
            ud_cv_pb   = pb;
            ud_unfold  = b;
          }
          in ex_delayed delayed subst
        else
          unirec_rec_struct envnb pb b flags subst cM cN
      end else
        unirec_rec_struct envnb pb b flags subst cM cN

  and unirec_rec_struct (env,nb as envnb) pb b flags subst cM cN =
      match (kind_of_term cM,kind_of_term cN) with
	| Meta k1, Meta k2 ->
	    let stM,stN = extract_instance_status pb in
	    if k1 < k2 
	    then ex_metasubst (k1,cN,stN) subst
	    else if k1 = k2 then subst
	    else ex_metasubst (k2,cM,stM) subst
	| Meta k, _ when not (dependent cM cN) -> 
	    (* Here we check that [cN] does not contain any local variables *)
	    if nb = 0 then
              ex_metasubst (k,cN,snd (extract_instance_status pb)) subst
            else if noccur_between 1 nb cN then
              ex_metasubst (k,lift (-nb) cN,snd (extract_instance_status pb)) subst
	    else error_cannot_unify_local env sigma (m,n,cN)
	| _, Meta k when not (dependent cN cM) -> 
	    (* Here we check that [cM] does not contain any local variables *)
	    if nb = 0 then
              ex_metasubst (k,cM,snd (extract_instance_status pb)) subst
	    else if noccur_between 1 nb cM
	    then
              ex_metasubst (k,lift (-nb) cM,fst (extract_instance_status pb)) subst
	    else error_cannot_unify_local env sigma (m,n,cM)
	| Evar ev, _ -> ex_evarsubst (ev,cN) subst
	| _, Evar ev -> ex_evarsubst (ev,cM) subst
	| Lambda (na,t1,c1), Lambda (_,t2,c2) ->
            let subst = unirec_rec envnb topconv true flags subst t1 t2 in
	      unirec_rec (push (na,t1) envnb) topconv true flags subst c1 c2
	| Prod (na,t1,c1), Prod (_,t2,c2) ->
            let subst = unirec_rec envnb topconv true flags subst t1 t2 in
              unirec_rec (push (na,t1) envnb) (prod_pb pb) true flags subst c1 c2
	| LetIn (_,a,_,c), _ -> unirec_rec envnb pb b flags subst (subst1 a c) cN
	| _, LetIn (_,a,_,c) -> unirec_rec envnb pb b flags subst cM (subst1 a c)
	    
	| Case (_,p1,c1,cl1), Case (_,p2,c2,cl2) ->
            array_fold_left2 (unirec_rec envnb topconv true flags)
	      (unirec_rec envnb topconv true flags
		  (unirec_rec envnb topconv true flags subst p1 p2) c1 c2) cl1 cl2

	| App (f1,l1), _ when
	    isMeta f1 & is_unification_pattern envnb f1 l1 cN &
	    not (dependent f1 cN) ->
            ex_from_subst
	      (solve_pattern_eqn_array envnb sigma f1 l1 cN (ex_to_subst subst))
              subst.us_delayed

	| _, App (f2,l2) when
	    isMeta f2 & is_unification_pattern envnb f2 l2 cM &
	    not (dependent f2 cM) ->
            ex_from_subst
	      (solve_pattern_eqn_array envnb sigma f2 l2 cM (ex_to_subst subst))
              subst.us_delayed

	| App (f1,l1), App (f2,l2) ->
	      let len1 = Array.length l1
	      and len2 = Array.length l2 in
	      (try
		  let (f1,l1,f2,l2) =
		    if len1 = len2 then (f1,l1,f2,l2)
		    else if len1 < len2 then
		      let extras,restl2 = array_chop (len2-len1) l2 in 
		      (f1, l1, appvect (f2,extras), restl2)
		    else 
		      let extras,restl1 = array_chop (len1-len2) l1 in 
		      (appvect (f1,extras), restl1, f2, l2) in
		  let pb = ConvUnderApp (len1,len2) in
		  array_fold_left2 (unirec_rec envnb topconv true flags)
		    (unirec_rec envnb pb true flags subst f1 f2) l1 l2
		with ex when precatchable_exception ex ->
		  expand envnb pb b flags subst cM f1 l1 cN f2 l2)
		
	| _ ->
            if constr_cmp (conv_pb_of top_pb) cM cN then subst else
	    let (f1,l1) = 
	      match kind_of_term cM with App (f,l) -> (f,l) | _ -> (cM,[||]) in
	    let (f2,l2) =
	      match kind_of_term cN with App (f,l) -> (f,l) | _ -> (cN,[||]) in
	    expand envnb pb b flags subst cM f1 l1 cN f2 l2

  and expand (env,_ as envnb) pb b flags subst cM f1 l1 cN f2 l2 =
    if trivial_unify flags (ex_to_subst subst) env pb cM cN then subst
    else if b then
      let cf1 = key_of flags f1 and cf2 = key_of flags f2 in
	match oracle_order env cf1 cf2 with
	| None -> error_cannot_unify env sigma (cM,cN)
	| Some true -> 
	    (match expand_key env cf1 with
	    | Some c ->
		unirec_rec envnb pb b flags subst
                  (whd_betaiotazeta sigma (mkApp(c,l1))) cN
	    | None ->
		(match expand_key env cf2 with
		| Some c ->
		    unirec_rec envnb pb b flags subst cM
                      (whd_betaiotazeta sigma (mkApp(c,l2)))
		| None ->
		    error_cannot_unify env sigma (cM,cN)))
	| Some false ->
	    (match expand_key env cf2 with
	    | Some c ->
		unirec_rec envnb pb b flags subst cM
                  (whd_betaiotazeta sigma (mkApp(c,l2)))
	    | None ->
		(match expand_key env cf1 with
		| Some c ->
		    unirec_rec envnb pb b flags subst
                      (whd_betaiotazeta sigma (mkApp(c,l1))) cN
		| None ->
		    error_cannot_unify env sigma (cM,cN)))
    else
      error_cannot_unify env sigma (cM,cN)

  in
    if (if occur_meta m then false else
       if (match flags.modulo_conv_on_closed_terms with
	  Some flags ->
	    is_trans_fconv (conv_pb_of top_pb) flags top_env sigma m n
	| None -> constr_cmp (conv_pb_of top_pb) m n) then true else
      if (not (is_ground_term (create_evar_defs sigma) m))
          || occur_meta_or_existential n then false else
      if (match flags.modulo_conv_on_closed_terms, flags.modulo_delta with
            | Some (cv_id, cv_k), (dl_id, dl_k) ->
                Idpred.subset dl_id cv_id && Cpred.subset dl_k cv_k
            | None,(dl_id, dl_k) ->
                Idpred.is_empty dl_id && Cpred.is_empty dl_k)
      then error_cannot_unify top_env sigma (m, n) else false) 
    then
      top_subst
    else 
      let rec do_delayed = fun subst delayed ->
        match delayed with
        | []            -> subst
        | ud :: delayed ->
            let left, right = ud.ud_unif_pb in
            let subst_left  = subst_meta_instances (fst subst) left
            and subst_right = subst_meta_instances (fst subst) right in
            let convertible =
              is_fconv
                (conv_pb_of ud.ud_cv_pb) (fst ud.ud_environ)
                sigma subst_left subst_right
            in
              if convertible then
                do_delayed subst delayed
              else begin
                let state =
                  unirec_rec
                    ud.ud_environ ud.ud_cv_pb ud.ud_unfold
                    { flags with can_dp_delayed = false }
                    (ex_from_subst subst []) left right
                in
                  assert (state.us_delayed = []);
                  do_delayed (ex_to_subst state) delayed
              end
      in
      let state = ex_from_subst top_subst [] in
      let state = unirec_rec (top_env,0) top_pb conv_at_top flags state m n in
        do_delayed (ex_to_subst state) (List.rev state.us_delayed)

let unify_0 = unify_0_with_initial_metas true ([],[])

let left = true
let right = false

let pop k = if k=0 then 0 else k-1

let rec unify_with_eta keptside flags env sigma k1 k2 c1 c2 =
  (* Reason up to limited eta-expansion: ci is allowed to start with ki lam *)
  (* Question: try whd_betadeltaiota on ci if ki>0 ? *)
  match kind_of_term c1, kind_of_term c2 with
  | (Lambda (na,t1,c1'), Lambda (_,t2,c2')) ->
      let env' = push_rel_assum (na,t1) env in
      let metas,evars = unify_0 env topconv sigma flags t1 t2 in
      let side,status,(metas',evars') =
	unify_with_eta keptside flags env' sigma (pop k1) (pop k2) c1' c2'
      in (side,status,(metas@metas',evars@evars'))
  | (Lambda (na,t,c1'),_) when k2 > 0 ->
      let env' = push_rel_assum (na,t) env in
      let side = left in (* expansion on the right: we keep the left side *)
      unify_with_eta side flags env' sigma (pop k1) (k2-1) 
	c1' (mkApp (lift 1 c2,[|mkRel 1|]))
  | (_,Lambda (na,t,c2')) when k1 > 0 ->
      let env' = push_rel_assum (na,t) env in
      let side = right in (* expansion on the left: we keep the right side *)
      unify_with_eta side flags env' sigma (k1-1) (pop k2) 
	(mkApp (lift 1 c1,[|mkRel 1|])) c2'
  | _ ->
      (keptside,ConvUpToEta(min k1 k2),
       unify_0 env topconv sigma flags c1 c2)

(* We solved problems [?n =_pb u] (i.e. [u =_(opp pb) ?n]) and [?n =_pb' u'],
   we now compute the problem on [u =? u'] and decide which of u or u' is kept

   Rem: the upper constraint is lost in case u <= ?n <= u' (and symmetrically
   in the case u' <= ?n <= u)
 *)

let merge_instances env sigma flags st1 st2 c1 c2 =
  match (opp_status st1, st2) with
  | (UserGiven, ConvUpToEta n2) ->
      unify_with_eta left flags env sigma 0 n2 c1 c2
  | (ConvUpToEta n1, UserGiven) ->
      unify_with_eta right flags env sigma n1 0 c1 c2
  | (ConvUpToEta n1, ConvUpToEta n2) ->
      let side = left (* arbitrary choice, but agrees with compatibility *) in
      unify_with_eta side flags env sigma n1 n2 c1 c2
  | ((IsSubType | ConvUpToEta _ | UserGiven as oppst1),
     (IsSubType | ConvUpToEta _ | UserGiven)) ->
      let res = unify_0 env Cumul sigma flags c2 c1 in
      if oppst1=st2 then (* arbitrary choice *) (left, st1, res)
      else if st2=IsSubType or st1=UserGiven then (left, st1, res)
      else (right, st2, res)
  | ((IsSuperType | ConvUpToEta _ | UserGiven as oppst1),
     (IsSuperType | ConvUpToEta _ | UserGiven)) ->
      let res = unify_0 env Cumul sigma flags c1 c2 in
      if oppst1=st2 then (* arbitrary choice *) (left, st1, res)
      else if st2=IsSuperType or st1=UserGiven then (left, st1, res)
      else (right, st2, res)
  | (IsSuperType,IsSubType) ->
      (try (left, IsSubType, unify_0 env Cumul sigma flags c2 c1)
       with _ -> (right, IsSubType, unify_0 env Cumul sigma flags c1 c2))
  | (IsSubType,IsSuperType) ->
      (try (left, IsSuperType, unify_0 env Cumul sigma flags c1 c2)
       with _ -> (right, IsSuperType, unify_0 env Cumul sigma flags c2 c1))

(* Unification
 *
 * Procedure:
 * (1) The function [unify mc wc M N] produces two lists:
 *     (a) a list of bindings Meta->RHS
 *     (b) a list of bindings EVAR->RHS
 *
 * The Meta->RHS bindings cannot themselves contain
 * meta-vars, so they get applied eagerly to the other
 * bindings.  This may or may not close off all RHSs of
 * the EVARs.  For each EVAR whose RHS is closed off,
 * we can just apply it, and go on.  For each which
 * is not closed off, we need to do a mimick step -
 * in general, we have something like:
 *
 *      ?X == (c e1 e2 ... ei[Meta(k)] ... en)
 *
 * so we need to do a mimick step, converting ?X
 * into
 *
 *      ?X -> (c ?z1 ... ?zn)
 *
 * of the proper types.  Then, we can decompose the
 * equation into
 *
 *      ?z1 --> e1
 *          ...
 *      ?zi --> ei[Meta(k)]
 *          ...
 *      ?zn --> en
 *
 * and keep on going.  Whenever we find that a R.H.S.
 * is closed, we can, as before, apply the constraint
 * directly.  Whenever we find an equation of the form:
 *
 *      ?z -> Meta(n)
 *
 * we can reverse the equation, put it into our metavar
 * substitution, and keep going.
 *
 * The most efficient mimick possible is, for each
 * Meta-var remaining in the term, to declare a
 * new EVAR of the same type.  This is supposedly
 * determinable from the clausale form context -
 * we look up the metavar, take its type there,
 * and apply the metavar substitution to it, to
 * close it off.  But this might not always work,
 * since other metavars might also need to be resolved. *)

let applyHead env evd n c  = 
  let rec apprec n c cty evd =
    if n = 0 then 
      (evd, c)
    else 
      match kind_of_term (whd_betadeltaiota env (evars_of evd) cty) with
        | Prod (_,c1,c2) ->
            let (evd',evar) = 
	      Evarutil.new_evar evd env ~src:(dummy_loc,GoalEvar) c1 in
	    apprec (n-1) (mkApp(c,[|evar|])) (subst1 evar c2) evd'
	| _ -> error "Apply_Head_Then"
  in 
  apprec n c (Typing.type_of env (evars_of evd) c) evd

let is_mimick_head f =
  match kind_of_term f with
      (Const _|Var _|Rel _|Construct _|Ind _) -> true
    | _ -> false

let pose_all_metas_as_evars env evd t =
  let evdref = ref evd in
  let rec aux t = match kind_of_term t with
  | Meta mv ->
      (match Evd.meta_opt_fvalue !evdref mv with
       | Some ({rebus=c},_) -> c
       | None ->
        let {rebus=ty;freemetas=mvs} = Evd.meta_ftype evd mv in
        let ty = if mvs = Evd.Metaset.empty then ty else aux ty in
        let ev = Evarutil.e_new_evar evdref env ~src:(dummy_loc,GoalEvar) ty in
        evdref := meta_assign mv (ev,(ConvUpToEta 0,TypeNotProcessed)) !evdref;
        ev)
  | _ ->
      map_constr aux t in
  let c = aux t in
  (* side-effect *)
  (!evdref, c)

let try_to_coerce env evd c cty tycon =
  let j = make_judge c cty in
  let (evd',j') = inh_conv_coerce_rigid_to dummy_loc env evd j tycon in
  let (evd',b) = Evarconv.consider_remaining_unif_problems env evd' in
  if b then
    let evd' = Evd.map_metas_fvalue (nf_evar (evars_of evd')) evd' in
    (evd',j'.uj_val)
  else
    error "Cannot solve unification constraints"

let w_coerce_to_type env evd c cty mvty =
  let evd,mvty = pose_all_metas_as_evars env evd mvty in
  let tycon = mk_tycon_type mvty in
  try try_to_coerce env evd c cty tycon
  with e when precatchable_exception e ->
    (* inh_conv_coerce_rigid_to should have reasoned modulo reduction 
       but there are cases where it though it was not rigid (like in
       fst (nat,nat)) and stops while it could have seen that it is rigid *)
    let cty = Tacred.hnf_constr env (evars_of evd) cty in
    try_to_coerce env evd c cty tycon

let w_coerce env evd mv c =
  let cty = get_type_of_with_meta env (evars_of evd) (metas_of evd) c in
  let mvty = Typing.meta_type evd mv in
  w_coerce_to_type env evd c cty mvty

let unify_to_type env evd flags c u =
  let sigma = evars_of evd in
  let c = refresh_universes c in
  let t = get_type_of_with_meta env sigma (List.map (on_snd (nf_meta evd)) (metas_of evd)) (nf_meta evd c) in
  let t = Tacred.hnf_constr env sigma (nf_betaiota sigma (nf_meta evd t)) in
  let u = Tacred.hnf_constr env sigma u in
  try unify_0 env Cumul sigma flags t u
  with e when precatchable_exception e -> ([],[])

let unify_type env evd flags mv c =
  let mvty = Typing.meta_type evd mv in
  if occur_meta_or_existential mvty or is_arity env (evars_of evd) mvty then
    unify_to_type env evd flags c mvty
  else ([],[])

(* Move metas that may need coercion at the end of the list of instances *)

let order_metas metas =
  let rec order latemetas = function
  | [] -> List.rev latemetas
  | (_,_,(status,to_type) as meta)::metas ->
      if to_type = CoerceToType then order (meta::latemetas) metas
      else meta :: order latemetas metas
  in order [] metas

(* Solve an equation ?n[x1=u1..xn=un] = t where ?n is an evar *)

let solve_simple_evar_eqn env evd ev rhs =
  let evd,b = solve_simple_eqn Evarconv.evar_conv_x env evd (CONV,ev,rhs) in
  if not b then error_cannot_unify env (evars_of evd) (mkEvar ev,rhs);
  let (evd,b) = Evarconv.consider_remaining_unif_problems env evd in
  if not b then error "Cannot solve unification constraints";
  evd

(* [w_merge env sigma b metas evars] merges common instances in metas
   or in evars, possibly generating new unification problems; if [b]
   is true, unification of types of metas is required *)

let w_merge env with_types flags (metas,evars) evd =
  let rec w_merge_rec evd metas evars eqns =

    (* Process evars *)
    match evars with
    | ((evn,_ as ev),rhs)::evars' ->
    	if is_defined_evar evd ev then
	  let v = Evd.existential_value (evars_of evd) ev in
	  let (metas',evars'') =
	    unify_0 env topconv (evars_of evd) flags rhs v in
	  w_merge_rec evd (metas'@metas) (evars''@evars') eqns
    	else begin
          let rhs' = subst_meta_instances metas rhs in
          match kind_of_term rhs with
	  | App (f,cl) when is_mimick_head f & occur_meta rhs' ->
	      if occur_evar evn rhs' then
                error_occur_check env (evars_of evd) evn rhs';
	      let evd' = mimick_evar evd flags f (Array.length cl) evn in
	      w_merge_rec evd' metas evars eqns
          | _ ->
	      w_merge_rec (solve_simple_evar_eqn env evd ev rhs')
		metas evars' eqns
	end
    | [] -> 

    (* Process metas *)
    match metas with
    | (mv,c,(status,to_type))::metas ->
        let ((evd,c),(metas'',evars'')),eqns =
	  if with_types & to_type <> TypeProcessed then
	    if to_type = CoerceToType then
              (* Some coercion may have to be inserted *)
	      (w_coerce env evd mv c,([],[])),[]
	    else
              (* No coercion needed: delay the unification of types *)
	      ((evd,c),([],[])),(mv,c)::eqns
	  else 
	    ((evd,c),([],[])),eqns in
    	if meta_defined evd mv then
	  let {rebus=c'},(status',_) = meta_fvalue evd mv in
          let (take_left,st,(metas',evars')) =
	    merge_instances env (evars_of evd) flags status' status c' c
	  in
	  let evd' = 
            if take_left then evd 
            else meta_reassign mv (c,(st,TypeProcessed)) evd 
	  in
          w_merge_rec evd' (metas'@metas@metas'') (evars'@evars'') eqns
    	else
	  let evd' = meta_assign mv (c,(status,TypeProcessed)) evd in
	  w_merge_rec evd' (metas@metas'') evars'' eqns
    | [] -> 

    (* Process type eqns *)
    match eqns with
    | (mv,c)::eqns ->
        let (metas,evars) = unify_type env evd flags mv c in 
        w_merge_rec evd metas evars eqns
    | [] -> evd
		
  and mimick_evar evd flags hdc nargs sp =
    let ev = Evd.find (evars_of evd) sp in
    let sp_env = Global.env_of_context ev.evar_hyps in
    let (evd', c) = applyHead sp_env evd nargs hdc in
    let (mc,ec) =
      unify_0 sp_env Cumul (evars_of evd') flags
        (Retyping.get_type_of_with_meta sp_env (evars_of evd') (metas_of evd') c) ev.evar_concl in
    let evd'' = w_merge_rec evd' mc ec [] in
    if (evars_of evd') == (evars_of evd'')
    then Evd.evar_define sp c evd''
    else Evd.evar_define sp (Evarutil.nf_evar (evars_of evd'') c) evd'' in

  (* merge constraints *)
  w_merge_rec evd (order_metas metas) evars []

let w_unify_meta_types env ?(flags=default_unify_flags) evd =
  let metas,evd = retract_coercible_metas evd in
  w_merge env true flags (metas,[]) evd

(* [w_unify env evd M N]
   performs a unification of M and N, generating a bunch of
   unification constraints in the process.  These constraints
   are processed, one-by-one - they may either generate new
   bindings, or, if there is already a binding, new unifications,
   which themselves generate new constraints.  This continues
   until we get failure, or we run out of constraints.
   [clenv_typed_unify M N clenv] expects in addition that expected
   types of metavars are unifiable with the types of their instances    *)

let check_types env evd flags subst m n =
  let sigma = evars_of evd in
  if isEvar (fst (whd_stack sigma m)) or isEvar (fst (whd_stack sigma n)) then
    unify_0_with_initial_metas true subst env topconv (evars_of evd)
      flags
      (Retyping.get_type_of_with_meta env sigma (metas_of evd) m)
      (Retyping.get_type_of_with_meta env sigma (metas_of evd) n)
  else
    subst

let w_unify_core_0 env with_types cv_pb flags m n evd =
  let (mc1,evd') = retract_coercible_metas evd in
  let subst1 = check_types env evd flags (mc1,[]) m n in
  let subst2 =
     unify_0_with_initial_metas true subst1 env cv_pb (evars_of evd') flags m n
  in 
  w_merge env with_types flags subst2 evd'

let w_unify_0 env = w_unify_core_0 env false
let w_typed_unify env = w_unify_core_0 env true


(* takes a substitution s, an open term op and a closed term cl
   try to find a subterm of cl which matches op, if op is just a Meta
   FAIL because we cannot find a binding *)

let iter_fail f a =
  let n = Array.length a in 
  let rec ffail i =
    if i = n then error "iter_fail" 
    else
      try f a.(i) 
      with ex when precatchable_exception ex -> ffail (i+1)
  in ffail 0

(* Tries to find an instance of term [cl] in term [op].
   Unifies [cl] to every subterm of [op] until it finds a match.
   Fails if no match is found *)
let w_unify_to_subterm env ?(flags=default_unify_flags) (op,cl) evd =
  let rec matchrec cl =
    let cl = strip_outer_cast cl in
    (try 
       if closed0 cl 
       then w_unify_0 env topconv flags op cl evd,cl
       else error "Bound 1"
     with ex when precatchable_exception ex ->
       (match kind_of_term cl with 
	  | App (f,args) ->
	      let n = Array.length args in
	      assert (n>0);
	      let c1 = mkApp (f,Array.sub args 0 (n-1)) in
	      let c2 = args.(n-1) in
	      (try 
		 matchrec c1
	       with ex when precatchable_exception ex -> 
		 matchrec c2)
          | Case(_,_,c,lf) -> (* does not search in the predicate *)
	       (try 
		 matchrec c
	       with ex when precatchable_exception ex -> 
		 iter_fail matchrec lf)
	  | LetIn(_,c1,_,c2) -> 
	       (try 
		 matchrec c1
	       with ex when precatchable_exception ex -> 
		 matchrec c2)

	  | Fix(_,(_,types,terms)) -> 
	       (try 
		 iter_fail matchrec types
	       with ex when precatchable_exception ex -> 
		 iter_fail matchrec terms)
	
	  | CoFix(_,(_,types,terms)) -> 
	       (try 
		 iter_fail matchrec types
	       with ex when precatchable_exception ex -> 
		 iter_fail matchrec terms)

          | Prod (_,t,c) ->
	      (try 
		 matchrec t 
	       with ex when precatchable_exception ex -> 
		 matchrec c)
          | Lambda (_,t,c) ->
	      (try 
		 matchrec t 
	       with ex when precatchable_exception ex -> 
		 matchrec c)
          | _ -> error "Match_subterm")) 
  in 
  try matchrec cl
  with ex when precatchable_exception ex ->
    raise (PretypeError (env,NoOccurrenceFound (op, None)))

let w_unify_to_subterm_list env flags allow_K oplist t evd = 
  List.fold_right 
    (fun op (evd,l) ->
      if isMeta op then
	if allow_K then (evd,op::l)
	else error "Match_subterm"
      else if occur_meta_or_existential op then
        let (evd',cl) =
          try 
	    (* This is up to delta for subterms w/o metas ... *)
	    w_unify_to_subterm env ~flags (strip_outer_cast op,t) evd
          with PretypeError (env,NoOccurrenceFound _) when allow_K -> (evd,op)
        in 
	(evd',cl::l)
      else if allow_K or dependent op t then
	(evd,op::l)
      else
	(* This is not up to delta ... *)
	raise (PretypeError (env,NoOccurrenceFound (op, None))))
    oplist 
    (evd,[])

let secondOrderAbstraction env flags allow_K typ (p, oplist) evd =
  (* Remove delta when looking for a subterm *)
  let flags = { flags with modulo_delta = (fst flags.modulo_delta, Cpred.empty) } in
  let (evd',cllist) =
    w_unify_to_subterm_list env flags allow_K oplist typ evd in
  let typp = Typing.meta_type evd' p in
  let pred = abstract_list_all env evd' typp typ cllist in
  w_merge env false flags ([p,pred,(ConvUpToEta 0,TypeProcessed)],[]) evd'

let w_unify2 env flags allow_K cv_pb ty1 ty2 evd =
  let c1, oplist1 = whd_stack (evars_of evd) ty1 in
  let c2, oplist2 = whd_stack (evars_of evd) ty2 in
  match kind_of_term c1, kind_of_term c2 with
    | Meta p1, _ ->
        (* Find the predicate *)
	let evd' =
          secondOrderAbstraction env flags allow_K ty2 (p1,oplist1) evd in 
        (* Resume first order unification *)
	w_unify_0 env cv_pb flags (nf_meta evd' ty1) ty2 evd'
    | _, Meta p2 ->
        (* Find the predicate *)
	let evd' =
          secondOrderAbstraction env flags allow_K ty1 (p2, oplist2) evd in 
        (* Resume first order unification *)
	w_unify_0 env cv_pb flags ty1 (nf_meta evd' ty2) evd'
    | _ -> error "w_unify2"

(* The unique unification algorithm works like this: If the pattern is
   flexible, and the goal has a lambda-abstraction at the head, then
   we do a first-order unification.

   If the pattern is not flexible, then we do a first-order
   unification, too.

   If the pattern is flexible, and the goal doesn't have a
   lambda-abstraction head, then we second-order unification. *)

(* We decide here if first-order or second-order unif is used for Apply *)
(* We apply a term of type (ai:Ai)C and try to solve a goal C'          *)
(* The type C is in clenv.templtyp.rebus with a lot of Meta to solve    *)

(* 3-4-99 [HH] New fo/so choice heuristic :
   In case we have to unify (Meta(1) args) with ([x:A]t args')
   we first try second-order unification and if it fails first-order.
   Before, second-order was used if the type of Meta(1) and [x:A]t was
   convertible and first-order otherwise. But if failed if e.g. the type of
   Meta(1) had meta-variables in it. *)
let w_unify allow_K env cv_pb ?(flags=default_unify_flags) ty1 ty2 evd =
  let cv_pb = of_conv_pb cv_pb in
  let hd1,l1 = whd_stack (evars_of evd) ty1 in
  let hd2,l2 = whd_stack (evars_of evd) ty2 in
    match kind_of_term hd1, l1<>[], kind_of_term hd2, l2<>[] with
      (* Pattern case *)
      | (Meta _, true, Lambda _, _ | Lambda _, _, Meta _, true)
	  when List.length l1 = List.length l2 ->
	  (try 
	      w_typed_unify env cv_pb flags ty1 ty2 evd
	    with ex when precatchable_exception ex -> 
	      try 
		w_unify2 env flags allow_K cv_pb ty1 ty2 evd
	      with PretypeError (env,NoOccurrenceFound _) as e -> raise e)
	    
      (* Second order case *)
      | (Meta _, true, _, _ | _, _, Meta _, true) -> 
	  (try 
	      w_unify2 env flags allow_K cv_pb ty1 ty2 evd
	    with PretypeError (env,NoOccurrenceFound _) as e -> raise e
	      | ex when precatchable_exception ex -> 
		  try 
		    w_typed_unify env cv_pb flags ty1 ty2 evd
		  with ex' when precatchable_exception ex' ->
		    raise ex)
	    
      (* General case: try first order *)
      | _ -> w_typed_unify env cv_pb flags ty1 ty2 evd
