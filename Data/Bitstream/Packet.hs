{-# LANGUAGE
    BangPatterns
  , EmptyDataDecls
  , FlexibleContexts
  , FlexibleInstances
  , RankNTypes
  , UnboxedTuples
  , UnicodeSyntax
  #-}
module Data.Bitstream.Packet
    ( Left
    , Right

    , Packet

    , full

    , fromOctet
    , toOctet

    , packetLToR
    , packetRToL
    )
    where
import Data.Bitstream.Generic
import Data.Bits
import qualified Data.List.Stream as L
import Data.Word
import Foreign.Storable
import Prelude hiding ((!!), drop, init, last, length, null, take, tail)
import Prelude.Unicode

data Left
data Right

data Packet d = Packet {-# UNPACK #-} !Int
                       {-# UNPACK #-} !Word8
    deriving (Eq)

instance Storable (Packet d) where
    sizeOf _  = 2
    alignment = sizeOf
    {-# INLINE peek #-}
    peek p
        = do n ← peekByteOff p 0
             o ← peekByteOff p 1
             return $! Packet (fromIntegral (n ∷ Word8)) o
    {-# INLINE poke #-}
    poke p (Packet n o)
        = do pokeByteOff p 0 (fromIntegral n ∷ Word8)
             pokeByteOff p 1 o

instance Show (Packet Left) where
    {-# INLINEABLE show #-}
    show (Packet n0 o0)
        = L.concat
          [ "["
          , L.unfoldr go (n0, o0)
          , "←]"
          ]
        where
          {-# INLINE go #-}
          go (0, _) = Nothing
          go (n, o)
              | o `testBit` (n-1) = Just ('1', (n-1, o))
              | otherwise         = Just ('0', (n-1, o))

instance Show (Packet Right) where
    {-# INLINEABLE show #-}
    show (Packet n0 o0)
        = L.concat
          [ "[→"
          , L.unfoldr go (n0, o0)
          , "]"
          ]
        where
          {-# INLINE δ #-}
          δ ∷ Int
          δ = 7 - n0
          {-# INLINE go #-}
          go (0, _) = Nothing
          go (n, o)
              | o `testBit` (n+δ) = Just ('1', (n-1, o))
              | otherwise         = Just ('0', (n-1, o))

instance Ord (Packet Left) where
    {-# INLINEABLE compare #-}
    (Packet nx ox) `compare` (Packet ny oy)
        = compare
          (reverseBits ox `shiftR` (8-nx))
          (reverseBits oy `shiftR` (8-ny))

instance Ord (Packet Right) where
    {-# INLINE compare #-}
    (Packet nx ox) `compare` (Packet ny oy)
        = compare
          (ox `shiftR` (8-nx))
          (oy `shiftR` (8-ny))

instance Bitstream (Packet Left) where
    {-# INLINE [0] pack #-}
    pack xs0 = case consume 0 0 xs0 of
                (# n, o #) → Packet n o
        where
          {-# INLINE consume #-}
          consume !n !o []      = (# n, o #)
          consume !n !o !(x:xs)
              | n < 8     = if x
                            then consume (n+1) (o `setBit` n) xs
                            else consume (n+1)  o             xs
              | otherwise = error "packet overflow"

    {-# INLINE [0] unpack #-}
    unpack (Packet n o) = L.unfoldr produce 0
        where
          {-# INLINE produce #-}
          produce ∷ Int → Maybe (Bool, Int)
          produce !p
              | p < n     = Just (o `testBit` p, p+1)
              | otherwise = Nothing

    {-# INLINE empty #-}
    empty = Packet 0 0

    {-# INLINE singleton #-}
    singleton True  = Packet 1 1
    singleton False = Packet 1 0

    {-# INLINE cons #-}
    cons b p
        | full p    = packetOverflow
        | otherwise = b `unsafeConsL` p

    {-# INLINE snoc #-}
    snoc p b
        | full p    = packetOverflow
        | otherwise = p `unsafeSnocL` b

    {-# INLINE append #-}
    append (Packet nx ox) (Packet ny oy)
        | nx + ny > 8 = packetOverflow
        | otherwise   = Packet (nx + ny) (ox .|. (oy `shiftL` nx))

    {-# INLINE head #-}
    head (Packet 0 _) = packetEmpty
    head (Packet _ o) = o `testBit` 0

    {-# INLINE uncons #-}
    uncons (Packet 0 _) = Nothing
    uncons (Packet n o) = Just ( o `testBit` 0
                               , Packet (n-1) (o `shiftR` 1) )

    {-# INLINE last #-}
    last (Packet 0 _) = packetEmpty
    last (Packet n o) = o `testBit` (n-1)

    {-# INLINE tail #-}
    tail (Packet 0 _) = packetEmpty
    tail (Packet n o) = Packet (n-1) (o `shiftR` 1)

    {-# INLINE init #-}
    init (Packet 0 _) = packetEmpty
    init (Packet n o) = Packet (n-1) o

    {-# INLINE null #-}
    null (Packet 0 _) = True
    null _            = False

    {-# INLINE length #-}
    {-# SPECIALISE length ∷ Packet Left → Int #-}
    length (Packet n _) = fromIntegral n

    {-# INLINE reverse #-}
    reverse (Packet n o)
        = Packet n (reverseBits o `shiftR` (8-n))

    {-# INLINE foldr #-}
    foldr = foldrPacket

    {-# INLINE foldr1 #-}
    foldr1 = foldr1Packet

    {-# INLINE and #-}
    and (Packet n o) = (0xff `shiftR` (8-n)) ≡ o

    {-# INLINE or #-}
    or (Packet _ o) = o ≢ 0

    {-# INLINE replicate #-}
    {-# SPECIALISE replicate ∷ Int → Bool → Packet Left #-}
    replicate n b
        | n > 8     = packetOverflow
        | otherwise = let o = if b
                              then 0xFF `shiftR` (8 - fromIntegral n)
                              else 0
                      in
                        Packet (fromIntegral n) o

    {-# INLINEABLE unfoldrN #-}
    {-# SPECIALISE
        unfoldrN ∷ Int → (β → Maybe (Bool, β)) → β → (Packet Left, Maybe β) #-}
    unfoldrN n0 f β0
        | n0 > 8    = packetOverflow
        | otherwise = loop_unfoldrN n0 β0 (∅)
        where
          {-# INLINE loop_unfoldrN #-}
          loop_unfoldrN 0 β α = (α, Just β)
          loop_unfoldrN n β α
              = case f β of
                  Nothing      → (α, Nothing)
                  Just (a, β') → loop_unfoldrN (n-1) β' (α `unsafeSnocL` a)

    {-# INLINE take #-}
    {-# SPECIALISE take ∷ Int → Packet Left → Packet Left #-}
    take l (Packet n o)
        | l ≤ 0      = (∅)
        | otherwise
            = let n' = fromIntegral (min (fromIntegral n) l)
                  o' = (0xFF `shiftR` (8-n')) .&. o
              in
                Packet n' o'

    {-# INLINE drop #-}
    {-# SPECIALISE drop ∷ Int → Packet Left → Packet Left #-}
    drop l (Packet n o)
        | l ≤ 0      = Packet n o
        | otherwise
            = let d  = fromIntegral (min (fromIntegral n) l)
                  n' = n-d
                  o' = o `shiftR` d
              in
                Packet n' o'

    {-# INLINE takeWhile #-}
    takeWhile = takeWhilePacket

    {-# INLINE dropWhile #-}
    dropWhile = dropWhilePacket

    {-# INLINE (!!) #-}
    {-# SPECIALISE (!!) ∷ Packet Left → Int → Bool #-}
    (Packet n o) !! i
        | i < 0 ∨ i ≥ fromIntegral n = indexOutOfRange i
        | otherwise                  = o `testBit` fromIntegral i

instance Bitstream (Packet Right) where
    {-# INLINE [0] pack #-}
    pack xs0 = case consume 0 0 xs0 of
                 (# n, o #) → Packet n o
        where
          {-# INLINE consume #-}
          consume !n !o []      = (# n, o #)
          consume !n !o !(x:xs)
              | n < 8     = if x
                            then consume (n+1) (o `setBit` (7-n)) xs
                            else consume (n+1)  o                 xs
              | otherwise = error "packet overflow"

    {-# INLINE [0] unpack #-}
    unpack (Packet n b) = L.unfoldr produce 0
        where
          {-# INLINE produce #-}
          produce ∷ Int → Maybe (Bool, Int)
          produce !p
              | p < n     = Just (b `testBit` (7-p), p+1)
              | otherwise = Nothing

    {-# INLINE empty #-}
    empty = Packet 0 0

    {-# INLINE singleton #-}
    singleton True  = Packet 1 0x80
    singleton False = Packet 1 0x00

    {-# INLINE cons #-}
    cons b p
        | full p    = packetOverflow
        | otherwise = b `unsafeConsR` p

    {-# INLINE snoc #-}
    snoc p b
        | full p    = packetOverflow
        | otherwise = p `unsafeSnocR` b

    {-# INLINE append #-}
    append (Packet nx ox) (Packet ny oy)
        | nx + ny > 8 = packetOverflow
        | otherwise   = Packet (nx + ny) (ox .|. (oy `shiftR` nx))

    {-# INLINE head #-}
    head (Packet 0 _) = packetEmpty
    head (Packet _ o) = o `testBit` 7

    {-# INLINE uncons #-}
    uncons (Packet 0 _) = Nothing
    uncons (Packet n o) = Just ( o `testBit` 7
                               , Packet (n-1) (o `shiftL` 1) )

    {-# INLINE last #-}
    last (Packet 0 _) = packetEmpty
    last (Packet n o) = o `testBit` (8-n)

    {-# INLINE tail #-}
    tail (Packet 0 _) = packetEmpty
    tail (Packet n o) = Packet (n-1) (o `shiftL` 1)

    {-# INLINE init #-}
    init (Packet 0 _) = packetEmpty
    init (Packet n o) = Packet (n-1) o

    {-# INLINE null #-}
    null (Packet 0 _) = True
    null _            = False

    {-# INLINE length #-}
    {-# SPECIALISE length ∷ Packet Right → Int #-}
    length (Packet n _) = fromIntegral n

    {-# INLINE reverse #-}
    reverse (Packet n o)
        = Packet n (reverseBits o `shiftL` (8-n))

    {-# INLINE foldr #-}
    foldr = foldrPacket

    {-# INLINE foldr1 #-}
    foldr1 = foldr1Packet

    {-# INLINE and #-}
    and (Packet n o) = (0xff `shiftL` (8-n)) ≡ o

    {-# INLINE or #-}
    or (Packet _ o) = o ≢ 0

    {-# INLINE replicate #-}
    {-# SPECIALISE replicate ∷ Int → Bool → Packet Right #-}
    replicate n b
        | n > 8     = packetOverflow
        | otherwise = let o = if b
                              then 0xFF `shiftL` (8 - fromIntegral n)
                              else 0
                      in
                        Packet (fromIntegral n) o

    {-# INLINEABLE unfoldrN #-}
    {-# SPECIALISE
        unfoldrN ∷ Int → (β → Maybe (Bool, β)) → β → (Packet Right, Maybe β) #-}
    unfoldrN n0 f β0
        | n0 > 8    = packetOverflow
        | otherwise = loop_unfoldrN n0 β0 (∅)
        where
          {-# INLINE loop_unfoldrN #-}
          loop_unfoldrN 0 β α = (α, Just β)
          loop_unfoldrN n β α
              = case f β of
                  Nothing      → (α, Nothing)
                  Just (a, β') → loop_unfoldrN (n-1) β' (α `unsafeSnocR` a)

    {-# INLINE take #-}
    {-# SPECIALISE take ∷ Int → Packet Right → Packet Right #-}
    take l (Packet n o)
        | l ≤ 0      = (∅)
        | otherwise
            = let n' = fromIntegral (min (fromIntegral n) l)
                  o' = (0xFF `shiftL` (8-n')) .&. o
              in
                Packet n' o'

    {-# INLINE drop #-}
    {-# SPECIALISE drop ∷ Int → Packet Right → Packet Right #-}
    drop l (Packet n o)
        | l ≤ 0      = Packet n o
        | otherwise
            = let d  = fromIntegral (min (fromIntegral n) l)
                  n' = n-d
                  o' = o `shiftL` d
              in
                Packet n' o'

    {-# INLINE takeWhile #-}
    takeWhile = takeWhilePacket

    {-# INLINE dropWhile #-}
    dropWhile = dropWhilePacket

    {-# INLINE (!!) #-}
    {-# SPECIALISE (!!) ∷ Packet Right → Int → Bool #-}
    (Packet n o) !! i
        | i < 0 ∨ i ≥ fromIntegral n = indexOutOfRange i
        | otherwise                  = o `testBit` (7 - fromIntegral i)

{-# INLINE packetEmpty #-}
packetEmpty ∷ α
packetEmpty = error "Data.Bitstream.Packet: packet is empty"

{-# INLINE packetOverflow #-}
packetOverflow ∷ α
packetOverflow = error "Data.Bitstream.Packet: packet size overflow"

{-# INLINE indexOutOfRange #-}
indexOutOfRange ∷ Integral n ⇒ n → α
indexOutOfRange n = error ("Data.Bitstream.Packet: index out of range: " L.++ show n)

{-# INLINE full #-}
full ∷ Packet d → Bool
full (Packet 8 _) = True
full _            = False

{-# INLINE fromOctet #-}
fromOctet ∷ Word8 → Packet d
fromOctet = Packet 8

{-# INLINE toOctet #-}
toOctet ∷ Packet d → Word8
toOctet (Packet _ o) = o

{-# INLINE unsafeConsL #-}
unsafeConsL ∷ Bool → Packet Left → Packet Left
unsafeConsL True  (Packet n o) = Packet (n+1) ((o `shiftL` 1) .|. 1)
unsafeConsL False (Packet n o) = Packet (n+1)  (o `shiftL` 1)

{-# INLINE unsafeConsR #-}
unsafeConsR ∷ Bool → Packet Right → Packet Right
unsafeConsR True  (Packet n o) = Packet (n+1) ((o `shiftR` 1) .|. 0x80)
unsafeConsR False (Packet n o) = Packet (n+1)  (o `shiftR` 1)

{-# INLINE unsafeSnocL #-}
unsafeSnocL ∷ Packet Left → Bool → Packet Left
unsafeSnocL (Packet n o) True  = Packet (n+1) (o `setBit` n)
unsafeSnocL (Packet n o) False = Packet (n+1)  o

{-# INLINE unsafeSnocR #-}
unsafeSnocR ∷ Packet Right → Bool → Packet Right
unsafeSnocR (Packet n o) True  = Packet (n+1) (o `setBit` (7-n))
unsafeSnocR (Packet n o) False = Packet (n+1)  o

{-# INLINE packetLToR #-}
packetLToR ∷ Packet Left → Packet Right
packetLToR (Packet n o) = Packet n (o `shiftL` (8-n))

{-# INLINE packetRToL #-}
packetRToL ∷ Packet Right → Packet Left
packetRToL (Packet n o) = Packet n (o `shiftR` (8-n))

{-# INLINE reverseBits #-}
reverseBits ∷ Word8 → Word8
reverseBits x
    = ((x .&. 0x01) `shiftL` 7) .|.
      ((x .&. 0x02) `shiftL` 5) .|.
      ((x .&. 0x04) `shiftL` 3) .|.
      ((x .&. 0x08) `shiftL` 1) .|.
      ((x .&. 0x10) `shiftR` 1) .|.
      ((x .&. 0x20) `shiftR` 3) .|.
      ((x .&. 0x40) `shiftR` 5) .|.
      ((x .&. 0x80) `shiftR` 7)

{-# INLINEABLE foldrPacket #-}
foldrPacket ∷ Bitstream (Packet d) ⇒ (Bool → β → β) → β → Packet d → β
foldrPacket f β0 α0 = go β0 α0
    where
      {-# INLINE go #-}
      go β α
          | null α    = β
          | otherwise = go (f (last α) β) (init α)

{-# INLINE foldr1Packet #-}
foldr1Packet ∷ Bitstream (Packet d) ⇒ (Bool → Bool → Bool) → Packet d → Bool
foldr1Packet f α
    | null α    = packetEmpty
    | otherwise = foldrPacket f (last α) (init α)

{-# INLINEABLE takeWhilePacket #-}
takeWhilePacket ∷ Bitstream (Packet d) ⇒ (Bool → Bool) → Packet d → Packet d
takeWhilePacket f α = take (go 0 ∷ Int) α
    where
      {-# INLINE go #-}
      go i | i ≥ length α = i
           | f (α !! i)   = go (i+1)
           | otherwise    = i

{-# INLINEABLE dropWhilePacket #-}
dropWhilePacket ∷ Bitstream (Packet d) ⇒ (Bool → Bool) → Packet d → Packet d
dropWhilePacket f α = drop (go 0 ∷ Int) α
    where
      {-# INLINE go #-}
      go i | i ≥ length α = i
           | f (α !! i)   = go (i+1)
           | otherwise    = i
