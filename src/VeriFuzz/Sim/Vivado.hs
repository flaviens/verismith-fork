{-|
Module      : VeriFuzz.Sim.Vivado
Description : Vivado Synthesiser implementation.
Copyright   : (c) 2019, Yann Herklotz Grave
License     : GPL-3
Maintainer  : ymherklotz [at] gmail [dot] com
Stability   : experimental
Portability : POSIX

Vivado Synthesiser implementation.
-}

module VeriFuzz.Sim.Vivado
    ( Vivado(..)
    , defaultVivado
    )
where

import           Prelude                  hiding (FilePath)
import           Shelly
import           Shelly.Lifted            (liftSh)
import           VeriFuzz.Sim.Internal
import           VeriFuzz.Sim.Template
import           VeriFuzz.Verilog.AST
import           VeriFuzz.Verilog.CodeGen

data Vivado = Vivado { vivadoPath   :: {-# UNPACK #-} !FilePath
                     , vivadoOutput :: {-# UNPACK #-} !FilePath
                     }
               deriving (Eq)

instance Show Vivado where
    show _ = "vivado"

instance Tool Vivado where
    toText _ = "vivado"

instance Synthesiser Vivado where
    runSynth = runSynthVivado
    synthOutput = vivadoOutput
    setSynthOutput (Vivado a _) = Vivado a

defaultVivado :: Vivado
defaultVivado = Vivado "vivado" "syn_vivado.v"

runSynthVivado :: Vivado -> SourceInfo -> ResultSh ()
runSynthVivado sim (SourceInfo top src) = do
    dir <- liftSh pwd
    liftSh $ do
        writefile vivadoTcl . vivadoSynthConfig top . toTextIgnore $ synthOutput
            sim
        writefile "rtl.v" $ genSource src
        run_ "sed" ["s/^module/(* use_dsp=\"no\" *) module/;", "-i", "rtl.v"]
        logger "Vivado: run"
    execute_ SynthFail
             dir
             "vivado"
             (vivadoPath sim)
             ["-mode", "batch", "-source", toTextIgnore vivadoTcl]
    liftSh $ logger "Vivado: done"
    where vivadoTcl = fromText ("vivado_" <> top) <.> "tcl"
