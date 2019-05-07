{-|
Module      : VeriFuzz.Sim.XST
Description : XST (ise) simulator implementation.
Copyright   : (c) 2018-2019, Yann Herklotz
License     : BSD-3
Maintainer  : ymherklotz [at] gmail [dot] com
Stability   : experimental
Portability : POSIX

XST (ise) simulator implementation.
-}

{-# LANGUAGE QuasiQuotes #-}

module VeriFuzz.Sim.XST
    ( XST(..)
    , defaultXST
    )
where

import           Prelude                  hiding (FilePath)
import           Shelly
import           Shelly.Lifted            (liftSh)
import           Text.Shakespeare.Text    (st)
import           VeriFuzz.Sim.Internal
import           VeriFuzz.Sim.Template
import           VeriFuzz.Verilog.AST
import           VeriFuzz.Verilog.CodeGen

data XST = XST { xstPath    :: {-# UNPACK #-} !FilePath
               , netgenPath :: {-# UNPACK #-} !FilePath
               , xstOutput  :: {-# UNPACK #-} !FilePath
               }
         deriving (Eq)

instance Show XST where
    show _ = "xst"

instance Tool XST where
    toText _ = "xst"

instance Synthesiser XST where
    runSynth = runSynthXST
    synthOutput = xstOutput
    setSynthOutput (XST a b _) = XST a b

defaultXST :: XST
defaultXST = XST "xst" "netgen" "syn_xst.v"

runSynthXST :: XST -> SourceInfo -> ResultSh ()
runSynthXST sim (SourceInfo top src) = do
    dir <- liftSh pwd
    let exec = execute_ SynthFail dir "xst"
    liftSh $ do
        writefile xstFile $ xstSynthConfig top
        writefile prjFile [st|verilog work "rtl.v"|]
        writefile "rtl.v" $ genSource src
        logger "XST: run"
    exec (xstPath sim) ["-ifn", toTextIgnore xstFile]
    liftSh $ logger "XST: netgen"
    exec
        (netgenPath sim)
        [ "-w"
        , "-ofmt"
        , "verilog"
        , toTextIgnore $ modFile <.> "ngc"
        , toTextIgnore $ synthOutput sim
        ]
    liftSh $ do
        logger "XST: clean"
        noPrint $ run_
            "sed"
            [ "-i"
            , "/^`ifndef/,/^`endif/ d; s/ *Timestamp: .*//;"
            , toTextIgnore $ synthOutput sim
            ]
        logger "XST: done"
  where
    modFile = fromText top
    xstFile = modFile <.> "xst"
    prjFile = modFile <.> "prj"
