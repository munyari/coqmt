(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2011     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id: printer.mli 13323 2010-07-24 15:57:30Z herbelin $ i*)

(*i*)
open Pp
open Names
open Libnames
open Term
open Sign
open Environ
open Rawterm
open Pattern
open Nametab
open Termops
open Evd
open Proof_type
open Rawterm
open Tacexpr
(*i*)

(* These are the entry points for printing terms, context, tac, ... *)

(* Terms *)

val pr_lconstr_env         : env -> constr -> std_ppcmds
val pr_lconstr_env_at_top  : env -> constr -> std_ppcmds
val pr_lconstr             : constr -> std_ppcmds

val pr_constr_env          : env -> constr -> std_ppcmds
val pr_constr              : constr -> std_ppcmds

val pr_open_constr_env     : env -> open_constr -> std_ppcmds
val pr_open_constr         : open_constr -> std_ppcmds

val pr_open_lconstr_env    : env -> open_constr -> std_ppcmds
val pr_open_lconstr        : open_constr -> std_ppcmds

val pr_constr_under_binders_env  : env -> constr_under_binders -> std_ppcmds
val pr_constr_under_binders      : constr_under_binders -> std_ppcmds

val pr_lconstr_under_binders_env : env -> constr_under_binders -> std_ppcmds
val pr_lconstr_under_binders     : constr_under_binders -> std_ppcmds

val pr_ltype_env_at_top    : env -> types -> std_ppcmds
val pr_ltype_env           : env -> types -> std_ppcmds
val pr_ltype               : types -> std_ppcmds

val pr_type_env            : env -> types -> std_ppcmds
val pr_type                : types -> std_ppcmds

val pr_ljudge_env          : env -> unsafe_judgment -> std_ppcmds * std_ppcmds
val pr_ljudge              : unsafe_judgment -> std_ppcmds * std_ppcmds

val pr_lrawconstr_env      : env -> rawconstr -> std_ppcmds
val pr_lrawconstr          : rawconstr -> std_ppcmds

val pr_rawconstr_env       : env -> rawconstr -> std_ppcmds
val pr_rawconstr           : rawconstr -> std_ppcmds

val pr_lconstr_pattern_env : env -> constr_pattern -> std_ppcmds
val pr_lconstr_pattern     : constr_pattern -> std_ppcmds

val pr_constr_pattern_env  : env -> constr_pattern -> std_ppcmds
val pr_constr_pattern      : constr_pattern -> std_ppcmds

val pr_cases_pattern       : cases_pattern -> std_ppcmds

val pr_sort                : sorts -> std_ppcmds

(* Printing global references using names as short as possible *)

val pr_global_env          : Idset.t -> global_reference -> std_ppcmds
val pr_global              : global_reference -> std_ppcmds

val pr_constant            : env -> constant -> std_ppcmds
val pr_existential         : env -> existential -> std_ppcmds
val pr_constructor         : env -> constructor -> std_ppcmds
val pr_inductive           : env -> inductive -> std_ppcmds
val pr_evaluable_reference : evaluable_global_reference -> std_ppcmds

(* Printers for DP theories and bindings *)
val pr_theories            : env -> std_ppcmds
val pr_bindings            : ?name:string -> env -> Pp.std_ppcmds

(* Contexts *)

val pr_ne_context_of       : std_ppcmds -> env -> std_ppcmds

val pr_var_decl            : env -> named_declaration -> std_ppcmds
val pr_rel_decl            : env -> rel_declaration -> std_ppcmds

val pr_named_context       : env -> named_context -> std_ppcmds
val pr_named_context_of    : env -> std_ppcmds
val pr_rel_context         : env -> rel_context -> std_ppcmds
val pr_rel_context_of      : env -> std_ppcmds
val pr_context_of          : env -> std_ppcmds

(* Predicates *)

val pr_predicate           : ('a -> std_ppcmds) -> (bool * 'a list) -> std_ppcmds
val pr_cpred               : Cpred.t -> std_ppcmds
val pr_idpred              : Idpred.t -> std_ppcmds
val pr_transparent_state   : transparent_state -> std_ppcmds

(* Proofs *)

val pr_goal                : goal -> std_ppcmds
val pr_subgoals            : string option -> evar_map -> goal list -> std_ppcmds
val pr_subgoal             : int -> goal list -> std_ppcmds

val pr_open_subgoals       : unit -> std_ppcmds
val pr_nth_open_subgoal    : int -> std_ppcmds
val pr_evars_int           : int -> (evar * evar_info) list -> std_ppcmds

val pr_prim_rule           : prim_rule -> std_ppcmds

(* Emacs/proof general support *)
(* (emacs_str s alts) outputs
   - s if emacs mode & unicode allowed,
   - alts if emacs mode and & unicode not allowed
   - nothing otherwise *)
val emacs_str              : string -> string -> string

(* Backwards compatibility *)

val prterm                 : constr -> std_ppcmds (* = pr_lconstr *)


(* spiwack: printer function for sets of Environ.assumption.
            It is used primarily by the Print Assumption command. *)
val pr_assumptionset :
  env -> Term.types Assumptions.ContextObjectMap.t ->std_ppcmds


type printer_pr = {
 pr_subgoals            : string option -> evar_map -> goal list -> std_ppcmds;
 pr_subgoal             : int -> goal list -> std_ppcmds;
 pr_goal                : goal -> std_ppcmds;
};;

val set_printer_pr : printer_pr -> unit

val default_printer_pr : printer_pr

val pr_instance_gmap : (global_reference, Typeclasses.instance Names.Cmap.t) Gmap.t ->
  Pp.std_ppcmds
