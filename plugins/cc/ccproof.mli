(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2011     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id: ccproof.mli 13323 2010-07-24 15:57:30Z herbelin $ *)

open Ccalgo
open Names
open Term

type rule=
    Ax of constr
  | SymAx of constr
  | Refl of term
  | Trans of proof*proof
  | Congr of proof*proof
  | Inject of proof*constructor*int*int
and proof =
    private {p_lhs:term;p_rhs:term;p_rule:rule}

val build_proof :
  forest ->
  [ `Discr of int * pa_constructor * int * pa_constructor
  | `Prove of int * int ] -> proof



