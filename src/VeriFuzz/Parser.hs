{-|
Module      : VeriFuzz.Parser
Description : Minimal Verilog parser to reconstruct the AST.
Copyright   : (c) 2019, Yann Herklotz Grave
License     : GPL-3
Maintainer  : ymherklotz [at] gmail [dot] com
Stability   : experimental
Portability : POSIX

Minimal Verilog parser to reconstruct the AST. This parser does not support the
whole Verilog syntax, as the AST does not support it either.
-}

module VeriFuzz.Parser
  ( -- * Parsers
    parseVerilogSrc
  , parseDescription
  , parseModDecl
  , parseContAssign
  , parseExpr
  ) where

import           Data.Functor          (($>))
import           Data.Functor.Identity (Identity)
import qualified Data.Text             as T
import           Text.Parsec
import           Text.Parsec.Expr
import           VeriFuzz.AST
import           VeriFuzz.Internal
import           VeriFuzz.Lexer

type Parser = Parsec String ()

type ParseOperator = Operator String () Identity

sBinOp :: BinaryOperator -> Expr -> Expr -> Expr
sBinOp = sOp BinOp
  where
    sOp f b a = f a b

parseExpr' :: Parser Expr
parseExpr' = buildExpressionParser parseTable parseTerm
            <?> "expr"

parseParens :: Parser a -> Parser a
parseParens a = do
  val <- string "(" *> spaces *> a
  _ <- spaces *> string ")"
  return val

ignoreWS :: Parser a -> Parser a
ignoreWS a = do
  spaces
  t <- a
  spaces
  return t

matchHex :: Char -> Bool
matchHex c = c == 'h' || c == 'H'

--matchBin :: Char -> Bool
--matchBin c = c == 'b' || c == 'B'

matchDec :: Char -> Bool
matchDec c = c == 'd' || c == 'D'

matchOct :: Char -> Bool
matchOct c = c == 'o' || c == 'O'

-- | Parse a Number depending on if it is in a hex or decimal form. Octal and
-- binary are not supported yet.
parseNum :: Parser Expr
parseNum = ignoreWS $ do
  size <- fromIntegral <$> decimal
  _ <- string "'"
  matchNum size
  where
    matchNum size = (satisfy matchHex >> Number size <$> hexadecimal)
                    <|> (satisfy matchDec >> Number size <$> decimal)
                    <|> (satisfy matchOct >> Number size <$> octal)

parseVar :: Parser Expr
parseVar = Id <$> ident

parseFunction :: Parser Function
parseFunction = string "unsigned" $> UnSignedFunc
                <|> string "signed" $> SignedFunc

parseFun :: Parser Expr
parseFun = do
  f <- spaces *> reservedOp "$" *> parseFunction
  expr <- string "(" *> spaces *> parseExpr
  _ <- spaces *> string ")" *> spaces
  return $ Func f expr

parseTerm :: Parser Expr
parseTerm = parseParens parseExpr
            <|> (Concat <$> aroundList (string "{") (string "}") parseExpr)
            <|> parseFun
            <|> parseNum
            <|> parseVar
            <?> "simple expr"

-- | Parses the ternary conditional operator. It will behave in a right
-- associative way.
parseCond :: Expr -> Parser Expr
parseCond e = do
  _ <- reservedOp "?"
  expr <- parseExpr
  _ <- reservedOp ":"
  Cond e expr <$> parseExpr

parseExpr :: Parser Expr
parseExpr = do
  e <- parseExpr'
  y <- option e $ parseCond e
  return y

-- | Table of binary and unary operators that encode the right precedence for
-- each.
parseTable :: [[ParseOperator Expr]]
parseTable =
  [ [ prefix "!" (UnOp UnLNot), prefix "~" (UnOp UnNot) ]
  , [ prefix "&" (UnOp UnAnd), prefix "|" (UnOp UnOr), prefix "~&" (UnOp UnNand)
    , prefix "~|" (UnOp UnNor), prefix "^" (UnOp UnXor), prefix "~^" (UnOp UnNxor)
    , prefix "^~" (UnOp UnNxorInv)
    ]
  , [ prefix "+" (UnOp UnPlus), prefix "-" (UnOp UnMinus) ]
  , [ binary "**" (sBinOp BinPower) AssocRight ]
  , [ binary "*" (sBinOp BinTimes) AssocLeft, binary "/" (sBinOp BinDiv) AssocLeft
    , binary "%" (sBinOp BinMod) AssocLeft
    ]
  , [ binary "+" (sBinOp BinPlus) AssocLeft, binary "-" (sBinOp BinPlus) AssocLeft ]
  , [ binary "<<" (sBinOp BinLSL) AssocLeft, binary ">>" (sBinOp BinLSR) AssocLeft ]
  , [ binary "<<<" (sBinOp BinASL) AssocLeft, binary ">>>" (sBinOp BinASR) AssocLeft ]
  , [ binary "<" (sBinOp BinLT) AssocNone, binary ">" (sBinOp BinGT) AssocNone
    , binary "<=" (sBinOp BinLEq) AssocNone, binary ">=" (sBinOp BinLEq) AssocNone
    ]
  , [ binary "==" (sBinOp BinEq) AssocNone, binary "!=" (sBinOp BinNEq) AssocNone ]
  , [ binary "===" (sBinOp BinEq) AssocNone, binary "!==" (sBinOp BinNEq) AssocNone ]
  , [ binary "&" (sBinOp BinAnd) AssocLeft ]
  , [ binary "^" (sBinOp BinXor) AssocLeft, binary "^~" (sBinOp BinXNor) AssocLeft
    , binary "~^" (sBinOp BinXNorInv) AssocLeft
    ]
  , [ binary "|" (sBinOp BinOr) AssocLeft ]
  , [ binary "&&" (sBinOp BinLAnd) AssocLeft ]
  , [ binary "|" (sBinOp BinLOr) AssocLeft ]
  ]

binary :: String -> (a -> a -> a) -> Assoc -> ParseOperator a
binary name fun = Infix ((reservedOp name <?> "binary") >> return fun)

prefix :: String -> (a -> a) -> ParseOperator a
prefix name fun = Prefix ((reservedOp name <?> "prefix") >> return fun)

aroundList :: Parser a -> Parser b -> Parser c -> Parser [c]
aroundList a b c = do
  l <- a *> spaces *> commaSep c
  _ <- b
  return l

parseContAssign :: Parser ContAssign
parseContAssign = do
  var <- (spaces *> reserved "assign" *> spaces *> ident)
  expr <- spaces *> reservedOp "=" *> spaces *> parseExpr
  _ <- spaces *> string ";"
  return $ ContAssign var expr

-- | Parse a range and return the total size. As it is inclusive, 1 has to be
-- added to the difference.
parseRange :: Parser Int
parseRange = do
  rangeH <- string "[" *> spaces *> decimal
  rangeL <- spaces *> string ":" *> spaces *> decimal
  spaces *> string "]" *> spaces
  return . fromIntegral $ rangeH - rangeL + 1

ident :: Parser Identifier
ident = Identifier . T.pack <$> identifier

parseNetDecl :: Maybe PortDir -> Parser ModItem
parseNetDecl pd = do
  t <- option Wire type_
  sign <- option False (reserved "signed" *> spaces $> True)
  range <- option 1 parseRange
  name <- ident
  _ <- spaces *> string ";"
  return . Decl pd . Port t sign range $ name
  where
    type_ = reserved "wire" *> spaces $> Wire
            <|> reserved "reg" *> spaces $> Reg

parsePortDir :: Parser PortDir
parsePortDir =
  reserved "output" *> spaces $> PortOut
  <|> reserved "input" *> spaces $> PortIn
  <|> reserved "inout" *> spaces $> PortInOut

parseDecl :: Parser ModItem
parseDecl =
  (Just <$> parsePortDir >>= parseNetDecl)
  <|> parseNetDecl Nothing

parseModItem :: Parser ModItem
parseModItem =
  (ModCA <$> parseContAssign)
  <|> parseDecl

parseModList :: Parser [Identifier]
parseModList = list <|> spaces $> []
  where
    list = aroundList (string "(") (string ")") ident

parseModDecl :: Parser ModDecl
parseModDecl = do
  name <- (reserved "module" *> ident)
  modL <- fmap defaultPort <$> parseModList
  _ <- string ";"
  modItem <- option [] . try $ many1 parseModItem
  _ <- reserved "endmodule"
  return $ ModDecl name [defaultPort "y"] modL modItem

parseDescription :: Parser Description
parseDescription = Description <$> parseModDecl

parseVerilogSrc :: Parser VerilogSrc
parseVerilogSrc = VerilogSrc <$> many parseDescription
