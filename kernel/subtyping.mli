(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2011     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id: subtyping.mli 13323 2010-07-24 15:57:30Z herbelin $ i*)

(*i*)
open Univ
open Declarations
open Environ
(*i*)

val check_subtypes : env -> module_type_body -> module_type_body -> constraints


