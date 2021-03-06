{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Lisp (compileLisp) where

import SM

import Control.Monad
import Control.Monad.State
import Data.List
import Data.Either
import Data.Char
import Data.Functor.Identity

import qualified Data.Text as T

import Text.Parsec (many1, satisfy, string, manyTill, newline, anyChar)
import Text.Parsec.Text (Parser)
import Data.SCargot
import Data.SCargot.Parse
import Data.SCargot.Repr
import Data.SCargot.Repr.Basic

data LState = LState { fname :: T.Text
                     , fparams :: [T.Text]
                     , flocals :: [T.Text]
                     , nlabels :: Int
                     }

type Compiler = State LState

isAtomChar :: Char -> Bool
isAtomChar c = isAlphaNum c
  || c == '-' || c == '*' || c == '/'
  || c == '+' || c == '<' || c == '>'
  || c == '=' || c == '!' || c == '?'
  || c == '_' || c == '\''

pToken :: Parser T.Text
pToken = T.pack <$> many1 (satisfy isAtomChar)

pComment :: Parser ()
pComment = string ";" *> manyTill anyChar newline *> pure ()

initialState :: LState
initialState = LState { fname = ""
                      , fparams = []
                      , flocals = []
                      , nlabels = 0
                      }

parseLisp :: T.Text -> Either String [SExpr T.Text]
parseLisp = decode (setComment pComment $ mkParser pToken)

compileLisp :: T.Text -> [Instr]
compileLisp s = compileDefs p
    where p = case parseLisp s of
                Left err -> error err
                Right x -> x

compileDefs :: [SExpr T.Text] -> [Instr]
compileDefs src = concat $ evalState (mapM parseDefun src) initialState

varIdx :: T.Text -> Compiler Int
varIdx var = do
    st <- get
    case elemIndex var (fparams st) of
      Just i -> return i
      Nothing -> case elemIndex var (flocals st) of
                   Just i -> return $ i + (length $ fparams st)
                   Nothing -> do
                       modify (\x -> x { flocals = flocals x ++ [var] })
                       return $ length $ flocals st ++ fparams st

freshLabel :: Compiler T.Text
freshLabel = do
    idx <- gets nlabels
    modify (\x -> x { nlabels = idx + 1 })
    return $ "$L" <> (T.pack $ show idx)

smartLabel :: Block -> Compiler (T.Text, Block)
smartLabel block =
    case block of
      [] -> do
          l <- freshLabel
          return (l, [Label l])
      _ -> case last block of
             Label l -> return (l, block)
             _ -> do
                 l <- freshLabel
                 return (l, block ++ [Label l])

varExists :: T.Text -> Compiler Bool
varExists var = do
    st <- get
    return $ var `elem` (fparams st ++ flocals st)

parseDefun :: SExpr T.Text -> Compiler [Instr]
parseDefun (A "defun" ::: A name ::: L params ::: body ::: SNil) = do
    modify (\x -> x { fname = name
                    , fparams = [p | A p <- params]
                    , flocals = []
                    })
    instr <- parseExpr body
    st <- get
    let n = length $ fparams st ++ flocals st
    let prefix = if name == "main" then [Main $ fparams st] else []
    return $ prefix ++ [ Label name, Locals n ] ++ [SetLocal n | n <- reverse [0..length params-1]] ++ instr ++ [Return]
parseDefun _ = error "invalid parseDefun"

parseExpr :: SExpr T.Text -> Compiler [Instr]
parseExpr (L [A "if", cond, tbody, fbody]) = do
    c <- parseExpr cond
    t <- parseExpr tbody
    f <- parseExpr fbody
    trueLabel <- freshLabel
    (endLabel, t') <- smartLabel t
    return $ c ++ [ CJmp trueLabel ] ++ f ++ [ Jmp endLabel, Label trueLabel ] ++ t'
parseExpr (L [A "exit", rv]) = do
    a <- parseExpr rv
    return $ a ++ [ Exit ]
parseExpr (L [A "eqa", lhs, rhs]) = do
    l <- parseExpr lhs
    r <- parseExpr rhs
    return $ l ++ r ++ [ Eqa ]
parseExpr (L [A "cons", lhs, rhs]) = do
    l <- parseExpr lhs
    r <- parseExpr rhs
    return $ r ++ l ++ [ Cons ]
parseExpr (L [A "is-cons", arg]) = do
    a <- parseExpr arg
    return $ a ++ [ Test ]
parseExpr (L [A "uncons", arg, A headVar, A tailVar]) = do
    a <- parseExpr arg
    h <- varIdx headVar
    t <- varIdx tailVar
    isCons <- freshLabel
    endLabel <- freshLabel
    return $ a ++ [ Split
                  , SetLocal h
                  , SetLocal t
                  , Push "Nil"
                  ]
parseExpr (L [A "set", A var, exp]) = do
    a <- parseExpr exp
    v <- varIdx var
    return $ a ++ [ SetLocal v, Push "Nil" ]
parseExpr (L [A "trace", exp]) = do
    a <- parseExpr exp
    return $ a ++ [ Trace, Push "Nil" ]
parseExpr (A fn ::: L args) = do
    as <- forM args parseExpr
    return $ concat as ++ [ Call fn ]
parseExpr (A var) = do
    e <- varExists var
    if e then do
        i <- varIdx var
        return [ GetLocal i ]
    else return [ Push var ]
parseExpr (L exprs) = do
    as <- forM exprs parseExpr
    return $ intercalate [ Drop ] as
parseExpr _ = error "invalid parseExpr"

