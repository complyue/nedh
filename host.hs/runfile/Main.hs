module Main where

-- import           Debug.Trace

import Language.Edh.EHI
import Language.Edh.Net
import Language.Edh.Run
import System.Environment
import System.Exit
import System.IO
import Prelude

main :: IO ()
main =
  getArgs >>= \case
    [edhFile] -> edhRunFile defaultEdhConsoleSettings edhFile $ \ !world -> do
      -- install all necessary batteries
      installEdhBatteries world
      installNetBatteries world

    --
    _ -> hPutStrLn stderr "Usage: runnedh <.edh-file>" >> exitFailure
