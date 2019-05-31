{-# language NoImplicitPrelude #-}
{-# language OverloadedStrings #-}
{-# language ViewPatterns #-}
module Language.Elm.Pretty where

import Protolude hiding (Type, local, list)

import qualified Bound
import qualified Bound.Var as Bound
import qualified Data.HashMap.Lazy as HashMap
import qualified Data.HashSet as HashSet
import Data.String
import Data.Text.Prettyprint.Doc

import Language.Elm.Definition (Definition)
import qualified Language.Elm.Definition as Definition
import Language.Elm.Expression (Expression)
import qualified Language.Elm.Expression as Expression
import qualified Language.Elm.Name as Name
import Language.Elm.Pattern (Pattern)
import qualified Language.Elm.Pattern as Pattern
import Language.Elm.Type (Type)
import qualified Language.Elm.Type as Type

-------------------------------------------------------------------------------
-- Environments

data Environment v = Environment
  { locals :: v -> Name.Local
  , freshLocals :: [Name.Local]
  }

empty :: Environment Void
empty = Environment
  { locals = absurd
  , freshLocals = (fromString . pure <$> ['a'..'z']) ++ [fromString $ [x] <> show n | x <- ['a'..'z'], n <- [(0 :: Int)..]]
  }

extend :: Environment v -> (Environment (Bound.Var () v), Name.Local)
extend env =
  case freshLocals env of
    [] ->
      panic "Language.Elm.Pretty no locals"

    fresh:freshLocals' ->
      ( env
        { locals = Bound.unvar (\() -> fresh) (locals env)
        , freshLocals = freshLocals'
        }
      , fresh
      )

extendPat :: Environment v -> Pattern Int -> Environment (Bound.Var Int v)
extendPat env pat =
  let
    occurrencesSet =
      foldMap HashSet.singleton pat

    occurrences =
      HashSet.toList occurrencesSet

    bindings =
      HashMap.fromList $
        zip occurrences $ freshLocals env

    freshLocals' =
      drop (length occurrences) $ freshLocals env

    lookupVar i =
      case HashMap.lookup i bindings of
        Nothing ->
          panic "Unbound pattern variable"

        Just v ->
          v
  in
  env
    { locals = Bound.unvar lookupVar (locals env)
    , freshLocals = freshLocals'
    }

-------------------------------------------------------------------------------
-- Names

local :: Name.Local -> Doc ann
local (Name.Local l) =
  pretty l

field :: Name.Field -> Doc ann
field (Name.Field f) =
  pretty f

constructor :: Name.Constructor -> Doc ann
constructor (Name.Constructor c) =
  pretty c

qualified :: Name.Qualified -> Doc ann
qualified name@(Name.Qualified modules l) =
  case defaultImport name of
    Nothing ->
      case modules of
        [] ->
          pretty l

        _ ->
          mconcat (intersperse dot $ pretty <$> modules) <> dot <> pretty l
    Just l' ->
      local l'

defaultImport :: Name.Qualified -> Maybe Name.Local
defaultImport qname =
  case qname of
    Name.Qualified ["Basics"] name ->
      Just $ Name.Local name

    "List.List" ->
      Just "List"

    "List.::" ->
      Just "::"

    "Maybe.Maybe" ->
      Just "Maybe"

    "Maybe.Nothing" ->
      Just "Nothing"

    "Maybe.Just" ->
      Just "Just"

    "Result.Result" ->
      Just "Result"

    "Result.Ok" ->
      Just "Ok"

    "Result.Err" ->
      Just "Err"

    "String.String" ->
      Just "String"

    "Char.Char" ->
      Just "Char"

    _ -> Nothing

fixity :: Name.Qualified -> Maybe (Int, Int, Int)
fixity qname =
  case qname of
    "Basics.>>" ->
      leftAssoc 9

    "Basics.<<" ->
      rightAssoc 9

    "Basics.^" ->
      rightAssoc 8

    "Basics.*" ->
      leftAssoc 7

    "Basics./" ->
      leftAssoc 7

    "Basics.//" ->
      leftAssoc 7

    "Basics.%" ->
      leftAssoc 7

    "Basics.+" ->
      leftAssoc 6

    "Basics.-" ->
      leftAssoc 6

    "Parser.|=" ->
      leftAssoc 5

    Name.Qualified ["Parser"] "|." ->
      leftAssoc 6

    "Basics.++" ->
      rightAssoc 5

    "Basics.++" ->
      rightAssoc 5

    "List.::" ->
      rightAssoc 5

    "Basics.==" ->
      noneAssoc 4

    "Basics./=" ->
      noneAssoc 4

    "Basics.<" ->
      noneAssoc 4

    "Basics.>" ->
      noneAssoc 4

    "Basics.<=" ->
      noneAssoc 4

    "Basics.>=" ->
      noneAssoc 4

    "Basics.&&" ->
      rightAssoc 3

    "Basics.||" ->
      leftAssoc 3

    "Basics.|>" ->
      leftAssoc 0

    "Basics.<|" ->
      rightAssoc 0

    _ ->
      Nothing

  where
    leftAssoc n =
      Just (n, n, n + 1)

    rightAssoc n =
      Just (n, n, n + 1)

    noneAssoc n =
      Just (n + 1, n, n + 1)

twoLineOperator :: Name.Qualified -> Bool
twoLineOperator qname =
  case qname of
    "Basics.>>" ->
      True

    "Basics.<<" ->
      True

    "Basics.|>" ->
      True

    "Basics.<|" ->
      True

-------------------------------------------------------------------------------
-- Definitions

definition :: Environment Void -> Definition -> Doc ann
definition env def =
  case def of
    Definition.Constant (Name.Qualified _ name) t e ->
      let
        (names, body) = lambdas env e
      in
      pretty name <+> ":" <+> type_ 0 t <> line <>
      pretty name <+> hsep (local <$> names) <+> "=" <> line <>
      indent 4 body

    Definition.Type (Name.Qualified _ name) constrs ->
      "type" <+> pretty name <> line <>
        indent 4 ("=" <+>
          mconcat
            (intersperse (line <> "| ")
              [constructor c <+> hsep (type_ (appPrec + 1) <$> ts) | (c, ts) <- constrs]))

    Definition.Alias (Name.Qualified _ name) t ->
      "type alias" <+> pretty name <+> "=" <> line <>
      indent 4 (type_ 0 t)

-------------------------------------------------------------------------------
-- Expressions

expression :: Environment v -> Int -> Expression v -> Doc ann
expression env prec expr =
  case expr of
    Expression.Var var ->
      local $ locals env var

    (Expression.appsView -> (Expression.Global qname@(Name.Qualified _ name), args)) ->
      case fixity qname of
        Nothing ->
          atomApps env prec (qualified qname) args

        Just (leftPrec, opPrec, rightPrec) ->
          case args of
            [arg1, arg2] ->
              parensWhen (prec > opPrec) $
                expression env leftPrec arg1 <+> pretty name <>
                (if twoLineOperator qname then line else space) <>
                expression env rightPrec arg2

            arg1:arg2:args' ->
              apps env prec (Expression.apps (Expression.Global qname) [arg1, arg2]) args'

            _ ->
              atomApps env prec (parens $ pretty name) args

    (Expression.appsView -> (fun, args@(_:_))) ->
      apps env prec fun args

    Expression.Global _ ->
      panic "Language.Elm.Pretty expression Global"

    Expression.App {} ->
      panic "Language.Elm.Pretty expression App"

    Expression.Let {} ->
      parensWhen (prec > letPrec) $
        let
          (bindings, body) =
            lets env expr
        in
        "let"
        <> line <> indent 4 (mconcat $ intersperse (line <> line) bindings)
        <> line <> "in"
        <> line <> body

    Expression.Lam {} ->
      parensWhen (prec > lamPrec) $
        let
          (names, body) =
            lambdas env expr
        in
        "\\" <> hsep (local <$> names) <+> "->" <+> body

    Expression.Record fields ->
      encloseSep "{ " " }" ", "
        [ field f <+> "=" <+> expression env 0 expr'
        | (f, expr') <- fields
        ]

    Expression.Proj f ->
      "." <> field f

    Expression.Case expr' branches ->
      parensWhen (prec > casePrec) $
        "case" <+> expression env 0 expr' <+> "of" <> line <>
        indent 4
        (
        mconcat $
        intersperse (line <> line) $
          [ pattern env' 0 pat <+> "->" <> line <> indent 4 (expression env' 0 (Bound.fromScope scope))
          | (pat, scope) <- branches
          , let
              env' =
                extendPat env pat
          ]
        )

    Expression.List exprs ->
      list $ expression env 0 <$> exprs

    Expression.String s ->
      "\"" <> pretty s <> "\""

    Expression.Int i ->
      pretty i

    Expression.Float f ->
      pretty f

apps :: Environment v -> Int -> Expression v -> [Expression v] -> Doc ann
apps env prec fun args =
  case args of
    [] ->
      expression env prec fun

    _ ->
      parensWhen (prec > appPrec) $
        expression env appPrec fun <+> hsep (expression env (appPrec + 1) <$> args)

atomApps :: Environment v -> Int -> Doc ann -> [Expression v] -> Doc ann
atomApps env prec fun args =
  case args of
    [] ->
      fun

    _ ->
      parensWhen (prec > appPrec) $
        fun <+> hsep (expression env (appPrec + 1) <$> args)

lets :: Environment v -> Expression v -> ([Doc ann], Doc ann)
lets env expr =
  case expr of
    Expression.Let expr' scope ->
      let
        (env', name) =
          extend env

        (bindings, body) =
          lets env' (Bound.fromScope scope)

        binding =
          local name <+> "="
            <> line <> indent 4 (expression env 0 expr')

      in
      (binding : bindings , body)

    _ ->
      ([], expression env letPrec expr)

lambdas :: Environment v -> Expression v -> ([Name.Local], Doc ann)
lambdas env expr =
  case expr of
    Expression.Lam scope ->
      let
        (env', name) =
          extend env

        (names, body) =
          lambdas env' (Bound.fromScope scope)
      in
      (name : names, body)

    _ ->
      ([], expression env lamPrec expr)

-------------------------------------------------------------------------------
-- Patterns

pattern :: Environment (Bound.Var Int v) -> Int -> Pattern Int -> Doc ann
pattern env prec pat =
  case pat of
    Pattern.Var var ->
      local $ locals env (Bound.B var)

    Pattern.Wildcard ->
      "_"

    Pattern.Con con [] ->
      qualified con

    Pattern.Con con pats ->
      parensWhen (prec > appPrec) $
        qualified con <+> hsep (pattern env (appPrec + 1) <$> pats)

    Pattern.String s ->
      "\"" <> pretty s <> "\""

    Pattern.Int i ->
      pretty i

    Pattern.Float f ->
      pretty f

-------------------------------------------------------------------------------
-- Types

type_ :: Int -> Type Void -> Doc ann
type_ prec t =
  case t of
    Type.Var v ->
      absurd v

    Type.Global name ->
      qualified name

    Type.App t1 t2 ->
      parensWhen (prec > appPrec) $
        type_ appPrec t1 <+> type_ (appPrec + 1) t2

    Type.Fun t1 t2 ->
      parensWhen (prec > funPrec) $
        type_ (funPrec + 1) t1 <+> "->" <+> type_ funPrec t2

    Type.Record fields ->
      encloseSep "{ " " }" ", "
        [ field f <+> ":" <+> type_ 0 type'
        | (f, type') <- fields
        ]

-------------------------------------------------------------------------------
-- Utils

parensWhen :: Bool -> Doc ann -> Doc ann
parensWhen b =
  if b then
    parens

  else
    identity

appPrec, letPrec, lamPrec, casePrec, funPrec :: Int
appPrec = 10
letPrec = 0
lamPrec = 0
casePrec = 0
funPrec = 0