(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2011     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id: BoolEq.v 13323 2010-07-24 15:57:30Z herbelin $ i*)
(* Cuihtlauac Alvarado - octobre 2000 *)

(** Properties of a boolean equality   *)


Require Export Bool.

Section Bool_eq_dec.

  Variable A : Set.

  Variable beq : A -> A -> bool.

  Variable beq_refl : forall x:A, true = beq x x.

  Variable beq_eq : forall x y:A, true = beq x y -> x = y.

  Definition beq_eq_true : forall x y:A, x = y -> true = beq x y.
  Proof.
    intros x y H.
    case H.
    apply beq_refl.
  Defined.

  Definition beq_eq_not_false : forall x y:A, x = y -> false <> beq x y.
  Proof.
    intros x y e.
    rewrite <- beq_eq_true; trivial; discriminate.
  Defined.

  Definition beq_false_not_eq : forall x y:A, false = beq x y -> x <> y.
  Proof.
    exact
     (fun (x y:A) (H:false = beq x y) (e:x = y) => beq_eq_not_false x y e H).
  Defined.

  Definition exists_beq_eq : forall x y:A, {b : bool | b = beq x y}.
  Proof.
    intros.
    exists (beq x y).
    constructor.
  Defined.

  Definition not_eq_false_beq : forall x y:A, x <> y -> false = beq x y.
  Proof.
    intros x y H.
    symmetry  in |- *.
    apply not_true_is_false.
    intro.
    apply H.
    apply beq_eq.
    symmetry  in |- *.
    assumption.
  Defined.

  Definition eq_dec : forall x y:A, {x = y} + {x <> y}.
  Proof.
    intros x y; case (exists_beq_eq x y).
    intros b; case b; intro H.
      left; apply beq_eq; assumption.
      right; apply beq_false_not_eq; assumption.
  Defined.

End Bool_eq_dec.
