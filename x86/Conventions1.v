(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*                Xavier Leroy, INRIA Paris                            *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Function calling conventions and other conventions regarding the use of
    machine registers and stack slots. *)

Require Import Coqlib Decidableplus.
Require Import AST Machregs Locations.

(** * Classification of machine registers *)

(** Machine registers (type [mreg] in module [Locations]) are divided in
  the following groups:
- Callee-save registers, whose value is preserved across a function call.
- Caller-save registers that can be modified during a function call.

  We follow the x86-32 and x86-64 application binary interfaces (ABI)
  in our choice of callee- and caller-save registers.
*)

Definition is_callee_save (r: mreg) : bool :=
  match r with
  | AX | CX | DX => false
  | BX | BP => true
  | SI | DI => negb Archi.ptr64 || Archi.win64 (**r callee-save in ELF 64 bits *)
  | R8 | R9 | R10 | R11 => false
  | R12 | R13 | R14 | R15 => true
  | X0 | X1 | X2 | X3 | X4 | X5 | X6 | X7 => false
  | X8 | X9 | X10 | X11 | X12 | X13 | X14 | X15 => Archi.win64
  | FP0 => false
  end.

Definition int_caller_save_regs :=
  if Archi.ptr64
  then if Archi.win64
       then AX :: CX :: DX :: R8 :: R9 :: R10 :: R11 :: nil
       else AX :: CX :: DX :: SI :: DI :: R8 :: R9 :: R10 :: R11 :: nil
  else AX :: CX :: DX :: nil.

Definition float_caller_save_regs :=
  if Archi.ptr64
  then if Archi.win64
       then X0 :: X1 :: X2 :: X3 :: X4 :: X5 :: nil
       else X0 :: X1 :: X2 :: X3 :: X4 :: X5 :: X6 :: X7 ::
            X8 :: X9 :: X10 :: X11 :: X12 :: X13 :: X14 :: X15 :: nil
  else X0 :: X1 :: X2 :: X3 :: X4 :: X5 :: X6 :: X7 :: nil.

Definition int_callee_save_regs :=
  if Archi.ptr64
  then if Archi.win64
       then BX :: SI :: DI :: BP :: R12 :: R13 :: R14 :: R15 :: nil
       else BX :: BP :: R12 :: R13 :: R14 :: R15 :: nil
  else BX :: SI :: DI :: BP :: nil.

Definition float_callee_save_regs :=
  if Archi.ptr64 && Archi.win64
  then X6 :: X7 :: X8 :: X9 :: X10 :: X11 :: X12 :: X13 :: X14 :: X15 :: nil
  else nil.

Definition destroyed_at_call :=
  List.filter (fun r => negb (is_callee_save r)) all_mregs.

Definition is_float_reg (r: mreg) :=
  match r with
  | AX | BX | CX | DX | SI | DI | BP
  | R8 | R9 | R10 | R11 | R12 | R13 | R14 | R15 => false
  | X0 | X1 | X2 | X3 | X4 | X5 | X6 | X7
  | X8 | X9 | X10 | X11 | X12 | X13 | X14 | X15 | FP0 => true
  end.

Definition dummy_int_reg := AX.     (**r Used in [Regalloc]. *)
Definition dummy_float_reg := X0.   (**r Used in [Regalloc]. *)

Definition callee_save_type := mreg_type.

(** How to use registers for register allocation.
    We favor the use of caller-save registers, using callee-save registers
    only when no caller-save is available. *)

Record alloc_regs := mk_alloc_regs {
  preferred_int_regs: list mreg;
  remaining_int_regs: list mreg;
  preferred_float_regs: list mreg;
  remaining_float_regs: list mreg
}.

Definition allocatable_registers (_: unit) :=
  {| preferred_int_regs := int_caller_save_regs;
     remaining_int_regs := int_callee_save_regs;
     preferred_float_regs := float_caller_save_regs;
     remaining_float_regs := float_callee_save_regs |}.

(** * Function calling conventions *)

(** The functions in this section determine the locations (machine registers
  and stack slots) used to communicate arguments and results between the
  caller and the callee during function calls.  These locations are functions
  of the signature of the function and of the call instruction.
  Agreement between the caller and the callee on the locations to use
  is guaranteed by our dynamic semantics for Cminor and RTL, which demand
  that the signature of the call instruction is identical to that of the
  called function.

  Calling conventions are largely arbitrary: they must respect the properties
  proved in this section (such as no overlapping between the locations
  of function arguments), but this leaves much liberty in choosing actual
  locations.  To ensure binary interoperability of code generated by our
  compiler with libraries compiled by another compiler, we
  implement the standard x86-32 and x86-64 conventions. *)

(** ** Location of function result *)

(** In 32 bit mode, the result value of a function is passed back to the
  caller in registers [AX] or [DX:AX] or [FP0], depending on the type
  of the returned value.  We treat a function without result as a
  function with one integer result. *)

Definition loc_result_32 (s: signature) : rpair mreg :=
  match proj_sig_res s with
  | Tint | Tany32 => One AX
  | Tfloat | Tsingle => One FP0
  | Tany64 => One X0
  | Tlong => Twolong DX AX
  end.

(** In 64 bit mode, he result value of a function is passed back to
  the caller in registers [AX] or [X0]. *)

Definition loc_result_64 (s: signature) : rpair mreg :=
  match proj_sig_res s with
  | Tint | Tlong | Tany32 | Tany64 => One AX
  | Tfloat | Tsingle => One X0
  end.

Definition loc_result :=
  if Archi.ptr64 then loc_result_64 else loc_result_32.

(** The result registers have types compatible with that given in the signature. *)

Lemma loc_result_type:
  forall sig,
  subtype (proj_sig_res sig) (typ_rpair mreg_type (loc_result sig)) = true.
Proof.
  intros. unfold loc_result, loc_result_32, loc_result_64, mreg_type;
  destruct Archi.ptr64; destruct (proj_sig_res sig); auto.
Qed.

(** The result locations are caller-save registers *)

Lemma loc_result_caller_save:
  forall (s: signature),
  forall_rpair (fun r => is_callee_save r = false) (loc_result s).
Proof.
  intros. unfold loc_result, loc_result_32, loc_result_64, is_callee_save;
  destruct Archi.ptr64; destruct (proj_sig_res s); simpl; auto.
Qed.

(** If the result is in a pair of registers, those registers are distinct and have type [Tint] at least. *)

Lemma loc_result_pair:
  forall sg,
  match loc_result sg with
  | One _ => True
  | Twolong r1 r2 =>
       r1 <> r2 /\ proj_sig_res sg = Tlong
    /\ subtype Tint (mreg_type r1) = true /\ subtype Tint (mreg_type r2) = true
    /\ Archi.ptr64 = false
  end.
Proof.
  intros. 
  unfold loc_result, loc_result_32, loc_result_64, mreg_type;
  destruct Archi.ptr64; destruct (proj_sig_res sg); auto.
  split; auto. congruence.
Qed.

(** The location of the result depends only on the result part of the signature *)

Lemma loc_result_exten:
  forall s1 s2, s1.(sig_res) = s2.(sig_res) -> loc_result s1 = loc_result s2.
Proof.
  intros. unfold loc_result, loc_result_32, loc_result_64, proj_sig_res.
  destruct Archi.ptr64; rewrite H; auto.
Qed.

(** ** Location of function arguments *)

(** In the x86-32 ABI, all arguments are passed on stack. (Snif.) *)

Fixpoint loc_arguments_32
    (tyl: list typ) (ofs: Z) {struct tyl} : list (rpair loc) :=
  match tyl with
  | nil => nil
  | ty :: tys =>
      match ty with
      | Tlong => Twolong (S Outgoing (ofs + 1) Tint) (S Outgoing ofs Tint)
      | _     => One (S Outgoing ofs ty)
      end
      :: loc_arguments_32 tys (ofs + typesize ty)
  end.

(** In the x86-64 ELF ABI:
- The first 6 integer arguments are passed in registers [DI], [SI], [DX], [CX], [R8], [R9].
- The first 8 floating-point arguments are passed in registers [X0] to [X7].
- Extra arguments are passed on the stack, in [Outgoing] slots.
  Consecutive stack slots are separated by 8 bytes, even if only 4 bytes
  of data is used in a slot.
*)

Definition int_param_regs_elf64 := DI :: SI :: DX :: CX :: R8 :: R9 :: nil.
Definition float_param_regs_elf64 := X0 :: X1 :: X2 :: X3 :: X4 :: X5 :: X6 :: X7 :: nil.

Fixpoint loc_arguments_elf64
    (tyl: list typ) (ir fr ofs: Z) {struct tyl} : list (rpair loc) :=
  match tyl with
  | nil => nil
  | (Tint | Tlong | Tany32 | Tany64) as ty :: tys =>
      match list_nth_z int_param_regs_elf64 ir with
      | None =>
          One (S Outgoing ofs ty) :: loc_arguments_elf64 tys ir fr (ofs + 2)
      | Some ireg =>
          One (R ireg) :: loc_arguments_elf64 tys (ir + 1) fr ofs
      end
  | (Tfloat | Tsingle) as ty :: tys =>
      match list_nth_z float_param_regs_elf64 fr with
      | None =>
          One (S Outgoing ofs ty) :: loc_arguments_elf64 tys ir fr (ofs + 2)
      | Some freg =>
          One (R freg) :: loc_arguments_elf64 tys ir (fr + 1) ofs
      end
  end.

(** In the x86-64 Win64 ABI:
- The first 4 arguments are passed in registers [RCX], [RDX], [R8], and [R9]
  (for integer arguments) and [X0] to [X3] (for floating-point arguments).
  Each argument "burns" both an integer register and a FP integer.
- The first 8 floating-point arguments are passed in registers [X0] to [X7].
- Extra arguments are passed on the stack, in [Outgoing] slots.
  Consecutive stack slots are separated by 8 bytes, even if only 4 bytes
  of data is used in a slot.
- Four 8-byte words are always reserved at the bottom of the outgoing area
  so that the callee can use them to save the registers containing the
  first four arguments.  This is handled in the Stacking phase.
*)

Definition int_param_regs_win64 := CX :: DX :: R8 :: R9 :: nil.
Definition float_param_regs_win64 := X0 :: X1 :: X2 :: X3 :: nil.

Fixpoint loc_arguments_win64
    (tyl: list typ) (r ofs: Z) {struct tyl} : list (rpair loc) :=
  match tyl with
  | nil => nil
  | (Tint | Tlong | Tany32 | Tany64) as ty :: tys =>
      match list_nth_z int_param_regs_win64 r with
      | None =>
          One (S Outgoing ofs ty) :: loc_arguments_win64 tys r (ofs + 2)
      | Some ireg =>
          One (R ireg) :: loc_arguments_win64 tys (r + 1) ofs
      end
  | (Tfloat | Tsingle) as ty :: tys =>
      match list_nth_z float_param_regs_win64 r with
      | None =>
          One (S Outgoing ofs ty) :: loc_arguments_win64 tys r (ofs + 2)
      | Some freg =>
          One (R freg) :: loc_arguments_win64 tys (r + 1) ofs
      end
  end.

(** [loc_arguments s] returns the list of locations where to store arguments
  when calling a function with signature [s].  *)

Definition loc_arguments (s: signature) : list (rpair loc) :=
  if Archi.ptr64
  then if Archi.win64
       then loc_arguments_win64 (proj_sig_args s) 0 0
       else loc_arguments_elf64 (proj_sig_args s) 0 0 0
  else loc_arguments_32 (proj_sig_args s) 0.

(** Argument locations are either caller-save registers or [Outgoing]
  stack slots at nonnegative offsets. *)

Definition loc_argument_acceptable (l: loc) : Prop :=
  match l with
  | R r => is_callee_save r = false
  | S Outgoing ofs ty => ofs >= 0 /\ (typealign ty | ofs)
  | _ => False
  end.

Definition loc_argument_32_charact (ofs: Z) (l: loc) : Prop :=
  match l with
  | S Outgoing ofs' ty => ofs' >= ofs /\ typealign ty = 1
  | _ => False
  end.

Definition loc_argument_elf64_charact (ofs: Z) (l: loc) : Prop :=
  match l with
  | R r => In r int_param_regs_elf64 \/ In r float_param_regs_elf64
  | S Outgoing ofs' ty => ofs' >= ofs /\ (2 | ofs')
  | _ => False
  end.

Definition loc_argument_win64_charact (ofs: Z) (l: loc) : Prop :=
  match l with
  | R r => In r int_param_regs_win64 \/ In r float_param_regs_win64
  | S Outgoing ofs' ty => ofs' >= ofs /\ (2 | ofs')
  | _ => False
  end.

Remark loc_arguments_32_charact:
  forall tyl ofs p,
  In p (loc_arguments_32 tyl ofs) -> forall_rpair (loc_argument_32_charact ofs) p.
Proof.
  assert (X: forall ofs1 ofs2 l, loc_argument_32_charact ofs2 l -> ofs1 <= ofs2 -> loc_argument_32_charact ofs1 l).
  { destruct l; simpl; intros; auto. destruct sl; auto. intuition lia. }
  induction tyl as [ | ty tyl]; simpl loc_arguments_32; intros.
- contradiction.
- destruct H.
+ destruct ty; subst p; simpl; lia.
+ apply IHtyl in H. generalize (typesize_pos ty); intros. destruct p; simpl in *.
* eapply X; eauto; lia.
* destruct H; split; eapply X; eauto; lia.
Qed.

Remark loc_arguments_elf64_charact:
  forall tyl ir fr ofs p,
  In p (loc_arguments_elf64 tyl ir fr ofs) -> (2 | ofs) -> forall_rpair (loc_argument_elf64_charact ofs) p.
Proof.
  assert (X: forall ofs1 ofs2 l, loc_argument_elf64_charact ofs2 l -> ofs1 <= ofs2 -> loc_argument_elf64_charact ofs1 l).
  { destruct l; simpl; intros; auto. destruct sl; auto. intuition lia. }
  assert (Y: forall ofs1 ofs2 p, forall_rpair (loc_argument_elf64_charact ofs2) p -> ofs1 <= ofs2 -> forall_rpair (loc_argument_elf64_charact ofs1) p).
  { destruct p; simpl; intuition eauto. }
  assert (Z: forall ofs, (2 | ofs) -> (2 | ofs + 2)).
  { intros. apply Z.divide_add_r; auto. apply Z.divide_refl. }
Opaque list_nth_z.
  induction tyl; simpl loc_arguments_elf64; intros.
  elim H.
  assert (A: forall ty, In p
      match list_nth_z int_param_regs_elf64 ir with
      | Some ireg => One (R ireg) :: loc_arguments_elf64 tyl (ir + 1) fr ofs
      | None => One (S Outgoing ofs ty) :: loc_arguments_elf64 tyl ir fr (ofs + 2)
      end ->
      forall_rpair (loc_argument_elf64_charact ofs) p).
  { intros. destruct (list_nth_z int_param_regs_elf64 ir) as [r|] eqn:E; destruct H1.
    subst. left. eapply list_nth_z_in; eauto.
    eapply IHtyl; eauto.
    subst. split. lia. assumption.
    eapply Y; eauto. lia. }
  assert (B: forall ty, In p
      match list_nth_z float_param_regs_elf64 fr with
      | Some ireg => One (R ireg) :: loc_arguments_elf64 tyl ir (fr + 1) ofs
      | None => One (S Outgoing ofs ty) :: loc_arguments_elf64 tyl ir fr (ofs + 2)
      end ->
      forall_rpair (loc_argument_elf64_charact ofs) p).
  { intros. destruct (list_nth_z float_param_regs_elf64 fr) as [r|] eqn:E; destruct H1.
    subst. right. eapply list_nth_z_in; eauto.
    eapply IHtyl; eauto.
    subst. split. lia. assumption.
    eapply Y; eauto. lia. }
  destruct a; eauto.
Qed.

Remark loc_arguments_win64_charact:
  forall tyl r ofs p,
  In p (loc_arguments_win64 tyl r ofs) -> (2 | ofs) -> forall_rpair (loc_argument_win64_charact ofs) p.
Proof.
  assert (X: forall ofs1 ofs2 l, loc_argument_win64_charact ofs2 l -> ofs1 <= ofs2 -> loc_argument_win64_charact ofs1 l).
  { destruct l; simpl; intros; auto. destruct sl; auto. intuition lia. }
  assert (Y: forall ofs1 ofs2 p, forall_rpair (loc_argument_win64_charact ofs2) p -> ofs1 <= ofs2 -> forall_rpair (loc_argument_win64_charact ofs1) p).
  { destruct p; simpl; intuition eauto. }
  assert (Z: forall ofs, (2 | ofs) -> (2 | ofs + 2)).
  { intros. apply Z.divide_add_r; auto. apply Z.divide_refl. }
Opaque list_nth_z.
  induction tyl; simpl loc_arguments_win64; intros.
  elim H.
  assert (A: forall ty, In p
      match list_nth_z int_param_regs_win64 r with
      | Some ireg => One (R ireg) :: loc_arguments_win64 tyl (r + 1) ofs
      | None => One (S Outgoing ofs ty) :: loc_arguments_win64 tyl r (ofs + 2)
      end ->
      forall_rpair (loc_argument_win64_charact ofs) p).
  { intros. destruct (list_nth_z int_param_regs_win64 r) as [r'|] eqn:E; destruct H1.
    subst. left. eapply list_nth_z_in; eauto.
    eapply IHtyl; eauto.
    subst. split. lia. assumption.
    eapply Y; eauto. lia. }
  assert (B: forall ty, In p
      match list_nth_z float_param_regs_win64 r with
      | Some ireg => One (R ireg) :: loc_arguments_win64 tyl (r + 1) ofs
      | None => One (S Outgoing ofs ty) :: loc_arguments_win64 tyl r (ofs + 2)
      end ->
      forall_rpair (loc_argument_win64_charact ofs) p).
  { intros. destruct (list_nth_z float_param_regs_win64 r) as [r'|] eqn:E; destruct H1.
    subst. right. eapply list_nth_z_in; eauto.
    eapply IHtyl; eauto.
    subst. split. lia. assumption.
    eapply Y; eauto. lia. }
  destruct a; eauto.
Qed.

Lemma loc_arguments_acceptable:
  forall (s: signature) (p: rpair loc),
  In p (loc_arguments s) -> forall_rpair loc_argument_acceptable p.
Proof.
  unfold loc_arguments; intros. destruct Archi.ptr64 eqn:SF; [destruct Archi.win64 eqn:W64|].
- (* WIN 64 bits *)
  assert (A: forall r, In r int_param_regs_win64 -> is_callee_save r = false) by (unfold is_callee_save; rewrite SF; decide_goal).
  assert (B: forall r, In r float_param_regs_win64 -> is_callee_save r = false) by (unfold is_callee_save; decide_goal).
  assert (X: forall l, loc_argument_win64_charact 0 l -> loc_argument_acceptable l).
  { unfold loc_argument_win64_charact, loc_argument_acceptable.
    destruct l as [r | [] ofs ty]; auto.  intros [C|C]; auto.
    intros [C D]. split; auto. apply Z.divide_trans with 2; auto.
    exists (2 / typealign ty); destruct ty; reflexivity.
  }
  exploit loc_arguments_win64_charact; eauto using Z.divide_0_r.
  unfold forall_rpair; destruct p; intuition auto.
- (* ELF 64 bits *)
  assert (A: forall r, In r int_param_regs_elf64 -> is_callee_save r = false) by (unfold is_callee_save; rewrite SF, W64; decide_goal).
  assert (B: forall r, In r float_param_regs_elf64 -> is_callee_save r = false) by (unfold is_callee_save; rewrite W64; decide_goal).
  assert (X: forall l, loc_argument_elf64_charact 0 l -> loc_argument_acceptable l).
  { unfold loc_argument_elf64_charact, loc_argument_acceptable.
    destruct l as [r | [] ofs ty]; auto.  intros [C|C]; auto.
    intros [C D]. split; auto. apply Z.divide_trans with 2; auto.
    exists (2 / typealign ty); destruct ty; reflexivity.
  }
  exploit loc_arguments_elf64_charact; eauto using Z.divide_0_r.
  unfold forall_rpair; destruct p; intuition auto.

- (* 32 bits *)
  assert (X: forall l, loc_argument_32_charact 0 l -> loc_argument_acceptable l).
  { destruct l as [r | [] ofs ty]; simpl; intuition auto. rewrite H2; apply Z.divide_1_l. }
  exploit loc_arguments_32_charact; eauto.
  unfold forall_rpair; destruct p; intuition auto.
Qed.

Global Hint Resolve loc_arguments_acceptable: locs.

Lemma loc_arguments_main:
  loc_arguments signature_main = nil.
Proof.
  unfold loc_arguments; destruct Archi.ptr64; auto; destruct Archi.win64; auto.
Qed.

(** ** Normalization of function results and parameters *)

(** In the x86 ABI, a return value of type "char" is returned in
    register AL, leaving the top 24 bits of EAX unspecified.
    Likewise, a return value of type "short" is returned in register
    AH, leaving the top 16 bits of EAX unspecified.  Hence, return
    values of small integer types need re-normalization after calls. *)

Definition return_value_needs_normalization (t: rettype) : bool :=
  match t with
  | Tint8signed | Tint8unsigned | Tint16signed | Tint16unsigned => true
  | _ => false
  end.

(** Function parameters are passed in normalized form and do not need
    to be re-normalized at function entry. *)

Definition parameter_needs_normalization (t: rettype) := false.
