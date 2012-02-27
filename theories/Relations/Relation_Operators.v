(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2011     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i $Id: Relation_Operators.v 13323 2010-07-24 15:57:30Z herbelin $ i*)

(************************************************************************)
(** *                   Bruno Barras, Cristina Cornes                   *)
(** *                                                                   *)
(** * Some of these definitions were taken from :                       *)
(** *    Constructing Recursion Operators in Type Theory                *)
(** *    L. Paulson  JSC (1986) 2, 325-355                              *)
(************************************************************************)

Require Import Relation_Definitions.

(** * Some operators to build relations *)

(** ** Transitive closure *)

Section Transitive_Closure.
  Variable A : Type.
  Variable R : relation A.

  (** Definition by direct transitive closure *)

  Inductive clos_trans (x: A) : A -> Prop :=
    | t_step (y:A) : R x y -> clos_trans x y
    | t_trans (y z:A) : clos_trans x y -> clos_trans y z -> clos_trans x z.

  (** Alternative definition by transitive extension on the left *)

  Inductive clos_trans_1n (x: A) : A -> Prop :=
    | t1n_step (y:A) : R x y -> clos_trans_1n x y
    | t1n_trans (y z:A) : R x y -> clos_trans_1n y z -> clos_trans_1n x z.

  (** Alternative definition by transitive extension on the right *)

  Inductive clos_trans_n1 (x: A) : A -> Prop :=
    | tn1_step (y:A) : R x y -> clos_trans_n1 x y
    | tn1_trans (y z:A) : R y z -> clos_trans_n1 x y -> clos_trans_n1 x z.

End Transitive_Closure.

(** ** Reflexive-transitive closure *)

Section Reflexive_Transitive_Closure.
  Variable A : Type.
  Variable R : relation A.

  (** Definition by direct reflexive-transitive closure *)

  Inductive clos_refl_trans (x:A) : A -> Prop :=
    | rt_step (y:A) : R x y -> clos_refl_trans x y
    | rt_refl : clos_refl_trans x x
    | rt_trans (y z:A) :
          clos_refl_trans x y -> clos_refl_trans y z -> clos_refl_trans x z.

  (** Alternative definition by transitive extension on the left *)

  Inductive clos_refl_trans_1n (x: A) : A -> Prop :=
    | rt1n_refl : clos_refl_trans_1n x x
    | rt1n_trans (y z:A) :
         R x y -> clos_refl_trans_1n y z -> clos_refl_trans_1n x z.

  (** Alternative definition by transitive extension on the right *)

 Inductive clos_refl_trans_n1 (x: A) : A -> Prop :=
    | rtn1_refl : clos_refl_trans_n1 x x
    | rtn1_trans (y z:A) :
        R y z -> clos_refl_trans_n1 x y -> clos_refl_trans_n1 x z.

End Reflexive_Transitive_Closure.

(** ** Reflexive-symmetric-transitive closure *)

Section Reflexive_Symmetric_Transitive_Closure.
  Variable A : Type.
  Variable R : relation A.

  (** Definition by direct reflexive-symmetric-transitive closure *)

  Inductive clos_refl_sym_trans : relation A :=
    | rst_step (x y:A) : R x y -> clos_refl_sym_trans x y
    | rst_refl (x:A) : clos_refl_sym_trans x x
    | rst_sym (x y:A) : clos_refl_sym_trans x y -> clos_refl_sym_trans y x
    | rst_trans (x y z:A) :
        clos_refl_sym_trans x y ->
        clos_refl_sym_trans y z -> clos_refl_sym_trans x z.

  (** Alternative definition by symmetric-transitive extension on the left *)

  Inductive clos_refl_sym_trans_1n (x: A) : A -> Prop :=
    | rst1n_refl : clos_refl_sym_trans_1n x x
    | rst1n_trans (y z:A) : R x y \/ R y x ->
         clos_refl_sym_trans_1n y z -> clos_refl_sym_trans_1n x z.

  (** Alternative definition by symmetric-transitive extension on the right *)

  Inductive clos_refl_sym_trans_n1 (x: A) : A -> Prop :=
    | rstn1_refl : clos_refl_sym_trans_n1 x x
    | rstn1_trans (y z:A) : R y z \/ R z y ->
         clos_refl_sym_trans_n1 x y -> clos_refl_sym_trans_n1 x z.

End Reflexive_Symmetric_Transitive_Closure.

(** ** Converse of a relation *)

Section Converse.
  Variable A : Type.
  Variable R : relation A.

  Definition transp (x y:A) := R y x.
End Converse.

(** ** Union of relations *)

Section Union.
  Variable A : Type.
  Variables R1 R2 : relation A.

  Definition union (x y:A) := R1 x y \/ R2 x y.
End Union.

(** ** Disjoint union of relations *)

Section Disjoint_Union.
Variables A B : Type.
Variable leA : A -> A -> Prop.
Variable leB : B -> B -> Prop.

Inductive le_AsB : A + B -> A + B -> Prop :=
  | le_aa (x y:A) : leA x y -> le_AsB (inl _ x) (inl _ y)
  | le_ab (x:A) (y:B) : le_AsB (inl _ x) (inr _ y)
  | le_bb (x y:B) : leB x y -> le_AsB (inr _ x) (inr _ y).

End Disjoint_Union.

(** ** Lexicographic order on dependent pairs *)

Section Lexicographic_Product.

  Variable A : Type.
  Variable B : A -> Type.
  Variable leA : A -> A -> Prop.
  Variable leB : forall x:A, B x -> B x -> Prop.

  Inductive lexprod : sigS B -> sigS B -> Prop :=
    | left_lex :
      forall (x x':A) (y:B x) (y':B x'),
        leA x x' -> lexprod (existS B x y) (existS B x' y')
    | right_lex :
      forall (x:A) (y y':B x),
        leB x y y' -> lexprod (existS B x y) (existS B x y').

End Lexicographic_Product.

(** ** Product of relations *)

Section Symmetric_Product.
  Variable A : Type.
  Variable B : Type.
  Variable leA : A -> A -> Prop.
  Variable leB : B -> B -> Prop.

  Inductive symprod : A * B -> A * B -> Prop :=
    | left_sym :
      forall x x':A, leA x x' -> forall y:B, symprod (x, y) (x', y)
    | right_sym :
      forall y y':B, leB y y' -> forall x:A, symprod (x, y) (x, y').

End Symmetric_Product.

(** ** Multiset of two relations *)

Section Swap.
  Variable A : Type.
  Variable R : A -> A -> Prop.

  Inductive swapprod : A * A -> A * A -> Prop :=
    | sp_noswap x y (p:A * A) : symprod A A R R (x, y) p -> swapprod (x, y) p
    | sp_swap x y (p:A * A) : symprod A A R R (x, y) p -> swapprod (y, x) p.
End Swap.

Local Open Scope list_scope.

Section Lexicographic_Exponentiation.

  Variable A : Set.
  Variable leA : A -> A -> Prop.
  Let Nil := nil (A:=A).
  Let List := list A.

  Inductive Ltl : List -> List -> Prop :=
    | Lt_nil (a:A) (x:List) : Ltl Nil (a :: x)
    | Lt_hd (a b:A) : leA a b -> forall x y:list A, Ltl (a :: x) (b :: y)
    | Lt_tl (a:A) (x y:List) : Ltl x y -> Ltl (a :: x) (a :: y).

  Inductive Desc : List -> Prop :=
    | d_nil : Desc Nil
    | d_one (x:A) : Desc (x :: Nil)
    | d_conc (x y:A) (l:List) :
        leA x y -> Desc (l ++ y :: Nil) -> Desc ((l ++ y :: Nil) ++ x :: Nil).

  Definition Pow : Set := sig Desc.

  Definition lex_exp (a b:Pow) : Prop := Ltl (proj1_sig a) (proj1_sig b).

End Lexicographic_Exponentiation.

Hint Unfold transp union: sets v62.
Hint Resolve t_step rt_step rt_refl rst_step rst_refl: sets v62.
Hint Immediate rst_sym: sets v62.

(* begin hide *)
(* Compatibility *)
Notation rts1n_refl := rst1n_refl (only parsing).
Notation rts1n_trans := rst1n_trans (only parsing).
Notation rtsn1_refl := rstn1_refl (only parsing).
Notation rtsn1_trans := rstn1_trans (only parsing).
(* end hide *)
