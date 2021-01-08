{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module HieDb.Types where

import Prelude hiding (mod)

import Name
import Module
import NameCache
import Fingerprint

import IfaceEnv (NameCacheUpdater(..))
import Data.IORef

import qualified Data.Text as T

import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Exception

import Data.List.NonEmpty (NonEmpty(..))

import Data.Int

import Database.SQLite.Simple
import Database.SQLite.Simple.ToField
import Database.SQLite.Simple.FromField

import qualified Text.ParserCombinators.ReadP as R

newtype HieDb = HieDb { getConn :: Connection }

data HieDbException
  = IncompatibleSchemaVersion
  { expectedVersion :: Integer, gotVersion :: Integer }
  deriving (Eq,Ord,Show)

instance Exception HieDbException where

setHieTrace :: HieDb -> Maybe (T.Text -> IO ()) -> IO ()
setHieTrace = setTrace . getConn

data ModuleInfo
  = ModuleInfo
  { modInfoName :: ModuleName
  , modInfoUnit :: UnitId -- ^ Identifies the package this module is part of
  , modInfoIsBoot :: Bool -- ^ True, when this ModuleInfo was created by indexing @.hie-boot@  file;
                          -- False when it was created from @.hie@ file
  , modInfoSrcFile :: Maybe FilePath -- ^ The path to the haskell source file, from which the @.hie@ file was created
  , modInfoIsReal :: Bool -- ^ Is this a real source file? I.e. does it come from user's project (as opposed to from project's dependency)?
  , modInfoHash :: Fingerprint -- ^ The hash of the @.hie@ file from which this ModuleInfo was created
  }

instance Show ModuleInfo where
  show = show . toRow

instance ToRow ModuleInfo where
  toRow (ModuleInfo a b c d e f) = toRow (a,b,c,d,e,f)
instance FromRow ModuleInfo where
  fromRow = ModuleInfo <$> field <*> field <*> field
                       <*> field <*> field <*> field

type Res a = a :. ModuleInfo

instance ToField ModuleName where
  toField mod = SQLText $ T.pack $ moduleNameString mod
instance FromField ModuleName where
  fromField fld = mkModuleName . T.unpack <$> fromField fld

instance ToField UnitId where
  toField uid = SQLText $ T.pack $ unitIdString uid
instance FromField UnitId where
  fromField fld = stringToUnitId . T.unpack <$> fromField fld

instance ToField Fingerprint where
  toField hash = SQLText $ T.pack $ show hash
instance FromField Fingerprint where
  fromField fld = readHexFingerprint . T.unpack <$> fromField fld

toNsChar :: NameSpace -> Char
toNsChar ns
  | isVarNameSpace ns = 'v'
  | isDataConNameSpace ns = 'c'
  | isTcClsNameSpace ns  = 't'
  | isTvNameSpace ns = 'z'
  | otherwise = error "namespace not recognized"

fromNsChar :: Char -> Maybe NameSpace
fromNsChar 'v' = Just varName
fromNsChar 'c' = Just dataName
fromNsChar 't' = Just tcClsName
fromNsChar 'z' = Just tvName
fromNsChar _ = Nothing

instance ToField OccName where
  toField occ = SQLText $ T.pack $ toNsChar (occNameSpace occ) : occNameString occ
instance FromField OccName where
  fromField fld =
    case fieldData fld of
      SQLText t ->
        case T.uncons t of
          Just (nsChar,occ)
            | Just ns <- fromNsChar nsChar ->
              return $ mkOccName ns (T.unpack occ)
          _ -> returnError ConversionFailed fld "OccName encoding invalid"
      _ -> returnError Incompatible fld "Expected a SQL string representing an OccName"

data HieModuleRow
  = HieModuleRow
  { hieModuleHieFile :: FilePath -- ^ Full path to @.hie@ file based on which this row was created
  , hieModInfo :: ModuleInfo
  }

instance ToRow HieModuleRow where
  toRow (HieModuleRow a b) =
     toField a : toRow b

instance FromRow HieModuleRow where
  fromRow =
    HieModuleRow <$> field <*> fromRow

data RefRow
  = RefRow
  { refSrc :: FilePath
  , refNameOcc :: OccName
  , refNameMod :: ModuleName
  , refNameUnit :: UnitId
  , refSLine :: Int
  , refSCol :: Int
  , refELine :: Int
  , refECol :: Int
  }

instance ToRow RefRow where
  toRow (RefRow a b c d e f g h) = toRow ((a,b,c):.(d,e,f):.(g,h))

instance FromRow RefRow where
  fromRow = RefRow <$> field <*> field <*> field
                   <*> field <*> field <*> field
                   <*> field <*> field

data DeclRow
  = DeclRow
  { declSrc :: FilePath
  , declNameOcc :: OccName
  , declSLine :: Int
  , declSCol :: Int
  , declELine :: Int
  , declECol :: Int
  , declRoot :: Bool
  }

instance ToRow DeclRow where
  toRow (DeclRow a b c d e f g) = toRow ((a,b,c,d):.(e,f,g))

instance FromRow DeclRow where
  fromRow = DeclRow <$> field <*> field <*> field <*> field
                    <*> field <*> field <*> field

data TypeName = TypeName
  { typeName :: OccName
  , typeMod :: ModuleName
  , typeUnit :: UnitId
  }

data TypeRef = TypeRef
  { typeRefOccId :: Int64
  , typeRefHieFile :: FilePath
  , typeRefDepth :: Int
  , typeRefSLine :: Int
  , typeRefSCol :: Int
  , typeRefELine :: Int
  , typeRefECol :: Int
  }

instance ToRow TypeRef where
  toRow (TypeRef a b c d e f g) = toRow ((a,b,c,d):.(e,f,g))

instance FromRow TypeRef where
  fromRow = TypeRef <$> field <*> field <*> field <*> field
                    <*> field <*> field <*> field

data DefRow
  = DefRow
  { defSrc :: FilePath
  , defNameOcc :: OccName
  , defSLine :: Int
  , defSCol :: Int
  , defELine :: Int
  , defECol :: Int
  }

instance ToRow DefRow where
  toRow (DefRow a b c d e f) = toRow ((a,b,c,d):.(e,f))

instance FromRow DefRow where
  fromRow = DefRow <$> field <*> field <*> field <*> field
                   <*> field <*> field


{-| Monad with access to 'NameCacheUpdater', which is needed to deserialize @.hie@ files -}
class Monad m => NameCacheMonad m where
  getNcUpdater :: m NameCacheUpdater

newtype DbMonadT m a = DbMonadT { runDbMonad :: ReaderT (IORef NameCache) m a } deriving (MonadTrans)
deriving instance Monad m => Functor (DbMonadT m)
deriving instance Monad m => Applicative (DbMonadT m)
deriving instance Monad m => Monad (DbMonadT m)
deriving instance MonadIO m => MonadIO (DbMonadT m)

type DbMonad = DbMonadT IO

runDbM :: IORef NameCache -> DbMonad a -> IO a
runDbM nc x = flip runReaderT nc $ runDbMonad x

instance MonadIO m => NameCacheMonad (DbMonadT m) where
  getNcUpdater = DbMonadT $ ReaderT $ \ref -> pure (NCU $ atomicModifyIORef' ref)


data HieDbErr
  = NotIndexed ModuleName (Maybe UnitId)
  | AmbiguousUnitId (NonEmpty ModuleInfo)
  | NameNotFound OccName (Maybe ModuleName) (Maybe UnitId)
  | NameUnhelpfulSpan Name String

data Symbol = Symbol
    { symName   :: !OccName
    , symModule :: !Module
    } deriving (Eq, Ord)

instance Show Symbol where
    show s =  toNsChar (occNameSpace $ symName s)
           :  ':'
           :  occNameString (symName s)
           <> ":"
           <> moduleNameString (moduleName $ symModule s)
           <> ":"
           <> unitIdString (moduleUnitId $ symModule s)

instance Read Symbol where
  readsPrec = const $ R.readP_to_S readSymbol

readNameSpace :: R.ReadP NameSpace
readNameSpace = do
  c <- R.get
  maybe R.pfail return (fromNsChar c)

readColon :: R.ReadP ()
readColon = () <$ R.char ':'

readSymbol :: R.ReadP Symbol
readSymbol = do
  ns <- readNameSpace
  readColon
  n <- R.many1 R.get
  readColon
  m <- R.many1 R.get
  readColon
  u <- R.many1 R.get
  R.eof
  let mn  = mkModuleName m
      uid = stringToUnitId u
      sym = Symbol
              { symName   = mkOccName ns n
              , symModule = mkModule uid mn
              }
  return sym

-- | GHC Library Directory. Typically you'll want to use
-- @libdir@ from <https://hackage.haskell.org/package/ghc-paths ghc-paths>
newtype LibDir = LibDir FilePath

-- | A way to specify which HieFile to operate on.
-- Either the path to @.hie@ file is given in the Left
-- Or ModuleName (with optional UnitId) is given in the Right
type HieTarget = Either FilePath (ModuleName, Maybe UnitId)
