{-#LANGUAGE ImpredicativeTypes, ScopedTypeVariables, FunctionalDependencies, TypeFamilies, UndecidableInstances, FlexibleInstances, MultiParamTypeClasses, AllowAmbiguousTypes, GADTs, KindSignatures, DataKinds, PolyKinds, TypeOperators, ViewPatterns, PatternSynonyms, RankNTypes, FlexibleContexts #-}

module Carnap.Core.Unification.Unification (
   Equation((:=:)), UError(..), FirstOrder(..), HigherOrder(..),
      applySub, mapAll, freeVars, emap, sameTypeEq, ExtApp(..), ExtLam(..)
) where

import Data.Type.Equality
import Data.Typeable
import Carnap.Core.Data.AbstractSyntaxClasses
import Carnap.Core.Util

data Equation f where
    (:=:) :: (Typeable a) => f a -> f a -> Equation f

instance Schematizable f => Show (Equation f) where
        show (x :=: y) = schematize x [] ++ " :=: " ++ schematize y []

instance UniformlyEq f => Eq (Equation f) where
        (x :=: y) == (x' :=: y') = x =* x' && y =* y'

instance (UniformlyEq f, UniformlyOrd f) => Ord (Equation f) where
        (x :=: y) <= (x' :=: y') =  (x :=: y) == (x' :=: y') 
                                 || (x =* x') && (y <=* y')
                                 || (x <=* x')

--this interface seems simpler for the user to implement than our previous
--1. There is no more varible type
--2. There is no substitution type
--3. other than decompose the operations are simpler. For instance rather than
--   freeVars there is occurs. rather than a full substitution there is just
--   a single varible substitution. rather than combining sameHead and decompose
--   they are seperate methods. rather than converting a varible to check if it
--   it is a varible we just have 'isVar'
--4. Additionally I have tried to allow this to meet the demands of more
--   unification algorithms so that this is a one stop shop for unification
--5. I have tried to name things here in a way that someone reading the HoAR
--   would recognize (hence "decompose" rather than "match")
class UniformlyEq f => FirstOrder f where
    isVar :: f a -> Bool
    sameHead :: f a -> f a -> Bool
    decompose :: f a -> f a -> [Equation f]
    occurs :: f a -> f b -> Bool
    subst :: f a -> f a -> f b -> f b

data ExtApp f a where
    ExtApp :: Typeable b => f (b -> a) -> f b -> ExtApp f a

data ExtLam f a where
    ExtLam :: (Typeable b, Typeable c) => 
        (f b -> f c) -> (a :~: (b -> c)) -> ExtLam f a

class FirstOrder f => HigherOrder f where
    matchApp :: f a -> Maybe (ExtApp f a)
    castLam ::  f a -> Maybe (ExtLam f a)
    --getLamVar :: f (a -> b) -> f a
    (.$.) :: (Typeable a, Typeable b) => f (a -> b) -> f a -> f b
    lam :: (Typeable a, Typeable b) => (f a -> f b) -> f (a -> b) 

instance {-# OVERLAPPABLE #-} (Monad m, Typeable a, HigherOrder f) => EtaExpand m f a

instance (Typeable b, MonadVar f m, EtaExpand m f a, HigherOrder f) 
        => EtaExpand m f (b -> a) where
        etaExpand l  = case castLam l of 
                        Just (ExtLam f Refl) -> 
                                 do v <- fresh
                                    inner <- etaExpand (f v)
                                    case inner of
                                        Nothing -> return Nothing 
                                        Just t -> return $ Just $ lam $ \x -> subst v x t
                        Nothing -> return $ Just $ lam $ \x -> l .$. x

data UError f where
    SubError :: f a -> f a -> UError f -> UError f
    MatchError ::  f a -> f a -> UError f
    OccursError :: f a -> f a -> UError f

instance Schematizable f => Show (UError f) where
        show (SubError x y e) =  show e ++ "with suberror"
                                 ++ schematize x [] ++ ", "
                                 ++ schematize y []
        show (MatchError x y) = "Match Error:"
                                 ++ schematize x [] ++ ", "
                                 ++ schematize y []
        show (OccursError x y) = "OccursError: "
                                 ++ schematize x [] ++ ", "
                                 ++ schematize y []

sameTypeEq :: Equation f -> Equation f -> Bool
sameTypeEq ((a :: f a) :=: _) ((b :: f b) :=: _) = 
        case eqT :: Maybe (a :~: b) of
            Just Refl -> True
            Nothing -> False

emap :: (forall a. f a -> f a) -> Equation f -> Equation f
emap f (x :=: y) = f x :=: f y

mapAll :: (forall a. f a -> f a) -> [Equation f] -> [Equation f]
mapAll f = map (emap f)

(Left x) .<. f = Left (f x)
x .<. _ = x

-- XXX: Depricated in favor of FirstOrder.hs
{- 
founify :: FirstOrder f => [Equation f] -> [Equation f] -> Either (UError f) [Equation f]
founify [] ss = Right ss
founify ((x :=: y):es) ss
    | isVar x && occurs x y       = Left $ OccursError x y
    | isVar x && not (occurs x y) = founify (mapAll (subst x y) es) ((x :=: y):ss)
    | isVar y                     = founify ((y :=: x):es) ss
    | sameHead x y                = founify (es ++ decompose x y) ss .<. SubError x y
    | otherwise                   = Left $ MatchError x y
-}

applySub :: FirstOrder f => [Equation f] -> f a -> f a
applySub []             y = y
applySub ((v :=: x):ss) y = applySub ss (subst v x y)

freeVars :: (Typeable a, FirstOrder f) => f a -> [AnyPig f]
freeVars t | isVar t   = [AnyPig t]
           | otherwise = concatMap rec (decompose t t)
    where rec (a :=: _) = freeVars a
