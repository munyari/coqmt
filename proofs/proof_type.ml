(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id: proof_type.ml 12168 2009-06-06 21:34:37Z herbelin $ *)

(*i*)
open Environ
open Evd
open Names
open Libnames
open Term
open Util
open Tacexpr
open Decl_expr
open Rawterm
open Genarg
open Nametab
open Pattern
(*i*)

(* This module defines the structure of proof tree and the tactic type. So, it
   is used by Proof_tree and Refiner *)

type prim_rule =
  | Intro of identifier
  | Cut of bool * bool * identifier * types
  | FixRule of identifier * int * (identifier * int * constr) list * int
  | Cofix of identifier * (identifier * constr) list * int
  | Refine of constr
  | Convert_concl of types * cast_kind
  | Convert_hyp of named_declaration
  | Thin of identifier list
  | ThinBody of identifier list
  | Move of bool * identifier * identifier move_location
  | Order of identifier list
  | Rename of identifier * identifier
  | Change_evars

type proof_tree = {
  open_subgoals : int;
  goal : goal;
  ref : (rule * proof_tree list) option }

and rule =
  | Prim of prim_rule
  | Nested of compound_rule * proof_tree 
  | Decl_proof of bool
  | Daimon

and compound_rule=  
  | Tactic of tactic_expr * bool
  | Proof_instr of bool*proof_instr (* the boolean is for focus restrictions *)

and goal = evar_info

and tactic = goal sigma -> (goal list sigma * validation)

and validation = (proof_tree list -> proof_tree)

and tactic_expr =
  (open_constr,
   constr_pattern,
   evaluable_global_reference,
   inductive,
   ltac_constant,
   identifier,
   glob_tactic_expr)
     Tacexpr.gen_tactic_expr

and atomic_tactic_expr =
  (open_constr,
   constr_pattern,
   evaluable_global_reference,
   inductive,
   ltac_constant,
   identifier,
   glob_tactic_expr)
     Tacexpr.gen_atomic_tactic_expr

and tactic_arg =
  (open_constr,
   constr_pattern,
   evaluable_global_reference,
   inductive,
   ltac_constant,
   identifier,
   glob_tactic_expr)
     Tacexpr.gen_tactic_arg

type hyp_location = identifier Tacexpr.raw_hyp_location

type ltac_call_kind = 
  | LtacNotationCall of string
  | LtacNameCall of ltac_constant
  | LtacAtomCall of glob_atomic_tactic_expr * atomic_tactic_expr option ref
  | LtacVarCall of identifier * glob_tactic_expr
  | LtacConstrInterp of rawconstr *
      ((identifier * constr) list * (identifier * identifier option) list)

type ltac_trace = (loc * ltac_call_kind) list

exception LtacLocated of (ltac_call_kind * ltac_trace * loc) * exn

let abstract_tactic_box = ref (ref None)
