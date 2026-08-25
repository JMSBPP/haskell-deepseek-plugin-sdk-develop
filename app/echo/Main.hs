{- |
Placeholder for the @dsh-plugin-echo@ example binary. Phase 7 (API-10)
replaces this with the real plugin; until then the binary exits non-zero so
no caller mistakes it for a working peer.
-}
module Main (main) where

import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    hPutStrLn stderr "dsh-plugin-echo: not implemented until Phase 7 (API-10)."
    exitFailure
