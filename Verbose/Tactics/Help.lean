import Verbose.Tactics.Common


open Lean Meta Elab Tactic

def Lean.Expr.relSymb : Expr → Option String
| .const ``LT.lt _ => pure " < "
| .const ``LE.le _ => pure " ≤ "
| .const ``GT.gt _ => pure " > "
| .const ``GE.ge _ => pure " ≥ "
| .const ``Membership.mem _ => pure " ∈ "
| _ => none


partial def Lean.Expr.relInfo? : Expr → MetaM (Option (String × Expr × Expr))
| .mvar m => do Lean.Expr.relInfo? (← m.getType'')
| e@(_) =>  if e.getAppNumArgs < 2 then
    return none
  else
    return some (← relSymb e.getAppFn, e.appFn!.appArg!, e.appArg!)



set_option autoImplicit false

open Lean

inductive MyExpr
| forall_rel (var_Name : Name) (typ : Expr) (rel : String) (rel_rhs : Expr) (propo : MyExpr) : MyExpr
| forall_simple (var_Name : Name) (typ : Expr) (propo : MyExpr) : MyExpr
| exist_rel (var_Name : Name) (typ : Expr) (rel : String) (rel_rhs : Expr) (propo : MyExpr) : MyExpr
| exist_simple (var_Name : Name) (typ : Expr) (propo : MyExpr) : MyExpr
| conjunction (propo propo' : MyExpr) : MyExpr
| disjunction (propo propo' : MyExpr) : MyExpr
| impl (le re : Expr) (lhs : MyExpr) (rhs : MyExpr) : MyExpr
| iff (le re : Expr) (lhs rhs : MyExpr) : MyExpr
| equal (le re : Expr) : MyExpr
| ineq (le : Expr) (symb : String) (re : Expr) : MyExpr
| mem (elem : Expr) (set : Expr) : MyExpr
| prop (e : Expr) : MyExpr
| data (e : Expr) : MyExpr
deriving Repr

def MyExpr.toStr : MyExpr → MetaM String
| .forall_rel var_name _typ rel rel_rhs propo => do
    let rhs := toString (← ppExpr rel_rhs)
    let p ← propo.toStr
    pure $ "∀ " ++ var_name.toString ++ rel ++ (toString rhs) ++ ", " ++ p
| .forall_simple var_name _typ propo => do
    let p ← propo.toStr
    pure $ "∀ " ++ var_name.toString ++ ", " ++ p
| .exist_rel var_name _typ rel rel_rhs propo => do
    let rhs := toString (← ppExpr rel_rhs)
    let p ← MyExpr.toStr propo
    pure $ "∃ " ++ var_name.toString ++ rel ++ rhs ++ ", " ++ p
| .exist_simple var_name _typ propo => do
    let p ← MyExpr.toStr propo
    pure $ "∃ " ++ var_name.toString ++ ", " ++ p
| .conjunction propo propo' => do
    let p ← MyExpr.toStr propo
    let p' ← MyExpr.toStr propo'
    pure $ p ++ " ∧ " ++ p'
| .disjunction propo propo' => do
    let p ← MyExpr.toStr propo
    let p' ← MyExpr.toStr propo'
    pure $ p ++ " ∨ " ++ p'
| .impl _le _re lhs rhs => do
  let l ← MyExpr.toStr lhs
  let r ← MyExpr.toStr rhs
  pure $ l ++ " → " ++ r
| .iff _le _re lhs rhs => do
  let l ← MyExpr.toStr lhs
  let r ← MyExpr.toStr rhs
  pure $ l ++ " ↔ " ++ r
| .equal le re => do
  let l := toString (← ppExpr le)
  let r := toString (← ppExpr re)
  pure $ l ++ " = " ++ r
| .ineq le symb re => do
  let l := toString (← ppExpr le)
  let r := toString (← ppExpr re)
  pure $ l ++ symb ++ r
| .mem elem set => do
  let l := toString (← ppExpr elem)
  let r := toString (← ppExpr set)
  pure $ l ++ " ∈ " ++ r
| .prop e => do return toString (← ppExpr e)
| .data e => do return toString (← ppExpr e)


partial def parse {α : Type} (e : Expr) (ret : MyExpr → MetaM α) : MetaM α :=
  match e with
  | Expr.forallE n t b bi =>
    if e.isArrow then do
      parse t fun left ↦ parse b fun right ↦ ret <| .impl t b left right
    else
      withLocalDecl n bi t fun x ↦ parse (b.instantiate1 x) fun b' ↦
        match b' with
        | .impl _ _ (.ineq _ symb re) new => do
           -- TODO: also check the lhs is the expected one
           ret <| MyExpr.forall_rel n t symb re new
        | _ => do
          ret <| MyExpr.forall_simple n t b'
  | e@(.app ..) => do
    match e.getAppFn with
    | .const `Exists .. => do
      let binding := e.getAppArgs'[1]!
      let varName := binding.bindingName!
      let varType := binding.bindingDomain!
      withLocalDecl varName binding.binderInfo varType fun x => do
        let body := binding.bindingBody!.instantiate1 x
        if body.isAppOf `And then
          if let some (rel, _, rhs) ← body.getAppArgs[0]!.relInfo? then
            -- TODO: also check the lhs is the expected one
            return ← parse body.getAppArgs'[1]! fun b' ↦ ret <| .exist_rel varName varType rel rhs b'
        return ← parse body fun b' ↦ ret <| .exist_simple varName varType b'
    | .const `And .. =>
      parse e.getAppArgs[0]! fun left ↦ parse e.getAppArgs[1]! fun right ↦ ret <| .conjunction left right
    | .const `Or .. =>
      parse e.getAppArgs[0]! fun left ↦ parse e.getAppArgs[1]! fun right ↦ ret <| .disjunction left right
    | .const `Iff .. =>
      parse e.getAppArgs[0]! fun left ↦ parse e.getAppArgs[1]! fun right ↦ ret <| .iff e.getAppArgs[0]! e.getAppArgs[1]! left right
    | .const `Eq .. => ret <| .equal e.getAppArgs[1]! e.getAppArgs[2]!
    | .const `LE.le _ | .const `LT.lt _ | .const `GE.ge _ | .const `GT.gt _ => do
      let some (rel, lhs, rhs) ← e.relInfo? | unreachable!
      ret <| .ineq lhs rel rhs
    | .const `Membership.mem _ => do
      let some (_, lhs, rhs) ← e.relInfo? | unreachable!
      ret <| .mem lhs rhs
    | _ => simple e
  | e => simple e
  where simple e := do
    if (← instantiateMVars (← inferType e)).isProp then
      ret <| .prop e
    else
      ret <| .data e

elab "test" x:term : tactic => withMainContext do
  let e ← Elab.Tactic.elabTerm x none
  parse e fun p => do
    logInfo m!"Parse output: {← p.toStr}"
  --  logInfo m!"Parse output: {repr p}"

elab "exp" x:ident: tactic => withMainContext do
  let e ← Meta.getLocalDeclFromUserName x.getId
  logInfo m!"{repr e.value}"


-- example (P : ℕ → Prop) (Q R : Prop) (s : Set ℕ): True := by
--   test ∃ n > 0, P n
--   test ∃ n, P n
--   test ∀ n, P n
--   test ∀ n > 0, P n
--   test Q ∧ R
--   test 0 < 3
--   test 0 ∈ s
--   test Q → R
--   trivial

/- example (Q R : ℕ → Prop) (P : ℕ → ℕ → Prop) : True := by
  let x := 0
  exp x
  test R 1 → Q 2
  test ∀ l, l - 3 = 0 → P l 0
  test ∀ k ≥ 2, ∃ n ≥ 3, ∀ l, l - n = 0 → P l k
  test ∃ n ≥ 5, Q n
  test ∀ k ≥ 2, ∃ n ≥ 3, P n k
  test ∃ n, Q n
  test ∀ k, ∃ n, P n k
  test ∀ k ≥ 2, ∃ n, P n k
  test (∀ k : ℕ, Q k) → (∀ l , R l)
  test (∀ k : ℕ, Q k) ↔ (∀ l , R l)
  test ∀ k, 1 ≤ k → Q k
  trivial -/

def symb_to_hyp : String → Expr → String
| " ≥ ", (.app (.app (.app (.const `OfNat.ofNat ..) _) (.lit <| .natVal 0)) _) => "_pos"
| " ≥ ", _ => "_sup"
| " > ", (.app (.app (.app (.const `OfNat.ofNat ..) _) (.lit <| .natVal 0)) _) => "_pos"
| " > ", _ => "_sup"
| " ≤ ", (.app (.app (.app (.const `OfNat.ofNat ..) _) (.lit <| .natVal 0)) _) => "_neg"
| " ≤ ", _ => "_inf"
| " < ", (.app (.app (.app (.const `OfNat.ofNat ..) _) (.lit <| .natVal 0)) _) => "_neg"
| " < ", _ => "_inf"
| " ∈ ", _ => "_dans"
| _, _ => ""

def describe : String → String
| "ℝ" => "un nombre réel"
| "ℕ" => "un nombre entier naturel"
| "ℤ" => "un nombre entier relatif"
| t => "une expression de type " ++ t

def describe_pl : String → String
| "ℝ" => "des nombres réels"
| "ℕ" => "des nombres entiers naturels"
| "ℤ" => "des nombres entiers relatifs"
| t => "des expressions de type " ++ t

def libre (s: String) : String := "Le nom " ++ s ++ " peut être choisi librement parmi les noms disponibles."

def libres (ls : List String) : String :=
"Les noms " ++ String.intercalate ", " ls ++ " peuvent être choisis librement parmi les noms disponibles."

def applique_a : List Expr → MetaM String
| [] => pure ""
| [x] => do return " appliqué à " ++ (toString <| ← ppExpr x)
| s => do return " appliqué à [" ++ ", ".intercalate ((← s.mapM ppExpr).map toString) ++ "]"

-- **FIXME**
/-- Une version de `expr.rename_var` qui renomme même les variables libres. -/
def Lean.Expr.rename (old new : Name) : Expr → Expr
| .forallE n t b bi => .forallE (if n = old then new else n) (t.rename old new) (b.rename old new) bi
| .lam n t b bi => .lam (if n = old then new else n) (t.rename old new) (b.rename old new) bi
| .app t b => .app (t.rename old new) (b.rename old new)
| .fvar x => .fvar x
| e => e

def MyExpr.rename (old new : Name) : MyExpr → MyExpr
| .forall_rel n typ rel rel_rhs propo => forall_rel (if n = old then new else n) typ rel rel_rhs $ propo.rename old new
| .forall_simple n typ propo => forall_simple (if n = old then new else n) typ $ propo.rename old new
| .exist_rel n typ rel rel_rhs propo => exist_rel (if n = old then new else n) typ rel rel_rhs $ propo.rename old new
| .exist_simple n typ propo => exist_simple (if n = old then new else n) typ $ propo.rename old new
| .conjunction propo propo' => conjunction (propo.rename old new) (propo'.rename old new)
| .disjunction propo propo' => disjunction (propo.rename old new) (propo'.rename old new)
| .impl le re lhs rhs => impl (le.renameBVar old new) (re.renameBVar old new) (lhs.rename old new) (rhs.rename old new)
| .iff le re lhs rhs => iff (le.renameBVar old new) (re.renameBVar old new) (lhs.rename old new) (rhs.rename old new)
| .equal le re => equal (le.renameBVar old new) (re.renameBVar old new)
| .ineq le rel re => ineq (le.renameBVar old new) rel (re.renameBVar old new)
| .mem elem set => mem (elem.renameBVar old new) (set.renameBVar old new)
| .prop e => prop (e.rename old new)
| .data e => data (e.rename old new)

/-
**FIXME**: the recommendation below should check that suggested names are not already used.
-/

def helpAtHyp (goal : MVarId) (hyp : Name) : MetaM String :=
  goal.withContext do
  let sh := toString hyp
  let eh := ← getLocalDeclFromUserName hyp

  let hyp := eh.type
  let but := toString (← ppExpr (← goal.getType))
  let baseMsg ← withoutModifyingState do
       (do
       let _ ← goal.apply eh.toExpr
       let prf ← instantiateMVars (mkMVar goal)
       pure s!"On conclut par {← ppExpr prf}{← applique_a prf.getAppArgs.toList}")
     <|>
       pure ""


  parse hyp fun m ↦ match m with
    | .forall_rel var_name typ rel rel_rhs propo => do
        let py ← ppExpr rel_rhs
        let t ← ppExpr typ
        let n := toString var_name
        let n₀ := n ++ "₀"
        let nn₀ := Name.mkSimple n₀
        let p ← (propo.rename var_name nn₀).toStr
        let mut msg := ""
        match propo with
        | .exist_rel var_name' _typ' rel' rel_rhs' propo' => do
          let n' := toString var_name'
          let py' ← toString <$> ppExpr rel_rhs'
          let p' ← (propo'.rename var_name nn₀).toStr
          msg := msg ++ s!"L'hypothèse {sh} commence par « ∀ {n}{rel}{py}, ∃ {n'}{rel'}{py'}, ... »\n"
          msg := msg ++ "On peut l'utiliser avec :\n"
          msg := msg ++ s!"  Par {sh} appliqué à [{n₀}, h{n₀}] on obtient {n'} tel que ({n'}{symb_to_hyp rel' rel_rhs'} : {n'}{rel'}{py'}) (h{n'} : {p'})\n"
          msg := msg ++ s!"où {n₀} est {describe (toString t)} et h{n₀} est une démonstration du fait que {n₀}{rel}{py}."
          msg := msg ++ libres [s!"{n'}{symb_to_hyp rel' rel_rhs'}", s!"h{n'}"]
        | .exist_simple var_name' _typ' propo' => do
          let n' := toString var_name'
          let p' ← (propo'.rename var_name nn₀).toStr
          msg := msg ++ s!"L'hypothèse {sh} commence par « ∀ {n}{rel}{py}, ∃ {n'}, ... »\n"
          msg := msg ++ "On peut l'utiliser avec :\n"
          msg := msg ++ s!"  Par {sh} appliqué à [{n₀}, h{n₀}] on obtient {n'} tel que (h{n'} : {p'})\n"
          msg := msg ++ s!"où {n₀} est {describe (toString t)} et h{n₀} est une démonstration du fait que {n₀}{rel}{py}\n"
          msg := msg ++ libres [n', s!"h{n'}"]
        | _ => do
          msg := msg ++ s!"L'hypothèse {sh} commence par « ∀ {var_name}{rel}{py}, »\n"
          msg := msg ++ "On peut l'utiliser avec :\n"
          msg := msg ++ s!"  Par {sh} appliqué à [{n₀}, h{n₀}] on obtient (h : {p})\n"
          msg := msg ++ s!"où {n₀} est {describe (toString t)} et h{n₀} est une démonstration du fait que {n₀}{rel}{py}\n"
          msg := msg ++ libre "h"
        pure msg
    | .forall_simple var_name typ propo => do
        let t ← ppExpr typ
        let n := toString var_name
        let n₀ := n ++ "₀"
        let nn₀ := Name.mkSimple n₀
        let p ← (propo.rename (Name.mkSimple n) nn₀).toStr
        let mut msg := ""
        match propo with
        | .exist_rel var_name' _typ' rel' rel_rhs' propo' => do
          let n' := toString var_name'
          let py' ← toString <$> ppExpr rel_rhs'
          let p' ← (propo'.rename var_name nn₀).toStr
          msg := msg ++ s!"L'hypothèse {sh} commence par « ∀ {n}, ∃ {n'}{rel'}{py'}, ... »\n"
          msg := msg ++ "On peut l'utiliser avec :\n"
          msg := msg ++ s!"  Par {sh} appliqué à {n₀} on obtient {n'} tel que ({n'}{symb_to_hyp rel' rel_rhs'} : {n'}{rel'}{py'}) (h{n'} : {p'})\n"
          msg := msg ++ "où {n₀} est {describe (toString t)}\n"
          msg := msg ++ libres [n', n' ++ symb_to_hyp rel' rel_rhs', s!"h{n'}"]
        | .exist_simple var_name' _typ' propo' => do
          let n' := toString var_name'
          let p' ← (propo'.rename var_name nn₀).toStr
          msg := msg ++ s!"L'hypothèse {sh} commence par « ∀ {n}, ∃ {n'}, ... »\n"
          msg := msg ++ "On peut l'utiliser avec :\n"
          msg := msg ++ s!"  Par {sh} appliqué à {n₀} on obtient {n'} tel que (h{n'} : {p'})\n"
          msg := msg ++ s!"où {n₀} est {describe (toString t)}\n"
          msg := msg ++ libres [n', "h{n'}"]
        | .forall_rel var_name' _typ' rel' _rel_rhs' propo' => do
          let n' := toString var_name'
          -- let py' ← ppExpr rel_rhs'
          let p' ← (propo'.rename var_name nn₀).toStr
          let rel := n ++ rel' ++ n'
          msg := msg ++ s!"L'hypothèse {sh} commence par « ∀ {n} {n'}, {rel} → ... \n"
          msg := msg ++ "On peut l'utiliser avec :\n"
          msg := msg ++ s!"  Par {sh} appliqué à [{n}, {n'}, H] on obtient (h : {p'})\n"
          msg := msg ++ s!"où {n} et {n'} sont {describe_pl (toString t)} et H est une démonstration de {rel}\n"
          msg := msg ++ libre "h"
        | _ => do
          msg := msg ++ s!"L'hypothèse {sh} commence par « ∀ {n}, »\n"
          msg := msg ++ "On peut l'utiliser avec :"
          msg := msg ++ s!"  Par {sh} appliqué à {n₀} on obtient (h : {p}),"
          msg := msg ++ s!"où {n₀} est {describe (toString t)}\n"
          msg := msg ++ libre "h" ++ "\n"
          msg := msg ++ s!"\nSi cette hypothèse ne servira plus dans sa forme générale, on peut aussi spécialiser {sh} par"
          msg := msg ++ s!"  On applique {sh} à {n₀},"
          if baseMsg ≠ "" then
            msg := s!"\nComme le but est {but}, on peut utiliser :" ++ baseMsg
        pure msg
    | .exist_rel var_name _typ rel rel_rhs propo => do
      let n := toString var_name
      let y ← toString <$> ppExpr rel_rhs
      let p ← propo.toStr
      let mut msg := s!"L'hypothèse {sh} est de la forme « ∃ {var_name}{rel}{y}, ... »\n"
      msg := msg ++ "On peut l'utiliser avec :\n"
      msg := msg ++  s!"  Par {sh} on obtient {n} tel que ({n}{symb_to_hyp rel rel_rhs} : {n}{rel}{y}) (h{n} : {p})\n"
      pure <| msg ++ libres [n, n ++ symb_to_hyp rel rel_rhs, "h" ++ n]
    | .exist_simple var_name _typ propo => do
      let n := toString var_name
      let p ← propo.toStr
      let mut msg := s!"L'hypothèse {sh} est de la forme « ∃ {var_name}, ... »\n"
      msg := msg ++ "On peut l'utiliser avec :\n"
      msg := msg ++ s!"  Par {sh} on obtient {n} tel que (h{n} : {p})\n"
      msg := msg ++ libres [n, "h" ++ n]
      pure msg
    | .conjunction propo propo' => do
      let p ← propo.toStr
      let p' ← propo'.toStr
      let mut msg := s!"L'hypothèse {sh} est de la forme « ... et ... »\n"
      msg := msg ++ s!"On peut l'utiliser avec :\n"
      msg := msg ++ s!"  Par {sh} on obtient (h₁ : {p}) (h₂ : {p'})\n"
      pure (msg ++ libres ["h₁", "h₂"])
    | .disjunction _propo _propo' => do
      let mut msg := s!"L'hypothèse {sh} est de la forme « ... ou ... »\n"
      msg := msg ++ s!"On peut l'utiliser avec :\n"
      pure (msg ++ s!"  On discute en utilisant {sh}")
    | _ => pure "Not yet done"


 elab "helpAt" h:ident : tactic => do
   let s ← helpAtHyp (← getMainGoal) h.getId
   logInfo s

 elab "help" : tactic => do
   pure ()


example {P : ℕ → Prop} (h : ∀ n > 0, P n) : P 2 := by
  helpAt h
  --apply h
  sorry

example (P Q : ℕ → Prop) (h : ∀ n, P n → Q n) (h' : P 2) : Q 2 := by
  helpAt h
  exact h 2 h'

example (P : ℕ → Prop) (h : ∀ n, P n) : P 2 := by
  helpAt h
  exact h 2

example (P Q : ℕ → Prop) (h : P 1 → Q 2) (h' : P 1) : Q 2 := by
  helpAt h
  exact h h'

example (P Q : ℕ → Prop) (h : P 1 → Q 2) : True := by
  helpAt h
  trivial

example (P Q : ℕ → Prop) (h : P 1 ∧ Q 2) : True := by
  helpAt h
  trivial

example (P Q : ℕ → Prop) (h : (∀ n ≥ 2, P n) ↔  ∀ l, Q l) : True := by
  helpAt h
  trivial

example : True ∧ 1 = 1 := by
  help
  exact ⟨trivial, rfl⟩

example (P Q : ℕ → Prop) (h : P 1 ∨ Q 2) : True := by
  helpAt h
  trivial


example : True ∨ false := by
  help
  left
  trivial

example (P : Prop) (h : P) : True := by
  helpAt h
  trivial

example (P : ℕ → ℕ → Prop) (k l n : ℕ) (h : l - n = 0 → P l k) : True := by
  helpAt h
  trivial

example (P : ℕ → ℕ → Prop) (h : ∀ k ≥ 2, ∃ n ≥ 3, ∀ l, l - n = 0 → P l k) : True := by
  helpAt h
  trivial

example (P : ℕ → Prop) (h : ∃ n ≥ 5, P n) : True := by
  helpAt h
  trivial


example (P : ℕ → ℕ → Prop) (h : ∀ k ≥ 2, ∃ n ≥ 3, P n k) : True := by
  helpAt h
  trivial


example (P : ℕ → Prop) (h : ∃ n : ℕ, P n) : True := by
  helpAt h
  trivial

example (P : ℕ → ℕ → Prop) (h : ∀ k, ∃ n : ℕ, P n k) : True := by
  helpAt h
  trivial

example (P : ℕ → ℕ → Prop) (h : ∀ k ≥ 2, ∃ n : ℕ, P n k) : True := by
  helpAt h
  trivial


example (P : ℕ → Prop): ∃ n : ℕ, P n → True := by
  help
  use 0
  tauto

example (P Q : Prop) (h : Q) : P → Q := by
  help
  exact fun _ ↦ h

example : ∀ n ≥ 0, True := by
  help
  intros
  trivial

example : ∀ n : ℕ, 0 ≤ n := by
  help
  exact Nat.zero_le
