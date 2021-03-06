{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}

module TSGInt where

import Lang
import SM
import Lisp

import qualified Data.Text as T
import Text.RawString.QQ (r)

-- Following data structures have representation at runtime:
--
-- Bool representation: (ATOM "True") | (ATOM "False")
-- List representation: (ATOM "Nil") | (CONS head tail)
-- Pair representation: (CONS fst snd)
-- Map representation: [(key, value)]
-- Function/variable name representation: Atom
-- Keyword representation: Atom
--
-- Input to the interpreter has the form as returned by repr :: Prog -> EVal

class Repr a where
    repr :: a -> EVal

instance Repr EVal where
    repr (ATOM a) = reprList [ATOM "ATOM", ATOM a]
    repr (CONS head tail) = reprList [ATOM "CONS", repr head, repr tail]
    repr (PVA name) = reprList [ATOM "PVA", ATOM name]
    repr (PVE name) = reprList [ATOM "PVE", ATOM name]
    repr _ = undefined

instance Repr Char where
    repr c = ATOM $ T.pack [c]

instance Repr Bool where
    repr b = ATOM (T.pack $ show b)

instance Repr a => Repr [a] where
    repr [] = ATOM "Nil"
    repr (x:xs) = CONS (repr x) (repr xs)

instance (Repr a, Repr b) => Repr (a, b) where
    repr (x, y) = CONS (repr x) (repr y)

instance Repr FDef where
    repr (DEFINE name params term) = reprList [ATOM "DEFINE", ATOM name, repr params, repr term]

instance Repr Term where
    repr (ALT cond true false) = reprList [ATOM "ALT", repr cond, repr true, repr false]
    repr (CALL fname params) = reprList [ATOM "CALL", ATOM fname, repr params]
    repr (RETURN exp) = reprList [ATOM "RETURN", repr exp]
    repr (TRACE exp term) = reprList [ATOM "TRACE", repr exp, repr term]

instance Repr Cond where
    repr (EQA' lhs rhs) = reprList [ATOM "EQA'", repr lhs, repr rhs]
    repr (CONS' exp lhs rhs a) = reprList [ATOM "CONS'", repr exp, repr lhs, repr rhs, repr a]

tsgInterpSourceCode :: T.Text
tsgInterpSourceCode = T.pack [r|
(defun main (source args) (
    (uncons source source-head source-tail)
    (uncons source-head should-be-define source-head)
    (if (eq should-be-define DEFINE) (
      (uncons source-head func-name source-head)
      (uncons source-head func-params source-head)
      (uncons source-head func-body source-head)

      (set map (register-funcs Nil source))
      (set env (pass-params Nil args func-params))
      (eval-term map env func-body)
    ) (exit FAIL))
))

(defun eval-term (map env term) (
    (uncons term instr term-tail)

    (if (eq instr RETURN) (
        (uncons term-tail exp term-tail)
        (eval-exp env exp)
    )

    (if (eq instr ALT) (
        (uncons term-tail cond term-tail)
        (uncons term-tail alt-1 term-tail)
        (uncons term-tail alt-2 term-tail)
        (uncons (eval-cond env cond) env result)
        (if result
            (eval-term map env alt-1)
            (eval-term map env alt-2)
        )
    )

    (if (eq instr CALL) (
      (uncons term-tail func-name term-tail)
      (uncons term-tail func-args term-tail)
      (set func-args (eval-args env func-args))
      (set func-info (map-get map func-name))
      (uncons func-info func-params func-body)
      (set env (pass-params Nil func-args func-params))
      (eval-term map env func-body)
    ) (exit FAIL))))
))

(defun pass-params (env args params) (
    (if (is-cons args) (
        (uncons args args-head args-tail)
        (uncons params params-head params-tail)
        (set env (cons (cons params-head args-head) env))
        (pass-params env args-tail params-tail)
    ) env)
))

(defun eval-args (env args) (
    (if (is-cons args) (
        (uncons args args-head args-tail)
        (cons (eval-exp env args-head) (eval-args env args-tail))
    ) Nil)
))

(defun eval-exp (env exp) (
    (uncons exp exp-head exp-tail)
    (if (if (eq exp-head PVA) True (eq exp-head PVE)) (
        (map-get env exp)
    )

    (if (eq exp-head ATOM) (
        (uncons exp-tail atom exp-tail)
        (if (is-cons atom) (exit FAIL) atom)
    )

    (if (eq exp-head CONS) (
      (uncons exp-tail car exp-tail)
      (uncons exp-tail cdr exp-tail)
      (set car (eval-exp env car))
      (set cdr (eval-exp env cdr))
      (cons car cdr)
    ) (exit FAIL))))
))

(defun eval-cond (env cond) (
    (uncons cond kind cond-tail)

    (if (eq kind EQA') (
        (uncons cond-tail lhs cond-tail)
        (uncons cond-tail rhs cond-tail)
        (set lhs (eval-exp env lhs))
        (set rhs (eval-exp env rhs))
        (cons env (eq lhs rhs))
    )

    (if (eq kind CONS') (
        (uncons cond-tail exp cond-tail)
        (uncons cond-tail e-var-1 cond-tail)
        (uncons cond-tail e-var-2 cond-tail)
        (uncons cond-tail a-var cond-tail)
        (set exp (eval-exp env exp))
        (if (is-cons exp) (
            (uncons exp exp-head exp-tail)
            (set env (cons (cons e-var-1 exp-head) env))
            (set env (cons (cons e-var-2 exp-tail) env))
            (cons env True)
        ) (
            (set env (cons (cons a-var exp) env))
            (cons env False)
        ))
    ) (exit FAIL))
)))

(defun register-funcs (map defines) (
    (if (is-cons defines) (
        (uncons defines defines-head defines-tail)
        (uncons defines-head DEFINE defines-head)
        (uncons defines-head func-name defines-head)
        (uncons defines-head func-args defines-head)
        (uncons defines-head func-body defines-head)
        (set map (cons (cons func-name (cons func-args func-body)) map))
        (register-funcs map defines-tail)
    ) map)
))

(defun map-get (map key) (
    (if (is-cons map) (
        (uncons map map-head map-tail)
        (uncons map-head map-head-key map-head-value)
        (if (eq key map-head-key) map-head-value
            (map-get map-tail key)
        )
    ) Nil)
))

(defun eq (x y) (
    (if (is-cons x) (
        (uncons x x-head x-tail) 
        (if (is-cons y) (
            (uncons y y-head y-tail)
            (if (eq x-head y-head) (eq x-tail y-tail) False)
        ) False)
    ) (
        (if (is-cons y) False (eqa x y))
    ))
))
|]

tsgInterp :: Prog
tsgInterp = compileSM $ compileLisp tsgInterpSourceCode

runTSGInterp :: Prog -> [Exp] -> Exp
runTSGInterp prog arg = int tsgInterp [repr prog, reprList arg]

selfInterp :: Exp
selfInterp = runTSGInterp tsgInterp [repr id_prog, reprList [reprList [ATOM "Hello", ATOM "World"]]]
