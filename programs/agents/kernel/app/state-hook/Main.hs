-- | The @state-hook@ command: the kernel's hooks over argv and one event on stdin.
module Main (main) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import State.Shell qualified as Shell
import System.Environment (getArgs)
import System.IO (hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = do
    -- The reply and its errors are UTF-8 whatever the locale; stdin is read as bytes.
    mapM_ (`hSetEncoding` utf8) [stdout, stderr]
    argv <- map Text.pack <$> getArgs
    Shell.hook argv =<< LBS.getContents
