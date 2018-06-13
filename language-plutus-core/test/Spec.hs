{-# LANGUAGE OverloadedStrings #-}

module Main ( main
            ) where

import qualified Data.ByteString.Lazy                  as BSL
import           Data.Foldable                         (fold)
import           Data.Function                         (on)
import           Data.List.NonEmpty                    (NonEmpty (..))
import qualified Data.List.NonEmpty                    as NE
import           Data.Text.Encoding                    (encodeUtf8)
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Render.Text
import           Hedgehog                              hiding (Size, Var)
import qualified Hedgehog.Gen                          as Gen
import qualified Hedgehog.Range                        as Range
import           Language.PlutusCore
import           Test.Tasty
import           Test.Tasty.Golden
import           Test.Tasty.Hedgehog
import           Test.Tasty.HUnit

main :: IO ()
main = do
    plcFiles <- findByExtension [".plc"] "test/data"
    defaultMain (allTests plcFiles)

compareName :: Name a -> Name a -> Bool
compareName = (==) `on` nameString

compareTyName :: TyName a -> TyName a -> Bool
compareTyName (TyName n) (TyName n') = compareName n n'

compareTerm :: Eq a => Term TyName Name a -> Term TyName Name a -> Bool
compareTerm (Var _ n) (Var _ n')                   = compareName n n'
compareTerm (TyAbs _ n k t) (TyAbs _ n' k' t')     = compareTyName n n' && k == k' && compareTerm t t'
compareTerm (LamAbs _ n ty t) (LamAbs _ n' ty' t') = compareName n n' && compareType ty ty' && compareTerm t t'
compareTerm (Apply _ t ts) (Apply _ t' ts')        = compareTerm t t' && and (NE.zipWith compareTerm ts ts')
compareTerm (Fix _ n ty t) (Fix _ n' ty' t')       = compareName n n' && compareType ty ty' && compareTerm t t'
compareTerm (Constant _ x) (Constant _ y)          = x == y
compareTerm (TyInst _ t ts) (TyInst _ t' ts')      = compareTerm t t' && and (NE.zipWith compareType ts ts')
compareTerm (Unwrap _ t) (Unwrap _ t')             = compareTerm t t'
compareTerm (Wrap _ n ty t) (Wrap _ n' ty' t')     = compareTyName n n' && compareType ty ty' && compareTerm t t'
compareTerm (Error _ ty) (Error _ ty')             = compareType ty ty'
compareTerm _ _                                    = False

compareType :: Eq a => Type TyName a -> Type TyName a -> Bool
compareType (TyVar _ n) (TyVar _ n')                 = compareTyName n n'
compareType (TyFun _ t s) (TyFun _ t' s')            = compareType t t' && compareType s s'
compareType (TyFix _ n k t) (TyFix _ n' k' t')       = compareTyName n n' && k == k' && compareType t t'
compareType (TyForall _ n k t) (TyForall _ n' k' t') = compareTyName n n' && k == k' && compareType t t'
compareType (TyBuiltin _ x) (TyBuiltin _ y)          = x == y
compareType (TyLam _ n k t) (TyLam _ n' k' t')       = compareTyName n n' && k == k' && compareType t t'
compareType (TyApp _ t ts) (TyApp _ t' ts')          = compareType t t' && and (NE.zipWith compareType ts ts')
compareType _ _                                      = False

compareProgram :: Eq a => Program TyName Name a -> Program TyName Name a -> Bool
compareProgram (Program _ v t) (Program _ v' t') = v == v' && compareTerm t t'

genVersion :: MonadGen m => m (Version AlexPosn)
genVersion = Version emptyPosn <$> int' <*> int' <*> int'
    where int' = Gen.integral_ (Range.linear 0 10)

genTyName :: MonadGen m => m (TyName AlexPosn)
genTyName = TyName <$> genName

-- TODO make this robust against generating identfiers such as "fix"?
genName :: MonadGen m => m (Name AlexPosn)
genName = Name emptyPosn <$> name' <*> int'
    where int' = Unique <$> Gen.int (Range.linear 0 3000)
          name' = BSL.fromStrict <$> Gen.utf8 (Range.linear 1 20) Gen.lower

simpleRecursive :: MonadGen m => [m a] -> [m a] -> m a
simpleRecursive = Gen.recursive Gen.choice

genKind :: MonadGen m => m (Kind AlexPosn)
genKind = simpleRecursive nonRecursive recursive
    where nonRecursive = pure <$> sequence [Type, Size] emptyPosn
          recursive = [KindArrow emptyPosn <$> genKind <*> genKind]

genBuiltinName :: MonadGen m => m BuiltinName
genBuiltinName = Gen.choice $ pure <$>
    [ AddInteger, SubtractInteger, MultiplyInteger, DivideInteger, RemainderInteger
    , LessThanInteger, LessThanEqInteger, GreaterThanInteger, GreaterThanEqInteger
    , EqInteger, IntToByteString, IntToByteString, Concatenate, TakeByteString
    , DropByteString, ResizeByteString, SHA2, SHA3, VerifySignature
    , EqByteString, TxHash, BlockNum, BlockTime
    ]

genBuiltin :: MonadGen m => m (Constant AlexPosn)
genBuiltin = Gen.choice [BuiltinName emptyPosn <$> genBuiltinName, genInt, genSize, genBS]
    where int' = Gen.integral_ (Range.linear (-10000000) 10000000)
          size' = Gen.integral_ (Range.linear 1 10)
          string' = BSL.fromStrict <$> Gen.utf8 (Range.linear 0 40) Gen.unicode
          genInt = BuiltinInt emptyPosn <$> size' <*> int'
          genSize = BuiltinSize emptyPosn <$> size'
          genBS = BuiltinBS emptyPosn <$> size' <*> string'

genType :: MonadGen m => m (Type TyName AlexPosn)
genType = simpleRecursive nonRecursive recursive
    where varGen = TyVar emptyPosn <$> genTyName
          funGen = TyFun emptyPosn <$> genType <*> genType
          lamGen = TyLam emptyPosn <$> genTyName <*> genKind <*> genType
          forallGen = TyForall emptyPosn <$> genTyName <*> genKind <*> genType
          fixGen = TyFix emptyPosn <$> genTyName <*> genKind <*> genType
          applyGen = TyApp emptyPosn <$> genType <*> args genType
          recursive = [funGen, applyGen]
          nonRecursive = [varGen, lamGen, forallGen, fixGen]
          args = Gen.nonEmpty (Range.linear 1 4)

genTerm :: MonadGen m => m (Term TyName Name AlexPosn)
genTerm = simpleRecursive nonRecursive recursive
    where varGen = Var emptyPosn <$> genName
          fixGen = Fix emptyPosn <$> genName <*> genType <*> genTerm
          absGen = TyAbs emptyPosn <$> genTyName <*> genKind <*> genTerm
          instGen = TyInst emptyPosn <$> genTerm <*> args genType
          lamGen = LamAbs emptyPosn <$> genName <*> genType <*> genTerm
          applyGen = Apply emptyPosn <$> genTerm <*> args genTerm
          unwrapGen = Unwrap emptyPosn <$> genTerm
          wrapGen = Wrap emptyPosn <$> genTyName <*> genType <*> genTerm
          errorGen = Error emptyPosn <$> genType
          recursive = [fixGen, absGen, instGen, lamGen, applyGen, unwrapGen, wrapGen]
          nonRecursive = [varGen, Constant emptyPosn <$> genBuiltin, errorGen]
          args = Gen.nonEmpty (Range.linear 1 4)

genProgram :: MonadGen m => m (Program TyName Name AlexPosn)
genProgram = Program emptyPosn <$> genVersion <*> genTerm

emptyPosn :: AlexPosn
emptyPosn = AlexPn 0 0 0

-- Generate a random 'Program', pretty-print it, and parse the pretty-printed
-- text, hopefully returning the same thing.
propParser :: Property
propParser = property $ do
    prog <- forAll genProgram
    let nullPosn = fmap (pure emptyPosn)
        reprint = BSL.fromStrict . encodeUtf8 . prettyText
        proc = nullPosn <$> parse (reprint prog)
        compared = and (compareProgram (nullPosn prog) <$> proc)
    Hedgehog.assert compared

allTests :: [FilePath] -> TestTree
allTests plcFiles = testGroup "all tests"
    [ tests
    , testProperty "parser round-trip" propParser
    , testsGolden plcFiles
    , renameTests
    ]

testsGolden :: [FilePath] -> TestTree
testsGolden plcFiles= testGroup "golden tests" $ fmap asGolden plcFiles
    where asGolden file = goldenVsString file (file ++ ".golden") (asIO file)
          -- TODO consider more useful output here
          asIO = fmap (either errorgen (BSL.fromStrict . encodeUtf8) . format) . BSL.readFile
          errorgen = BSL.fromStrict . encodeUtf8 . renderStrict . layoutSmart defaultLayoutOptions . pretty

renameTests :: TestTree
renameTests = testCase "parseScoped" $ fold
    [ parseScoped "(program 0.1.0 (lam x y (lam x z [(con addInteger) x x])))" @?= Right (Program (AlexPn 1 1 2) (Version (AlexPn 9 1 10) 0 1 0) (LamAbs (AlexPn 16 1 17) (Name {nameAttribute = AlexPn 20 1 21, nameString = "x", nameUnique = Unique {unUnique = 3}}) (TyVar (AlexPn 22 1 23) (TyName {unTyName = Name {nameAttribute = AlexPn 22 1 23, nameString = "y", nameUnique = Unique {unUnique = 1}}})) (LamAbs (AlexPn 25 1 26) (Name {nameAttribute = AlexPn 29 1 30, nameString = "x", nameUnique = Unique {unUnique = 4}}) (TyVar (AlexPn 31 1 32) (TyName {unTyName = Name {nameAttribute = AlexPn 31 1 32, nameString = "z", nameUnique = Unique {unUnique = 2}}})) (Apply (AlexPn 33 1 34) (Constant (AlexPn 35 1 36) (BuiltinName (AlexPn 39 1 40) AddInteger)) (Var (AlexPn 51 1 52) (Name {nameAttribute = AlexPn 51 1 52, nameString = "x", nameUnique = Unique {unUnique = 4}}) :| [Var (AlexPn 53 1 54) (Name {nameAttribute = AlexPn 53 1 54, nameString = "x", nameUnique = Unique {unUnique = 4}})]))))) ]

tests :: TestTree
tests = testCase "example programs" $ fold
    [ format "(program 0.1.0 [(con addInteger) x y])" @?= Right "(program 0.1.0 [ (con addInteger) x y ])"
    , format "(program 0.1.0 doesn't)" @?= Right "(program 0.1.0 doesn't)"
    , format "{- program " @?= Left (LexErr "Error in nested comment at line 1, column 12")
    ]
