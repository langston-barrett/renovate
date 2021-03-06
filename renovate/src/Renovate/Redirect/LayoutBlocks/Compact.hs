{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
module Renovate.Redirect.LayoutBlocks.Compact (
  Layout(..),
  compactLayout
  ) where

import qualified GHC.Err.Located as L

import           Control.Monad.State ( gets )

import qualified Data.ByteString as BS
import           Data.Monoid ( Any(Any) )
import           Data.Ord ( Down(..) )
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import           Control.Exception ( Exception, SomeException(SomeException), assert )
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.ST
import qualified Data.Foldable as F
import qualified Data.Functor.Compose as C
import qualified Data.Heap as H
import qualified Data.List as L
import qualified Data.Map.Strict as M
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.STRef
import qualified Data.Traversable as T
import           Data.Typeable ( Typeable )
import qualified Data.UnionFind.ST as UF
import           Data.Word ( Word64 )
import           Text.Printf ( printf )

import qualified System.Random.MWC as MWC

import qualified Data.Macaw.CFG as MM
import           Data.Parameterized.Some ( Some(Some) )
import qualified Lang.Crucible.Analysis.Fixpoint.Components as WTO
import qualified Lang.Crucible.CFG.Core as CFG
import qualified What4.ProgramLoc as W4

import           Renovate.Address
import           Renovate.BasicBlock
import           Renovate.ISA
import           Renovate.Recovery ( SCFG, SymbolicCFG, getSymbolicCFG )
import           Renovate.Redirect.Monad

import qualified Renovate.Redirect.LayoutBlocks.SuccessorMap as LBSM
import           Renovate.Redirect.LayoutBlocks.Types

-- | The address heap associates chunks of memory to addresses.  The
-- ordering of the heap is based on the size of the chunk of memory at
-- each address. It's a priority heap with larger addresses having
-- higher priority, hence @Down Int@ to sort decreasing on @Int@ size.
type AddressHeap arch = H.Heap (H.Entry (Down Int) (ConcreteAddress arch))

-- | Compute a concrete address for each 'SymbolicBlock'.
--
-- Right now, we use an inefficient encoding of jumps.  We could do
-- better later on.
compactLayout :: forall m t arch
              .  (MonadIO m, T.Traversable t, InstructionConstraints arch)
              => ConcreteAddress arch
              -- ^ Address to begin block layout of instrumented blocks
              -> LayoutStrategy
              -> t (SymbolicPair arch)
              -> t (SymbolicAddress arch, BS.ByteString)
              -> M.Map (ConcreteAddress arch) (SymbolicCFG arch)
              -> RewriterT arch m (Layout AddressAssignedPair arch)
compactLayout startAddr strat blocks0 injectedCode cfgs = do
  -- Augment all symbolic blocks such that fallthrough behavior is explicitly
  -- represented with symbolic unconditional jumps.
  --
  -- We need this so that we can re-arrange them and preserve the fallthrough
  -- behavior of blocks ending in conditional jumps (or non-jumps).
  -- traceM (show (PD.vcat (map PD.pretty (L.sortOn (basicBlockAddress . lpOrig) (F.toList blocks)))))
  blockChunks <- groupBlocks (grouping strat) cfgs blocks0
  let (modifiedBlockChunks, unmodifiedBlocks_) = foldMap splitChunk blockChunks
      unmodifiedBlocks = map noFallthroughPair unmodifiedBlocks_
  mem <- askMem
  blockChunks' <- reifyFallthroughSuccessors mem modifiedBlockChunks blocks0

  (h0, blocks1) <- case allocator strat of
    -- the parallel strategy is now a special case of compact. In particular,
    -- we avoid allocating the heap and we avoid sorting the input blocklist.
    Parallel -> return (mempty, concat blockChunks')
    -- We use blockChunks' (instead of blockChunks or modifiedBlockChunks)
    -- because buildAddressHeap checks the modification status, and
    -- reifyFallthroughSuccessors updates the modification status if it adds a
    -- fallthrough to an unmodified block. (It is okay not to additionally pass
    -- in the unmodified blocks because buildAddressHeap ignores unmodified
    -- blocks anyway.)
    _ -> buildAddressHeap (trampolines strat) startAddr (concat blockChunks')

  -- Either, a) Sort all of the instrumented blocks by size
  --         b) Randomize the order of the blocks.
  --         c) Use the input order exactly
  -- The (a) will give a more optimal answer, but (b) will provide some
  -- synthetic diversity at the cost of optimality. (c) is for treating
  -- the parallel layout as a special case of compact.
  isa <- askISA

  let newBlocks = map (map (lpNew . unFallthroughPair)) blockChunks'
      sortedBlocks = case allocator strat of
        Compact SortedOrder        -> L.sortOn    (bySize isa mem) newBlocks
        Compact (RandomOrder seed) -> randomOrder seed             newBlocks
        Parallel                   -> newBlocks

  -- Allocate an address for each block (falling back to startAddr if the heap
  -- can't provide a large enough space).
  (h1, symBlockAddrs, injectedAddrs) <- allocateSymbolicBlockAddresses startAddr h0 sortedBlocks injectedCode

  -- Overwrite any leftover space with ISA-specific padding. This is not,
  -- strictly speaking, necessary; without it, the assembler will take bytes
  -- from the original text section as padding instead. But it is safer to
  -- catch jumps that our tool didn't know about by landing at a halt
  -- instruction, when that is possible.
  (h2, blocks2) <- case allocator strat of
    -- In the parallel layout, we don't use any space reclaimed by redirecting
    -- things, so we should overwrite it all with padding.
    Parallel -> buildAddressHeap (trampolines strat) startAddr (concat blockChunks')
    _ -> return (h1, blocks1)

  let paddingBlocks :: [ConcreteBlock arch]
      paddingBlocks = [ BasicBlock (isaMakePadding isa (fromIntegral size)) addr
                      | H.Entry (Down size) addr <- H.toUnsortedList h2
                      ]

  -- Traverse the original container and update it with the addresses allocated
  -- to each symbolic block.  This will have an irrefutable pattern match that
  -- is actually safe.
  --
  -- Note that we are assigning addresses to blocks2, which has augmented the
  -- symbolic blocks with additional jumps to preserve fallthrough behavior and
  -- information about whether space was reserved for a redirection.
  -- That is critical.
  assignedPairs <- T.traverse
    (assignConcreteAddress symBlockAddrs)
    (unmodifiedBlocks ++ blocks2)

  return Layout { programBlockLayout = assignedPairs
                , layoutPaddingBlocks = paddingBlocks
                , injectedBlockLayout = [ (symAddr, caddr, bs) | (caddr, (symAddr, bs)) <- M.elems injectedAddrs ]
                }
  where
    bySize isa mem = Down . sum . map (symbolicBlockSize isa mem startAddr)

-- | Group together blocks into chunks which the allocator will keep together
-- when computing the layout.
groupBlocks :: forall arch f m. (MM.MemWidth (MM.ArchAddrWidth arch), F.Foldable f, MonadIO m) =>
  Grouping ->
  M.Map (ConcreteAddress arch) (SymbolicCFG arch) ->
  f (SymbolicPair arch) ->
  RewriterT arch m [[SymbolicPair arch]]
groupBlocks BlockGrouping _cfgs blocks = return (foldMap (\block -> [[block]]) blocks)
groupBlocks LoopGrouping cfgs_ blocks = do
  cfgs <- traverse (liftIO . getSymbolicCFG) cfgs_
  -- We want to keep together blocks that are part of loops. Consequently we
  -- want a way to map each block that's part of a loop to a canonical
  -- representative block of that loop, and check properties of all the blocks
  -- with the same canonical representative. First we build the mapping.
  --
  -- We won't rule out the possibility that some block is part of multiple
  -- loops yet, though that seems pretty preposterous to me (dmwit) right now.
  return . M.elems . groupByRep (cfgHeads cfgs) $ blocks
groupBlocks FunctionGrouping _cfgs blocks = do
  functions <- gets (functionBlocks . rwsStats)
  return . M.elems . groupByRep (functionHeads functions) $ blocks

-- | Lift a 'SymbolicPair' to a 'FallthroughPair' by marking each instruction
-- with 'noFallthrough' -- that is, as not a conditional jump. This is safe if
-- the pair is unmodified, since then it won't be rewritten and these
-- annotations will be ignored anyway.
noFallthroughPair :: SymbolicPair arch -> FallthroughPair arch
noFallthroughPair (SymbolicPair lp) = FallthroughPair lp
  { lpNew = (lpNew lp)
    { basicBlockInstructions = map noFallthrough (basicBlockInstructions (lpNew lp))
    }
  }

-- | Some grouping strategies may ask modified and immutable blocks to be
-- "chunked up" and relocated together. We can't honor that request, but we'll
-- come as close as we can by splitting off the immutable blocks, but
-- relocating any modifiable blocks together.
--
-- So given a collection of blocks, this gives back 0 or 1 chunks of blocks
-- that should be treated as modified, and a collection of blocks that can be
-- treated as unmodified.
splitChunk :: [SymbolicPair arch] -> ([[SymbolicPair arch]], [SymbolicPair arch])
splitChunk pairs = case foldMap summarize pairs of
  (immutable, modifiable, Any True) -> ([modifiable], immutable)
  (_, _, Any False) -> ([], pairs)
  where
  summarize pair = case lpStatus (unSymbolicPair pair) of
    Modified   -> ([], [pair], Any True)
    Unmodified -> ([], [pair], Any False)
    Immutable  -> ([pair], [], Any False)
    Subsumed   -> ([], [pair], Any True) -- should never happen

-- | Group together blocks that are part of a loop. The arguments are a map
-- that tells which loop each block is part of, and a collection of blocks to
-- partition. The returned result is a partitioning of the input collection of
-- blocks.
--
-- Eventually we're going to layout the blocks in each sublist of the
-- partition. If the original (un-rewritten) loop was created in a way that
-- took advantage of instruction cache locality, we'd like to preserve that
-- property. Therefore we sort each sublist of the partition by its original
-- memory location, so that blocks within a single loop that were previously
-- adjacent are kept adjacent after layout.
groupByRep ::
  Foldable t =>
  M.Map (ConcreteAddress arch) (ConcreteAddress arch) ->
  t (SymbolicPair arch) ->
  M.Map (ConcreteAddress arch) [SymbolicPair arch]
groupByRep repMap blocks = L.sortOn origAddr
  <$> M.fromListWith (++)
      [ (rep, [b])
      | b <- F.toList blocks
      , let addr = origAddr b
            rep = M.findWithDefault addr addr repMap
      ]
  where
  origAddr = basicBlockAddress . lpOrig . unSymbolicPair

functionHeads :: forall arch.
  MM.MemWidth (MM.ArchAddrWidth arch) =>
  M.Map (ConcreteAddress arch) [ConcreteAddress arch] ->
  M.Map (ConcreteAddress arch) (ConcreteAddress arch)
functionHeads functions = runST $ do
  rel <- discrete
  _ <- M.traverseMaybeWithKey (go rel) functions
  freeze rel
  where
  go rel entryPoint blocks = Nothing <$ F.traverse_ (equate rel entryPoint) blocks

cfgHeads :: forall arch pairs.
  ( pairs ~ [(ConcreteAddress arch, ConcreteAddress arch)]
  , MM.MemWidth (MM.ArchAddrWidth arch)
  ) =>
  M.Map (ConcreteAddress arch) (SCFG CFG.SomeCFG arch) ->
  M.Map (ConcreteAddress arch) (ConcreteAddress arch)
cfgHeads cfgs = runST $ do
  rel <- discrete
  F.traverse_ (uncurry (equate rel)) (goSCFGs cfgs)
  freeze rel
  where
  goSCFGs :: M.Map (ConcreteAddress arch) (SCFG CFG.SomeCFG arch) -> pairs
  goSCFGs = F.foldMap goSCFG

  goSCFG :: SCFG CFG.SomeCFG arch -> pairs
  goSCFG (CFG.SomeCFG cfg) = foldMap
    (goWTOComponent (CFG.cfgBlockMap cfg))
    (WTO.cfgWeakTopologicalOrdering cfg)

  goWTOComponent :: CFG.BlockMap ext blocks ret -> WTO.WTOComponent (Some (CFG.BlockID blocks)) -> pairs
  goWTOComponent _ WTO.Vertex{} = []
  goWTOComponent m component =
    [ (src, tgt)
    | tgt <- goSomeBlockID m (WTO.wtoHead component)
    , node <- F.toList component
    , src <- goSomeBlockID m node
    ]

  goSomeBlockID :: CFG.BlockMap ext blocks ret -> Some (CFG.BlockID blocks) -> [ConcreteAddress arch]
  goSomeBlockID m (Some ix) = goPosition . W4.plSourceLoc . CFG.blockLoc . CFG.getBlock ix $ m

  goPosition :: W4.Position -> [ConcreteAddress arch]
  goPosition (W4.BinaryPos _ w) = [concreteFromAbsolute (MM.memWord w)]
  goPosition _ = []

-- | A mutable equivalence relation; it can be mutated by making the relation
-- coarser, equating two previously-inequal things.
type EquivRel s a = STRef s (M.Map a (UF.Point s a))

-- | The finest equivalence relation: nothing is related to anything else.
discrete :: ST s (EquivRel s a)
discrete = newSTRef M.empty

-- | Modify the given equivalence relation by equating two values.
equate :: Ord a => EquivRel s a -> a -> a -> ST s ()
equate ref l r = do
  m0 <- readSTRef ref
  (pl, m1) <- insertLookupA l (UF.fresh l) m0
  (pr, m2) <- insertLookupA r (UF.fresh r) m1
  UF.union pl pr
  writeSTRef ref m2

-- | Produce an immutable representation of an equivalence relation. The
-- resulting 'Map' gives a mapping from a member of an equivalence class to a
-- canonical representative of that class (and all members of the class map to
-- the same representative). It is unspecified how the representative is chosen
-- from among equivalence class members. Missing keys in the 'Map' are
-- equivalent only to themselves.
freeze :: EquivRel s a -> ST s (M.Map a a)
freeze = readSTRef >=> traverse UF.descriptor

-- | Look up a key in a 'Map'. If the key doesn't exist in the 'Map' yet,
-- insert the result of running the given action first, and then do the lookup.
insertLookupA :: (Applicative f, Ord k) => k -> f v -> M.Map k v -> f (v, M.Map k v)
insertLookupA k fv m = C.getCompose (M.alterF (pairSelf . maybe fv pure) k m) where
  pairSelf = C.Compose . fmap (\self -> (self, Just self))

-- | Look up the concrete address assigned to each symbolic block and tag it
-- onto the tuple to create a suitable return value.
--
-- Every symbolic block is assumed to have been assigned an address at this
-- point.
assignConcreteAddress :: (Monad m, MM.MemWidth (MM.ArchAddrWidth arch))
                      => M.Map (SymbolicInfo arch) (ConcreteAddress arch, Word64)
                      -> FallthroughPair arch
                      -> RewriterT arch m (AddressAssignedPair arch)
assignConcreteAddress assignedAddrs (FallthroughPair (LayoutPair cb fb status))
  | changed status = case M.lookup (basicBlockAddress fb) assignedAddrs of
    Nothing -> L.error $ printf "Expected an assigned address for symbolic block %s (derived from concrete block %s)"
                                (show (basicBlockAddress fb))
                                (show (basicBlockAddress cb))
    Just (addr, size) -> return (AddressAssignedPair (LayoutPair cb (AddressAssignedBlock fb addr size) status))
  | otherwise =
    return (AddressAssignedPair (LayoutPair cb (AddressAssignedBlock fb (basicBlockAddress cb) 0) status))

allocateSymbolicBlockAddresses :: (Monad m, MM.MemWidth (MM.ArchAddrWidth arch), F.Foldable t, Functor t)
                               => ConcreteAddress arch
                               -> AddressHeap arch
                               -> [[FallthroughBlock arch]]
                               -> t (SymbolicAddress arch, BS.ByteString)
                               -> RewriterT arch m ( AddressHeap arch
                                                   , M.Map (SymbolicInfo arch) (ConcreteAddress arch, Word64)
                                                   , M.Map (SymbolicAddress arch) (ConcreteAddress arch, (SymbolicAddress arch, BS.ByteString))
                                                   )
allocateSymbolicBlockAddresses startAddr h0 blocksBySize injectedCode = do
  isa <- askISA
  mem <- askMem
  let blockItemSize = symbolicBlockSize isa mem startAddr
  let blockItemKey = basicBlockAddress
  let blockItemVal addr size _block = (addr, size)
  let injectedItemVal addr _size code = (addr, code)
  (nextStart, h1, m1) <- F.foldlM (allocateBlockGroupAddresses blockItemSize blockItemKey blockItemVal) (startAddr, h0, M.empty) blocksBySize
  (_, h2, m2) <- F.foldlM (allocateBlockGroupAddresses (fromIntegral . BS.length . snd) fst injectedItemVal) (nextStart, h1, M.empty) ((:[]) <$> injectedCode)
  return (h2, m1, m2)

-- | Allocate an address for the given symbolic block.
--
-- If the block will fit into a space held in the address heap, allocate it to
-- that space (and return unused space to the heap).  Otherwise, place the
-- symbolic block into the new code section we are building up (based on the
-- @newTextAddr@).
--
-- Note that the 'SymbolicBlock' at this stage must have been augmented with its
-- final unconditional jump to preserve fallthrough control flow (we rely on the
-- size of the block to be correct).
--
-- NOTE: This function is excessively parameterized so that we can assign
-- addresses both to lists of concrete blocks and also injected code (which is
-- just a bytestring instead of a basic block).
allocateBlockGroupAddresses
                     :: (MM.MemWidth (MM.ArchAddrWidth arch), Monad m, Ord key)
                     => (item -> Word64)
                     -> (item -> key)
                     -> (ConcreteAddress arch -> Word64 -> item -> val)
                     -> (ConcreteAddress arch, AddressHeap arch, M.Map key val)
                     -> [item]
                     -> RewriterT arch m (ConcreteAddress arch, AddressHeap arch, M.Map key val)
allocateBlockGroupAddresses itemSize itemKey itemVal (newTextAddr, h, m) items =
  case H.viewMin h of
    Nothing -> return allocateNewTextAddr
    Just (H.Entry (Down size) addr, h')
      | size < fromIntegral itemsSize -> return allocateNewTextAddr
      | otherwise -> do
          recordReusedBytes size
          return (allocateFromHeap size addr h')
  where
    addOff = addressAddOffset

    itemsSizes = map itemSize items
    itemsSize = sum itemsSizes

    blockGroupMapping baseAddr =
      let addrs = scanl (\addr size -> addr `addOff` fromIntegral size) baseAddr itemsSizes
          newMappings = zipWith3 (\addr size item -> (itemKey item, itemVal addr size item)) addrs itemsSizes items
      in M.union m (M.fromList newMappings)

    allocateNewTextAddr =
      let nextBlockStart = newTextAddr `addOff` fromIntegral itemsSize
      in (nextBlockStart, h, blockGroupMapping newTextAddr)

    allocateFromHeap allocSize addr h' =
      assert (allocSize >= fromIntegral itemsSize) $ do
        let addr'      = addr `addOff` fromIntegral itemsSize
            allocSize' = allocSize - fromIntegral itemsSize
        case allocSize' of
          0 -> (newTextAddr, h', blockGroupMapping addr)
          _ ->
            let h'' = H.insert (H.Entry (Down allocSize') addr') h'
            in (newTextAddr, h'', blockGroupMapping addr)


-- | Make the fallthrough behavior of our symbolic blocks explicit.
--
-- During the layout process, we are going to re-arrange blocks so that old
-- fallthrough behavior no longer works.  We make fallthroughs explicit (with
-- unconditional jumps).
--
-- A block has fallthrough behavior if it does not end in an unconditional jump.
reifyFallthroughSuccessors :: ( Traversable t, Traversable t', Traversable t''
                              , Monad m, MM.MemWidth (MM.ArchAddrWidth arch)
                              )
                           => MM.Memory (MM.ArchAddrWidth arch)
                           -> t (t' (SymbolicPair arch))
                           -- ^ The modified blocks
                           -> t'' (SymbolicPair arch)
                           -- ^ All blocks (which we need to compute the fallthrough address index)
                           -> RewriterT arch m (t (t' (FallthroughPair arch)))
reifyFallthroughSuccessors mem modifiedBlocks allBlocks = do
  isa <- askISA
  let symSuccIdx = LBSM.successorMap isa allBlocks
  T.traverse (T.traverse (addExplicitFallthrough mem symSuccIdx)) modifiedBlocks

addExplicitFallthrough :: (Monad m, MM.MemWidth (MM.ArchAddrWidth arch))
                       => MM.Memory (MM.ArchAddrWidth arch)
                       -> LBSM.SuccessorMap arch
                       -> SymbolicPair arch
                       -> RewriterT arch m (FallthroughPair arch)
addExplicitFallthrough mem symSucIdx (SymbolicPair (LayoutPair cb sb status)) = do
  -- quick sanity check
  unless (changeable status) . error $ printf
    "Attempted to modify an immutable block (at address %s) by adding explicit fallthrough information"
    (show (basicBlockAddress cb))

  isa <- askISA
  -- We pass in a fake relative address since we don't need the resolution of
  -- relative jumps.  We just need the type of jump.
  let lift = if isUnconditionalJT (isaJumpType isa lastInsn mem fakeAddress)
        then noFallthrough
        else case LBSM.lookupSuccessor symSucIdx sb of
               Just sucAddr -> addFallthrough sucAddr
               Nothing -> error (printf "Expected a successor block for symbolic block %s (derived from block %s)"
                               (show (basicBlockAddress sb))
                               (show (basicBlockAddress cb)))
  return (FallthroughPair (LayoutPair cb (lastInstructionFallthrough lift sb) Modified))
  where
    -- We explicitly match on all constructor patterns so that if/when new ones
    -- are added this will break instead of having some default case that does
    -- (potentially) the wrong thing on the new cases.
    isUnconditionalJT (Return       cond    ) = isUnconditionalCond cond
    isUnconditionalJT (IndirectJump cond    ) = isUnconditionalCond cond
    isUnconditionalJT (AbsoluteJump cond _  ) = isUnconditionalCond cond
    isUnconditionalJT (RelativeJump cond _ _) = isUnconditionalCond cond
    isUnconditionalJT (IndirectCall         ) = False
    isUnconditionalJT (DirectCall {}        ) = False
    isUnconditionalJT (NoJump               ) = False

    isUnconditionalCond Unconditional = True
    isUnconditionalCond Conditional   = False

    fakeAddress = concreteFromAbsolute 0
    lastInsn
      | null (basicBlockInstructions sb) = L.error (printf "Empty block for symbolic block %s (derived from block %s)"
                                                           (show (basicBlockAddress sb))
                                                           (show (basicBlockAddress cb)))
      | otherwise = projectInstruction $ last (basicBlockInstructions sb)

lastInstructionFallthrough ::
  (TaggedInstruction arch (InstructionAnnotation arch) -> SymbolicFallthrough arch (InstructionAnnotation arch)) ->
  (SymbolicBlock arch -> FallthroughBlock arch)
lastInstructionFallthrough fallthrough sb = sb { basicBlockInstructions = insns } where
  insns = case basicBlockInstructions sb of
    [] -> []
    is -> map noFallthrough (init is) ++ [fallthrough (last is)]

buildAddressHeap :: (MM.MemWidth (MM.ArchAddrWidth arch), Monad m, Typeable arch)
                 => TrampolineStrategy
                 -> ConcreteAddress arch
                 -> [FallthroughPair arch]
                 -> RewriterT arch m (AddressHeap arch, [FallthroughPair arch])
buildAddressHeap strat startAddr blocks = do
  functionToBlocks <- gets (functionBlocks . rwsStats)
  isa <- askISA
  let dummyJump = isaMakeRelativeJumpTo  isa startAddr startAddr
      jumpSize = fromIntegral $ sum (map (isaInstructionSize isa) dummyJump)
      (blockToFunctions, disjointFunctions) = findRelocatableFunctionBlocks functionToBlocks
      smallBlocks = S.fromList
        [ addr
        | FallthroughPair (LayoutPair cb@(BasicBlock _ addr) _ _) <- blocks
        , concreteBlockSize isa cb < jumpSize
        ]
      relocatedFunctions = findRelocatedFunctions blockToFunctions functionToBlocks blocks
      redirectableFunctions = (disjointFunctions S.\\ smallBlocks) `S.intersection` relocatedFunctions
      pRedirect = case strat of
        AlwaysTrampoline -> const True
        WholeFunctionTrampoline -> \addr -> case M.lookup addr blockToFunctions of
          Just [entryPoint] -> entryPoint == addr || entryPoint `S.notMember` redirectableFunctions
          _ -> True
      (preh, blocks') = F.foldl' (addOriginalBlock isa jumpSize pRedirect) (M.empty, []) blocks
  h <- coalesceHeap preh
  return (h, blocks')

-- | Given a mapping from function entry points to the blocks that participate
-- in that function, produce two things:
--
-- 1. An inverse mapping, from blocks to the function entry points of any
--    functions they participate in.
-- 2. The set of entry points of those functions whose set of participating
--    blocks are disjoint from all other functions'.
findRelocatableFunctionBlocks ::
  M.Map (ConcreteAddress arch) [ConcreteAddress arch] ->
  (M.Map (ConcreteAddress arch) [ConcreteAddress arch], Set (ConcreteAddress arch))
findRelocatableFunctionBlocks m = go M.empty (M.keysSet m) . concat . M.mapWithKey (map . (,)) $ m where
  go entryPointMap disjointFunctions [] = (entryPointMap, disjointFunctions)
  go epm df ((entryPoint, blockAddr) : rest) = case M.lookup blockAddr epm of
    Nothing -> go (M.insert blockAddr [entryPoint] epm) df rest
    Just entryPoints -> go
      (M.insert blockAddr (entryPoint:entryPoints) epm)
      (S.delete entryPoint df)
      rest

-- | Figure out which functions have had all their blocks modified. Arguments are:
--
-- * A mapping from basic block addresses to the entry points of the functions
--   those blocks participate in.
-- * A mapping from entry points of functions to the blocks that participate in
--   that function.
-- * All the blocks that have been modified (and maybe some that haven't been
--   modified).
--
-- Returns the entry points of the completely modified functions.
findRelocatedFunctions ::
  M.Map (ConcreteAddress arch) [ConcreteAddress arch] ->
  M.Map (ConcreteAddress arch) [ConcreteAddress arch] ->
  [FallthroughPair arch] ->
  S.Set (ConcreteAddress arch)
findRelocatedFunctions entryPointMap initBlockMap = go (S.fromList <$> initBlockMap) where
  go unrelocatedBlockMap [] = M.keysSet (M.filter S.null unrelocatedBlockMap)
  go ubm (FallthroughPair (LayoutPair (BasicBlock _ addr) _ status) : pairs)
    | changed status = case M.lookup addr entryPointMap of
      Nothing -> go ubm pairs
      Just entryPoints -> go (foldr (M.adjust (S.delete addr)) ubm entryPoints) pairs
    | otherwise = go ubm pairs

-- | A pre-address heap stores blocks of free space in a format that's
-- efficient for coalescing neighboring blocks, but inefficient for finding the
-- largest block. (By contrast, an @'AddressHeap' arch@ is inefficient for
-- coalescing blocks but efficient for finding the largest block.)
--
-- See also 'coalesceHeap' for performing this coalescing operation and
-- converting to an 'AddressHeap'.
type PreAddressHeap arch = M.Map (ConcreteAddress arch) Int

data OverlappingFreeBlocks arch
  = OverlappingFreeBlocks (ConcreteAddress arch) Int (ConcreteAddress arch) Int
  deriving (Eq, Ord, Typeable)
deriving instance MM.MemWidth (MM.ArchAddrWidth arch) => Show (OverlappingFreeBlocks arch)

instance (MM.MemWidth (MM.ArchAddrWidth arch), Typeable arch) => Exception (OverlappingFreeBlocks arch)

coalesceHeap ::
  (Monad m, MM.MemWidth (MM.ArchAddrWidth arch), Typeable arch) =>
  PreAddressHeap arch ->
  RewriterT arch m (AddressHeap arch)
coalesceHeap = go . M.toAscList where
  go ((addr, len):pairs@((addr', len'):rest)) = case compare nextAddr addr' of
    LT -> (H.insert (H.Entry (Down len) addr) $!) <$> go pairs
    EQ -> go ((addr, len+len'):rest)
    GT -> throwError (SomeException (OverlappingFreeBlocks addr len addr' len'))
    where nextAddr = addressAddOffset addr (fromIntegral len)
  go [(addr, len)] = return (H.singleton (H.Entry (Down len) addr))
  go [] = return H.empty

-- | Add the available space in a 'ConcreteBlock' to the heap
--
-- We subtract out the space required to redirect execution of the block to its
-- instrumented version.
--
-- NOTE: We only add blocks that have been *modified*.  If a block is
-- unmodified, overwriting it would throw away code, as we don't lay out
-- duplicates of unmodified blocks.
addOriginalBlock :: (MM.MemWidth (MM.ArchAddrWidth arch))
                 => ISA arch
                 -> Word64
                 -> (ConcreteAddress arch -> Bool)
                 -> (PreAddressHeap arch, [FallthroughPair arch])
                 -> FallthroughPair arch
                 -> (PreAddressHeap arch, [FallthroughPair arch])
addOriginalBlock isa jumpSize pRedirect (h, pairs) pair@(FallthroughPair (LayoutPair cb sb status))
  | status == Modified && not (pRedirect origAddr) =
    (M.insert origAddr (fromIntegral bsize) h, FallthroughPair (LayoutPair cb sb Subsumed) : pairs)
  | bsize > jumpSize && status == Modified =
    (M.insert addr spaceSize h, pair:pairs)
  | otherwise = (h, pair:pairs)
  where
    bsize     = concreteBlockSize isa cb
    spaceSize :: Int
    spaceSize = fromIntegral (bsize - jumpSize)
    addr      = origAddr `addressAddOffset` fromIntegral jumpSize
    origAddr  = basicBlockAddress cb

randomOrder :: RandomSeed -> [a] -> [a]
randomOrder seed initial = runST $ do
  gen      <- MWC.initialize seed
  vec      <- V.thaw (V.fromList initial)
  finalVec <- go gen 0 vec >>= V.freeze
  return (V.toList finalVec)
  where
  -- This looks like a bit of a mess, but it's actually just the fisher-yates
  -- inplace shuffle.
  go :: MWC.GenST s -> Int -> MV.STVector s a -> ST s (MV.STVector s a)
  go g i vec
    | i >= MV.length vec - 1 = return vec
    | otherwise = do
      j <- MWC.uniformR (i,MV.length vec-1) g
      MV.swap vec i j
      go g (i+1) vec

{- Note [Design]

The idea is that we want to re-use space in the original basic blocks to hold
new (instrumented) basic blocks.  We'll create a heap of all of the space
available in the original blocks and allocate that space to instrumented blocks.
Any instrumented blocks that cannot fit will be added to a new section.

Before we start, we need to augment each basic block that has a fallthrough case
with an unconditional jump to the correct block.  This means adding an
instruction to the end with a symbolic target.  We need to pre-process all
blocks to find fallthrough cases.

Steps:

1) Add all of the original basic blocks to the heap, subtracting the space
   required to add the redirection jump at the beginning.  If an original block
   is smaller than the size of a redirection jump, don't bother to add it.

2) Order the instrumented blocks by their size in bytes (with the largest blocks
   first).

3) Pull out the largest space available in the heap.  If it can fit the current
   instrumented block (plus space for an unconditional jump), allocate that
   address and return unused storage to the heap.



-}
