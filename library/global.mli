(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2011     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id: global.mli 13323 2010-07-24 15:57:30Z herbelin $ i*)

(*i*)
open Names
open Univ
open Term
open Declarations
open Entries
open Indtypes
open Mod_subst
open Safe_typing
   (*i*)

(* This module defines the global environment of Coq.  The functions
   below are exactly the same as the ones in [Safe_typing], operating on
   that global environment. [add_*] functions perform name verification,
   i.e. check that the name given as argument match those provided by
   [Safe_typing]. *)



val safe_env : unit -> safe_environment
val env : unit -> Environ.env

val env_is_empty : unit -> bool

val universes : unit -> universes
val named_context_val : unit -> Environ.named_context_val
val named_context : unit -> Sign.named_context

val env_is_empty : unit -> bool

(*s Extending env with variables and local definitions *)
val push_named_assum : (identifier * types) -> Univ.constraints
val push_named_def   : (identifier * constr * types option) -> Univ.constraints

(*s Adding constants, inductives, modules and module types.  All these
  functions verify that given names match those generated by kernel *)

val add_constant :
  dir_path -> identifier -> global_declaration -> constant
val add_mind        :
  dir_path -> identifier -> mutual_inductive_entry -> mutual_inductive

val add_module      :
 identifier -> module_entry -> bool -> module_path * delta_resolver
val add_modtype     :
 identifier -> module_struct_entry -> bool -> module_path
val add_include :
 module_struct_entry -> bool -> bool -> delta_resolver

val add_constraints : constraints -> unit

val set_engagement : engagement -> unit

(*s Interactive modules and module types *)
(* Both [start_*] functions take the [dir_path] argument to create a
   [mod_self_id]. This should be the name of the compilation unit. *)

(* [start_*] functions return the [module_path] valid for components
   of the started module / module type *)

val start_module : identifier -> module_path

val end_module : Summary.frozen ->identifier ->
  (module_struct_entry * bool) option -> module_path * delta_resolver

val add_module_parameter :
 mod_bound_id -> module_struct_entry -> bool -> delta_resolver

val start_modtype : identifier -> module_path
val end_modtype : Summary.frozen -> identifier -> module_path
val pack_module : unit -> module_body


(* Queries *)
val lookup_named     : variable -> named_declaration
val lookup_constant  : constant -> constant_body
val lookup_inductive : inductive -> mutual_inductive_body * one_inductive_body
val lookup_mind      : mutual_inductive -> mutual_inductive_body
val lookup_module    : module_path -> module_body
val lookup_modtype   : module_path -> module_type_body
val constant_of_delta : constant -> constant
val mind_of_delta : mutual_inductive -> mutual_inductive

(* Compiled modules *)
val start_library : dir_path -> module_path
val export : dir_path -> module_path * compiled_library
val import : compiled_library -> Digest.t -> module_path

(*s Function to get an environment from the constants part of the global
 * environment and a given context. *)

val type_of_global : Libnames.global_reference -> types
val env_of_context : Environ.named_context_val -> Environ.env


(* spiwack: register/unregister function for retroknowledge *)
val register : Retroknowledge.field -> constr -> constr -> unit

(* Decision procedures *)
module DP : sig
  val bindings    : unit -> Decproc.Bindings.t
  val theories    : unit -> Decproc.dpinfos list
  val add_binding : Decproc.binding -> constr list -> unit
  val add_theory  : Decproc.dpinfos -> unit
  val find_theory : string -> Decproc.dpinfos option
end
