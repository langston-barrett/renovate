{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
module Renovate.BinaryFormat.ELF.Rewriter (
  ElfRewriter,
  runElfRewriter,
  RewriterInfo(..),
  emptyRewriterInfo,
  SomeBlocks(..),
  assertM,
  -- * Lenses
  riInitialBytes,
  riStats,
  riSmallBlockCount,
  riReusedByteCount,
  riUnrelocatableTerm,
  riEntryPointAddress,
  riSectionBaseAddress,
  riInstrumentationSites,
  riLogMsgs,
  riSegmentVirtualAddress,
  riOverwrittenRegions,
  riAppendedSegments,
  riRecoveredBlocks,
  riOriginalTextSize,
  riNewTextSize,
  riIncompleteBlocks,
  riTransitivelyIncompleteBlocks,
  riIncompleteFunctions,
  riRedirectionDiagnostics,
  riBlockRecoveryDiagnostics,
  riDiscoveredBlocks,
  riInstrumentedBytes,
  riBlockMapping,
  riOutputBlocks,
  riRewritePairs,
  riFunctionBlocks,
  riSections,
  ) where

import           GHC.Generics ( Generic )
import           GHC.Stack ( HasCallStack )

import           Control.Applicative
import qualified Control.Exception as X
import qualified Control.Lens as L
import qualified Control.Monad.Catch.Pure as P
import qualified Control.Monad.IO.Class as IO
import qualified Control.Monad.State.Strict as S
import qualified Data.ByteString as B
import qualified Data.Generics.Product as GL
import qualified Data.Map as M
import qualified Data.Set as S
import           Data.Word ( Word16, Word64 )

import           Prelude

import qualified Data.ElfEdit as E
import qualified Data.Macaw.CFG as MM

import qualified Renovate.Address as RA
import qualified Renovate.BasicBlock as B
import qualified Renovate.Diagnostic as RD
import qualified Renovate.ISA as ISA
import qualified Renovate.Redirect.LayoutBlocks.Types as RT
import qualified Renovate.Rewrite as RW
import qualified Renovate.Redirect.Monad as RM

assertM :: (Monad m, HasCallStack) => Bool -> m ()
assertM b = X.assert b (return ())

-- | Statistics gathered and diagnostics generated during the
-- rewriting phase.
--
-- Here @lm@ is the user controlled type of log msgs.
data RewriterInfo lm arch =
  RewriterInfo { _riSegmentVirtualAddress :: Maybe Word64
               , _riOverwrittenRegions :: [(String, Word64)]
               -- ^ The name of a data region and its length (which is
               -- the number of zero bytes that that replaced it)
               , _riAppendedSegments :: [(E.ElfSegmentType, Word16, Word64, Word64)]
               -- ^ The type of the segment, the index of the segment,
               -- the aligned offset at which it will be placed, the
               -- amount of padding required.
               , _riEntryPointAddress :: Maybe Word64
               , _riSectionBaseAddress :: Maybe Word64
               , _riInitialBytes :: Maybe B.ByteString
               , _riBlockRecoveryDiagnostics :: [RD.Diagnostic]
               , _riRedirectionDiagnostics :: [RD.Diagnostic]
               , _riRecoveredBlocks :: Maybe SomeBlocks
               , _riInstrumentationSites :: [RW.RewriteSite arch]
               , _riLogMsgs :: [lm]
               , _riELF :: E.Elf (MM.ArchAddrWidth arch)
               , _riOriginalTextSize :: Int
               -- ^ The number of bytes in the original text section
               , _riNewTextSize :: Int
               -- ^ The number of bytes allocated in the new text section
               , _riTransitivelyIncompleteBlocks :: S.Set (RA.ConcreteAddress arch)
               -- ^ The number of blocks that reside in incomplete functions
               , _riIncompleteFunctions :: M.Map (RA.ConcreteAddress arch) (S.Set (RA.ConcreteAddress arch))
               -- ^ For each function, the set of blocks that are incomplete due to translation errors or classify failures
               , _riOutputBlocks :: Maybe SomeBlocks
               -- ^ The blocks generated by the rewriter (both original and new blocks)
               , _riStats :: !(RM.RewriterStats arch)
               -- ^ The correspondence between original and new blocks
               , _riRewritePairs :: [RT.RewritePair arch]
               }
  deriving (Generic)

data SomeBlocks = forall arch
                . (B.InstructionConstraints arch)
                => SomeBlocks (ISA.ISA arch) [B.ConcreteBlock arch]

newtype ElfRewriter lm arch a = ElfRewriter { unElfRewrite :: S.StateT (RewriterInfo lm arch) IO a }
                          deriving (Monad,
                                    Functor,
                                    Applicative,
                                    IO.MonadIO,
                                    P.MonadThrow,
                                    S.MonadState (RewriterInfo lm arch))

runElfRewriter :: E.Elf (MM.ArchAddrWidth arch)
               -> ElfRewriter lm arch a
               -> IO (a, RewriterInfo lm arch)
runElfRewriter e a =
  S.runStateT (unElfRewrite a) (emptyRewriterInfo e)

emptyRewriterInfo :: E.Elf (MM.ArchAddrWidth arch) -> RewriterInfo lm arch
emptyRewriterInfo e = RewriterInfo { _riSegmentVirtualAddress    = Nothing
                                   , _riOverwrittenRegions       = []
                                   , _riAppendedSegments         = []
                                   , _riEntryPointAddress        = Nothing
                                   , _riSectionBaseAddress       = Nothing
                                   , _riInitialBytes             = Nothing
                                   , _riBlockRecoveryDiagnostics = []
                                   , _riRedirectionDiagnostics   = []
                                   , _riRecoveredBlocks          = Nothing
                                   , _riInstrumentationSites     = []
                                   , _riLogMsgs                  = []
                                   , _riELF                      = e
                                   , _riOriginalTextSize         = 0
                                   , _riTransitivelyIncompleteBlocks = S.empty
                                   , _riIncompleteFunctions      = M.empty
                                   , _riNewTextSize              = 0
                                   , _riOutputBlocks             = Nothing
                                   , _riStats                    = RM.emptyRewriterStats
                                   , _riRewritePairs             = []
                                   }
riOriginalTextSize :: L.Simple L.Lens (RewriterInfo lm arch) Int
riOriginalTextSize = GL.field @"_riOriginalTextSize"

riNewTextSize :: L.Simple L.Lens (RewriterInfo lm arch) Int
riNewTextSize = GL.field @"_riNewTextSize"

riStats :: L.Simple L.Lens (RewriterInfo lm arch) (RM.RewriterStats arch)
riStats = GL.field @"_riStats"

riIncompleteBlocks :: L.Simple L.Lens (RewriterInfo lm arch) Int
riIncompleteBlocks = riStats . GL.field @"incompleteBlocks"

riTransitivelyIncompleteBlocks :: L.Simple L.Lens (RewriterInfo lm arch) (S.Set (RA.ConcreteAddress arch))
riTransitivelyIncompleteBlocks = GL.field @"_riTransitivelyIncompleteBlocks"

riIncompleteFunctions :: L.Simple L.Lens (RewriterInfo lm arch) (M.Map (RA.ConcreteAddress arch) (S.Set (RA.ConcreteAddress arch)))
riIncompleteFunctions = GL.field @"_riIncompleteFunctions"

riSegmentVirtualAddress :: L.Simple L.Lens (RewriterInfo lm arch) (Maybe Word64)
riSegmentVirtualAddress = GL.field @"_riSegmentVirtualAddress"

riOverwrittenRegions :: L.Simple L.Lens (RewriterInfo lm arch) [(String, Word64)]
riOverwrittenRegions = GL.field @"_riOverwrittenRegions"

riAppendedSegments :: L.Simple L.Lens (RewriterInfo lm arch) [(E.ElfSegmentType, Word16, Word64, Word64)]
riAppendedSegments = GL.field @"_riAppendedSegments"

riEntryPointAddress :: L.Simple L.Lens (RewriterInfo lm arch) (Maybe Word64)
riEntryPointAddress = GL.field @"_riEntryPointAddress"

riSectionBaseAddress :: L.Simple L.Lens (RewriterInfo lm arch) (Maybe Word64)
riSectionBaseAddress = GL.field @"_riSectionBaseAddress"

riInitialBytes :: L.Simple L.Lens (RewriterInfo lm arch) (Maybe B.ByteString)
riInitialBytes = GL.field @"_riInitialBytes"

riBlockRecoveryDiagnostics :: L.Simple L.Lens (RewriterInfo lm arch) [RD.Diagnostic]
riBlockRecoveryDiagnostics = GL.field @"_riBlockRecoveryDiagnostics"

riRedirectionDiagnostics :: L.Simple L.Lens (RewriterInfo lm arch) [RD.Diagnostic]
riRedirectionDiagnostics = GL.field @"_riRedirectionDiagnostics"

riRecoveredBlocks :: L.Simple L.Lens (RewriterInfo lm arch) (Maybe SomeBlocks)
riRecoveredBlocks = GL.field @"_riRecoveredBlocks"

riInstrumentationSites :: L.Simple L.Lens (RewriterInfo lm arch) [RW.RewriteSite arch]
riInstrumentationSites = GL.field @"_riInstrumentationSites"

riLogMsgs :: L.Simple L.Lens (RewriterInfo lm arch) [lm]
riLogMsgs = GL.field @"_riLogMsgs"

riSmallBlockCount :: L.Simple L.Lens (RewriterInfo lm arch) Int
riSmallBlockCount = riStats . GL.field @"smallBlockCount"

riReusedByteCount :: L.Simple L.Lens (RewriterInfo lm arch) Int
riReusedByteCount = riStats . GL.field @"reusedByteCount"

riUnrelocatableTerm :: L.Simple L.Lens (RewriterInfo lm arch) Int
riUnrelocatableTerm = riStats . GL.field @"unrelocatableTerm"

riDiscoveredBlocks :: L.Simple L.Lens (RewriterInfo lm arch) (M.Map (RA.ConcreteAddress arch) Int)
riDiscoveredBlocks = riStats . GL.field @"discoveredBlocks"

riInstrumentedBytes :: L.Simple L.Lens (RewriterInfo lm arch) Int
riInstrumentedBytes = riStats . GL.field @"instrumentedBytes"

riBlockMapping :: L.Simple L.Lens (RewriterInfo lm arch) [(RA.ConcreteAddress arch, RA.ConcreteAddress arch)]
riBlockMapping = riStats . GL.field @"blockMapping"

riOutputBlocks :: L.Simple L.Lens (RewriterInfo lm arch) (Maybe SomeBlocks)
riOutputBlocks = GL.field @"_riOutputBlocks"

riRewritePairs :: L.Simple L.Lens (RewriterInfo lm arch) [RT.RewritePair arch]
riRewritePairs = GL.field @"_riRewritePairs"

riFunctionBlocks :: L.Simple L.Lens (RewriterInfo lm arch) (M.Map (RA.ConcreteAddress arch) [RA.ConcreteAddress arch])
riFunctionBlocks = riStats . GL.field @"functionBlocks"

riSections :: L.Simple L.Lens (RewriterInfo lm arch) (M.Map String (RM.SectionInfo arch))
riSections = riStats . GL.field @"sections"
