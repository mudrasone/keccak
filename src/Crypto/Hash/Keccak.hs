module Crypto.Hash.Keccak where

import           Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import           Data.Word

type State = [[Word64]]

emptyState :: State
emptyState = replicate 5 (replicate 5 0)

-- truncated when w is smaller than 64
roundConstants :: [Word64]
roundConstants = [ 0x0000000000000001, 0x0000000000008082, 0x800000000000808A
                 , 0x8000000080008000, 0x000000000000808B, 0x0000000080000001
                 , 0x8000000080008081, 0x8000000000008009, 0x000000000000008A
                 , 0x0000000000000088, 0x0000000080008009, 0x000000008000000A
                 , 0x000000008000808B, 0x800000000000008B, 0x8000000000008089
                 , 0x8000000000008003, 0x8000000000008002, 0x8000000000000080
                 , 0x000000000000800A, 0x800000008000000A, 0x8000000080008081
                 , 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
                 ]

rotationConstants :: [[Int]]
rotationConstants = [ [  0, 36,  3, 41, 18 ]
                    , [  1, 44, 10, 45,  2 ]
                    , [ 62,  6, 43, 15, 61 ]
                    , [ 28, 55, 25, 21, 56 ]
                    , [ 27, 20, 39,  8, 14 ]
                    ]


paddingKeccak :: BS.ByteString -> [Word8]
paddingKeccak = multiratePadding 0x1


paddingSha3 :: BS.ByteString -> [Word8]
paddingSha3 = multiratePadding 0x6


multiratePadding :: Word -> BS.ByteString -> [Word8]
multiratePadding pad input = BS.unpack . BS.append input $ if padlen == 1
    then BS.pack [0x81]
    else BS.pack $ 0x01 : replicate (padlen - 2) 0x00 ++ [0x80]
    where bitRateBytes = 136
          -- TODO: modulo bitRateBytes?
          usedBytes = BS.length input
          padlen = bitRateBytes - mod usedBytes bitRateBytes

-- r (bitrate) = 1088
-- c (capacity) = 512
keccak256 :: BS.ByteString -> BS.ByteString
keccak256 = squeeze 32 . absorb . toBlocks 136 . paddingKeccak

-- Sized inputs to this?
toBlocks :: Int -> [Word8] -> [[Word64]]
toBlocks _ [] = []
toBlocks sizeInBytes input = let (a, b) = splitAt sizeInBytes input
                             in toLanes a : toBlocks sizeInBytes b
    where toLanes :: [Word8] -> [Word64]
          toLanes [] = []
          toLanes octets = let (a, b) = splitAt 8 octets
                           in toLane a : toLanes b
          toLane :: [Word8] -> Word64
          toLane octets = foldl1 xor $ zipWith (\offset octet -> shiftL (fromIntegral octet) (offset * 8)) [0..7] octets


--   for each block Pi in P
--     S[x,y] = S[x,y] xor Pi[x+5*y],          for (x,y) such that x+5*y < r/w
--     S = Keccak-f[r+c](S)
--     TODO support `input` larger than single block
absorb :: [[Word64]] -> State
absorb = foldl absorbBlock emptyState

absorbBlock :: State -> [Word64] -> State
absorbBlock state input = keccakF state'
    where r = 1088
          w = 64
          state' = [ [ if x + 5 * y < div r w
                            then ((state !! x) !! y) `xor` (input !! (x + 5 * y))
                            else (state !! x) !! y
                        | y <- [0..4]  ]
                            | x <- [0..4] ]


--  # Squeezing phase
--  Z = empty string
--  while output is requested
--    Z = Z || S[x,y],                        for (x,y) such that x+5*y < r/w
--    S = Keccak-f[r+c](S)
--    TODO handle longer outputs
squeeze :: Int -> State -> BS.ByteString
squeeze len = BS.pack . take len . stateToBytes
    where comma = 44


stateToBytes :: State -> [Word8]
stateToBytes state = concat [ laneToBytes (state !! x !!  y) | y <- [0..4] , x <- [0..4] ]


laneToBytes :: Word64 -> [Word8]
laneToBytes word = fmap (\x -> fromIntegral (shiftR word (x * 8) .&. 0xFF)) [0..7]


keccakF :: State -> State
keccakF state = foldl (\s r -> iota r . chi . rhoPi $ theta s) state [0 .. (rounds - 1)]
    where rounds = 24

--   # θ step
--   C[x] = A[x,0] xor A[x,1] xor A[x,2] xor A[x,3] xor A[x,4],   for x in 0…4
--   D[x] = C[x-1] xor rot(C[x+1],1),                             for x in 0…4
--   A[x,y] = A[x,y] xor D[x],                           for (x,y) in (0…4,0…4)
theta :: State -> State
theta state = [ [ ((state !! x) !! y) `xor` (d !! x)
                    | y <- [0..4] ]
                        | x <- [0..4] ]
    where c = [ foldl1 xor [ (state !! x) !! y
                    | y <- [0..4] ]
                        | x <- [0..4] ]
          d = [ c !! ((x - 1) `mod` 5) `xor` rotateL (c !! ((x + 1) `mod` 5)) 1 | x <- [0..4] ]


--   # ρ and π steps
--   B[y,2*x+3*y] = rot(A[x,y], r[x,y]),                 for (x,y) in (0…4,0…4)
rhoPi :: State -> [[Word64]]
rhoPi state = fmap (fmap rotFunc) [ [ ((x + 3 * y) `mod` 5, x) | y <- [0..4] ] | x <- [0..4] ]
    where rotFunc (x, y) = rotateL ((state !! x) !! y) ((rotationConstants !! x) !! y)


--   # χ step
--   A[x,y] = B[x,y] xor ((not B[x+1,y]) and B[x+2,y]),  for (x,y) in (0…4,0…4)
chi :: [[Word64]] -> State
chi b = [ [ ((b !! x) !! y) `xor` (complement ((b !! ((x + 1) `mod` 5)) !! y) .&. ((b !! ((x + 2) `mod` 5)) !! y))
                    | y <- [0..4] ]
                        | x <- [0..4] ]


--   # ι step
--   A[0,0] = A[0,0] xor RC
--   TODO Data.List.Lens
iota :: Int -> State -> State
iota round ((first : rest) : restRows) = (xor (roundConstants !! round) first : rest) : restRows
