(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2011     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id: safe_typing.ml 13323 2010-07-24 15:57:30Z herbelin $ *)

open Util
open Names
open Univ
open Term
open Reduction
open Sign
open Declarations
open Inductive
open Environ
open Entries
open Typeops
open Type_errors
open Indtypes
open Term_typing
open Modops
open Subtyping
open Mod_typing
open Mod_subst


type modvariant =
  | NONE
  | SIG of (* funsig params *) (mod_bound_id * module_type_body) list
  | STRUCT of (* functor params *) (mod_bound_id * module_type_body) list
  | LIBRARY of dir_path

type module_info =
    {modpath : module_path;
     label : label;
     variant : modvariant;
     resolver : delta_resolver;
     resolver_of_param : delta_resolver;}

let check_label l labset =
  if Labset.mem l labset then error_existing_label l

let check_labels ls senv =
  Labset.iter (fun l -> check_label l senv) ls

let labels_of_mib mib =
  let add,get =
    let labels = ref Labset.empty in
    (fun id -> labels := Labset.add (label_of_id id) !labels),
    (fun () -> !labels)
  in
  let visit_mip mip =
    add mip.mind_typename;
    Array.iter add mip.mind_consnames
  in
  Array.iter visit_mip mib.mind_packets;
  get ()

let set_engagement_opt oeng env =
  match oeng with
      Some eng -> set_engagement eng env
    | _ -> env

type library_info = dir_path * Digest.t

type safe_environment =
    { old : safe_environment;
      env : env;
      modinfo : module_info;
      labset : Labset.t;
      revstruct : structure_body;
      univ : Univ.constraints;
      engagement : engagement option;
      imports : library_info list;
      loads : (module_path * module_body) list;
      local_retroknowledge : Retroknowledge.action list;
      dpopcodes : Decproc.OpCodes.opcode list; }

(* a small hack to avoid variants and an unused case in all functions *)
let rec empty_environment =
  { old = empty_environment;
    env = empty_env;
    modinfo = {
      modpath = initial_path;
      label = mk_label "_";
      variant = NONE;
      resolver = empty_delta_resolver;
      resolver_of_param = empty_delta_resolver};
    labset = Labset.empty;
    revstruct = [];
    univ = Univ.Constraint.empty;
    engagement = None;
    imports = [];
    loads = [];
    local_retroknowledge = [];
    dpopcodes = []; }

let env_of_safe_env senv = senv.env
let env_of_senv = env_of_safe_env







let add_constraints cst senv =
  {senv with
    env = Environ.add_constraints cst senv.env;
    univ = Univ.Constraint.union cst senv.univ }


(* universal lifting, used for the "get" operations mostly *)
let retroknowledge f senv =
  Environ.retroknowledge f (env_of_senv senv)

let register senv field value by_clause =
  (* todo : value closed, by_clause safe, by_clause of the proper type*)
  (* spiwack : updates the safe_env with the information that the register
     action has to be performed (again) when the environement is imported *)
  {senv with env = Environ.register senv.env field value;
             local_retroknowledge =
      Retroknowledge.RKRegister (field,value)::senv.local_retroknowledge
  }

(* spiwack : currently unused *)
let unregister senv field  =
  (*spiwack: todo: do things properly or delete *)
  {senv with env = Environ.unregister senv.env field}
(* /spiwack *)










(* Insertion of section variables. They are now typed before being
   added to the environment. *)

(* Same as push_named, but check that the variable is not already
   there. Should *not* be done in Environ because tactics add temporary
   hypothesis many many times, and the check performed here would
   cost too much. *)
let safe_push_named (id,_,_ as d) env =
  let _ =
    try
      let _ = lookup_named id env in
      error ("Identifier "^string_of_id id^" already defined.")
    with Not_found -> () in
  Environ.push_named d env

let push_named_def (id,b,topt) senv =
  let (c,typ,cst) = translate_local_def senv.env (b,topt) in
  let senv' = add_constraints cst senv in
  let env'' = safe_push_named (id,Some c,typ) senv'.env in
  (cst, {senv' with env=env''})

let push_named_assum (id,t) senv =
  let (t,cst) = translate_local_assum senv.env t in
  let senv' = add_constraints cst senv in
  let env'' = safe_push_named (id,None,t) senv'.env in
  (cst, {senv' with env=env''})


(* Insertion of constants and parameters in environment. *)

type global_declaration =
  | ConstantEntry of constant_entry
  | GlobalRecipe of Cooking.recipe

let hcons_constant_type = function
  | NonPolymorphicType t ->
      NonPolymorphicType (hcons1_constr t)
  | PolymorphicArity (ctx,s) ->
      PolymorphicArity (map_rel_context hcons1_constr ctx,s)

let hcons_constant_body cb =
  let body = match cb.const_body with
      None -> None
    | Some l_constr -> let constr = Declarations.force l_constr in
	Some (Declarations.from_val (hcons1_constr constr))
  in
    { cb with
	const_body = body;
	const_type = hcons_constant_type cb.const_type }

let add_constant dir l decl senv =
  check_label l senv.labset;
  let kn = make_con senv.modinfo.modpath dir l in
  let cb =
    match decl with
      | ConstantEntry ce -> translate_constant senv.env kn ce
      | GlobalRecipe r ->
	  let cb = translate_recipe senv.env kn r in
	    if dir = empty_dirpath then hcons_constant_body cb else cb
  in
  let senv' = add_constraints cb.const_constraints senv in
  let env'' = Environ.add_constant kn cb senv'.env in
  let resolver = 
    if cb.const_inline then
      add_inline_delta_resolver kn senv'.modinfo.resolver
    else
      senv'.modinfo.resolver
  in
    kn, { old = senv'.old;
	  env = env'';
	  modinfo = {senv'.modinfo with
		       resolver = resolver};
	  labset = Labset.add l senv'.labset;
	  revstruct = (l,SFBconst cb)::senv'.revstruct;
          univ = senv'.univ;
          engagement = senv'.engagement;
	  imports = senv'.imports;
	  loads = senv'.loads ;
	  local_retroknowledge = senv'.local_retroknowledge;
    dpopcodes = senv'.dpopcodes; }

(* Insertion of inductive types. *)
let add_mind dir l mie senv =
  if mie.mind_entry_inds = [] then
    anomaly "empty inductive types declaration";
            (* this test is repeated by translate_mind *)
  let id = (List.nth mie.mind_entry_inds 0).mind_entry_typename in
  if l <> label_of_id id then
    anomaly ("the label of inductive packet and its first inductive"^
	     " type do not match");
  let mib = translate_mind senv.env mie in
  let labels = labels_of_mib mib in
  check_labels labels senv.labset;
  let senv' = add_constraints mib.mind_constraints senv in
  let kn = make_mind senv.modinfo.modpath dir l in
  let env'' = Environ.add_mind kn mib senv'.env in
  kn, { old = senv'.old;
	env = env'';
	modinfo = senv'.modinfo;
	labset = Labset.union labels senv'.labset;
	revstruct = (l,SFBmind mib)::senv'.revstruct;
        univ = senv'.univ;
        engagement = senv'.engagement;
	imports = senv'.imports;
	loads = senv'.loads;
        local_retroknowledge = senv'.local_retroknowledge;
        dpopcodes = senv'.dpopcodes; }

(* Insertion of module types *)

let add_modtype l mte inl senv =
  check_label l senv.labset;
  let mp = MPdot(senv.modinfo.modpath, l) in
  let mtb = translate_module_type senv.env mp inl mte  in
  let senv' = add_constraints mtb.typ_constraints senv in
   let env'' = Environ.add_modtype mp mtb senv'.env in
    mp, { old = senv'.old;
	  env = env'';
	  modinfo = senv'.modinfo;
	  labset = Labset.add l senv'.labset;
	  revstruct = (l,SFBmodtype mtb)::senv'.revstruct;
    univ = senv'.univ;
    engagement = senv'.engagement;
	  imports = senv'.imports;
	  loads = senv'.loads;
    local_retroknowledge = senv'.local_retroknowledge;
    dpopcodes = senv'.dpopcodes; }


(* full_add_module adds module with universes and constraints *)
let full_add_module mb senv =
  let senv = add_constraints mb.mod_constraints senv in
  let env = Modops.add_module mb senv.env in
    {senv with env = env}

(* Insertion of modules *)

let add_module l me inl senv =
  check_label l senv.labset;
  let mp = MPdot(senv.modinfo.modpath, l) in
  let mb = translate_module senv.env mp inl me in
  let senv' = full_add_module mb senv  in
  let modinfo = match mb.mod_type with
      SEBstruct _ -> 
	{ senv'.modinfo with
	    resolver = 
	    add_delta_resolver mb.mod_delta senv'.modinfo.resolver}
    | _ -> senv'.modinfo
  in
    mp,mb.mod_delta,
  { old = senv'.old;
    env = senv'.env;
    modinfo = modinfo;
    labset = Labset.add l senv'.labset;
    revstruct = (l,SFBmodule mb)::senv'.revstruct;
    univ = senv'.univ;
    engagement = senv'.engagement;
    imports = senv'.imports;
    loads = senv'.loads;
    local_retroknowledge = senv'.local_retroknowledge;
    dpopcodes = senv'.dpopcodes; }
    
(* Interactive modules *)

let start_module l senv =
  check_label l senv.labset;
 let mp = MPdot(senv.modinfo.modpath, l) in
 let modinfo = { modpath = mp;
		 label = l;
		 variant = STRUCT [];
		 resolver = empty_delta_resolver;
		 resolver_of_param = empty_delta_resolver}
 in
   mp, { old = senv;
	 env = senv.env;
	 modinfo = modinfo;
	 labset = Labset.empty;
	 revstruct = [];
         univ = Univ.Constraint.empty;
         engagement = None;
	 imports = senv.imports;
	 loads = [];
	 (* spiwack : not sure, but I hope it's correct *)
   local_retroknowledge = [];
   (* /spiwack *)
   dpopcodes = []; }

let end_module l restype senv =
  let oldsenv = senv.old in
  let modinfo = senv.modinfo in
  let mp = senv.modinfo.modpath in
  let restype =
    Option.map
      (fun (res,inl) -> translate_module_type senv.env mp inl res) restype in
  let params,is_functor =
    match modinfo.variant with
      | NONE | LIBRARY _ | SIG _ -> error_no_module_to_end ()
      | STRUCT params -> params, (List.length params > 0)
  in
  if l <> modinfo.label then error_incompatible_labels l modinfo.label;
  if not (empty_context senv.env) then error_local_context None;
  let functorize_struct tb =
    List.fold_left
      (fun mtb (arg_id,arg_b) ->
	SEBfunctor(arg_id,arg_b,mtb))
      tb
      params
  in
   let auto_tb =
     SEBstruct (List.rev senv.revstruct)
  in
   let mexpr,mod_typ,mod_typ_alg,resolver,cst = 
    match restype with
      | None ->  let mexpr = functorize_struct auto_tb in
	 mexpr,mexpr,None,modinfo.resolver,Constraint.empty
      | Some mtb ->
	  let auto_mtb = {
	    typ_mp = senv.modinfo.modpath;
	    typ_expr = auto_tb;
	    typ_expr_alg = None;
	    typ_constraints = Constraint.empty;
	    typ_delta = empty_delta_resolver} in
	  let cst = check_subtypes senv.env auto_mtb
	    mtb in
	  let mod_typ = functorize_struct mtb.typ_expr in
	  let mexpr = functorize_struct auto_tb in
	  let typ_alg = 
	    Option.map functorize_struct mtb.typ_expr_alg in
	    mexpr,mod_typ,typ_alg,mtb.typ_delta,cst
  in
  let cst = Constraint.union cst senv.univ in
  let mb =
    { mod_mp = mp;
      mod_expr = Some mexpr;
      mod_type = mod_typ;
      mod_type_alg = mod_typ_alg;
      mod_constraints = cst;
      mod_delta = resolver;
      mod_retroknowledge = senv.local_retroknowledge;
      mod_dp = senv.dpopcodes; }
  in
  let newenv = oldsenv.env in
  let newenv = set_engagement_opt senv.engagement newenv in
  let senv'= {senv with env=newenv} in
  let senv' =
    List.fold_left
      (fun env (_,mb) -> full_add_module mb env) 
      senv'
      (List.rev senv'.loads)
  in
  let newenv = Environ.add_constraints cst senv'.env in
  let newenv =
    Modops.add_module mb newenv in 
  let modinfo = match mb.mod_type with
      SEBstruct _ -> 
	{ oldsenv.modinfo with
	    resolver = 
	    add_delta_resolver resolver oldsenv.modinfo.resolver}
    | _ -> oldsenv.modinfo
  in
    mp,resolver,{ old = oldsenv.old;
		  env = newenv;
		  modinfo = modinfo;
		  labset = Labset.add l oldsenv.labset;
		  revstruct = (l,SFBmodule mb)::oldsenv.revstruct;
		  univ = Univ.Constraint.union senv'.univ oldsenv.univ;
		  (* engagement is propagated to the upper level *)
		  engagement = senv'.engagement;
		  imports = senv'.imports;
		  loads = senv'.loads@oldsenv.loads;
		  local_retroknowledge = 
	      senv'.local_retroknowledge@oldsenv.local_retroknowledge;
      dpopcodes = senv'.dpopcodes @ oldsenv.dpopcodes; }


(* Include for module and module type*)
 let add_include me is_module inl senv =
   let sign,cst,resolver =
     if is_module then
       let sign,resolver,cst =  
	 translate_struct_include_module_entry senv.env 
	   senv.modinfo.modpath inl me in
	 sign,cst,resolver
     else
       let mtb = 
	 translate_module_type senv.env 
	   senv.modinfo.modpath inl me in
       mtb.typ_expr,mtb.typ_constraints,mtb.typ_delta
   in
   let senv = add_constraints cst senv in
   let mp_sup = senv.modinfo.modpath in
     (* Include Self support  *)
  let rec compute_sign sign mb resolver senv = 
     match sign with
     | SEBfunctor(mbid,mtb,str) ->
	 let cst_sub = check_subtypes senv.env mb mtb in
	 let senv = add_constraints cst_sub senv in
	 let mpsup_delta = if not inl then mb.typ_delta else
	   complete_inline_delta_resolver senv.env mp_sup mbid mtb mb.typ_delta
	 in
	 let subst = map_mbid mbid mp_sup mpsup_delta in
	 let resolver = subst_codom_delta_resolver subst resolver in
	   (compute_sign 
	      (subst_struct_expr subst str) mb resolver senv)
     | str -> resolver,str,senv
  in
   let resolver,sign,senv = compute_sign sign {typ_mp = mp_sup;
				      typ_expr = SEBstruct (List.rev senv.revstruct);
				      typ_expr_alg = None;
				      typ_constraints = Constraint.empty;
				      typ_delta = senv.modinfo.resolver} resolver senv in
   let str = match sign with
     | SEBstruct(str_l) -> str_l
     | _ -> error ("You cannot Include a high-order structure.")
   in
   let senv =
     {senv 
      with modinfo = 
	 {senv.modinfo
	  with resolver =
	     add_delta_resolver resolver senv.modinfo.resolver}}
   in
   let add senv (l,elem)  =
     check_label l senv.labset;
     match elem with
       | SFBconst cb ->
	   let kn = make_kn mp_sup empty_dirpath l in
	   let con = constant_of_kn_equiv kn
	     (canonical_con 
		(constant_of_delta resolver (constant_of_kn kn)))
	   in
	   let senv' = add_constraints cb.const_constraints senv in
	   let env'' = Environ.add_constant con cb senv'.env in
	     { old = senv'.old;
	       env = env'';
	       modinfo = senv'.modinfo;
	       labset = Labset.add l senv'.labset;
	       revstruct = (l,SFBconst cb)::senv'.revstruct;
               univ = senv'.univ;
               engagement = senv'.engagement;
	       imports = senv'.imports;
	       loads = senv'.loads ;
	       local_retroknowledge = senv'.local_retroknowledge;
         dpopcodes = senv'.dpopcodes; }
       | SFBmind mib ->
	   let kn = make_kn mp_sup empty_dirpath l in
	   let mind = mind_of_kn_equiv kn
	     (canonical_mind 
		(mind_of_delta resolver (mind_of_kn kn)))
	   in
	   let labels = labels_of_mib mib in
	   check_labels labels senv.labset;
	   let senv' = add_constraints mib.mind_constraints senv in
	   let env'' = Environ.add_mind mind mib senv'.env in
	     { old = senv'.old;
	       env = env'';
	       modinfo = senv'.modinfo;
	       labset = Labset.union labels senv'.labset;
	       revstruct = (l,SFBmind mib)::senv'.revstruct;
               univ = senv'.univ;
               engagement = senv'.engagement;
	       imports = senv'.imports;
	       loads = senv'.loads;
         local_retroknowledge = senv'.local_retroknowledge;
         dpopcodes = senv'.dpopcodes; }

       | SFBmodule mb ->
	   let senv' = full_add_module mb senv in
	     { old = senv'.old;
	       env = senv'.env;
	       modinfo = senv'.modinfo;
	       labset = Labset.add l senv'.labset;
	       revstruct = (l,SFBmodule mb)::senv'.revstruct;
	       univ = senv'.univ;
	       engagement = senv'.engagement;
	       imports = senv'.imports;
	       loads = senv'.loads;
	       local_retroknowledge = senv'.local_retroknowledge;
         dpopcodes = senv'.dpopcodes; }
       | SFBmodtype mtb ->
	   let senv' = add_constraints mtb.typ_constraints senv in
	   let mp = MPdot(senv.modinfo.modpath, l) in
	   let env' = Environ.add_modtype mp mtb senv'.env in
	     { old = senv.old;
	       env = env';
	       modinfo = senv'.modinfo;
	       labset = Labset.add l senv.labset;
	       revstruct = (l,SFBmodtype mtb)::senv'.revstruct;
               univ = senv'.univ;
               engagement = senv'.engagement;
	       imports = senv'.imports;
	       loads = senv'.loads;
         local_retroknowledge = senv'.local_retroknowledge;
         dpopcodes = senv'.dpopcodes; }
   in
     resolver,(List.fold_left add senv str)

(* Adding parameters to modules or module types *)

let add_module_parameter mbid mte inl senv =
  if  senv.revstruct <> [] or senv.loads <> [] then
    anomaly "Cannot add a module parameter to a non empty module";
  let mtb = translate_module_type senv.env (MPbound mbid) inl mte in
  let senv = 
    full_add_module (module_body_of_type (MPbound mbid) mtb) senv
  in
  let new_variant = match senv.modinfo.variant with
    | STRUCT params -> STRUCT ((mbid,mtb) :: params)
    | SIG params -> SIG ((mbid,mtb) :: params)
    | _ ->
	anomaly "Module parameters can only be added to modules or signatures"  
  in
    
  let resolver_of_param = match mtb.typ_expr with
      SEBstruct _ -> mtb.typ_delta
    | _ -> empty_delta_resolver
  in
    mtb.typ_delta, { old = senv.old;
		     env = senv.env;
		     modinfo = { senv.modinfo with 
				   variant = new_variant;
				   resolver_of_param = add_delta_resolver
			      resolver_of_param senv.modinfo.resolver_of_param};
		     labset = senv.labset;
		     revstruct = [];
		     univ = senv.univ;
		     engagement = senv.engagement;
		     imports = senv.imports;
		     loads = [];
		     local_retroknowledge = senv.local_retroknowledge;
         dpopcodes = senv.dpopcodes; }

(* Interactive module types *)

let start_modtype l senv =
  check_label l senv.labset;
 let mp = MPdot(senv.modinfo.modpath, l) in
 let modinfo = { modpath = mp;
		 label = l;
		 variant = SIG [];
		 resolver = empty_delta_resolver;
		 resolver_of_param = empty_delta_resolver}
 in
  mp, { old = senv;
	env = senv.env;
	modinfo = modinfo;
	labset = Labset.empty;
	revstruct = [];
        univ = Univ.Constraint.empty;
        engagement = None;
	imports = senv.imports;
	loads = [] ;
	(* spiwack: not 100% sure, but I think it should be like that *)
  local_retroknowledge = [];
  (* /spiwack *)
  dpopcodes = []; }

let end_modtype l senv =
  let oldsenv = senv.old in
  let modinfo = senv.modinfo in
  let params =
    match modinfo.variant with
      | LIBRARY _ | NONE | STRUCT _ -> error_no_modtype_to_end ()
      | SIG params -> params
  in
  if l <> modinfo.label then error_incompatible_labels l modinfo.label;
  if not (empty_context senv.env) then error_local_context None;
  let auto_tb =
     SEBstruct (List.rev senv.revstruct)
  in
  let mtb_expr =
    List.fold_left
      (fun mtb (arg_id,arg_b) ->
	 SEBfunctor(arg_id,arg_b,mtb))
      auto_tb
      params
  in
  let mp = MPdot (oldsenv.modinfo.modpath, l) in
  let newenv = oldsenv.env in
  let newenv = Environ.add_constraints senv.univ  newenv in
  let newenv = set_engagement_opt senv.engagement newenv in
  let senv = {senv with env=newenv} in
  let senv =
    List.fold_left
      (fun env (mp,mb) -> full_add_module mb env)
      senv
      (List.rev senv.loads)
  in
  let mtb = {typ_mp = mp;
    typ_expr = mtb_expr;
    typ_expr_alg = None;
    typ_constraints = senv.univ;
    typ_delta = senv.modinfo.resolver} in
  let newenv =
    Environ.add_modtype mp mtb senv.env
  in
    mp, { old = oldsenv.old;
	  env = newenv;
	  modinfo = oldsenv.modinfo;
	  labset = Labset.add l oldsenv.labset;
	  revstruct = (l,SFBmodtype mtb)::oldsenv.revstruct;
          univ = Univ.Constraint.union senv.univ oldsenv.univ;
          engagement = senv.engagement;
	  imports = senv.imports;
	  loads = senv.loads@oldsenv.loads;
    (* spiwack : if there is a bug with retroknowledge in nested modules
                 it's likely to come from here *)
    local_retroknowledge = 
        senv.local_retroknowledge@oldsenv.local_retroknowledge;
    dpopcodes = senv.dpopcodes @ oldsenv.dpopcodes; }

let current_modpath senv = senv.modinfo.modpath
let delta_of_senv senv = senv.modinfo.resolver,senv.modinfo.resolver_of_param

(* Check that the engagement expected by a library matches the initial one *)
let check_engagement env c =
  match Environ.engagement env, c with
    | Some ImpredicativeSet, Some ImpredicativeSet -> ()
    | _, None -> ()
    | _, Some ImpredicativeSet ->
        error "Needs option -impredicative-set."

let set_engagement c senv =
  {senv with
    env = Environ.set_engagement c senv.env;
    engagement = Some c }

(* Libraries = Compiled modules *)

type compiled_library =
    dir_path * module_body * library_info list * engagement option

(* We check that only initial state Require's were performed before
   [start_library] was called *)

let is_empty senv =
  senv.revstruct = [] &&
  senv.modinfo.modpath = initial_path &&
  senv.modinfo.variant = NONE

let start_library dir senv =
  if not (is_empty senv) then
    anomaly "Safe_typing.start_library: environment should be empty";
  let dir_path,l =
    match (repr_dirpath dir) with
	[] -> anomaly "Empty dirpath in Safe_typing.start_library"
      | hd::tl ->
	  make_dirpath tl, label_of_id hd
  in
  let mp = MPfile dir in
  let modinfo = {modpath = mp;
		 label = l;
		 variant = LIBRARY dir;
		 resolver = empty_delta_resolver;
		 resolver_of_param = empty_delta_resolver}
  in
  mp, { old = senv;
	env = senv.env;
	modinfo = modinfo;
	labset = Labset.empty;
	revstruct = [];
        univ = Univ.Constraint.empty;
        engagement = None;
	imports = senv.imports;
	loads = [];
  local_retroknowledge = [];
  dpopcodes = []; }

let pack_module senv =
  {mod_mp=senv.modinfo.modpath;
   mod_expr=None;
   mod_type= SEBstruct (List.rev senv.revstruct);
   mod_type_alg=None;
   mod_constraints=Constraint.empty;
   mod_delta=senv.modinfo.resolver;
   mod_retroknowledge=[];
   mod_dp = [];                         (* FIXME (STRUB); *)
  }

let export senv dir =
  let modinfo = senv.modinfo in
  begin
    match modinfo.variant with
      | LIBRARY dp ->
	  if dir <> dp then
	    anomaly "We are not exporting the right library!"
      | _ ->
	  anomaly "We are not exporting the library"
  end;
  (*if senv.modinfo.params <> [] || senv.modinfo.restype <> None then
    (* error_export_simple *) (); *)
    let str = SEBstruct (List.rev senv.revstruct) in
    let mp = senv.modinfo.modpath in
    let mb = 
    { mod_mp = mp;
      mod_expr = Some str;
      mod_type = str;
      mod_type_alg = None;
      mod_constraints = senv.univ;
      mod_delta = senv.modinfo.resolver;
      mod_retroknowledge = senv.local_retroknowledge;
      mod_dp = senv.dpopcodes; }
  in
   mp, (dir,mb,senv.imports,engagement senv.env)


let check_imports senv needed =
  let imports = senv.imports in
  let check (id,stamp) =
    try
      let actual_stamp = List.assoc id imports in
      if stamp <> actual_stamp then
	error
	  ("Inconsistent assumptions over module "^(string_of_dirpath id)^".")
    with Not_found ->
      error ("Reference to unknown module "^(string_of_dirpath id)^".")
  in
  List.iter check needed



(* we have an inefficiency: Since loaded files are added to the
environment every time a module is closed, their components are
calculated many times. Thic could be avoided in several ways:

1 - for each file create a dummy environment containing only this
file's components, merge this environment with the global
environment, and store for the future (instead of just its type)

2 - create "persistent modules" environment table in Environ add put
loaded by side-effect once and for all (like it is done in OCaml).
Would this be correct with respect to undo's and stuff ?
*)

let import (dp,mb,depends,engmt) digest senv =
  check_imports senv depends;
  check_engagement senv.env engmt;
  let mp = MPfile dp in
  let env = senv.env in
  let env = Environ.add_constraints mb.mod_constraints env in
  let env = Modops.add_module mb env in
  mp, { senv with
	  env = env;
	  modinfo = 
      {senv.modinfo with 
	 resolver = 
	    add_delta_resolver mb.mod_delta senv.modinfo.resolver};
	  imports = (dp,digest)::senv.imports;
	  loads = (mp,mb)::senv.loads }


(* Remove the body of opaque constants in modules *)
 let rec lighten_module mb =
  { mb with
    mod_expr = None;
    mod_type = lighten_modexpr mb.mod_type;
  }

and lighten_struct struc =
  let lighten_body (l,body) = (l,match body with
    | SFBconst ({const_opaque=true} as x) -> SFBconst {x with const_body=None}
    | (SFBconst _ | SFBmind _ ) as x -> x
    | SFBmodule m -> SFBmodule (lighten_module m)
    | SFBmodtype m -> SFBmodtype
	({m with
	    typ_expr = lighten_modexpr m.typ_expr}))
  in
    List.map lighten_body struc

and lighten_modexpr = function
  | SEBfunctor (mbid,mty,mexpr) ->
      SEBfunctor (mbid,
		    ({mty with
			typ_expr = lighten_modexpr mty.typ_expr}),
		  lighten_modexpr mexpr)
  | SEBident mp as x -> x
  | SEBstruct (struc) ->
      SEBstruct  (lighten_struct struc)
  | SEBapply (mexpr,marg,u) ->
      SEBapply (lighten_modexpr mexpr,lighten_modexpr marg,u)
  | SEBwith (seb,wdcl) ->
      SEBwith (lighten_modexpr seb,wdcl)

let lighten_library (dp,mb,depends,s) = (dp,lighten_module mb,depends,s)


type judgment = unsafe_judgment

let unsafe_judgment_of_safe =
  fun (x : judgment) -> (x : unsafe_judgment)

let j_val j = j.uj_val
let j_type j = j.uj_type

let safe_infer senv = infer (env_of_senv senv)

let typing senv = Typeops.typing (env_of_senv senv)

 
(* Decision procedures *)
module HasAxioms : sig
  val hasaxioms : Environ.env -> constr -> bool
end = struct
  exception HasAxioms
  
  type bag_t = {
    bg_ids    : Names.Idset.t;
    bg_consts : Names.Cset.t;
  }
  
  let hasaxioms = fun env ->
    let rec noaxioms = fun bag t ->
      match Term.kind_of_term t with
      | Rel _                    -> bag
      | Var x                    -> noaxioms_var bag x
      | Const c                  -> noaxioms_const bag c
      | Sort _                   -> bag
      | Cast   (t1, _, t2)       -> fold bag [|t1; t2|]
      | Prod   (_, t1, t2)       -> fold bag [|t1; t2|]
      | Lambda (_, t1, t2)       -> fold bag [|t1; t2|]
      | LetIn  (_, t1, t2, t3)   -> fold bag [|t1; t2; t3|]
      | App    (t1, t2)          -> fold (noaxioms bag t1) t2
      | Ind    _                 -> bag
      | Construct _              -> bag
      | Case (_, t1, t2, ts)     -> fold (fold bag [|t1; t2|]) ts
      | Fix   (_, (_, ts1, ts2)) -> fold (fold bag ts1) ts2
      | CoFix (_, (_, ts1, ts2)) -> fold (fold bag ts1) ts2
  
      | Meta _ -> Util.anomaly "noaxioms: unexpected [Meta]"
      | Evar _ -> Util.anomaly "noaxioms: unexpetedt [Evar]"
  
    and fold = fun bag array ->
      Array.fold_left noaxioms bag array
  
    and noaxioms_var = fun bag x ->
      if   Names.Idset.mem x bag.bg_ids
      then bag
      else begin
        match Environ.lookup_named x env with
          | (_, None   , _) -> raise HasAxioms
          | (_, Some bd, _) ->
              let bag = { bag with bg_ids = Names.Idset.add x bag.bg_ids } in
                noaxioms bag bd
      end
  
    and noaxioms_const = fun bag c ->
      if   Names.Cset.mem c bag.bg_consts
      then bag
      else begin
        let cb = Environ.lookup_constant c env in
          match cb.Declarations.const_body with
            | None    -> raise HasAxioms
            | Some bd ->
                let bag = { bag with bg_consts = Names.Cset.add c bag.bg_consts } in
                  noaxioms bag (Declarations.force bd)
      end
    in
      fun t ->
        let emptybag =
          { bg_ids    = Names.Idset.empty;
            bg_consts = Names.Cset.empty }
        in
          try
            (ignore : bag_t -> unit) (noaxioms emptybag t);
            false
          with HasAxioms -> true
end

module DP =
struct
  open Decproc
  open Decproc.FOTerm

  module CoqLogicBinding =
  struct
    type coq_logic = {
      cql_true  : constr;
      cql_false : constr;
      cql_eq    : constr;
      cql_not   : constr;
      cql_and   : constr;
      cql_conj  : constr;
      cql_or    : constr;
      cql_ex    : constr;
    }
  
    let __coq_logic = (ref None : coq_logic option ref)
  
    let register_coq_logic = fun cql ->
      match !__coq_logic with
      | None   -> __coq_logic := Some cql
      | Some _ -> failwith "[register_coq_logic] : already registered"
  
    let coq_logic = fun () -> !__coq_logic
  
    let coq_logic_exn = fun () ->
      match !__coq_logic with
      | None     -> failwith "[coq_logic] : nothing registered"
      | Some cql -> (cql : coq_logic)
  end

  open CoqLogicBinding

  let _coq_True  = fun () -> (coq_logic_exn ()).cql_true
  let _coq_False = fun () -> (coq_logic_exn ()).cql_false
  let _coq_eq    = fun () -> (coq_logic_exn ()).cql_eq
  let _coq_not   = fun () -> (coq_logic_exn ()).cql_not
  let _coq_and   = fun () -> (coq_logic_exn ()).cql_and
  let _coq_conj  = fun () -> (coq_logic_exn ()).cql_conj
  let _coq_or    = fun () -> (coq_logic_exn ()).cql_or
  let _coq_ex    = fun () -> (coq_logic_exn ()).cql_ex

  module Conversion : sig
    open FOTerm

    exception ConversionError of string

    val coqentry   : entry -> constr
    val coqarity   : types -> int -> types
    val coqsymbol  : binding -> symbol -> constr
    val coqterm    : binding -> string list -> sfterm -> constr
    val coqformula : binding -> sfformula -> types
  end = struct
    exception ConversionError of string

    let _e_UnboundSymbol = fun f ->
      Printf.sprintf "Unbounded symbol: [%s]" f
    let _e_UnboundVariable = fun x ->
      Printf.sprintf "Unbounded variable: [%s]" x

    let coqentry = function
      | DPE_Constructor c -> Term.mkConstruct c
      | DPE_Constant    c -> Term.mkConst     c
      | DPE_Inductive   i -> Term.mkInd       i

    let coqarity = fun ty ->
      let rec coqarity = fun i acc ->
        if   i = 0
        then acc
        else coqarity (i-1) (mkProd (Names.Anonymous, ty, acc))
      in
        fun i ->
          if i < 0 then
            raise (Invalid_argument "[coqarity _ ty] with i < 0");
          coqarity i ty
            
    let coqsymbol = fun binding f ->
      try  coqentry (List.assoc f binding.dpb_bsymbols)
      with Not_found ->
        raise (ConversionError (_e_UnboundSymbol (uncname f.s_name)))

    let coqterm = fun binding varbinds ->
      let rec coqterm = function
        | FVar (CName x) -> begin
            try  Term.mkRel (Util.list_index x varbinds)
            with Not_found -> raise (ConversionError (_e_UnboundVariable x))
          end

        | FSymb (f, ts) ->
            let f  = coqsymbol binding f
            and ts = Array.of_list (List.map coqterm ts) in
              Term.mkApp (f, ts)
      in
        fun (t : sfterm) -> coqterm t

    let coqformula = fun binding ->
      let btype = coqentry binding.dpb_bsort in
      let rec coqformula = fun varbinds -> function
        | FTrue  -> _coq_True  ()
        | FFalse -> _coq_False ()

        | FEq (left, right) ->
            let left  = coqterm binding varbinds left
            and right = coqterm binding varbinds right in
              Term.mkApp (_coq_eq (), [|btype; left; right|])

        | FNeg phi ->
            let phi = coqformula varbinds phi in
              Term.mkApp (_coq_not (), [|phi|])

        | FAnd (left, right) ->
            let left  = coqformula varbinds left
            and right = coqformula varbinds right in
              Term.mkApp (_coq_and (), [|left; right|])

        | FOr (left, right) ->
            let left  = coqformula varbinds left
            and right = coqformula varbinds right in
              Term.mkApp (_coq_or (), [|left; right|])

        | FImply (left, right) ->
            let left  = coqformula varbinds left
            and right = coqformula varbinds right in
              Term.mkProd (Names.Anonymous, left, right)

        | FAll (vars, phi) ->
            let vars = List.map uncname (List.rev vars) in
              List.fold_left
                (fun coqphi var ->
                   let var = Names.Name (Names.id_of_string var) in
                     Term.mkProd (var, btype, coqphi))
                (coqformula (vars @ varbinds) phi) vars

        | FExist (vars, phi) ->
            let vars = List.map uncname (List.rev vars) in
              List.fold_left
                (fun coqphi var ->
                   let var    = Names.Name (Names.id_of_string var) in
                   let expred = Term.mkLambda (var, btype, coqphi)  in
                     Term.mkApp (_coq_ex (), [|btype; expred|]))
                (coqformula (vars @ varbinds) phi) vars

      in
        fun t -> coqformula [] t
  end

  open Conversion

  let bindings = fun senv ->
    Environ.DP.bindings senv.env

  let theories = fun senv ->
    Environ.DP.theories senv.env

  let add_binding = fun (senv : safe_environment) binding witnesses ->
    assert (List.length witnesses = List.length binding.dpb_theory.dpi_axioms);

    (* Check that fo-constructors are mapped to CIC constructors *)
    List.iter
      (fun (symbol, entry) ->
         if symbol.s_status = FConstructor then begin
           match entry with
             | DPE_Constructor _ -> ()
             | _ ->
                 error "theory constructors must be mapped to Coq constructors"
         end)
      binding.dpb_bsymbols;

    (* Check arities *)
    List.iter
      (fun (symbol, entry) ->
         let coqarity = coqarity (coqentry binding.dpb_bsort) symbol.s_arity
         and entryT   = j_type (typing senv (coqentry entry))
         in
           try  ignore (conv_leq senv.env entryT coqarity)
           with
           | NotConvertible ->
               error
                 (Printf.sprintf
                    "invalid bound symbol arity for symbol [%s]"
                    (uncname symbol.s_name)))
      binding.dpb_bsymbols;

    (* Check axioms witnesses *)
    list_iter2_i
      (fun i witness axiom ->
         if HasAxioms.hasaxioms senv.env witness then
           error (Printf.sprintf "witness #%d depends on assumptions" (i+1));
         let coqtype  = coqformula binding (FOTerm.formula_of_safe axiom)
         and witnessT = typing senv witness
         in
           try
             ignore (conv_leq senv.env (j_type witnessT) coqtype)
           with
           | NotConvertible ->
               let error =
                 ActualType (unsafe_judgment_of_safe witnessT, coqtype)
               in
                 raise (TypeError (senv.env, error)))
      witnesses binding.dpb_theory.dpi_axioms;

    (* All checks done, add binding to environment *)
    { senv with
        env       = Environ.DP.add_binding senv.env binding;
        dpopcodes = OpCodes.DP_Bind (OpCodes.of_binding binding) :: senv.dpopcodes; }

  let add_theory = fun senv theory ->
    { senv with
        env       = Environ.DP.add_theory senv.env theory;
        dpopcodes = OpCodes.DP_Load theory.dpi_name :: senv.dpopcodes; }

  let find_theory = fun senv name ->
    Environ.DP.find_theory senv.env name
end
