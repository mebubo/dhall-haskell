{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -Wall #-}

module Dhall.Import.Types where

import Control.Exception (Exception)
import Control.Monad.Trans.State.Strict (StateT)
import Data.Dynamic
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import Data.Semigroup ((<>))
import Data.Text.Prettyprint.Doc (Pretty(..))
import Data.Void (Void)
import Dhall.Context (Context)
import Dhall.Core
  ( Directory (..)
  , Expr
  , File (..)
  , FilePrefix (..)
  , Import (..)
  , ImportHashed (..)
  , ImportMode (..)
  , ImportType (..)
  , ReifiedNormalizer(..)
  , URL
  )
import Dhall.Parser (Src)
import Lens.Family (LensLike')
import System.FilePath (isRelative, splitDirectories)

import qualified Dhall.Context
import qualified Data.Map      as Map
import qualified Data.Text

-- | A fully 'chained' import, i.e. if it contains a relative path that path is
--   relative to the current directory. If it is a remote import with headers
--   those are well-typed (either of type `List { header : Text, value Text}` or
--   `List { mapKey : Text, mapValue Text})` and in normal form. These
--   invariants are preserved by the API exposed by @Dhall.Import@.
newtype Chained = Chained
    { chainedImport :: Import
      -- ^ The underlying import
    }
  deriving (Eq, Ord)

instance Pretty Chained where
    pretty (Chained import_) = pretty import_

-- | An import that has been fully interpeted
data ImportSemantics = ImportSemantics
    { importSemantics :: Expr Src Void
    -- ^ The fully resolved import, typechecked and beta-normal.
    }

-- | `parent` imports (i.e. depends on) `child`
data Depends = Depends { parent :: Chained, child :: Chained }

{-| This enables or disables the semantic cache for imports protected by
    integrity checks
-}
data SemanticCacheMode = IgnoreSemanticCache | UseSemanticCache deriving (Eq)

-- | State threaded throughout the import process
data Status = Status
    { _stack :: NonEmpty Chained
    -- ^ Stack of `Import`s that we've imported along the way to get to the
    -- current point

    , _graph :: [Depends]
    -- ^ Graph of all the imports visited so far, represented by a list of
    --   import dependencies.

    , _cache :: Map Chained ImportSemantics
    -- ^ Cache of imported expressions with their node id in order to avoid
    --   importing the same expression twice with different values

    , _remote :: URL -> StateT Status IO Data.Text.Text
    -- ^ The remote resolver, fetches the content at the given URL.

    , _normalizer :: Maybe (ReifiedNormalizer Void)

    , _startingContext :: Context (Expr Src Void)

    , _semanticCacheMode :: SemanticCacheMode
    }

-- | Initial `Status`, parameterised over the remote resolver, importing
--   relative to the given directory.
emptyStatusWith :: (URL -> StateT Status IO Data.Text.Text) -> FilePath -> Status
emptyStatusWith _remote rootDirectory = Status {..}
  where
    _stack = pure (Chained rootImport)

    _graph = []

    _cache = Map.empty

    _normalizer = Nothing

    _startingContext = Dhall.Context.empty

    _semanticCacheMode = UseSemanticCache

    prefix = if isRelative rootDirectory
      then Here
      else Absolute
    pathComponents =
        fmap Data.Text.pack (reverse (splitDirectories rootDirectory))

    dirAsFile = File (Directory pathComponents) "."

    -- Fake import to set the directory we're relative to.
    rootImport = Import
      { importHashed = ImportHashed
        { hash = Nothing
        , importType = Local prefix dirAsFile
        }
      , importMode = Code
      }

-- | Lens from a `Status` to its `_stack` field
stack :: Functor f => LensLike' f Status (NonEmpty Chained)
stack k s = fmap (\x -> s { _stack = x }) (k (_stack s))

-- | Lens from a `Status` to its `_graph` field
graph :: Functor f => LensLike' f Status [Depends]
graph k s = fmap (\x -> s { _graph = x }) (k (_graph s))

-- | Lens from a `Status` to its `_cache` field
cache :: Functor f => LensLike' f Status (Map Chained ImportSemantics)
cache k s = fmap (\x -> s { _cache = x }) (k (_cache s))

-- | Lens from a `Status` to its `_remote` field
remote
    :: Functor f => LensLike' f Status (URL -> StateT Status IO Data.Text.Text)
remote k s = fmap (\x -> s { _remote = x }) (k (_remote s))

-- | Lens from a `Status` to its `_normalizer` field
normalizer :: Functor f => LensLike' f Status (Maybe (ReifiedNormalizer Void))
normalizer k s = fmap (\x -> s {_normalizer = x}) (k (_normalizer s))

-- | Lens from a `Status` to its `_startingContext` field
startingContext :: Functor f => LensLike' f Status (Context (Expr Src Void))
startingContext k s =
    fmap (\x -> s { _startingContext = x }) (k (_startingContext s))

{-| This exception indicates that there was an internal error in Dhall's
    import-related logic
    the `expected` type then the `extract` function must succeed.  If not, then
    this exception is thrown

    This exception indicates that an invalid `Type` was provided to the `input`
    function
-}
data InternalError = InternalError deriving (Typeable)


instance Show InternalError where
    show InternalError = unlines
        [ _ERROR <> ": Compiler bug                                                        "
        , "                                                                                "
        , "Explanation: This error message means that there is a bug in the Dhall compiler."
        , "You didn't do anything wrong, but if you would like to see this problem fixed   "
        , "then you should report the bug at:                                              "
        , "                                                                                "
        , "https://github.com/dhall-lang/dhall-haskell/issues                              "
        , "                                                                                "
        , "Please include the following text in your bug report:                           "
        , "                                                                                "
        , "```                                                                             "
        , "Header extraction failed even though the header type-checked                    "
        , "```                                                                             "
        ]
      where
        _ERROR :: String
        _ERROR = "\ESC[1;31mError\ESC[0m"

instance Exception InternalError

-- | Wrapper around `HttpException`s with a prettier `Show` instance.
--
-- In order to keep the library API constant even when the @with-http@ Cabal
-- flag is disabled the pretty error message is pre-rendered and the real
-- 'HttpExcepion' is stored in a 'Dynamic'
data PrettyHttpException = PrettyHttpException String Dynamic
    deriving (Typeable)

instance Exception PrettyHttpException

instance Show PrettyHttpException where
  show (PrettyHttpException msg _) = msg
