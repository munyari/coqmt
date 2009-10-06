(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id: g_natsyntax.mli 11087 2008-06-10 13:29:52Z letouzey $ i*)

(* Nice syntax for naturals. *)

open Notation

val nat_of_int : Bigint.bigint prim_token_interpreter
