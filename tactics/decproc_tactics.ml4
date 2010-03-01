(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i camlp4deps: "parsing/grammar.cma" i*)

open Pp
open Pcoq
open Genarg
open Term
open Decproc
open Decproc.FOTerm

(* -------------------------------------------------------------------- *)
module Conversion : sig
  open FOTerm

  exception ConversionError of string

  val coqentry   : entry -> constr
  val coqarity   : types -> int -> types
  val coqsymbol  : binding -> symbol -> constr
  val coqterm    : binding -> string list -> sfterm -> constr
  val coqformula : binding -> types -> sfformula -> types
end = struct
  open FOTerm

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

  let coqformula = fun binding btype ->
    let rec coqformula = fun varbinds -> function
      | FTrue  -> Coqlib.build_coq_True  ()
      | FFalse -> Coqlib.build_coq_False ()

      | FEq (left, right) ->
          let left  = coqterm binding varbinds left
          and right = coqterm binding varbinds right in
            Term.mkApp (Coqlib.build_coq_eq (), [|btype; left; right|])

      | FNeg phi ->
          let phi = coqformula varbinds phi in
            Term.mkApp (Coqlib.build_coq_not (), [|phi|])

      | FAnd (left, right) ->
          let left  = coqformula varbinds left
          and right = coqformula varbinds right in
            Term.mkApp (Coqlib.build_coq_and (), [|left; right|])

      | FOr (left, right) ->
          let left  = coqformula varbinds left
          and right = coqformula varbinds right in
            Term.mkApp (Coqlib.build_coq_or (), [|left; right|])

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
                   Term.mkApp (Coqlib.build_coq_ex (), [|btype; expred|]))
              (coqformula (vars @ varbinds) phi) vars

    in
      fun t -> coqformula [] t
end

(* -------------------------------------------------------------------- *)
type pid_ctr_map = string * Topconstr.constr_expr

type 'a pid_ctr_map_argtype =
    (pid_ctr_map, 'a) Genarg.abstract_argument_type

let constr_of_topconstr = fun tc ->
  Constrintern.interp_constr Evd.empty (Global.env ()) tc

let
  (wit_pid_ctr_map     : Genarg.tlevel pid_ctr_map_argtype) ,
  (globwit_pid_ctr_map : Genarg.glevel pid_ctr_map_argtype) ,
  (rawwit_pid_ctr_map  : Genarg.rlevel pid_ctr_map_argtype) =
  Genarg.create_arg "r_pid_ctr_map"

let pr_pid_ctr_map = fun _ _ _ (x, c) ->
  (Ppconstr.pr_constr_expr c) ++ (str " for ") ++ (str x)

let pr_ne_pid_ctr_map =
  fun prc prlc prt xs ->
    Util.prlist_with_sep
      Util.pr_coma (pr_pid_ctr_map prc prlc prt) xs

let pr_nelist_constr =
  fun prc _prlc _prt xs ->
    Util.prlist_with_sep Util.pr_coma prc xs

ARGUMENT EXTEND pid_ctr_map
    TYPED AS pid_ctr_map
    PRINTED BY pr_pid_ctr_map
  | [ constr(c) "for" preident(x) ] -> [ (x, c) ]
END

ARGUMENT EXTEND nelist_pid_ctr_map
    TYPED AS   pid_ctr_map list
    PRINTED BY pr_ne_pid_ctr_map

| [ pid_ctr_map(x) "," nelist_pid_ctr_map(l) ] -> [ x :: l ]
| [ pid_ctr_map(x) ]                           -> [ [x] ]
END

ARGUMENT EXTEND nelist_constr
    TYPED AS constr list
    PRINTED BY pr_nelist_constr

| [ constr(x) "," nelist_constr(xs) ] -> [ x :: xs ]
| [ constr(x) ]                       -> [ [x] ]
END

VERNAC COMMAND EXTEND DecProcBind
| [ "Load" "Theory" preident(theory) ] -> [
    match Decproc.global_find_theory theory with
    | None -> Util.error (Printf.sprintf "theory not found: %s" theory)
    | Some theory -> Global.DP.add_theory theory
  ]

| [ "Bind" "Theory" preident(theory) "As" preident(name)
      "Sort"    "Binded" "By" constr(bsort)
      "Symbols" "Binded" "By" nelist_pid_ctr_map(symbols)
      "Axioms"  "Proved" "By" nelist_constr(axioms)
  ] -> [
    let theory =
      match Global.DP.find_theory theory with
      | None ->
          Util.error (Printf.sprintf "cannot find theory: %s" theory)
      | Some theory -> theory
    in
    let entry_of_topconstr = fun tc ->
      match kind_of_term (constr_of_topconstr tc) with
      | Const     const       -> DPE_Constant    const
      | Construct constructor -> DPE_Constructor constructor
      | Ind       inductive   -> DPE_Inductive   inductive
      | _                     ->
          Util.error
            "can only bind constant, constructor and inductive types"
    in
    let symbols =
      List.map
        (fun (x, c) -> (mkcname x, entry_of_topconstr c))
        symbols
    and bsort = entry_of_topconstr bsort
    and name  = Names.id_of_string name
    in
    let binding =
      try
        mkbinding theory name bsort symbols
      with
        | Decproc.InvalidBinding s ->
            let message = Printf.sprintf "Invalid binding: %s" s in
              Util.error message
    in
      (* Check that fo-constructors are mapped to CIC constructors *)
      List.iter
        (fun (symbol, entry) ->
           if symbol.s_status = FConstructor then begin
             match entry with
             | DPE_Constructor _ -> ()
             | _ ->
                 Util.error "theory constructors must be mapped to Coq constructors"
           end)
        binding.dpb_bsymbols;

      (* Check arities *)
      List.iter
        (fun (symbol, entry) ->
           let coqarity =
             Conversion.coqarity (Conversion.coqentry bsort) symbol.s_arity
           in let entryT =
             Safe_typing.j_type
               (Safe_typing.typing
                  (Global.safe_env ()) (Conversion.coqentry entry))
           in
             try
               ignore (Reduction.conv_leq (Global.env ()) entryT coqarity);
             with
               | Reduction.NotConvertible ->
                   let message =
                     Printf.sprintf
                       "invalid bound symbol arity for symbol [%s]"
                       (uncname symbol.s_name)
                   in
                     Util.error message)
        binding.dpb_bsymbols;

      (* Check axioms witnesses *)
      if List.length axioms <> List.length theory.dpi_axioms then begin
        let message =
          Printf.sprintf
            "not the right numbers of axioms proofs (%d <> %d)"
            (List.length axioms) (List.length theory.dpi_axioms)
        in
          Util.error message
      end;
      Util.list_iter2_i
        (fun i witness axiom ->
           let coqtype =
             Conversion.coqformula binding (Conversion.coqentry bsort)
               (FOTerm.formula_of_safe axiom)
           in let witness =
               Constrintern.interp_constr Evd.empty (Global.env ()) witness
           in let witnessT =
               Safe_typing.typing (Global.safe_env ()) witness
           in
             try
               ignore
                 (Reduction.conv_leq
                    (Global.env ()) (Safe_typing.j_type witnessT) coqtype)
             with
               | Reduction.NotConvertible ->
                   let message =
                     Himsg.explain_type_error (Global.env ())
                       (Type_errors.ActualType
                          (Safe_typing.unsafe_judgment_of_safe witnessT, coqtype))
                   in
                     Util.errorlabstrm "" message)
        axioms theory.dpi_axioms;
      Global.DP.add_binding binding 
  ]
END

VERNAC COMMAND EXTEND DecProcAdmin
| [ "Parse" "Formula" string(formula) ] -> [
    let formula = Decproc.Parsing.ofstring formula in
      Printf.fprintf stderr "%s\n%!" (Decproc.Parsing.tostring formula)
  ]

| [ "DP" preident(command) ] -> [
    match command with
    | "theories" -> 
        Printf.printf "%s\n%!"
          (String.concat ", "
             (List.map (fun x -> uncname x.dpi_name) (Global.DP.theories ())))
    | "bindings" ->
        List.iter
          (fun binding ->
             Printf.printf "%s\n%!" (Names.string_of_id binding.dpb_name))
          (Bindings.all (Global.DP.bindings ()))

    | _ -> Util.error (Printf.sprintf "Unknown DP command: %s" command)
  ]
END
