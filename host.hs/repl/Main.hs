module Main where

-- import           Debug.Trace

import Language.Edh.EHI
import Language.Edh.Net
import Language.Edh.Repl
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Prelude

main :: IO ()
main =
  getArgs >>= \case
    [] -> replWithModule "net"
    [edhModu] -> replWithModule edhModu
    _ -> hPutStrLn stderr "Usage: nedh [ <edh-module> ]" >> exitFailure
  where
    replWithModule :: FilePath -> IO ()
    replWithModule = edhRepl defaultEdhConsoleSettings $
      \ !world -> do
        let !consoleOut = consoleIO (edh'world'console world) . ConsoleOut

        -- install all necessary batteries
        installEdhBatteries world
        installNetBatteries world

        consoleOut $
          ">> Networked Đ (Edh) <<\n"
            <> "* Blank Screen Syndrome ? Take the Tour as your companion, checkout:\n"
            <> "  https://github.com/e-wrks/tour\n"
