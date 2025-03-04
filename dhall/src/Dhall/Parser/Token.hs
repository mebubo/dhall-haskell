{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Parse Dhall tokens. Even though we don't have a tokenizer per-se this
---  module is useful for keeping some small parsing utilities.
module Dhall.Parser.Token (
    validCodepoint,
    whitespace,
    nonemptyWhitespace,
    bashEnvironmentVariable,
    posixEnvironmentVariable,
    ComponentType(..),
    file_,
    labelOnly,
    label,
    anyLabel,
    labels,
    httpRaw,
    hexdig,
    identifier,
    hexNumber,
    doubleLiteral,
    doubleInfinity,
    naturalLiteral,
    integerLiteral,
    _Optional,
    _if,
    _then,
    _else,
    _letOnly,
    _let,
    _in,
    _as,
    _using,
    _merge,
    _toMap,
    _assert,
    _Some,
    _None,
    _NaturalFold,
    _NaturalBuild,
    _NaturalIsZero,
    _NaturalEven,
    _NaturalOdd,
    _NaturalToInteger,
    _NaturalShow,
    _NaturalSubtract,
    _IntegerShow,
    _IntegerToDouble,
    _DoubleShow,
    _ListBuild,
    _ListFold,
    _ListLength,
    _ListHead,
    _ListLast,
    _ListIndexed,
    _ListReverse,
    _OptionalFold,
    _OptionalBuild,
    _Bool,
    _Natural,
    _Integer,
    _Double,
    _Text,
    _TextShow,
    _List,
    _True,
    _False,
    _NaN,
    _Type,
    _Kind,
    _Sort,
    _Location,
    _equalOnly,
    _equal,
    _or,
    _plus,
    _textAppend,
    _listAppend,
    _and,
    _times,
    _doubleEqual,
    _notEqual,
    _dot,
    _openBrace,
    _closeBrace,
    _openBracket,
    _closeBracket,
    _openAngle,
    _closeAngle,
    _bar,
    _comma,
    _openParens,
    _closeParens,
    _colonOnly,
    _colon,
    _at,
    _equivalent,
    _missing,
    _importAlt,
    _combine,
    _combineTypes,
    _prefer,
    _lambda,
    _forall,
    _arrow,
    _doubleColon,
    ) where

import           Dhall.Parser.Combinators

import Control.Applicative (Alternative(..), optional)
import Data.Functor (void)
import Data.Semigroup (Semigroup(..))
import Data.Text (Text)
import Dhall.Core
import Dhall.Set (Set)
import Prelude hiding (const, pi)
import Text.Parser.Combinators (choice, try, (<?>))

import qualified Control.Monad
import qualified Data.Char                  as Char
import qualified Data.HashSet
import qualified Data.List.NonEmpty
import qualified Data.Text
import qualified Dhall.Set
import qualified Network.URI.Encode         as URI.Encode
import qualified Text.Megaparsec
import qualified Text.Megaparsec.Char.Lexer
import qualified Text.Parser.Char
import qualified Text.Parser.Combinators

import Numeric.Natural (Natural)
import Prelude hiding (const, pi)

import qualified Text.Parser.Token

-- | Returns `True` if the given `Char` is a valid Unicode codepoint
validCodepoint :: Char -> Bool
validCodepoint c =
    not (category == Char.Surrogate || category == Char.NotAssigned)
  where
    category = Char.generalCategory c

{-| Parse 0 or more whitespace characters (including comments)

    This corresponds to the @whsp@ rule in the official grammar
-}
whitespace :: Parser ()
whitespace = Text.Parser.Combinators.skipMany whitespaceChunk

{-| Parse 1 or more whitespace characters (including comments)

    This corresponds to the @whsp1@ rule in the official grammar
-}
nonemptyWhitespace :: Parser ()
nonemptyWhitespace = Text.Parser.Combinators.skipSome whitespaceChunk

alpha :: Char -> Bool
alpha c = ('\x41' <= c && c <= '\x5A') || ('\x61' <= c && c <= '\x7A')

digit :: Char -> Bool
digit c = '\x30' <= c && c <= '\x39'

alphaNum :: Char -> Bool
alphaNum c = alpha c || digit c

{-| Parse a hex digit (uppercase or lowercase)

    This corresponds to the @HEXDIG@ rule in the official grammar
-}
hexdig :: Char -> Bool
hexdig c =
        ('0' <= c && c <= '9')
    ||  ('A' <= c && c <= 'F')
    ||  ('a' <= c && c <= 'f')

signPrefix :: Num a => Parser (a -> a)
signPrefix = (do
    let positive = fmap (\_ -> id    ) (Text.Parser.Char.char '+')
    let negative = fmap (\_ -> negate) (Text.Parser.Char.char '-')
    positive <|> negative ) <?> "sign"

{-| Parse a `Double` literal

    This corresponds to the @double-literal@ rule from the official grammar
-}
doubleLiteral :: Parser Double
doubleLiteral = (do
    sign <- signPrefix <|> pure id
    a <- Text.Parser.Token.double
    return (sign a) ) <?> "double literal"

{-| Parse a signed @Infinity@

    This corresponds to the @minus-infinity-literal@ and @plus-infinity-literal@
    rules from the official grammar
-}
doubleInfinity :: Parser Double
doubleInfinity = (do
    let negative = fmap (\_ -> negate) (Text.Parser.Char.char '-')
    sign <- negative <|> pure id
    a <- Text.Parser.Char.text "Infinity" >> whitespace >> return (1.0/0.0)
    return (sign a) ) <?> "double infinity"

{-| Parse an `Integer` literal

    This corresponds to the @integer-literal@ rule from the official grammar
-}
integerLiteral :: Parser Integer
integerLiteral = (do
    sign <- signPrefix
    a <- Text.Megaparsec.Char.Lexer.decimal
    whitespace
    return (sign a) ) <?> "integer literal"

{-| Parse a `Natural` literal 

    This corresponds to the @natural-literal@ rule from the official grammar
-}
naturalLiteral :: Parser Natural
naturalLiteral = (do
    a <- Text.Megaparsec.Char.Lexer.decimal
    whitespace
    return a ) <?> "natural literal"

{-| Parse an identifier (i.e. a variable or built-in)

    Variables can have an optional index to disambiguate shadowed variables

    This corresponds to the @identifier@ rule from the official grammar
-}
identifier :: Parser Var
identifier = do
    x <- label

    let indexed = do
            _ <- Text.Parser.Char.char '@'
            n <- Text.Megaparsec.Char.Lexer.decimal
            whitespace
            return n

    n <- indexed <|> pure 0
    return (V x n)

whitespaceChunk :: Parser ()
whitespaceChunk =
    choice
        [ void (Dhall.Parser.Combinators.takeWhile1 predicate)
        , void (Text.Parser.Char.text "\r\n")
        , lineComment
        , blockComment
        ] <?> "whitespace"
  where
    predicate c = c == ' ' || c == '\t' || c == '\n'

-- | Parse a hexademical number and convert to the corresponding `Int`
hexNumber :: Parser Int
hexNumber = choice [ hexDigit, hexUpper, hexLower ]
  where
    hexDigit = do
        c <- Text.Parser.Char.satisfy predicate
        return (Char.ord c - Char.ord '0')
      where
        predicate c = '0' <= c && c <= '9'

    hexUpper = do
        c <- Text.Parser.Char.satisfy predicate
        return (10 + Char.ord c - Char.ord 'A')
      where
        predicate c = 'A' <= c && c <= 'F'

    hexLower = do
        c <- Text.Parser.Char.satisfy predicate
        return (10 + Char.ord c - Char.ord 'a')
      where
        predicate c = 'a' <= c && c <= 'f'

lineComment :: Parser ()
lineComment = do
    _ <- Text.Parser.Char.text "--"

    let predicate c = ('\x20' <= c && c <= '\x10FFFF') || c == '\t'

    _ <- Dhall.Parser.Combinators.takeWhile predicate

    endOfLine

    return ()
  where
    endOfLine =
            void (Text.Parser.Char.char '\n'  )
        <|> void (Text.Parser.Char.text "\r\n")

blockComment :: Parser ()
blockComment = do
    _ <- Text.Parser.Char.text "{-"
    blockCommentContinue

blockCommentChunk :: Parser ()
blockCommentChunk =
    choice
        [ blockComment  -- Nested block comment
        , characters
        , character
        , endOfLine
        ]
  where
    characters = void (Dhall.Parser.Combinators.takeWhile1 predicate)
      where
        predicate c =
                '\x20' <= c && c <= '\x10FFFF' && c /= '-' && c /= '{'
            ||  c == '\n'
            ||  c == '\t'

    character = void (Text.Parser.Char.satisfy predicate)
      where
        predicate c = '\x20' <= c && c <= '\x10FFFF' || c == '\n' || c == '\t'

    endOfLine = void (Text.Parser.Char.text "\r\n")

blockCommentContinue :: Parser ()
blockCommentContinue = endOfComment <|> continue
  where
    endOfComment = void (Text.Parser.Char.text "-}")

    continue = do
        blockCommentChunk
        blockCommentContinue

simpleLabel :: Bool -> Parser Text
simpleLabel allowReserved = try (do
    c    <- Text.Parser.Char.satisfy headCharacter
    rest <- Dhall.Parser.Combinators.takeWhile tailCharacter
    let text = Data.Text.cons c rest
    Control.Monad.guard (allowReserved || not (Data.HashSet.member text reservedIdentifiers))
    return text )
  where
    headCharacter c = alpha c || c == '_'

    tailCharacter c = alphaNum c || c == '_' || c == '-' || c == '/'

backtickLabel :: Parser Text
backtickLabel = do
    _ <- Text.Parser.Char.char '`'
    t <- takeWhile1 predicate
    _ <- Text.Parser.Char.char '`'
    return t
  where
    predicate c =
            '\x20' <= c && c <= '\x5F'
        ||  '\x61' <= c && c <= '\x7E'

{-| Parse a braced sequence of comma-separated labels

    For example, this is used to parse the record projection syntax

    This corresponds to the @labels@ rule in the official grammar
-}
labels :: Parser (Set Text)
labels = do
    _openBrace
    xs <- nonEmptyLabels <|> emptyLabels
    _closeBrace
    return xs
  where
    emptyLabels = pure Dhall.Set.empty

    nonEmptyLabels = do
        x  <- anyLabel
        xs <- many (do _ <- _comma; anyLabel)
        noDuplicates (x : xs)

-- | Parse a label without parsing trailing whitespace
labelOnly :: Parser Text
labelOnly = backtickLabel <|> simpleLabel False <?> "label"

{-| Parse a label (e.g. a variable\/field\/alternative name)

    Rejects labels that match built-in names (e.g. @Natural/even@)

    This corresponds to the @nonreserved-label@ rule in the official grammar
-}
label :: Parser Text
label = (do
    t <- backtickLabel <|> simpleLabel False
    whitespace
    return t ) <?> "label"

{-| Same as `label` except that built-in names are allowed

    This corresponds to the @any-label@ rule in the official grammar
-}
anyLabel :: Parser Text
anyLabel = (do
    t <- backtickLabel <|> simpleLabel True
    whitespace
    return t ) <?> "any label"

{-| Parse a valid Bash environment variable name

    This corresponds to the @bash-environment-variable@ rule in the official
    grammar
-}
bashEnvironmentVariable :: Parser Text
bashEnvironmentVariable = satisfy predicate0 <> star (satisfy predicate1)
  where
    predicate0 c = alpha c || c == '_'

    predicate1 c = alphaNum c || c == '_'

{-| Parse a valid POSIX environment variable name, which permits a wider range
    of characters than a Bash environment variable name

    This corresponds to the @posix-environment-variable@ rule in the official
    grammar
-}
posixEnvironmentVariable :: Parser Text
posixEnvironmentVariable = plus posixEnvironmentVariableCharacter

posixEnvironmentVariableCharacter :: Parser Text
posixEnvironmentVariableCharacter =
    escapeCharacter <|> satisfy predicate1
  where
    escapeCharacter = do
        _ <- Text.Parser.Char.char '\\'

        c <- Text.Parser.Char.satisfy (`elem` ("\"\\abfnrtv" :: String))

        case c of
            '"'  -> return "\""
            '\\' -> return "\\"
            'a'  -> return "\a"
            'b'  -> return "\b"
            'f'  -> return "\f"
            'n'  -> return "\n"
            'r'  -> return "\r"
            't'  -> return "\t"
            'v'  -> return "\v"
            _    -> empty

    predicate1 c =
            ('\x20' <= c && c <= '\x21')
        ||  ('\x23' <= c && c <= '\x3C')
        ||  ('\x3E' <= c && c <= '\x5B')
        ||  ('\x5D' <= c && c <= '\x7E')

quotedPathCharacter :: Char -> Bool
quotedPathCharacter c =
        ('\x20' <= c && c <= '\x21')
    ||  ('\x23' <= c && c <= '\x2E')
    ||  ('\x30' <= c && c <= '\x10FFFF')

{-| The `pathComponent` function uses this type to distinguish whether to parse
    a URL path component or a file path component
-}
data ComponentType = URLComponent | FileComponent

-- | Parse a path component
pathComponent :: ComponentType -> Parser Text
pathComponent componentType = do
    _ <- "/" :: Parser Text

    let pathData =
            case componentType of
                FileComponent -> do
                    Text.Megaparsec.takeWhile1P Nothing Dhall.Core.pathCharacter
                URLComponent -> do
                    star pchar

    let quotedPathData = do
            _    <- Text.Parser.Char.char '"'
            text <- Text.Megaparsec.takeWhile1P Nothing quotedPathCharacter
            _    <- Text.Parser.Char.char '"'

            case componentType of
              FileComponent -> do
                return text
              URLComponent -> do
                return (URI.Encode.encodeText text)

    quotedPathData <|> pathData

-- | Parse a `File`
file_ :: ComponentType -> Parser File
file_ componentType = do
    let emptyPath =
            case componentType of
                URLComponent  -> pure (pure "")
                FileComponent -> empty

    path <- Data.List.NonEmpty.some1 (pathComponent componentType) <|> emptyPath

    let directory = Directory (reverse (Data.List.NonEmpty.init path))
    let file      = Data.List.NonEmpty.last path

    return (File {..})

scheme_ :: Parser Scheme
scheme_ =
        ("http" :: Parser Text)
    *>  ((("s" :: Parser Text) *> pure HTTPS) <|> pure HTTP)
    <*  ("://" :: Parser Text)

{-| Parse an HTTP(S) URL without trailing whitespace

    This corresponds to the @http-raw@ rule in the official grammar
-}
httpRaw :: Parser URL
httpRaw = do
    scheme    <- scheme_
    authority <- authority_
    path      <- file_ URLComponent
    query     <- optional (("?" :: Parser Text) *> query_)

    let headers = Nothing

    return (URL {..})

authority_ :: Parser Text
authority_ = option (try (userinfo <> "@")) <> host <> option (":" <> port)

userinfo :: Parser Text
userinfo = star (satisfy predicate <|> pctEncoded)
  where
    predicate c = unreserved c || subDelims c || c == ':'

host :: Parser Text
host = choice [ ipLiteral, try ipV4Address, domain ]

port :: Parser Text
port = star (satisfy digit)

ipLiteral :: Parser Text
ipLiteral = "[" <> (ipV6Address <|> ipVFuture) <> "]"

ipVFuture :: Parser Text
ipVFuture = "v" <> plus (satisfy hexdig) <> "." <> plus (satisfy predicate)
  where
    predicate c = unreserved c || subDelims c || c == ':'

ipV6Address :: Parser Text
ipV6Address =
    choice
        [ try alternative0
        , try alternative1
        , try alternative2
        , try alternative3
        , try alternative4
        , try alternative5
        , try alternative6
        , try alternative7
        ,     alternative8
        ]
  where
    alternative0 = count 6 (h16 <> ":") <> ls32

    alternative1 = "::" <> count 5 (h16 <> ":") <> ls32

    alternative2 = option h16 <> "::" <> count 4 (h16 <> ":") <> ls32

    alternative3 =
            option (h16 <> range 0 1 (try (":" <> h16)))
        <>  "::"
        <>  count 3 (h16 <> ":")
        <>  ls32

    alternative4 =
            option (h16 <> range 0 2 (try (":" <> h16)))
        <>  "::"
        <>  count 2 (h16 <> ":")
        <>  ls32

    alternative5 =
            option (h16 <> range 0 3 (try (":" <> h16)))
        <>  "::"
        <>  h16
        <>  ":"
        <>  ls32

    alternative6 =
        option (h16 <> range 0 4 (try (":" <> h16))) <> "::" <> ls32

    alternative7 =
        option (h16 <> range 0 5 (try (":" <> h16))) <> "::" <> h16

    alternative8 =
        option (h16 <> range 0 6 (try (":" <> h16))) <> "::"

h16 :: Parser Text
h16 = range 1 3 (satisfy hexdig)

ls32 :: Parser Text
ls32 = try (h16 <> ":" <> h16) <|> ipV4Address

ipV4Address :: Parser Text
ipV4Address = decOctet <> "." <> decOctet <> "." <> decOctet <> "." <> decOctet

decOctet :: Parser Text
decOctet =
    choice
        [ try alternative4
        , try alternative3
        , try alternative2
        , try alternative1
        ,     alternative0
        ]
  where
    alternative0 = satisfy digit

    alternative1 = satisfy predicate <> satisfy digit
      where
        predicate c = '\x31' <= c && c <= '\x39'

    alternative2 = "1" <> count 2 (satisfy digit)

    alternative3 = "2" <> satisfy predicate <> satisfy digit
      where
        predicate c = '\x30' <= c && c <= '\x34'

    alternative4 = "25" <> satisfy predicate
      where
        predicate c = '\x30' <= c && c <= '\x35'

domain :: Parser Text
domain = domainLabel <> star ("." <> domainLabel ) <> option "."

domainLabel :: Parser Text
domainLabel = plus alphaNum_ <> star (plus "-" <> plus alphaNum_)
  where
    alphaNum_ = satisfy alphaNum

pchar :: Parser Text
pchar = satisfy predicate <|> pctEncoded
  where
    predicate c = unreserved c || subDelims c || c == ':' || c == '@'

query_ :: Parser Text
query_ = star (pchar <|> satisfy predicate)
  where
    predicate c = c == '/' || c == '?'

pctEncoded :: Parser Text
pctEncoded = "%" <> count 2 (satisfy hexdig)

subDelims :: Char -> Bool
subDelims c = c `elem` ("!$&'()*+,;=" :: String)

unreserved :: Char -> Bool
unreserved c =
    alphaNum c || c == '-' || c == '.' || c == '_' || c == '~'

reserved :: Data.Text.Text -> Parser ()
reserved x = do _ <- Text.Parser.Char.text x; whitespace

reservedCharOnly :: Char -> Parser ()
reservedCharOnly c = do _ <- Text.Parser.Char.char c; return ()

reservedChar :: Char -> Parser ()
reservedChar c = do _ <- Text.Parser.Char.char c; whitespace

keywordOnly :: Data.Text.Text -> Parser ()
keywordOnly x = try (do _ <- Text.Parser.Char.text x; return ())

keyword :: Data.Text.Text -> Parser ()
keyword x = try (do _ <- Text.Parser.Char.text x; nonemptyWhitespace)

{-| Parse the @if@ keyword

    This corresponds to the @if@ rule from the official grammar
-}
_if :: Parser ()
_if = keyword "if"

{-| Parse the @then@ keyword

    This corresponds to the @then@ rule from the official grammar
-}
_then :: Parser ()
_then = keyword "then"

{-| Parse the @else@ keyword

    This corresponds to the @else@ rule from the official grammar
-}
_else :: Parser ()
_else = keyword "else"

-- | Parse the @let@ keyword without trailing whitespace
_letOnly :: Parser ()
_letOnly = keywordOnly "let"

{-| Parse the @let@ keyword

    This corresponds to the @let@ rule from the official grammar
-}
_let :: Parser ()
_let = keyword "let"

{-| Parse the @in@ keyword

    This corresponds to the @in@ rule from the official grammar
-}
_in :: Parser ()
_in = keyword "in"

{-| Parse the @as@ keyword

    This corresponds to the @as@ rule from the official grammar
-}
_as :: Parser ()
_as = keyword "as"

{-| Parse the @using@ keyword

    This corresponds to the @using@ rule from the official grammar
-}
_using :: Parser ()
_using = keyword "using"

{-| Parse the @merge@ keyword

    This corresponds to the @merge@ rule from the official grammar
-}
_merge :: Parser ()
_merge = keyword "merge"

{-| Parse the @toMap@ keyword

    This corresponds to the @toMap@ rule from the official grammar
-}
_toMap :: Parser ()
_toMap = keyword "toMap"

{-| Parse the @assert@ keyword

    This corresponds to the @assert@ rule from the official grammar
-}
_assert :: Parser ()
_assert = keyword "assert"

{-| Parse the @Some@ built-in

    This corresponds to the @Some@ rule from the official grammar
-}
_Some :: Parser ()
_Some = keyword "Some"

{-| Parse the @None@ built-in

    This corresponds to the @None@ rule from the official grammar
-}
_None :: Parser ()
_None = reserved "None"

{-| Parse the @Natural/fold@ built-in

    This corresponds to the @Natural-fold@ rule from the official grammar
-}
_NaturalFold :: Parser ()
_NaturalFold = reserved "Natural/fold"

{-| Parse the @Natural/build@ built-in

    This corresponds to the @Natural-build@ rule from the official grammar
-}
_NaturalBuild :: Parser ()
_NaturalBuild = reserved "Natural/build"

{-| Parse the @Natural/isZero@ built-in

    This corresponds to the @Natural-isZero@ rule from the official grammar
-}
_NaturalIsZero :: Parser ()
_NaturalIsZero = reserved "Natural/isZero"

{-| Parse the @Natural/even@ built-in

    This corresponds to the @Natural-even@ rule from the official grammar
-}
_NaturalEven :: Parser ()
_NaturalEven = reserved "Natural/even"

{-| Parse the @Natural/odd@ built-in

    This corresponds to the @Natural-odd@ rule from the official grammar
-}
_NaturalOdd :: Parser ()
_NaturalOdd = reserved "Natural/odd"

{-| Parse the @Natural/toInteger@ built-in

    This corresponds to the @Natural-toInteger@ rule from the official grammar
-}
_NaturalToInteger :: Parser ()
_NaturalToInteger = reserved "Natural/toInteger"

{-| Parse the @Natural/show@ built-in

    This corresponds to the @Natural-show@ rule from the official grammar
-}
_NaturalShow :: Parser ()
_NaturalShow = reserved "Natural/show"

{-| Parse the @Natural/subtract@ built-in

    This corresponds to the @Natural-subtract@ rule from the official grammar
-}
_NaturalSubtract :: Parser ()
_NaturalSubtract = reserved "Natural/subtract"

{-| Parse the @Integer/show@ built-in

    This corresponds to the @Integer-show@ rule from the official grammar
-}
_IntegerShow :: Parser ()
_IntegerShow = reserved "Integer/show"

{-| Parse the @Integer/toDouble@ built-in

    This corresponds to the @Integer-toDouble@ rule from the official grammar
-}
_IntegerToDouble :: Parser ()
_IntegerToDouble = reserved "Integer/toDouble"

{-| Parse the @Double/show@ built-in

    This corresponds to the @Double-show@ rule from the official grammar
-}
_DoubleShow :: Parser ()
_DoubleShow = reserved "Double/show"

{-| Parse the @List/build@ built-in

    This corresponds to the @List-build@ rule from the official grammar
-}
_ListBuild :: Parser ()
_ListBuild = reserved "List/build"

{-| Parse the @List/fold@ built-in

    This corresponds to the @List-fold@ rule from the official grammar
-}
_ListFold :: Parser ()
_ListFold = reserved "List/fold"

{-| Parse the @List/length@ built-in

    This corresponds to the @List-length@ rule from the official grammar
-}
_ListLength :: Parser ()
_ListLength = reserved "List/length"

{-| Parse the @List/head@ built-in

    This corresponds to the @List-head@ rule from the official grammar
-}
_ListHead :: Parser ()
_ListHead = reserved "List/head"

{-| Parse the @List/last@ built-in

    This corresponds to the @List-last@ rule from the official grammar
-}
_ListLast :: Parser ()
_ListLast = reserved "List/last"

{-| Parse the @List/indexed@ built-in

    This corresponds to the @List-indexed@ rule from the official grammar
-}
_ListIndexed :: Parser ()
_ListIndexed = reserved "List/indexed"

{-| Parse the @List/reverse@ built-in

    This corresponds to the @List-reverse@ rule from the official grammar
-}
_ListReverse :: Parser ()
_ListReverse = reserved "List/reverse"

{-| Parse the @Optional/fold@ built-in

    This corresponds to the @Optional-fold@ rule from the official grammar
-}
_OptionalFold :: Parser ()
_OptionalFold = reserved "Optional/fold"

{-| Parse the @Optional/build@ built-in

    This corresponds to the @Optional-build@ rule from the official grammar
-}
_OptionalBuild :: Parser ()
_OptionalBuild = reserved "Optional/build"

{-| Parse the @Bool@ built-in

    This corresponds to the @Bool@ rule from the official grammar
-}
_Bool :: Parser ()
_Bool = reserved "Bool"

{-| Parse the @Optional@ built-in

    This corresponds to the @Optional@ rule from the official grammar
-}
_Optional :: Parser ()
_Optional = reserved "Optional"

{-| Parse the @Natural@ built-in

    This corresponds to the @Natural@ rule from the official grammar
-}
_Natural :: Parser ()
_Natural = reserved "Natural"

{-| Parse the @Integer@ built-in

    This corresponds to the @Integer@ rule from the official grammar
-}
_Integer :: Parser ()
_Integer = reserved "Integer"

{-| Parse the @Double@ built-in

    This corresponds to the @Double@ rule from the official grammar
-}
_Double :: Parser ()
_Double = reserved "Double"

{-| Parse the @Text@ built-in

    This corresponds to the @Text@ rule from the official grammar
-}
_Text :: Parser ()
_Text = reserved "Text"

{-| Parse the @Text/show@ built-in

    This corresponds to the @Text-show@ rule from the official grammar
-}
_TextShow :: Parser ()
_TextShow = reserved "Text/show"

{-| Parse the @List@ built-in

    This corresponds to the @List@ rule from the official grammar
-}
_List :: Parser ()
_List = reserved "List"

{-| Parse the @True@ built-in

    This corresponds to the @True@ rule from the official grammar
-}
_True :: Parser ()
_True = reserved "True"

{-| Parse the @False@ built-in

    This corresponds to the @False@ rule from the official grammar
-}
_False :: Parser ()
_False = reserved "False"

{-| Parse a @NaN@ literal

    This corresponds to the @NaN@ rule from the official grammar
-}
_NaN :: Parser ()
_NaN = reserved "NaN"

{-| Parse the @Type@ built-in

    This corresponds to the @Type@ rule from the official grammar
-}
_Type :: Parser ()
_Type = reserved "Type"

{-| Parse the @Kind@ built-in

    This corresponds to the @Kind@ rule from the official grammar
-}
_Kind :: Parser ()
_Kind = reserved "Kind"

{-| Parse the @Sort@ built-in

    This corresponds to the @Sort@ rule from the official grammar
-}
_Sort :: Parser ()
_Sort = reserved "Sort"

{-| Parse the @Location@ keyword

    This corresponds to the @Location@ rule from the official grammar
-}
_Location :: Parser ()
_Location = reserved "Location"

-- | Parse the @=@ symbol without trailing whitespace
_equalOnly :: Parser ()
_equalOnly = reservedCharOnly '='

-- | Parse the @=@ symbol
_equal :: Parser ()
_equal = reservedChar '='

-- | Parse the @||@ symbol
_or :: Parser ()
_or = reserved "||"

-- | Parse the @+@ symbol
_plus :: Parser ()
_plus = reservedChar '+'

-- | Parse the @++@ symbol
_textAppend :: Parser ()
_textAppend = reserved "++"

-- | Parse the @#@ symbol
_listAppend :: Parser ()
_listAppend = reservedChar '#'

-- | Parse the @&&@ symbol
_and :: Parser ()
_and = reserved "&&"

-- | Parse the @*@ symbol
_times :: Parser ()
_times = reservedChar '*'

-- | Parse the @==@ symbol
_doubleEqual :: Parser ()
_doubleEqual = reserved "=="

-- | Parse the @!=@ symbol
_notEqual :: Parser ()
_notEqual = reserved "!="

-- | Parse the @.@ symbol
_dot :: Parser ()
_dot = reservedChar '.'

-- | Parse the @{@ symbol
_openBrace :: Parser ()
_openBrace = reservedChar '{'

-- | Parse the @}@ symbol
_closeBrace :: Parser ()
_closeBrace = reservedChar '}'

-- | Parse the @[@] symbol
_openBracket :: Parser ()
_openBracket = reservedChar '['

-- | Parse the @]@ symbol
_closeBracket :: Parser ()
_closeBracket = reservedChar ']'

-- | Parse the @<@ symbol
_openAngle :: Parser ()
_openAngle = reservedChar '<'

-- | Parse the @>@ symbol
_closeAngle :: Parser ()
_closeAngle = reservedChar '>'

-- | Parse the @|@ symbol
_bar :: Parser ()
_bar = reservedChar '|'

-- | Parse the @,@ symbol
_comma :: Parser ()
_comma = reservedChar ','

-- | Parse the @(@ symbol
_openParens :: Parser ()
_openParens = reservedChar '('

-- | Parse the @)@ symbol
_closeParens :: Parser ()
_closeParens = reservedChar ')'

-- | Parse the @:@ symbol without trailing whitespace
_colonOnly :: Parser ()
_colonOnly = reservedCharOnly ':'

-- | Parse the @:@ symbol
_colon :: Parser ()
_colon = reservedChar ':'

-- | Parse the @\@@ symbol
_at :: Parser ()
_at = reservedChar '@'

-- | Parse the equivalence symbol (@===@ or @≡@)
_equivalent :: Parser ()
_equivalent = do
    void (Text.Parser.Char.char '≡' <?> "\"≡\"") <|> void (Text.Parser.Char.text "===")
    whitespace

-- | Parse the @missing@ keyword
_missing :: Parser ()
_missing = keyword "missing"

-- | Parse the @?@ symbol
_importAlt :: Parser ()
_importAlt = reservedChar '?'

-- | Parse the record combine operator (@/\\@ or @∧@)
_combine :: Parser ()
_combine = do
    void (Text.Parser.Char.char '∧' <?> "\"∧\"") <|> void (Text.Parser.Char.text "/\\")
    whitespace

-- | Parse the record type combine operator (@//\\\\@ or @⩓@)
_combineTypes :: Parser ()
_combineTypes = do
    void (Text.Parser.Char.char '⩓' <?> "\"⩓\"") <|> void (Text.Parser.Char.text "//\\\\")
    whitespace

-- | Parse the record \"prefer\" operator (@//@ or @⫽@)
_prefer :: Parser ()
_prefer = do
    void (Text.Parser.Char.char '⫽' <?> "\"⫽\"") <|> void (Text.Parser.Char.text "//")
    whitespace

-- | Parse a lambda (@\\@ or @λ@)
_lambda :: Parser ()
_lambda = do
    _ <- Text.Parser.Char.satisfy predicate
    whitespace
  where
    predicate 'λ'  = True
    predicate '\\' = True
    predicate _    = False

-- | Parse a forall (@forall@ or @∀@)
_forall :: Parser ()
_forall = do
    void (Text.Parser.Char.char '∀' <?> "\"∀\"") <|> void (Text.Parser.Char.text "forall")
    whitespace

-- | Parse a right arrow (@->@ or @→@)
_arrow :: Parser ()
_arrow = do
    void (Text.Parser.Char.char '→' <?> "\"→\"") <|> void (Text.Parser.Char.text "->")
    whitespace

-- | Parse a double colon (@::@)
_doubleColon :: Parser ()
_doubleColon = reserved "::"
