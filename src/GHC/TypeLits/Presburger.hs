{-# LANGUAGE MultiWayIf, PatternGuards, TupleSections #-}
module GHC.TypeLits.Presburger (plugin) where
import           Data.Foldable       (asum)
import           Data.Integer.SAT    (Expr (..), Prop (..), Prop, PropSet)
import           Data.Integer.SAT    (assert, checkSat, noProps, toName)
import qualified Data.Integer.SAT    as SAT
import           Data.IORef          (readIORef)
import           Data.List           (nub)
import           Data.Maybe          (fromMaybe, isNothing, mapMaybe)
import           GHC.IORef           (newIORef)
import           GHC.IORef           (IORef)
import           GHC.IORef           (writeIORef)
import           GHC.TcPluginM.Extra (evByFiat)
import           GHC.TcPluginM.Extra (tracePlugin)
import           GhcPlugins          (EqRel (..), PredTree (..))
import           GhcPlugins          (classifyPredType, mkTyConTy, ppr)
import           GhcPlugins          (promotedFalseDataCon, promotedTrueDataCon)
import           GhcPlugins          (text, tyConAppTyCon_maybe, typeKind)
import           GhcPlugins          (typeNatKind)
import           Plugins             (Plugin (..), defaultPlugin)
import           TcEvidence          (EvTerm)
import           TcPluginM           (TcPluginM, tcPluginTrace)
import           TcPluginM           (tcPluginIO)
import           TcRnMonad           (Ct, TcPluginResult (..), isWanted)
import           TcRnTypes           (TcPlugin (..), ctEvPred, ctEvidence)
import           TcTypeNats          (typeNatAddTyCon, typeNatExpTyCon)
import           TcTypeNats          (typeNatLeqTyCon, typeNatMulTyCon)
import           TcTypeNats          (typeNatSubTyCon)
import           Type                (emptyTvSubst)
import           Type                (TvSubst)
import           Type                (unionTvSubst)
import           Type                (substTy)
import           TypeRep             (TyLit (NumTyLit), Type (..))
import           Unify               (tcUnifyTy)
import           Unique              (getKey, getUnique)

assert' :: Prop -> PropSet -> PropSet
assert' p ps = foldr assert ps (p : varPos)
  where
    varPos = [K 0 :<= Var i | i <- varsProp p ]

varsProp :: Prop -> [SAT.Name]
varsProp (p :|| q) = nub $ varsProp p ++ varsProp q
varsProp (p :&& q) = nub $ varsProp p ++ varsProp q
varsProp (Not p)   = varsProp p
varsProp (e :== v) = nub $ varsExpr e ++ varsExpr v
varsProp (e :/= v) = nub $ varsExpr e ++ varsExpr v
varsProp (e :< v) = nub $ varsExpr e ++ varsExpr v
varsProp (e :> v) = nub $ varsExpr e ++ varsExpr v
varsProp (e :<= v) = nub $ varsExpr e ++ varsExpr v
varsProp (e :>= v) = nub $ varsExpr e ++ varsExpr v
varsProp _ = []

varsExpr :: Expr -> [SAT.Name]
varsExpr (e :+ v)   = nub $ varsExpr e ++ varsExpr v
varsExpr (e :- v)   = nub $ varsExpr e ++ varsExpr v
varsExpr (_ :* v)   = varsExpr v
varsExpr (Negate e) = varsExpr e
varsExpr (Var i)    = [i]
varsExpr (K _)      = []
varsExpr (If p e v) = nub $ varsProp p ++ varsExpr e ++ varsExpr v
varsExpr (Div e _)  = varsExpr e
varsExpr (Mod e _)  = varsExpr e

plugin :: Plugin
plugin = defaultPlugin { tcPlugin = const $ Just presburgerPlugin }

presburgerPlugin :: TcPlugin
presburgerPlugin =
  tracePlugin "typelits-presburger" $
  TcPlugin { tcPluginInit  = tcPluginIO $ newIORef emptyTvSubst
           , tcPluginSolve = decidePresburger
           , tcPluginStop  = const $ return ()
           }

testIf :: PropSet -> Prop -> Bool
testIf ps q = isNothing $ checkSat (Not q `assert'` ps)

type PresState = IORef TvSubst

decidePresburger :: PresState -> [Ct] -> [Ct] -> [Ct] -> TcPluginM TcPluginResult
decidePresburger _ref gs [] [] = do
  tcPluginTrace "Started givens with: " (ppr gs)
  let subst = foldr unionTvSubst emptyTvSubst $
              map genSubst gs
      givens = mapMaybe (\a -> (,) a <$> toPresburgerPred subst (deconsPred a)) gs
      prems0 = map snd givens
      prems  = foldr assert' noProps prems0
      (solved, _) = foldr go ([], noProps) givens
  tcPluginIO $ writeIORef _ref subst
  if isNothing (checkSat prems)
    then return $ TcPluginContradiction gs
    else return $ TcPluginOk (map withEv solved) []
  where
    go (ct, p) (ss, prem)
      | testIf prem p = (ct : ss, prem)
      | otherwise = (ss, assert' p prem)
decidePresburger _ref gs ds ws = do
  subst0 <- tcPluginIO $ readIORef _ref
  let subst = foldr unionTvSubst subst0 $
              map genSubst (gs ++ ds)
  tcPluginTrace "Current subst" (ppr subst)
  tcPluginTrace "wanteds" (ppr ws)
  tcPluginTrace "givens" (ppr gs)
  tcPluginTrace "driveds" (ppr ds)
  let wants = mapMaybe (\ct -> (,) ct <$> toPresburgerPred subst (deconsPred ct)) $
              filter (isWanted . ctEvidence) ws
      prems = foldr assert' noProps $
              mapMaybe (toPresburgerPred subst . deconsPred) (ds ++ gs)
      solved = map fst $ filter (testIf prems . snd) wants
      coerced = [(evByFiat "ghc-typelits-presburger" t1 t2, ct)
                | ct <- solved
                , EqPred NomEq t1 t2 <- return (deconsPred ct)
                ]
      leq'd = []
  tcPluginIO $ writeIORef _ref subst
  tcPluginTrace "prems" (text $ show prems)
  if isNothing $ checkSat (foldr (assert' . snd) noProps wants)
    then return $ TcPluginContradiction $ map fst wants
    else return $ TcPluginOk (coerced ++ leq'd) []

genSubst :: Ct -> TvSubst
genSubst ct = case deconsPred ct of
  EqPred NomEq t u -> fromMaybe emptyTvSubst $ tcUnifyTy t u
  _ -> emptyTvSubst

withEv :: Ct -> (EvTerm, Ct)
withEv ct
  | EqPred _ t1 t2 <- deconsPred ct =
      (evByFiat "ghc-typelits-presburger" t1 t2, ct)
  | otherwise = undefined

deconsPred :: Ct -> PredTree
deconsPred = classifyPredType . ctEvPred . ctEvidence

toPresburgerPred :: TvSubst -> PredTree -> Maybe Prop
toPresburgerPred subst (EqPred NomEq p false) -- P ~ 'False <=> Not P ~ 'True
  | Just promotedFalseDataCon  == tyConAppTyCon_maybe (substTy subst false) =
    Not <$> toPresburgerPred subst (EqPred NomEq p (mkTyConTy promotedTrueDataCon))
toPresburgerPred subst (EqPred NomEq p b)  -- (n :<=? m) ~ 'True
  | Just promotedTrueDataCon  == tyConAppTyCon_maybe (substTy subst b)
  , TyConApp con [t1, t2] <- substTy subst p
  , con == typeNatLeqTyCon = (:<=) <$> toPresburgerExp subst t1  <*> toPresburgerExp subst t2
toPresburgerPred subst (EqPred NomEq t1 t2) -- (n :: Nat) ~ (m :: Nat)
  | typeKind t1 == typeNatKind = (:==) <$> toPresburgerExp subst t1 <*> toPresburgerExp subst t2
toPresburgerPred _ _ = Nothing

toPresburgerExp :: TvSubst -> Type -> Maybe Expr
toPresburgerExp dic ty = case substTy dic ty of
  TyVarTy t -> Just $ Var $ toName $ getKey $ getUnique t
  TyConApp tc ts  ->
    let step con op
          | tc == con, [tl, tr] <- ts =
            op <$> toPresburgerExp dic tl <*> toPresburgerExp dic tr
          | otherwise = Nothing
    in case ts of
      [tl, tr] | tc == typeNatMulTyCon ->
        case (simpleExp tl, simpleExp tr) of
          (LitTy (NumTyLit n), LitTy (NumTyLit m)) -> Just $ K $ n * m
          (LitTy (NumTyLit n), x) -> (:*) <$> pure n <*> toPresburgerExp dic x
          (x, LitTy (NumTyLit n)) -> (:*) <$> pure n <*> toPresburgerExp dic x
          _ -> Nothing
      _ ->  asum [ step con op
                 | (con, op) <- [(typeNatAddTyCon, (:+)), (typeNatSubTyCon, (:-))]]
  LitTy (NumTyLit n) -> Just (K n)
  _ -> Nothing

simpleExp :: Type -> Type
simpleExp (TyVarTy t) = TyVarTy t
simpleExp (AppTy t1 t2) = AppTy (simpleExp t1) (simpleExp t2)
simpleExp (FunTy t1 t2) = FunTy (simpleExp t1) (simpleExp t2)
simpleExp (ForAllTy t1 t2) = ForAllTy t1 (simpleExp t2)
simpleExp (LitTy t) = LitTy t
simpleExp (TyConApp tc ts) = fromMaybe (TyConApp tc (map simpleExp ts)) $
  asum (map simpler [(typeNatAddTyCon, (+))
                    ,(typeNatSubTyCon, (-))
                    ,(typeNatMulTyCon, (*))
                    ,(typeNatExpTyCon, (^))
                    ])
  where
    simpler (con, op)
      | con == tc, [tl, tr] <- map simpleExp ts =
        Just $
        case (tl, tr) of
          (LitTy (NumTyLit n), LitTy (NumTyLit m)) -> LitTy (NumTyLit (op n m))
          _ -> TyConApp con [tl, tr]
      | otherwise = Nothing

