module Main where

-- import           Debug.Trace

import Language.Edh.EHI
import Language.Edh.Net
import Language.Edh.Run
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Prelude

main :: IO ()
main =
  getArgs >>= \case
    [moduSpec] -> edhRunModule defaultEdhConsoleSettings moduSpec $
      \ !world -> do
        -- install all necessary batteries
        installEdhBatteries world
        installNetBatteries world

    --
    _ -> hPutStrLn stderr "Usage: nedhm <edh-module>" >> exitFailure
