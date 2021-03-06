{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module for exhaustivity checking over pattern matching definitions
-- The algorithm analyses the clauses of a definition one by one from top
-- to bottom, where in each step it has the cases already missing (uncovered),
-- and it generates the new set of missing cases.
--
module Language.PureScript.Linter.Exhaustive (checkExhaustiveModule) where

import Prelude ()
import Prelude.Compat

import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Data.List (foldl', sortBy, nub)
import Data.Function (on)

import Control.Monad (unless)
import Control.Applicative
import Control.Arrow (first, second)
import Control.Monad.Writer.Class

import Language.PureScript.Crash
import Language.PureScript.AST.Binders
import Language.PureScript.AST.Literals
import Language.PureScript.AST.Declarations
import Language.PureScript.Environment
import Language.PureScript.Names as P
import Language.PureScript.Kinds
import Language.PureScript.Types as P
import Language.PureScript.Errors

-- | There are two modes of failure for the redundancy check:
--
-- 1. Exhaustivity was incomplete due to too many cases, so we couldn't determine redundancy.
-- 2. We didn't attempt to determine redundancy for a binder, e.g. an integer binder.
--
-- We want to warn the user in the first case.
data RedundancyError = Incomplete | Unknown

-- |
-- Qualifies a propername from a given qualified propername and a default module name
--
qualifyName
  :: (ProperName a)
  -> ModuleName
  -> Qualified (ProperName b)
  -> Qualified (ProperName a)
qualifyName n defmn qn = Qualified (Just mn) n
  where
  (mn, _) = qualify defmn qn

-- |
-- Given an environment and a datatype or newtype name,
-- this function returns the associated data constructors if it is the case of a datatype
-- where: - ProperName is the name of the constructor (for example, "Nothing" in Maybe)
--        - [Type] is the list of arguments, if it has (for example, "Just" has [TypeVar "a"])
--
getConstructors :: Environment -> ModuleName -> Qualified (ProperName 'ConstructorName) -> [(ProperName 'ConstructorName, [Type])]
getConstructors env defmn n = extractConstructors lnte
  where

  extractConstructors :: Maybe (Kind, TypeKind) -> [(ProperName 'ConstructorName, [Type])]
  extractConstructors (Just (_, DataType _ pt)) = pt
  extractConstructors _ = internalError "Data name not in the scope of the current environment in extractConstructors"

  lnte :: Maybe (Kind, TypeKind)
  lnte = M.lookup qpn (types env)

  qpn :: Qualified (ProperName 'TypeName)
  qpn = getConsDataName n

  getConsDataName :: Qualified (ProperName 'ConstructorName) -> Qualified (ProperName 'TypeName)
  getConsDataName con =
    case getConsInfo con of
      Nothing -> internalError $ "Constructor " ++ showQualified runProperName con ++ " not in the scope of the current environment in getConsDataName."
      Just (_, pm, _, _) -> qualifyName pm defmn con

  getConsInfo :: Qualified (ProperName 'ConstructorName) -> Maybe (DataDeclType, ProperName 'TypeName, Type, [Ident])
  getConsInfo con = M.lookup con (dataConstructors env)

-- |
-- Replicates a wildcard binder
--
initialize :: Int -> [Binder]
initialize l = replicate l NullBinder

-- |
-- Applies a function over two lists of tuples that may lack elements
--
genericMerge :: Ord a =>
  (a -> Maybe b -> Maybe c -> d) ->
  [(a, b)] ->
  [(a, c)] ->
  [d]
genericMerge _ [] [] = []
genericMerge f bs [] = map (\(s, b) -> f s (Just b) Nothing) bs
genericMerge f [] bs = map (\(s, b) -> f s Nothing (Just b)) bs
genericMerge f bsl@((s, b):bs) bsr@((s', b'):bs')
  | s < s' = f s (Just b) Nothing : genericMerge f bs bsr
  | s > s' = f s' Nothing (Just b') : genericMerge f bsl bs'
  | otherwise = f s (Just b) (Just b') : genericMerge f bs bs'

-- |
-- Find the uncovered set between two binders:
-- the first binder is the case we are trying to cover, the second one is the matching binder
--
missingCasesSingle :: Environment -> ModuleName -> Binder -> Binder -> ([Binder], Either RedundancyError Bool)
missingCasesSingle _ _ _ NullBinder = ([], return True)
missingCasesSingle _ _ _ (VarBinder _) = ([], return True)
missingCasesSingle env mn (VarBinder _) b = missingCasesSingle env mn NullBinder b
missingCasesSingle env mn br (NamedBinder _ bl) = missingCasesSingle env mn br bl
missingCasesSingle env mn NullBinder cb@(ConstructorBinder con _) =
  (concatMap (\cp -> fst $ missingCasesSingle env mn cp cb) allPatterns, return True)
  where
  allPatterns = map (\(p, t) -> ConstructorBinder (qualifyName p mn con) (initialize $ length t))
                  $ getConstructors env mn con
missingCasesSingle env mn cb@(ConstructorBinder con bs) (ConstructorBinder con' bs')
  | con == con' = let (bs'', pr) = missingCasesMultiple env mn bs bs' in (map (ConstructorBinder con) bs'', pr)
  | otherwise = ([cb], return False)
missingCasesSingle env mn NullBinder (LiteralBinder (ObjectLiteral bs)) =
  (map (LiteralBinder . ObjectLiteral . zip (map fst bs)) allMisses, pr)
  where
  (allMisses, pr) = missingCasesMultiple env mn (initialize $ length bs) (map snd bs)
missingCasesSingle env mn (LiteralBinder (ObjectLiteral bs)) (LiteralBinder (ObjectLiteral bs')) =
  (map (LiteralBinder . ObjectLiteral . zip sortedNames) allMisses, pr)
  where
  (allMisses, pr) = uncurry (missingCasesMultiple env mn) (unzip binders)

  sortNames = sortBy (compare `on` fst)

  (sbs, sbs') = (sortNames bs, sortNames bs')

  compB :: a -> Maybe a -> Maybe a -> (a, a)
  compB e b b' = (fm b, fm b')
    where
    fm = fromMaybe e

  compBS :: Eq a => b -> a -> Maybe b -> Maybe b -> (a, (b, b))
  compBS e s b b' = (s, compB e b b')

  (sortedNames, binders) = unzip $ genericMerge (compBS NullBinder) sbs sbs'
missingCasesSingle _ _ NullBinder (LiteralBinder (BooleanLiteral b)) = ([LiteralBinder . BooleanLiteral $ not b], return True)
missingCasesSingle _ _ (LiteralBinder (BooleanLiteral bl)) (LiteralBinder (BooleanLiteral br))
  | bl == br = ([], return True)
  | otherwise = ([LiteralBinder $ BooleanLiteral bl], return False)
missingCasesSingle env mn b (PositionedBinder _ _ cb) = missingCasesSingle env mn b cb
missingCasesSingle env mn b (TypedBinder _ cb) = missingCasesSingle env mn b cb
missingCasesSingle _ _ b _ = ([b], Left Unknown)

-- |
-- Returns the uncovered set of binders
-- the first argument is the list of uncovered binders at step i
-- the second argument is the (i+1)th clause of a pattern matching definition
--
-- The idea of the algorithm is as follows:
-- it processes each binder of the two lists (say, `x` and `y`) one by one
-- at each step two cases arises:
--   - there are no missing cases between `x` and `y`: this is very straightforward, it continues with the remaining cases
--       but keeps the uncovered binder in its position.
--   - there are missing cases, let us call it the set `U`: on the one hand, we mix each new uncovered case in `U`
--       with the current tail of uncovered set. On the other hand, it continues with the remaining cases: here we
--       can use `x` (but it will generate overlapping cases), or `y`, which will generate non-overlapping cases.
--
--     As an example, consider:
--
--       data N = Z | S N
--       f Z Z = Z   --> {[S _, _], [Z, S _]} which are the right non-overlapping cases (GHC uses this).
--
--       if we use `x` instead of `y` (in this case, `y` stands for `Z` and `x` for `_`) we obtain:
--       f Z Z = Z   --> {[S _, _], [_, S _]} you can see that both cases overlaps each other.
--
--       Up to now, we've decided to use `x` just because we expect to generate uncovered cases which might be
--       redundant or not, but uncovered at least. If we use `y` instead, we'll need to have a redundancy checker
--       (which ought to be available soon), or increase the complexity of the algorithm.
--
missingCasesMultiple :: Environment -> ModuleName -> [Binder] -> [Binder] -> ([[Binder]], Either RedundancyError Bool)
missingCasesMultiple env mn = go
  where
  go [] [] = ([], pure True)
  go (x:xs) (y:ys) = (map (: xs) miss1 ++ map (x :) miss2, liftA2 (&&) pr1 pr2)
    where
    (miss1, pr1) = missingCasesSingle env mn x y
    (miss2, pr2) = go xs ys
  go _ _ = internalError "Argument lengths did not match in missingCasesMultiple."

-- |
-- Guard handling
--
-- We say a guard is exhaustive iff it has an `otherwise` (or `true`) expression.
-- Example:
--   f x | x < 0 = 0
--       | otherwise = 1
--   is exhaustive, whereas `f x | x < 0` is not
--
-- The function below say whether or not a guard has an `otherwise` expression
-- It is considered that `otherwise` is defined in Prelude
--
isExhaustiveGuard :: Either [(Guard, Expr)] Expr -> Bool
isExhaustiveGuard (Left gs) = not . null $ filter (\(g, _) -> isOtherwise g) gs
  where
  isOtherwise :: Expr -> Bool
  isOtherwise (Literal (BooleanLiteral True)) = True
  isOtherwise (Var (Qualified (Just (ModuleName [ProperName "Prelude"])) (Ident "otherwise"))) = True
  isOtherwise (Var (Qualified (Just (ModuleName [ProperName "Data", ProperName "Boolean"])) (Ident "otherwise"))) = True
  isOtherwise (TypedValue _ e _) = isOtherwise e
  isOtherwise (PositionedValue _ _ e) = isOtherwise e
  isOtherwise _ = False
isExhaustiveGuard (Right _) = True

-- |
-- Returns the uncovered set of case alternatives
--
missingCases :: Environment -> ModuleName -> [Binder] -> CaseAlternative -> ([[Binder]], Either RedundancyError Bool)
missingCases env mn uncovered ca = missingCasesMultiple env mn uncovered (caseAlternativeBinders ca)

missingAlternative :: Environment -> ModuleName -> CaseAlternative -> [Binder] -> ([[Binder]], Either RedundancyError Bool)
missingAlternative env mn ca uncovered
  | isExhaustiveGuard (caseAlternativeResult ca) = mcases
  | otherwise = ([uncovered], snd mcases)
  where
  mcases = missingCases env mn uncovered ca

-- |
-- Main exhaustivity checking function
-- Starting with the set `uncovered = { _ }` (nothing covered, one `_` for each function argument),
-- it partitions that set with the new uncovered cases, until it consumes the whole set of clauses.
-- Then, returns the uncovered set of case alternatives.
--
checkExhaustive :: forall m. (MonadWriter MultipleErrors m) => Bool -> Environment -> ModuleName -> Int -> [CaseAlternative] -> m ()
checkExhaustive hasConstraint env mn numArgs cas = makeResult . first nub $ foldl' step ([initialize numArgs], (pure True, [])) cas
  where
  step :: ([[Binder]], (Either RedundancyError Bool, [[Binder]])) -> CaseAlternative -> ([[Binder]], (Either RedundancyError Bool, [[Binder]]))
  step (uncovered, (nec, redundant)) ca =
    let (missed, pr) = unzip (map (missingAlternative env mn ca) uncovered)
        (missed', approx) = splitAt 10000 (nub (concat missed))
        cond = or <$> sequenceA pr
    in (missed', ( if null approx
                     then liftA2 (&&) cond nec
                     else Left Incomplete
                 , if either (const True) id cond
                     then redundant
                     else caseAlternativeBinders ca : redundant
                 )
       )

  makeResult :: ([[Binder]], (Either RedundancyError Bool, [[Binder]])) -> m ()
  makeResult (bss, (rr, bss')) =
    do unless (hasConstraint || null bss) tellNonExhaustive
       unless (null bss') tellRedundant
       case rr of
         Left Incomplete -> unless hasConstraint tellIncomplete
         _ -> return ()
    where
    tellNonExhaustive = tell . errorMessage . uncurry NotExhaustivePattern . second null . splitAt 5 $ bss
    tellRedundant = tell . errorMessage . uncurry OverlappingPattern . second null . splitAt 5 $ bss'
    tellIncomplete = tell . errorMessage $ IncompleteExhaustivityCheck

-- |
-- Exhaustivity checking over a list of declarations
--
checkExhaustiveDecls :: forall m. MonadWriter MultipleErrors m => Environment -> ModuleName -> [Declaration] -> m ()
checkExhaustiveDecls env mn = mapM_ onDecl
  where
  onDecl :: Declaration -> m ()
  onDecl (BindingGroupDeclaration bs) = mapM_ (onDecl . convert) bs
    where
    convert :: (Ident, NameKind, Expr) -> Declaration
    convert (name, nk, e) = ValueDeclaration name nk [] (Right e)
  onDecl (ValueDeclaration name _ _ (Right e)) = censor (addHint (ErrorInValueDeclaration name)) (onExpr False e)
  onDecl (PositionedDeclaration pos _ dec) = censor (addHint (PositionedError pos)) (onDecl dec)
  onDecl _ = return ()

  onExpr :: Bool -> Expr -> m ()
  onExpr isP (UnaryMinus e) = onExpr isP e
  onExpr isP (Literal (ArrayLiteral es)) = mapM_ (onExpr isP) es
  onExpr isP (Literal (ObjectLiteral es)) = mapM_ (onExpr isP . snd) es
  onExpr isP (TypeClassDictionaryConstructorApp _ e) = onExpr isP e
  onExpr isP (Accessor _ e) = onExpr isP e
  onExpr isP (ObjectUpdate o es) = onExpr isP o >> mapM_ (onExpr isP . snd) es
  onExpr isP (Abs _ e) = onExpr isP e
  onExpr isP (App e1 e2) = onExpr isP e1 >> onExpr isP e2
  onExpr isP (IfThenElse e1 e2 e3) = onExpr isP e1 >> onExpr isP e2 >> onExpr isP e3
  onExpr isP (Case es cas) = checkExhaustive isP env mn (length es) cas >> mapM_ (onExpr isP) es >> mapM_ (onCaseAlternative isP) cas
  onExpr isP (TypedValue _ e ty) = onExpr (isP || hasPartialConstraint ty) e
  onExpr isP (Let ds e) = mapM_ onDecl ds >> onExpr isP e
  onExpr isP (PositionedValue pos _ e) = censor (addHint (PositionedError pos)) (onExpr isP e)
  onExpr _ _ = return ()

  onCaseAlternative :: Bool -> CaseAlternative -> m ()
  onCaseAlternative isP (CaseAlternative _ (Left es)) = mapM_ (\(e, g) -> onExpr isP e >> onExpr isP g) es
  onCaseAlternative isP (CaseAlternative _ (Right e)) = onExpr isP e

  hasPartialConstraint :: Type -> Bool
  hasPartialConstraint (ConstrainedType cs _) = any (go . fst) cs
    where
    go :: Qualified (ProperName 'ClassName) -> Bool
    go qname
      | qname == partialClass = True
      | otherwise =
          case qname `M.lookup` typeClasses env of
            Just ([], _, cs') -> any (go . fst) cs'
            _ -> False
    partialClass :: Qualified (ProperName 'ClassName)
    partialClass = primName "Partial"
  hasPartialConstraint _ = False

-- |
-- Exhaustivity checking over a single module
--
checkExhaustiveModule :: forall m. MonadWriter MultipleErrors m => Environment -> Module -> m ()
checkExhaustiveModule env (Module _ _ mn ds _) = censor (addHint (ErrorInModule mn)) $ checkExhaustiveDecls env mn ds
