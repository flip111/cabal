{-# OPTIONS -cpp #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Program
-- Copyright   :  Isaac Jones 2006
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  GHC, Hugs
--
-- Explanation: A program is basically a name, a location, and some
-- arguments.
--
-- One nice thing about using it is that any program that is
-- registered with Cabal will get some \"configure\" and \".cabal\"
-- helpers like --with-foo-args --foo-path= and extra-foo-args.
--
-- There's also good default behavior for trying to find \"foo\" in
-- PATH, being able to override its location, etc.
--
-- There's also a hook for adding programs in a Setup.lhs script.  See
-- hookedPrograms in 'Distribution.Simple.UserHooks'.  This gives a
-- hook user the ability to get the above flags and such so that they
-- don't have to write all the PATH logic inside Setup.lhs.

module Distribution.Program(
                           -- * Program-Related types
                             Program(..)
                           , ProgramLocation(..)
                           , ProgramConfiguration(..)
                           -- * Helper functions
                           , withProgramFlag
                           , programOptsFlag
                           , programOptsField
                           , programPath
                           , findProgram
                           , findProgramAndVersion
                           , defaultProgramConfiguration
                           , updateProgram
                           , maybeUpdateProgram
                           , userSpecifyPath
                           , userSpecifyArgs
                           , lookupProgram
                           , lookupProgram' --TODO eliminate this export
                           , lookupPrograms
                           , rawSystemProgram
                           , rawSystemProgramConf
                           , simpleProgram
                           , simpleProgramAt
                             -- * Programs that Cabal knows about
                           , ghcProgram
                           , ghcPkgProgram
                           , nhcProgram
                           , jhcProgram
                           , hugsProgram
                           , ranlibProgram
                           , arProgram
                           , happyProgram
                           , alexProgram
                           , hsc2hsProgram
                           , c2hsProgram
                           , cpphsProgram
                           , hscolourProgram
                           , haddockProgram
                           , greencardProgram
                           , ldProgram
                           , cppProgram
                           , pfesetupProgram
                           ) where

import qualified Distribution.Compat.Map as Map
import Distribution.Compat.Directory (findExecutable)
import Distribution.Simple.Utils (die, rawSystemExit, rawSystemStdout)
import Distribution.System
import Distribution.Version (Version, readVersion)
import Distribution.Verbosity
import System.Directory (doesFileExist)
import Control.Monad (when)

-- |Represents a program which cabal may call.
data Program
    = Program { -- |The simple name of the program, eg. ghc
               programName :: String
                -- |The name of this program's binary, eg. ghc-6.4
              ,programBinName :: String
                -- |The version of this program, if it is known
              ,programVersion :: Maybe Version
                -- |Default command-line args for this program
              ,programArgs :: [String]
                -- |Location of the program.  eg. \/usr\/bin\/ghc-6.4
              ,programLocation :: ProgramLocation
              } deriving (Read, Show)

-- |Similar to Maybe, but tells us whether it's specifed by user or
-- not.  This includes not just the path, but the program as well.
data ProgramLocation 
    = EmptyLocation -- ^Like Nothing
    | UserSpecified FilePath 
      -- ^The user gave the path to this program,
      -- eg. --ghc-path=\/usr\/bin\/ghc-6.6
    | FoundOnSystem FilePath 
      -- ^The location of the program, as located by searching PATH.
      deriving (Read, Show)

-- |The configuration is a collection of 'Program's.  It's a mapping from the
--  name of the program (eg. ghc) to the Program.
data ProgramConfiguration = ProgramConfiguration (Map.Map String Program)

-- Read & Show instances are based on listToFM

instance Show ProgramConfiguration where
  show (ProgramConfiguration s) = show $ Map.toAscList s

instance Read ProgramConfiguration where
  readsPrec p s = [(ProgramConfiguration $ Map.fromList $ s', r)
                       | (s', r) <- readsPrec p s ]

-- |The default list of programs and their arguments.  These programs
-- are typically used internally to Cabal.

defaultProgramConfiguration :: ProgramConfiguration
defaultProgramConfiguration = progListToFM 
                              [ hscolourProgram
                              , haddockProgram
                              , happyProgram
                              , alexProgram
                              , hsc2hsProgram
                              , c2hsProgram
                              , cpphsProgram
                              , greencardProgram
                              , pfesetupProgram
                              , ranlibProgram
                              , simpleProgram "runghc"
                              , simpleProgram "runhugs"
                              , arProgram
			      , ldProgram
			      , tarProgram
			      ]
-- haddock is currently the only one that really works.
{-                              [ ghcProgram
                              , ghcPkgProgram
                              , nhcProgram
                              , hugsProgram
                              , cppProgram
                              ]-}

-- |The flag for giving a path to this program.  eg. --with-alex=\/usr\/bin\/alex
withProgramFlag :: Program -> String
withProgramFlag Program{programName=n} = "with-" ++ n

-- |The flag for giving args for this program.
--  eg. --haddock-options=-s http:\/\/foo
programOptsFlag :: Program -> String
programOptsFlag Program{programName=n} = n ++ "-options"

-- |The foo.cabal field for  giving args for this program.
--  eg. haddock-options: -s http:\/\/foo
programOptsField :: Program -> String
programOptsField = programOptsFlag

-- |The full path of a configured program.
--
-- * This is a partial function, it is not defined for programs with an
-- EmptyLocation.
programPath :: Program -> FilePath
programPath program =
  case programLocation program of
    UserSpecified p -> p
    FoundOnSystem p -> p
    EmptyLocation -> error "programPath EmptyLocation"

-- | Look for a program. It can accept either an absolute path or the name of
-- a program binary, in which case we will look for the program on the path.
--
findProgram :: Verbosity -> String -> Maybe FilePath -> IO Program
findProgram verbosity prog maybePath = do
  location <- case maybePath of
    Nothing   -> searchPath verbosity prog
    Just path -> do
      absolute <- doesFileExist path
      if absolute
        then return (UserSpecified path)
        else searchPath verbosity path
  return (simpleProgramAt prog location)

searchPath :: Verbosity -> FilePath -> IO ProgramLocation
searchPath verbosity prog = do
  when (verbosity >= verbose) $
      putStrLn $ "searching for " ++ prog ++ " in path."
  res <- findExecutable prog
  case res of
    Nothing   -> die ("Cannot find " ++ prog ++ " on the path") 
    Just path -> do when (verbosity >= verbose) $
                      putStrLn ("found " ++ prog ++ " at "++ path)
                    return (FoundOnSystem path)

-- | Look for a program and try to find it's version number. It can accept
-- either an absolute path or the name of a program binary, in which case we
-- will look for the program on the path.
--
findProgramAndVersion :: Verbosity
                      -> String             -- ^ program binary name
                      -> Maybe FilePath     -- ^ possible location
                      -> String             -- ^ version args
                      -> (String -> String) -- ^ function to select version
                                            --   number from program output
                      -> IO Program
findProgramAndVersion verbosity name maybePath versionArg selectVersion = do
  prog <- findProgram verbosity name maybePath
  str <- rawSystemStdout verbosity (programPath prog) [versionArg]
  case readVersion (selectVersion str) of
    Just v -> return prog { programVersion = Just v }
    _      -> die ("cannot determine version of " ++ name ++ " :\n" ++ show str)

-- ------------------------------------------------------------
-- * cabal programs
-- ------------------------------------------------------------

ghcProgram :: Program
ghcProgram = simpleProgram "ghc"

ghcPkgProgram :: Program
ghcPkgProgram = simpleProgram "ghc-pkg"

nhcProgram :: Program
nhcProgram = simpleProgram "nhc"

jhcProgram :: Program
jhcProgram = simpleProgram "jhc"

hugsProgram :: Program
hugsProgram = simpleProgram "hugs"

happyProgram :: Program
happyProgram = simpleProgram "happy"

alexProgram :: Program
alexProgram = simpleProgram "alex"

ranlibProgram :: Program
ranlibProgram = simpleProgram "ranlib"

arProgram :: Program
arProgram = simpleProgram "ar"

hsc2hsProgram :: Program
hsc2hsProgram = simpleProgram "hsc2hs"

c2hsProgram :: Program
c2hsProgram = simpleProgram "c2hs"

cpphsProgram :: Program
cpphsProgram = simpleProgram "cpphs"

hscolourProgram :: Program
hscolourProgram = (simpleProgram "hscolour"){ programBinName = "HsColour" }

haddockProgram :: Program
haddockProgram = simpleProgram "haddock"

greencardProgram :: Program
greencardProgram = simpleProgram "greencard"

ldProgram :: Program
ldProgram = case os of
                Windows MingW ->
                    Program "ld" "ld" Nothing []
                        (FoundOnSystem "<what-your-hs-compiler-shipped-with>")
                _ -> simpleProgram "ld"

tarProgram :: Program
tarProgram = simpleProgram "tar"

cppProgram :: Program
cppProgram = simpleProgram "cpp"

pfesetupProgram :: Program
pfesetupProgram = simpleProgram "pfesetup"

-- ------------------------------------------------------------
-- * helpers
-- ------------------------------------------------------------

-- |Looks up a program in the given configuration.  If there's no
-- location information in the configuration, then we use IO to look
-- on the system in PATH for the program.  If the program is not in
-- the configuration at all, we return Nothing.  FIX: should we build
-- a simpleProgram in that case? Do we want a way to specify NOT to
-- find it on the system (populate programLocation).

lookupProgram :: String -- simple name of program
              -> ProgramConfiguration
              -> IO (Maybe Program) -- the full program
lookupProgram name conf = 
  case lookupProgram' name conf of
    Nothing   -> return Nothing
    Just p@Program{ programLocation= configLoc
                  , programBinName = binName}
        -> do newLoc <- case configLoc of
                         EmptyLocation
                             -> do maybeLoc <- findExecutable binName
                                   return $ maybe EmptyLocation FoundOnSystem maybeLoc
                         a   -> return a
              return $ Just p{programLocation=newLoc}

lookupPrograms :: ProgramConfiguration -> IO [(String, Maybe Program)]
lookupPrograms conf@(ProgramConfiguration fm) = do
  let l = Map.elems fm
  mapM (\p -> do fp <- lookupProgram (programName p) conf
                 return (programName p, fp)
       ) l

-- |User-specify this path.  Basically override any path information
-- for this program in the configuration. If it's not a known
-- program, add it.
userSpecifyPath :: String   -- ^Program name
                -> FilePath -- ^user-specified path to filename
                -> ProgramConfiguration
                -> ProgramConfiguration
userSpecifyPath name path conf'@(ProgramConfiguration conf)
    = case Map.lookup name conf of
       Just p  -> updateProgram p{programLocation=UserSpecified path} conf'
       Nothing -> updateProgram (simpleProgramAt name (UserSpecified path))
                                conf'

-- |User-specify the arguments for this program.  Basically override
-- any args information for this program in the configuration. If it's
-- not a known program, add it.
userSpecifyArgs :: String -- ^Program name
                -> String -- ^user-specified args
                -> ProgramConfiguration
                -> ProgramConfiguration
userSpecifyArgs name args conf'@(ProgramConfiguration conf)
    = case Map.lookup name conf of
       Just p  -> updateProgram p{programArgs=(words args)} conf'
       Nothing -> updateProgram (Program name name Nothing (words args) EmptyLocation) conf'

-- |Update this program's entry in the configuration.
updateProgram :: Program -> ProgramConfiguration -> ProgramConfiguration
updateProgram p@Program{programName=n} (ProgramConfiguration conf)
    = ProgramConfiguration $ Map.insert n p conf

-- |Same as updateProgram but no changes if you pass in Nothing.
maybeUpdateProgram :: Maybe Program -> ProgramConfiguration -> ProgramConfiguration
maybeUpdateProgram m c = maybe c (\p -> updateProgram p c) m

-- |Runs the given program.
rawSystemProgram :: Verbosity -- ^Verbosity
                 -> Program   -- ^The program to run
                 -> [String]  -- ^Any /extra/ arguments to add
                 -> IO ()
rawSystemProgram _ prog@(Program { programLocation = EmptyLocation }) _
  = die ("Error: Could not find location for program: " ++ programName prog)
rawSystemProgram verbosity prog extraArgs
  = rawSystemExit verbosity (programPath prog) (programArgs prog ++ extraArgs)

rawSystemProgramConf :: Verbosity            -- ^verbosity
                     -> String               -- ^The name of the program to run
                     -> ProgramConfiguration -- ^look up the program here
                     -> [String]             -- ^Any /extra/ arguments to add
                     -> IO ()
rawSystemProgramConf verbosity progName programConf extraArgs 
    = do prog <- do mProg <- lookupProgram progName programConf
                    case mProg of
                        Nothing -> (die (progName ++ " command not found"))
                        Just h  -> return h
         rawSystemProgram verbosity prog extraArgs


-- ------------------------------------------------------------
-- * Internal helpers
-- ------------------------------------------------------------

lookupProgram' :: String -> ProgramConfiguration -> Maybe Program
lookupProgram' s (ProgramConfiguration conf) = Map.lookup s conf

progListToFM :: [Program] -> ProgramConfiguration
progListToFM progs = foldl
                     (\ (ProgramConfiguration conf')
                      p@(Program {programName=n})
                          -> ProgramConfiguration (Map.insert n p conf'))
                     (ProgramConfiguration Map.empty)
                     progs

simpleProgram :: String -> Program
simpleProgram s = simpleProgramAt s EmptyLocation

simpleProgramAt :: String -> ProgramLocation -> Program
simpleProgramAt s l = Program s s Nothing [] l
