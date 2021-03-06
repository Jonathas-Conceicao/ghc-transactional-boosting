module Paths_funsat (
    version,
    getBinDir, getLibDir, getDataDir, getLibexecDir,
    getDataFileName
  ) where

import Data.Version (Version(..))
import System.Environment (getEnv)

version :: Version
version = Version {versionBranch = [0,6,1], versionTags = []}

bindir, libdir, datadir, libexecdir :: FilePath

bindir     = "/Users/dave/.cabal/bin"
libdir     = "/Users/dave/.cabal/lib/funsat-0.6.1/ghc-7.1.20101021"
datadir    = "/Users/dave/.cabal/share/funsat-0.6.1"
libexecdir = "/Users/dave/.cabal/libexec"

getBinDir, getLibDir, getDataDir, getLibexecDir :: IO FilePath
getBinDir = catch (getEnv "funsat_bindir") (\_ -> return bindir)
getLibDir = catch (getEnv "funsat_libdir") (\_ -> return libdir)
getDataDir = catch (getEnv "funsat_datadir") (\_ -> return datadir)
getLibexecDir = catch (getEnv "funsat_libexecdir") (\_ -> return libexecdir)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir ++ "/" ++ name)
