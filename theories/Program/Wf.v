(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)
(* $Id: Wf.v 12187 2009-06-13 19:36:59Z msozeau $ *)

(** Reformulation of the Wf module using subsets where possible, providing
   the support for [Program]'s treatment of well-founded definitions. *)

Require Import Coq.Init.Wf.
Require Import Coq.Program.Utils.
Require Import ProofIrrelevance.

Open Local Scope program_scope.

Implicit Arguments Acc_inv [A R x y].

Section Well_founded.
  Variable A : Type.
  Variable R : A -> A -> Prop.
  Hypothesis Rwf : well_founded R.
  
  Section Acc.
    
    Variable P : A -> Type.
    
    Variable F_sub : forall x:A, (forall y: { y : A | R y x }, P (proj1_sig y)) -> P x.
    
    Fixpoint Fix_F_sub (x : A) (r : Acc R x) {struct r} : P x :=
      F_sub x (fun y: { y : A | R y x}  => Fix_F_sub (proj1_sig y) 
        (Acc_inv r (proj2_sig y))).
    
    Definition Fix_sub (x : A) := Fix_F_sub x (Rwf x).
  End Acc.
  
  Section FixPoint.
    Variable P : A -> Type.
    
    Variable F_sub : forall x:A, (forall y: { y : A | R y x }, P (proj1_sig y)) -> P x.
    
    Notation Fix_F := (Fix_F_sub P F_sub) (only parsing). (* alias *)
    
    Definition Fix (x:A) := Fix_F_sub P F_sub x (Rwf x).
    
    Hypothesis
      F_ext :
      forall (x:A) (f g:forall y:{y:A | R y x}, P (`y)),
        (forall (y : A | R y x), f y = g y) -> F_sub x f = F_sub x g.

    Lemma Fix_F_eq :
      forall (x:A) (r:Acc R x),
        F_sub x (fun (y:A|R y x) => Fix_F (`y) (Acc_inv r (proj2_sig y))) = Fix_F x r.
    Proof. 
      destruct r using Acc_inv_dep; auto.
    Qed.
    
    Lemma Fix_F_inv : forall (x:A) (r s:Acc R x), Fix_F x r = Fix_F x s.
    Proof.
      intro x; induction (Rwf x); intros.
      rewrite (proof_irrelevance (Acc R x) r s) ; auto.
    Qed.

    Lemma Fix_eq : forall x:A, Fix x = F_sub x (fun (y:A|R y x) => Fix (proj1_sig y)).
    Proof.
      intro x; unfold Fix in |- *.
      rewrite <- (Fix_F_eq ).
      apply F_ext; intros.
      apply Fix_F_inv.
    Qed.

    Lemma fix_sub_eq :
        forall x : A,
          Fix_sub P F_sub x =
          let f_sub := F_sub in
            f_sub x (fun (y : A | R y x) => Fix (`y)).
      exact Fix_eq.
    Qed.

 End FixPoint.

End Well_founded.

Extraction Inline Fix_F_sub Fix_sub.

Require Import Wf_nat.
Require Import Lt.

Section Well_founded_measure.
  Variable A : Type.
  Variable m : A -> nat.
  
  Section Acc.
    
    Variable P : A -> Type.
    
    Variable F_sub : forall x:A, (forall y: { y : A | m y < m x }, P (proj1_sig y)) -> P x.
    
    Program Fixpoint Fix_measure_F_sub (x : A) (r : Acc lt (m x)) {struct r} : P x :=
      F_sub x (fun (y : A | m y < m x)  => Fix_measure_F_sub y
        (@Acc_inv _ _ _ r (m y) (proj2_sig y))).
    
    Definition Fix_measure_sub (x : A) := Fix_measure_F_sub x (lt_wf (m x)).
  
  End Acc.

  Section FixPoint.
    Variable P : A -> Type.
    
    Program Variable F_sub : forall x:A, (forall (y : A | m y < m x), P y) -> P x.
    
    Notation Fix_F := (Fix_measure_F_sub P F_sub) (only parsing). (* alias *)
    
    Definition Fix_measure (x:A) := Fix_measure_F_sub P F_sub x (lt_wf (m x)).
    
    Hypothesis
      F_ext :
      forall (x:A) (f g:forall y : { y : A | m y < m x}, P (`y)),
        (forall y : { y : A | m y < m x}, f y = g y) -> F_sub x f = F_sub x g.

    Program Lemma Fix_measure_F_eq :
      forall (x:A) (r:Acc lt (m x)),
        F_sub x (fun (y:A | m y < m x) => Fix_F y (Acc_inv r (proj2_sig y))) = Fix_F x r.
    Proof.
      intros x.
      set (y := m x).
      unfold Fix_measure_F_sub.
      intros r ; case r ; auto.
    Qed.
    
    Lemma Fix_measure_F_inv : forall (x:A) (r s:Acc lt (m x)), Fix_F x r = Fix_F x s.
    Proof.
      intros x r s.
      rewrite (proof_irrelevance (Acc lt (m x)) r s) ; auto.
    Qed.

    Lemma Fix_measure_eq : forall x:A, Fix_measure x = F_sub x (fun (y:{y:A| m y < m x}) => Fix_measure (proj1_sig y)).
    Proof.
      intro x; unfold Fix_measure in |- *.
      rewrite <- (Fix_measure_F_eq ).
      apply F_ext; intros.
      apply Fix_measure_F_inv.
    Qed.

    Lemma fix_measure_sub_eq : forall x : A,
      Fix_measure_sub P F_sub x =
        let f_sub := F_sub in
          f_sub x (fun (y : A | m y < m x) => Fix_measure (`y)).
      exact Fix_measure_eq.
    Qed.

 End FixPoint.

End Well_founded_measure.

Extraction Inline Fix_measure_F_sub Fix_measure_sub.

Set Implicit Arguments.

(** Reasoning about well-founded fixpoints on measures. *)

Section Measure_well_founded.

  (* Measure relations are well-founded if the underlying relation is well-founded. *)

  Variables T M: Type.
  Variable R: M -> M -> Prop.
  Hypothesis wf: well_founded R.
  Variable m: T -> M.

  Definition MR (x y: T): Prop := R (m x) (m y).

  Lemma measure_wf: well_founded MR.
  Proof with auto.
    unfold well_founded.
    cut (forall a: M, (fun mm: M => forall a0: T, m a0 = mm -> Acc MR a0) a).
      intros.
      apply (H (m a))...
    apply (@well_founded_ind M R wf (fun mm => forall a, m a = mm -> Acc MR a)).
    intros.
    apply Acc_intro.
    intros.
    unfold MR in H1.
    rewrite H0 in H1.
    apply (H (m y))...
  Defined.

End Measure_well_founded.

Section Fix_measure_rects.

  Variable A: Type.
  Variable m: A -> nat.
  Variable P: A -> Type.
  Variable f: forall (x : A), (forall y: { y: A | m y < m x }, P (proj1_sig y)) -> P x.
  
  Lemma F_unfold x r:
    Fix_measure_F_sub A m P f x r =
    f (fun y => Fix_measure_F_sub A m P f (proj1_sig y) (Acc_inv r (proj2_sig y))).
  Proof. intros. case r; auto. Qed.

  (* Fix_measure_F_sub_rect lets one prove a property of
  functions defined using Fix_measure_F_sub by showing
  that property to be invariant over single application of the
  function body (f in our case). *)

  Lemma Fix_measure_F_sub_rect
    (Q: forall x, P x -> Type)
    (inv: forall x: A,
     (forall (y: A) (H: MR lt m y x) (a: Acc lt (m y)),
        Q y (Fix_measure_F_sub A m P f y a)) ->
        forall (a: Acc lt (m x)),
          Q x (f (fun y: {y: A | m y < m x} =>
            Fix_measure_F_sub A m P f (proj1_sig y) (Acc_inv a (proj2_sig y)))))
    : forall x a, Q _ (Fix_measure_F_sub A m P f x a).
  Proof with auto.
    intros Q inv.
    set (R := fun (x: A) => forall a, Q _ (Fix_measure_F_sub A m P f x a)).
    cut (forall x, R x)...
    apply (well_founded_induction_type (measure_wf lt_wf m)).
    subst R.
    simpl.
    intros.
    rewrite F_unfold...
  Qed.

  (* Let's call f's second parameter its "lowers" function, since it
  provides it access to results for inputs with a lower measure.

  In preparation of lemma similar to Fix_measure_F_sub_rect, but
  for Fix_measure_sub, we first
  need an extra hypothesis stating that the function body has the
  same result for different "lowers" functions (g and h below) as long
  as those produce the same results for lower inputs, regardless
  of the lt proofs. *)

  Hypothesis equiv_lowers:
    forall x0 (g h: forall x: {y: A | m y < m x0}, P (proj1_sig x)),
    (forall x p p', g (exist (fun y: A => m y < m x0) x p) = h (exist _ x p')) ->
      f g = f h.

  (* From equiv_lowers, it follows that
   [Fix_measure_F_sub A m P f x] applications do not not
  depend on the Acc proofs. *)

  Lemma eq_Fix_measure_F_sub x (a a': Acc lt (m x)):
    Fix_measure_F_sub A m P f x a =
    Fix_measure_F_sub A m P f x a'.
  Proof.
    intros x a.
    pattern x, (Fix_measure_F_sub A m P f x a).
    apply Fix_measure_F_sub_rect.
    intros.
    rewrite F_unfold.
    apply equiv_lowers.
    intros.
    apply H.
    assumption.
  Qed.

  (* Finally, Fix_measure_F_rect lets one prove a property of
  functions defined using Fix_measure_F by showing that
  property to be invariant over single application of the function
  body (f). *)

  Lemma Fix_measure_sub_rect
    (Q: forall x, P x -> Type)
    (inv: forall
      (x: A)
      (H: forall (y: A), MR lt m y x -> Q y (Fix_measure_sub A m P f y))
      (a: Acc lt (m x)),
        Q x (f (fun y: {y: A | m y < m x} => Fix_measure_sub A m P f (proj1_sig y))))
    : forall x, Q _ (Fix_measure_sub A m P f x).
  Proof with auto.
    unfold Fix_measure_sub.
    intros.
    apply Fix_measure_F_sub_rect.
    intros.
    assert (forall y: A, MR lt m y x0 -> Q y (Fix_measure_F_sub A m P f y (lt_wf (m y))))...
    set (inv x0 X0 a). clearbody q.
    rewrite <- (equiv_lowers (fun y: {y: A | m y < m x0} => Fix_measure_F_sub A m P f (proj1_sig y) (lt_wf (m (proj1_sig y)))) (fun y: {y: A | m y < m x0} => Fix_measure_F_sub A m P f (proj1_sig y) (Acc_inv a (proj2_sig y))))...
    intros.
    apply eq_Fix_measure_F_sub.
  Qed.

End Fix_measure_rects.

(** Tactic to fold a definition based on [Fix_measure_sub]. *)

Ltac fold_sub f :=
  match goal with
    | [ |- ?T ] => 
      match T with
        appcontext C [ @Fix_measure_sub _ _ _ _ ?arg ] => 
        let app := context C [ f arg ] in
          change app
      end
  end.

(** This module provides the fixpoint equation provided one assumes
   functional extensionality. *)

Module WfExtensionality.

  Require Import FunctionalExtensionality.

  (** The two following lemmas allow to unfold a well-founded fixpoint definition without
     restriction using the functional extensionality axiom. *)
  
  (** For a function defined with Program using a well-founded order. *)

  Program Lemma fix_sub_eq_ext :
    forall (A : Type) (R : A -> A -> Prop) (Rwf : well_founded R)
      (P : A -> Type)
      (F_sub : forall x : A, (forall (y : A | R y x), P y) -> P x),
      forall x : A,
        Fix_sub A R Rwf P F_sub x =
          F_sub x (fun (y : A | R y x) => Fix A R Rwf P F_sub y).
  Proof.
    intros ; apply Fix_eq ; auto.
    intros.
    assert(f = g).
    extensionality y ; apply H.
    rewrite H0 ; auto.
  Qed.

  (** For a function defined with Program using a measure. *)
  
  Program Lemma fix_sub_measure_eq_ext :
    forall (A : Type) (f : A -> nat) (P : A -> Type)
      (F_sub : forall x : A, (forall (y : A | f y < f x), P y) -> P x),
      forall x : A,
        Fix_measure_sub A f P F_sub x =
          F_sub x (fun (y : A | f y < f x) => Fix_measure_sub A f P F_sub y).
  Proof.
    intros ; apply Fix_measure_eq ; auto.
    intros.
    assert(f0 = g).
    extensionality y ; apply H.
    rewrite H0 ; auto.
  Qed.
  
  (** Tactic to unfold once a definition based on [Fix_measure_sub]. *)
  
  Ltac unfold_sub f fargs := 
    set (call:=fargs) ; unfold f in call ; unfold call ; clear call ; 
      rewrite fix_sub_measure_eq_ext ; repeat fold_sub fargs ; simpl proj1_sig.

End WfExtensionality.
