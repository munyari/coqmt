(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* Functional morphisms.
 
   Author: Matthieu Sozeau
   Institution: LRI, CNRS UMR 8623 - UniversitÃcopyright Paris Sud
   91405 Orsay, France *)

(* $Id: Functions.v 11709 2008-12-20 11:42:15Z msozeau $ *)

Require Import Coq.Classes.RelationClasses.
Require Import Coq.Classes.Morphisms.

Set Implicit Arguments.
Unset Strict Implicit.

Class Injective `(m : Morphism (A -> B) (RA ++> RB) f) : Prop :=
  injective : forall x y : A, RB (f x) (f y) -> RA x y.

Class Surjective `(m : Morphism (A -> B) (RA ++> RB) f) : Prop :=
  surjective : forall y, exists x : A, RB y (f x).

Definition Bijective `(m : Morphism (A -> B) (RA ++> RB) (f : A -> B)) :=
  Injective m /\ Surjective m.

Class MonoMorphism `(m : Morphism (A -> B) (eqA ++> eqB)) :=
  monic :> Injective m.

Class EpiMorphism `(m : Morphism (A -> B) (eqA ++> eqB)) :=
  epic :> Surjective m.

Class IsoMorphism `(m : Morphism (A -> B) (eqA ++> eqB)) :=
  { monomorphism :> MonoMorphism m ; epimorphism :> EpiMorphism m }.

Class AutoMorphism `(m : Morphism (A -> A) (eqA ++> eqA)) {I : IsoMorphism m}.
